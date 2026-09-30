--------------------------------------------------------------------------------
-- V007  V_POLICY_STATUS: derived status (R4) and what is payable today
--
-- Status comes from NEXT_DUE_DATE, the mode's grace period and today's date in
-- IST. LEGACY_STATUS is never read. The rules live in POLICY_RULES, which
-- RECORD_PAYMENT also uses, so the screen and the procedure cannot disagree.
--
-- DERIVED_STATUS is NULL where it cannot be derived (no due date; an overdue
-- policy with no known grace period). Those rows always carry a DATA_ISSUE.
--
-- Filtering and pagination are applied by the caller on top of this view
-- (see backend/src/routes/policies.js); they run in the database.
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW V_POLICY_STATUS AS
WITH biz AS (
  SELECT POLICY_RULES.business_today AS TODAY FROM DUAL
),
base AS (
  SELECT p.POLICY_ID,
         p.POLICY_NO,
         p.CUSTOMER_ID,
         c.FULL_NAME                    AS CUSTOMER_NAME,
         p.PLAN_NAME,
         p.PREMIUM_MODE,
         m.LABEL                        AS PREMIUM_MODE_LABEL,
         m.PERIOD_MONTHS,
         m.GRACE_DAYS,
         p.PREMIUM_AMOUNT,
         p.SUM_ASSURED,
         p.COMMENCEMENT_DATE,
         p.NEXT_DUE_DATE,
         p.FIRST_UNPAID_DUE_DATE,
         p.DUE_DAY,
         p.DATA_ISSUE,
         b.TODAY                        AS BUSINESS_DATE,
         POLICY_RULES.derive_status(p.NEXT_DUE_DATE, m.GRACE_DAYS, b.TODAY) AS DERIVED_STATUS
    FROM POLICIES p
   CROSS JOIN biz b
    LEFT JOIN CUSTOMERS c     ON c.CUSTOMER_ID = p.CUSTOMER_ID
    LEFT JOIN PREMIUM_MODES m ON m.MODE_CODE   = p.PREMIUM_MODE
),
revival AS (
  SELECT base.*,
         CASE WHEN DERIVED_STATUS = 'LAPSED'
              THEN POLICY_RULES.revival_deadline(NVL(FIRST_UNPAID_DUE_DATE, NEXT_DUE_DATE))
         END AS REVIVAL_DEADLINE
    FROM base
),
payable AS (
  SELECT revival.*,
         CASE WHEN DATA_ISSUE IS NULL
               AND (DERIVED_STATUS IN ('DUE', 'IN_GRACE')
                    OR (DERIVED_STATUS = 'LAPSED' AND BUSINESS_DATE <= REVIVAL_DEADLINE))
              THEN POLICY_RULES.instalments_payable(NEXT_DUE_DATE, PERIOD_MONTHS, DUE_DAY, BUSINESS_DATE)
         END AS INSTALMENTS_PAYABLE
    FROM revival
)
SELECT POLICY_ID,
       POLICY_NO,
       CUSTOMER_ID,
       CUSTOMER_NAME,
       PLAN_NAME,
       PREMIUM_MODE,
       PREMIUM_MODE_LABEL,
       GRACE_DAYS,
       PREMIUM_AMOUNT,
       SUM_ASSURED,
       COMMENCEMENT_DATE,
       NEXT_DUE_DATE,
       FIRST_UNPAID_DUE_DATE,
       NEXT_DUE_DATE + GRACE_DAYS           AS GRACE_END_DATE,
       DERIVED_STATUS,
       REVIVAL_DEADLINE,
       INSTALMENTS_PAYABLE,
       INSTALMENTS_PAYABLE * PREMIUM_AMOUNT AS AMOUNT_PAYABLE,
       DATA_ISSUE,
       BUSINESS_DATE
  FROM payable;
