--------------------------------------------------------------------------------
-- V004  Payments: suspense for rows that cannot stand, reconciliation of a
--       half-applied legacy payment, and the idempotency ledger
--
-- Money records are never deleted. Rows that break the rules we are about to
-- enforce move to PAYMENT_SUSPENSE with the reason, for Finance to refund or
-- re-apply. That is what an insurer's suspense account is for.
--------------------------------------------------------------------------------

CREATE TABLE PAYMENT_SUSPENSE (
  PAYMENT_ID       NUMBER        NOT NULL CONSTRAINT PK_PAYMENT_SUSPENSE PRIMARY KEY,
  POLICY_ID        NUMBER,
  AMOUNT           NUMBER(12,2),
  PAID_AT          TIMESTAMP,
  IDEMPOTENCY_KEY  VARCHAR2(64),
  COVERS_DUE_DATE  DATE,
  CHANNEL          VARCHAR2(20),
  CREATED_AT       TIMESTAMP,
  REASON           VARCHAR2(400 CHAR) NOT NULL,
  MOVED_AT         TIMESTAMP     DEFAULT SYS_EXTRACT_UTC(SYSTIMESTAMP) NOT NULL
);

DECLARE
  PROCEDURE move_to_suspense(p_payment_id NUMBER, p_reason VARCHAR2) IS
  BEGIN
    INSERT INTO PAYMENT_SUSPENSE (PAYMENT_ID, POLICY_ID, AMOUNT, PAID_AT, IDEMPOTENCY_KEY,
                                  COVERS_DUE_DATE, CHANNEL, CREATED_AT, REASON)
    SELECT PAYMENT_ID, POLICY_ID, AMOUNT, PAID_AT, IDEMPOTENCY_KEY, COVERS_DUE_DATE, CHANNEL, CREATED_AT, p_reason
      FROM PAYMENTS WHERE PAYMENT_ID = p_payment_id;
    DELETE FROM PAYMENTS WHERE PAYMENT_ID = p_payment_id;
    DBMS_OUTPUT.PUT_LINE('suspense ' || p_payment_id || ': ' || p_reason);
  END;
