import React, { useRef, useState } from 'react';
import { newIdempotencyKey, recordPayment } from './api.js';
import { formatDate, formatINR } from './format.js';

const TIMEOUT_MS = 30000;

const TITLES = {
  AMOUNT_MISMATCH: 'The amount does not match',
  NOTHING_DUE: 'Nothing is due on this policy yet',
  REVIVAL_WINDOW_EXPIRED: 'This policy can no longer be revived',
  POLICY_NOT_SERVICEABLE: 'This policy needs Operations',
  DUE_DATE_CHANGED: 'Someone else has just paid this instalment',
  POLICY_BUSY: 'Another payment on this policy is in progress',
  INSTALMENT_ALREADY_PAID: 'Our records disagree about this instalment',
  IDEMPOTENCY_KEY_REUSED: 'This payment clashes with an earlier one',
  INVALID_REQUEST: 'Please check the details',
};

const UNKNOWN_OUTCOME =
  'We could not confirm whether this payment was recorded. Do not take the money again. ' +
  'Press “Record payment” once more: it is safe to retry and will never charge twice.';

/**
 * Double submission is blocked three ways:
 *  - inFlight (a ref, so it is set synchronously) stops a second click or
 *    Enter press in the same tick, before React has re-rendered;
 *  - the fieldset is disabled while the request is running;
 *  - the Idempotency-Key is kept for every retry of the same attempt, so even
 *    a request the browser resends is recorded once by the server.
 *
 * A new key is made when the clerk changes what they are paying (amount or
 * channel), after a success, and after a definite rejection. It is kept when
 * the outcome is unknown (network error, timeout, 5xx) or the policy was busy.
 */
export default function PaymentForm({ policy, onRecorded, onStale }) {
  const [amount, setAmount] = useState('');
  const [channel, setChannel] = useState('BRANCH');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState(null);
  const inFlight = useRef(false);
  const attemptKey = useRef(null);

  function startNewAttempt() {
    attemptKey.current = null;
  }

  async function onSubmit(e) {
    e.preventDefault();
    if (inFlight.current) return;

    const text = amount.trim().replace(/,/g, '');
    if (!/^\d{1,10}(\.\d{1,2})?$/.test(text) || Number(text) <= 0) {
      setError({ code: 'INVALID_REQUEST', field: 'amount', message: 'Enter the amount received in rupees, for example 12500 or 12500.50.' });
      return;
    }

    inFlight.current = true;
    setSubmitting(true);
    setError(null);
    if (!attemptKey.current) attemptKey.current = newIdempotencyKey();

    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
    try {
      const result = await recordPayment(
        policy.id,
        { amount: Number(text), channel, dueDate: policy.nextDueDate },
        attemptKey.current,
        ctrl.signal,
      );
      startNewAttempt();
      setAmount('');
      onRecorded(result);
    } catch (err) {
      if (err.name === 'AbortError') {
        setError({ code: 'TIMEOUT', message: UNKNOWN_OUTCOME });
      } else if (err.outcomeUnknown) {
        setError({ code: err.code, message: UNKNOWN_OUTCOME + ` (${err.message})` });
      } else {
        if (err.code !== 'POLICY_BUSY') startNewAttempt();
        setError({ code: err.code, field: err.field, message: err.message });
        if (err.code === 'DUE_DATE_CHANGED') onStale();
      }
    } finally {
      clearTimeout(timer);
      inFlight.current = false;
      setSubmitting(false);
    }
  }

  const amountError = error && error.field === 'amount';

  return (
    <form className="payment-form" onSubmit={onSubmit} noValidate>
      <h2>Record payment</h2>

      <p className="due-line">
        {policy.instalmentsPayable > 1 ? (
          <>
            Revival: <strong>{policy.instalmentsPayable} instalments</strong> of {formatINR(policy.premiumAmount)} ={' '}
            <strong>{formatINR(policy.amountPayable)}</strong>, from {formatDate(policy.nextDueDate)}
          </>
        ) : (
          <>
            Instalment due {formatDate(policy.nextDueDate)}: <strong>{formatINR(policy.amountPayable)}</strong>
          </>
        )}
      </p>

      <fieldset disabled={submitting}>
        <div className="field">
          <label htmlFor="amount">Amount received (₹)</label>
          <input
            id="amount"
            name="amount"
            inputMode="decimal"
            autoComplete="off"
            value={amount}
            aria-invalid={amountError || undefined}
            aria-describedby={amountError ? 'payment-error' : undefined}
            onChange={(e) => { setAmount(e.target.value); startNewAttempt(); }}
          />
        </div>

        <div className="field">
          <label htmlFor="channel">Channel</label>
          <select id="channel" value={channel} onChange={(e) => { setChannel(e.target.value); startNewAttempt(); }}>
            <option value="BRANCH">Branch counter</option>
            <option value="AGENT">Agent</option>
            <option value="ONLINE">Online</option>
            <option value="AUTO-DEBIT">Auto-debit</option>
          </select>
        </div>

        <button type="submit" className="primary">
          {submitting ? 'Recording…' : 'Record payment'}
        </button>
      </fieldset>

      {error && (
        <div id="payment-error" className="alert alert-error" role="alert">
          <strong>{TITLES[error.code] || 'Payment not recorded'}</strong>
          <p>{error.message}</p>
        </div>
      )}

    </form>
  );
}
