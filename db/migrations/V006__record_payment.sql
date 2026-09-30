--------------------------------------------------------------------------------
-- V006  RECORD_PAYMENT
--
-- Signature changes from the stub, and why:
--   P_EXPECTED_DUE (in, optional)  the due date the clerk was looking at. If
--       the policy has moved on since (another counter took the payment), the
--       request is refused instead of silently paying the NEXT instalment.
--       Without it a second clerk on a monthly policy would pay next month.
--   O_INSTALMENTS (out)  how many instalments were covered; > 1 on revival.
--
-- Errors are raised as  ORA-2000n: <CODE>: <message a clerk can read>
--   -20001 POLICY_NOT_FOUND         -20006 AMOUNT_MISMATCH
--   -20002 POLICY_NOT_SERVICEABLE   -20007 IDEMPOTENCY_KEY_REUSED
--   -20003 DUE_DATE_CHANGED         -20008 INVALID_REQUEST
--   -20004 NOTHING_DUE              -20009 POLICY_BUSY
--   -20005 REVIVAL_WINDOW_EXPIRED   -20010 INSTALMENT_ALREADY_PAID
--
-- Does not COMMIT: the caller commits (the API uses autoCommit on the call).
-- Any error rolls back everything the call did, including the claimed key.
--
-- Concurrency:
--   1. SELECT ... FOR UPDATE on the policy row serialises every payment for
--      one policy. The second session waits, then reads the post-payment row.
--   2. Only then is the key claimed by INSERT into PAYMENT_REQUESTS (PK). A
--      concurrent request with the same key blocks on the uncommitted key and
--      gets DUP_VAL_ON_INDEX once the first commits -> replay the stored result.
--   3. UQ_PAYMENTS_INSTALMENT (POLICY_ID, COVERS_DUE_DATE) makes a second
--      payment for the same instalment impossible even if 1 and 2 were bypassed.
--   Locks are always taken policy-then-key, so two calls cannot deadlock.
--------------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE RECORD_PAYMENT (
  P_POLICY_ID    IN  NUMBER,
  P_AMOUNT       IN  NUMBER,
  P_IDEM_KEY     IN  VARCHAR2,
  P_CHANNEL      IN  VARCHAR2 DEFAULT 'BRANCH',
  P_EXPECTED_DUE IN  DATE     DEFAULT NULL,
  O_PAYMENT_ID   OUT NUMBER,
  O_NEXT_DUE     OUT DATE,
  O_RESULT       OUT VARCHAR2,
  O_INSTALMENTS  OUT NUMBER
) AS
  e_lock_timeout EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_lock_timeout, -30006);

  l_next_due      POLICIES.NEXT_DUE_DATE%TYPE;
  l_first_unpaid  POLICIES.FIRST_UNPAID_DUE_DATE%TYPE;
  l_premium       POLICIES.PREMIUM_AMOUNT%TYPE;
  l_due_day       POLICIES.DUE_DAY%TYPE;
  l_data_issue    POLICIES.DATA_ISSUE%TYPE;
  l_period_months PREMIUM_MODES.PERIOD_MONTHS%TYPE;
  l_grace_days    PREMIUM_MODES.GRACE_DAYS%TYPE;

  l_req           PAYMENT_REQUESTS%ROWTYPE;
  l_today         DATE;
  l_status        VARCHAR2(10);
  l_deadline      DATE;
  l_count         PLS_INTEGER;
  l_required      NUMBER;
  l_covers        DATE;
  l_payment_id    NUMBER;
  l_paid_at       TIMESTAMP := SYS_EXTRACT_UTC(SYSTIMESTAMP);

  PROCEDURE fail(p_errnum PLS_INTEGER, p_code VARCHAR2, p_message VARCHAR2) IS
  BEGIN
    RAISE_APPLICATION_ERROR(p_errnum, p_code || ': ' || p_message);
  END;