BEGIN
  -- 1. Payments against a policy that does not exist.
  FOR r IN (SELECT y.PAYMENT_ID, y.POLICY_ID FROM PAYMENTS y
             WHERE NOT EXISTS (SELECT 1 FROM POLICIES p WHERE p.POLICY_ID = y.POLICY_ID)) LOOP
    move_to_suspense(r.PAYMENT_ID, 'Unallocated: policy ' || r.POLICY_ID || ' does not exist');
  END LOOP;

  -- 2. The same Idempotency-Key recorded more than once: a retry that charged
  --    twice. The first row stands; later ones are refund candidates.
  FOR r IN (SELECT PAYMENT_ID, IDEMPOTENCY_KEY, FIRST_ID FROM (
              SELECT PAYMENT_ID, IDEMPOTENCY_KEY,
                     FIRST_VALUE(PAYMENT_ID) OVER (PARTITION BY IDEMPOTENCY_KEY ORDER BY PAID_AT, PAYMENT_ID) AS FIRST_ID
                FROM PAYMENTS)
             WHERE PAYMENT_ID <> FIRST_ID) LOOP
    move_to_suspense(r.PAYMENT_ID, 'Duplicate of payment ' || r.FIRST_ID || ' (same Idempotency-Key '
                                   || r.IDEMPOTENCY_KEY || '): refund candidate');
  END LOOP;

  -- 3. Any other instalment paid twice.
  FOR r IN (SELECT PAYMENT_ID, FIRST_ID FROM (
              SELECT PAYMENT_ID,
                     FIRST_VALUE(PAYMENT_ID) OVER (PARTITION BY POLICY_ID, COVERS_DUE_DATE ORDER BY PAID_AT, PAYMENT_ID) AS FIRST_ID
                FROM PAYMENTS)
             WHERE PAYMENT_ID <> FIRST_ID) LOOP
    move_to_suspense(r.PAYMENT_ID, 'Second payment for the same instalment as payment ' || r.FIRST_ID || ': refund candidate');
  END LOOP;

  -- 4. A payment exists for the very instalment the policy still shows as
  --    unpaid: the legacy code committed the INSERT and the UPDATE separately,
  --    so the due date was never moved on. Judge each by R3 in IST:
  --      on time -> the payment stands; finish the job and advance the policy
  --      late    -> the legacy UTC check accepted money after the policy had
  --                 lapsed; suspense it for Finance (refund or apply to revival)
  FOR r IN (SELECT y.PAYMENT_ID, y.PAID_AT, y.COVERS_DUE_DATE,
                   p.POLICY_ID, p.NEXT_DUE_DATE, p.DUE_DAY, m.PERIOD_MONTHS, m.GRACE_DAYS,
                   TRUNC(CAST(FROM_TZ(y.PAID_AT, 'UTC') AT TIME ZONE 'Asia/Kolkata' AS DATE)) AS PAID_ON_IST
              FROM PAYMENTS y
              JOIN POLICIES p      ON p.POLICY_ID = y.POLICY_ID AND y.COVERS_DUE_DATE = p.NEXT_DUE_DATE
              JOIN PREMIUM_MODES m ON m.MODE_CODE = p.PREMIUM_MODE) LOOP
    IF r.PAID_ON_IST <= r.COVERS_DUE_DATE + r.GRACE_DAYS THEN
      UPDATE POLICIES
         SET NEXT_DUE_DATE = POLICY_RULES.add_period(NEXT_DUE_DATE, r.PERIOD_MONTHS, DUE_DAY),
             FIRST_UNPAID_DUE_DATE = NULL
       WHERE POLICY_ID = r.POLICY_ID;
      UPDATE POLICIES
         SET FIRST_UNPAID_DUE_DATE = NEXT_DUE_DATE
       WHERE POLICY_ID = r.POLICY_ID AND NEXT_DUE_DATE < POLICY_RULES.business_today;
      DBMS_OUTPUT.PUT_LINE('advanced policy ' || r.POLICY_ID || ': payment ' || r.PAYMENT_ID
                           || ' was on time in IST but NEXT_DUE_DATE was never moved');
    ELSE
      move_to_suspense(r.PAYMENT_ID, 'Paid ' || TO_CHAR(r.PAID_ON_IST, 'YYYY-MM-DD') || ' IST, after grace ended on '
                                     || TO_CHAR(r.COVERS_DUE_DATE + r.GRACE_DAYS, 'YYYY-MM-DD')
                                     || '; accepted by the legacy UTC check. Refund, or apply to revival');
    END IF;
  END LOOP;
END;
/

--------------------------------------------------------------------------------
-- PAYMENT_REQUESTS: one row per Idempotency-Key, holding the outcome of the
-- first request so a repeat can be answered without doing anything.
--
-- The key cannot simply be UNIQUE on PAYMENTS: a revival records several
-- instalments (several PAYMENTS rows) for one request. So the key is unique
-- here, and PAYMENTS.IDEMPOTENCY_KEY is a foreign key to it.
--------------------------------------------------------------------------------
CREATE TABLE PAYMENT_REQUESTS (
  IDEMPOTENCY_KEY   VARCHAR2(64)  CONSTRAINT PK_PAYMENT_REQUESTS PRIMARY KEY,
  POLICY_ID         NUMBER        NOT NULL,
  AMOUNT            NUMBER(12,2)  NOT NULL,
  CHANNEL           VARCHAR2(20)  NOT NULL,
  SOURCE            VARCHAR2(10)  NOT NULL CONSTRAINT CK_PAYMENT_REQUESTS_SOURCE CHECK (SOURCE IN ('API', 'LEGACY')),
  PAYMENT_ID        NUMBER,
  INSTALMENTS       NUMBER(4),
  NEXT_DUE_DATE     DATE,
  CREATED_AT        TIMESTAMP     DEFAULT SYS_EXTRACT_UTC(SYSTIMESTAMP) NOT NULL
);

INSERT INTO PAYMENT_REQUESTS (IDEMPOTENCY_KEY, POLICY_ID, AMOUNT, CHANNEL, SOURCE, PAYMENT_ID, INSTALMENTS, CREATED_AT)
SELECT IDEMPOTENCY_KEY, POLICY_ID, AMOUNT, CHANNEL, 'LEGACY', PAYMENT_ID, 1, PAID_AT
  FROM PAYMENTS;

COMMIT;
