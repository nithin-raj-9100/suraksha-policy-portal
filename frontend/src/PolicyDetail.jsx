import React, { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { getPolicy } from './api.js';
import PaymentForm from './PaymentForm.jsx';
import StatusBadge from './StatusBadge.jsx';
import { formatDate, formatINR, formatTimestampIST, statusDetail } from './format.js';

function whyNotPayable(policy) {
  if (policy.dataIssue) return `Payments cannot be taken until the policy records are corrected: ${policy.dataIssue}. Refer the customer to Operations.`;
  if (policy.status === 'PAID') return `Nothing is due yet. The next premium is due on ${formatDate(policy.nextDueDate)}.`;
  if (policy.status === 'LAPSED') return `This policy lapsed and its 2-year revival window ended on ${formatDate(policy.revivalDeadline)}. No payment can be accepted.`;
  return 'This policy cannot take a payment right now.';
}

export default function PolicyDetail() {
  const { id } = useParams();
  const [state, setState] = useState({ loading: true, error: null, data: null });
  const [reloadToken, setReloadToken] = useState(0);
  const [receipt, setReceipt] = useState(null);
  const reload = useCallback(() => setReloadToken((n) => n + 1), []);
  const onRecorded = useCallback((result) => { setReceipt(result); reload(); }, [reload]);

  useEffect(() => setReceipt(null), [id]);

  useEffect(() => {
    const ctrl = new AbortController();
    setState((s) => ({ ...s, loading: true, error: null }));
    getPolicy(id, ctrl.signal)
      .then((data) => setState({ loading: false, error: null, data }))
      .catch((error) => {
        if (error.name !== 'AbortError') setState((s) => ({ ...s, loading: false, error }));
      });
    return () => ctrl.abort();
  }, [id, reloadToken]);

  const { loading, error, data } = state;

  if (error && !data) {
    return (
      <div>
        <p><Link to="/">← All policies</Link></p>
        <div className="alert alert-error" role="alert">
          <p>{error.status === 404 ? `Policy ${id} was not found.` : `Could not load this policy. ${error.message}`}</p>
          {error.status !== 404 && <button type="button" onClick={reload}>Try again</button>}
        </div>
      </div>
    );
  }

  if (!data) {
    return <p className="muted" role="status">Loading policy…</p>;
  }

  const { policy, customer, payments, otherPolicies } = data;

  return (
    <div className={loading ? 'is-loading' : undefined}>
      <p><Link to="/">← All policies</Link></p>

      <div className="detail-header">
        <h1>{policy.policyNo}</h1>
        <StatusBadge status={policy.status} />
        <span className="status-detail">{statusDetail(policy)}</span>
      </div>

      {error && (
        <div className="alert alert-error" role="alert">
          <p>Could not refresh this policy. {error.message}</p>
          <button type="button" onClick={reload}>Try again</button>
        </div>
      )}

      {policy.dataIssue && (
        <div className="alert alert-warning" role="note">
          <strong>Records need correcting.</strong> {policy.dataIssue}
        </div>
      )}

      <div className="detail-grid">
        <section>
          <h2>Policy</h2>
          <dl>
            <dt>Plan</dt><dd>{policy.planName}</dd>
            <dt>Premium</dt><dd>{formatINR(policy.premiumAmount)} {policy.premiumModeLabel && `· ${policy.premiumModeLabel}`}</dd>
            <dt>Sum assured</dt><dd>{formatINR(policy.sumAssured)}</dd>
            <dt>Commenced</dt><dd>{formatDate(policy.commencementDate)}</dd>
            <dt>Next due</dt><dd>{formatDate(policy.nextDueDate)}</dd>
            {policy.graceEndDate && (<><dt>Grace ends</dt><dd>{formatDate(policy.graceEndDate)} ({policy.graceDays} days)</dd></>)}
            {policy.firstUnpaidDueDate && (<><dt>First unpaid</dt><dd>{formatDate(policy.firstUnpaidDueDate)}</dd></>)}
            {policy.revivalDeadline && (<><dt>Revive by</dt><dd>{formatDate(policy.revivalDeadline)}</dd></>)}
          </dl>
        </section>

        <section>
          <h2>Customer</h2>
          {customer ? (
            <dl>
              <dt>Name</dt><dd>{customer.name}</dd>
              <dt>PAN</dt><dd>{customer.panMasked}</dd>
              <dt>Mobile</dt><dd>{customer.mobile}</dd>
              <dt>Email</dt><dd>{customer.email || '—'}</dd>
              <dt>City</dt><dd>{customer.city || '—'}</dd>
              {customer.dataIssue && (<><dt>Note</dt><dd className="warning-text">{customer.dataIssue}</dd></>)}
            </dl>
          ) : (
            <p className="warning-text">No customer record exists for customer id {policy.customerId}.</p>
          )}
        </section>
      </div>

      <section>
        {receipt && (
          <div className="alert alert-success" role="status">
            <strong>{receipt.result === 'ALREADY_RECORDED' ? 'This payment was already recorded' : 'Payment recorded'}</strong>
            <p>
              Receipt {receipt.payments.map((p) => p.id).join(', ')} ·{' '}
              {formatINR(receipt.payments.reduce((sum, p) => sum + p.amount, 0))}
              {receipt.instalments > 1 && ` for ${receipt.instalments} instalments`}. Next due {formatDate(receipt.nextDueDate)}.
            </p>
          </div>
        )}
        {policy.instalmentsPayable ? (
          <PaymentForm key={policy.id} policy={policy} onRecorded={onRecorded} onStale={reload} />
        ) : (
          <div className="payment-form">
            <h2>Record payment</h2>
            <p className="muted">{whyNotPayable(policy)}</p>
          </div>
        )}
      </section>

      <section>
        <h2>Payment history</h2>
        {payments.length === 0 ? (
          <p className="muted">No payments recorded for this policy.</p>
        ) : (
          <table className="table">
            <thead>
              <tr>
                <th>Receipt</th>
                <th>Paid (IST)</th>
                <th>For instalment due</th>
                <th>Channel</th>
                <th className="num">Amount</th>
              </tr>
            </thead>
            <tbody>
              {payments.map((p) => (
                <tr key={p.id}>
                  <td>{p.id}</td>
                  <td>{formatTimestampIST(p.paidAt)}</td>
                  <td>{formatDate(p.coversDueDate)}</td>
                  <td>{p.channel}</td>
                  <td className="num">{formatINR(p.amount)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      {otherPolicies.length > 0 && (
        <section>
          <h2>Other policies of this customer</h2>
          <ul className="plain">
            {otherPolicies.map((o) => (
              <li key={o.id}>
                <Link to={`/policies/${o.id}`}>{o.policyNo}</Link> · {o.planName} · <StatusBadge status={o.status} />
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}