BEGIN
  IF P_IDEM_KEY IS NULL OR LENGTH(P_IDEM_KEY) > 64 THEN
    fail(-20008, 'INVALID_REQUEST', 'An Idempotency-Key of 1 to 64 characters is required.');
  END IF;
  IF P_AMOUNT IS NULL OR P_AMOUNT <= 0 OR P_AMOUNT <> ROUND(P_AMOUNT, 2) THEN
    fail(-20008, 'INVALID_REQUEST', 'Enter the amount in rupees, greater than zero, with at most two decimal places.');
  END IF;
  IF P_CHANNEL IS NULL OR P_CHANNEL NOT IN ('BRANCH', 'ONLINE', 'AGENT', 'AUTO-DEBIT') THEN
    fail(-20008, 'INVALID_REQUEST', 'Channel must be one of BRANCH, ONLINE, AGENT or AUTO-DEBIT.');
  END IF;

  -- 1. Serialise on the policy.
  BEGIN
    SELECT p.NEXT_DUE_DATE, p.FIRST_UNPAID_DUE_DATE, p.PREMIUM_AMOUNT, p.DUE_DAY, p.DATA_ISSUE,
           m.PERIOD_MONTHS, m.GRACE_DAYS
      INTO l_next_due, l_first_unpaid, l_premium, l_due_day, l_data_issue,
           l_period_months, l_grace_days
      FROM POLICIES p
      LEFT JOIN PREMIUM_MODES m ON m.MODE_CODE = p.PREMIUM_MODE
     WHERE p.POLICY_ID = P_POLICY_ID
       FOR UPDATE OF p.NEXT_DUE_DATE WAIT 10;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      fail(-20001, 'POLICY_NOT_FOUND', 'No policy with id ' || P_POLICY_ID || ' exists.');
    WHEN e_lock_timeout THEN
      fail(-20009, 'POLICY_BUSY', 'Another payment on this policy is being processed. Wait a moment and check the payment history before trying again.');
  END;

  -- 2. Claim the key, or replay what the first request with it did.
  BEGIN
    INSERT INTO PAYMENT_REQUESTS (IDEMPOTENCY_KEY, POLICY_ID, AMOUNT, CHANNEL, SOURCE)
    VALUES (P_IDEM_KEY, P_POLICY_ID, P_AMOUNT, P_CHANNEL, 'API');
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      SELECT * INTO l_req FROM PAYMENT_REQUESTS WHERE IDEMPOTENCY_KEY = P_IDEM_KEY;
      IF l_req.POLICY_ID <> P_POLICY_ID OR l_req.AMOUNT <> P_AMOUNT THEN
        fail(-20007, 'IDEMPOTENCY_KEY_REUSED',
             'This request reuses the reference of an earlier, different payment (policy ' || l_req.POLICY_ID
             || ', ' || POLICY_RULES.format_inr(l_req.AMOUNT) || '). Nothing was recorded. Start a new payment.');
      END IF;
      O_PAYMENT_ID  := l_req.PAYMENT_ID;
      O_NEXT_DUE    := l_req.NEXT_DUE_DATE;
      O_INSTALMENTS := l_req.INSTALMENTS;
      O_RESULT      := 'ALREADY_RECORDED';
      RETURN;
  END;

  -- 3. Business rules, against the locked, current row.
  IF l_data_issue IS NOT NULL THEN
    fail(-20002, 'POLICY_NOT_SERVICEABLE',
         'Payments cannot be taken on this policy until its records are corrected (' || l_data_issue
         || '). Please refer the customer to Operations.');
  END IF;

  IF P_EXPECTED_DUE IS NOT NULL AND P_EXPECTED_DUE <> l_next_due THEN
    fail(-20003, 'DUE_DATE_CHANGED',
         'The instalment due on ' || POLICY_RULES.format_date(P_EXPECTED_DUE)
         || ' has already been paid, possibly at another counter. The next due date is now '
         || POLICY_RULES.format_date(l_next_due) || '. Refresh the policy before taking any money.');
  END IF;

  l_today  := POLICY_RULES.business_today;
  l_status := POLICY_RULES.derive_status(l_next_due, l_grace_days, l_today);

  IF l_status = 'PAID' THEN
    fail(-20004, 'NOTHING_DUE',
         'Nothing is due yet. The next premium of ' || POLICY_RULES.format_inr(l_premium) || ' is due on '
         || POLICY_RULES.format_date(l_next_due) || ' and can be paid from '
         || POLICY_RULES.format_date(l_next_due - POLICY_RULES.c_due_window_days) || '.');
  END IF;

  IF l_status = 'LAPSED' THEN
    l_deadline := POLICY_RULES.revival_deadline(NVL(l_first_unpaid, l_next_due));
    IF l_today > l_deadline THEN
      fail(-20005, 'REVIVAL_WINDOW_EXPIRED',
           'This policy has lapsed and can no longer be revived: the 2-year revival window from its first unpaid due date ('
           || POLICY_RULES.format_date(NVL(l_first_unpaid, l_next_due)) || ') ended on '
           || POLICY_RULES.format_date(l_deadline) || '. No payment can be accepted.');
    END IF;
  END IF;

  l_count    := POLICY_RULES.instalments_payable(l_next_due, l_period_months, l_due_day, l_today);
  l_required := l_count * l_premium;

  IF P_AMOUNT <> l_required THEN
    IF l_count = 1 THEN
      fail(-20006, 'AMOUNT_MISMATCH',
           'The premium due is exactly ' || POLICY_RULES.format_inr(l_required) || '. '
           || POLICY_RULES.format_inr(P_AMOUNT) || ' was entered. Part-payments and over-payments cannot be accepted.');
    ELSE
      fail(-20006, 'AMOUNT_MISMATCH',
           'To revive this lapsed policy all ' || l_count || ' unpaid instalments must be paid together: '
           || l_count || ' x ' || POLICY_RULES.format_inr(l_premium) || ' = ' || POLICY_RULES.format_inr(l_required)
           || '. ' || POLICY_RULES.format_inr(P_AMOUNT) || ' was entered.');
    END IF;
  END IF;

  -- 4. Record one row per instalment and move the policy on.
  BEGIN
    FOR i IN 0 .. l_count - 1 LOOP
      l_covers := POLICY_RULES.add_period(l_next_due, i * l_period_months, l_due_day);
      INSERT INTO PAYMENTS (PAYMENT_ID, POLICY_ID, AMOUNT, PAID_AT, IDEMPOTENCY_KEY, COVERS_DUE_DATE, CHANNEL)
      VALUES (SEQ_PAYMENT_ID.NEXTVAL, P_POLICY_ID, l_premium, l_paid_at, P_IDEM_KEY, l_covers, P_CHANNEL)
      RETURNING PAYMENT_ID INTO l_payment_id;
      IF i = 0 THEN
        O_PAYMENT_ID := l_payment_id;
      END IF;
    END LOOP;
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      fail(-20010, 'INSTALMENT_ALREADY_PAID',
           'Our records already hold a payment for the instalment due on ' || POLICY_RULES.format_date(l_covers)
           || ', but the policy still shows it as unpaid. Nothing was recorded. Please refer this policy to Operations.');
  END;

  O_NEXT_DUE    := POLICY_RULES.add_period(l_next_due, l_count * l_period_months, l_due_day);
  O_INSTALMENTS := l_count;
  O_RESULT      := 'RECORDED';

  UPDATE POLICIES
     SET NEXT_DUE_DATE = O_NEXT_DUE,
         FIRST_UNPAID_DUE_DATE = NULL
   WHERE POLICY_ID = P_POLICY_ID;

  UPDATE PAYMENT_REQUESTS
     SET PAYMENT_ID = O_PAYMENT_ID, INSTALMENTS = O_INSTALMENTS, NEXT_DUE_DATE = O_NEXT_DUE
   WHERE IDEMPOTENCY_KEY = P_IDEM_KEY;
END RECORD_PAYMENT;
/
SHOW ERRORS
