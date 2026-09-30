--------------------------------------------------------------------------------
-- V001  Premium modes as reference data; typed premium columns; policy flags
--
-- PREMIUM_MODE arrives in 25 spellings ('Mly', ' Quarterly', 'SEMI-ANNUAL', ...)
-- and PREMIUM_AMOUNT is free text ('Rs. 24,000.00', 'INR 3,200.00', '  60000 ').
-- A VARCHAR2 column cannot be MODIFY'd to NUMBER while it holds data
-- (ORA-01439), so the legacy columns are renamed to LEGACY_* and kept for audit,
-- and new typed columns take over the original names.
--
-- Rows we cannot interpret are not guessed at. They get a DATA_ISSUE text,
-- which the view surfaces and RECORD_PAYMENT refuses to take money against.
--------------------------------------------------------------------------------

CREATE TABLE PREMIUM_MODES (
  MODE_CODE      VARCHAR2(12)      CONSTRAINT PK_PREMIUM_MODES PRIMARY KEY,
  LABEL          VARCHAR2(30 CHAR) NOT NULL,
  PERIOD_MONTHS  NUMBER(2)         NOT NULL CONSTRAINT CK_PREMIUM_MODES_PERIOD CHECK (PERIOD_MONTHS IN (1, 3, 6, 12)),
  GRACE_DAYS     NUMBER(3)         NOT NULL CONSTRAINT CK_PREMIUM_MODES_GRACE CHECK (GRACE_DAYS >= 0)
);

INSERT INTO PREMIUM_MODES VALUES ('YEARLY',      'Yearly',      12, 30);
INSERT INTO PREMIUM_MODES VALUES ('HALF_YEARLY', 'Half-yearly',  6, 30);
INSERT INTO PREMIUM_MODES VALUES ('QUARTERLY',   'Quarterly',    3, 30);
INSERT INTO PREMIUM_MODES VALUES ('MONTHLY',     'Monthly',      1, 15);

ALTER TABLE POLICIES RENAME COLUMN PREMIUM_MODE   TO LEGACY_PREMIUM_MODE;
ALTER TABLE POLICIES RENAME COLUMN PREMIUM_AMOUNT TO LEGACY_PREMIUM_AMOUNT;

ALTER TABLE POLICIES ADD (
  PREMIUM_MODE           VARCHAR2(12),
  PREMIUM_AMOUNT         NUMBER(12,2),
  DUE_DAY                NUMBER(2),
  DATA_ISSUE             VARCHAR2(400 CHAR),
  POLICY_NO_CONFLICT_OF  NUMBER
);

UPDATE POLICIES
   SET PREMIUM_MODE =
       CASE REGEXP_REPLACE(UPPER(LEGACY_PREMIUM_MODE), '[^A-Z]', '')
         WHEN 'YEARLY'     THEN 'YEARLY'
         WHEN 'ANNUAL'     THEN 'YEARLY'
         WHEN 'Y'          THEN 'YEARLY'
         WHEN 'YLY'        THEN 'YEARLY'
         WHEN 'HALFYEARLY' THEN 'HALF_YEARLY'
         WHEN 'SEMIANNUAL' THEN 'HALF_YEARLY'
         WHEN 'HY'         THEN 'HALF_YEARLY'
         WHEN 'H'          THEN 'HALF_YEARLY'
         WHEN 'HLY'        THEN 'HALF_YEARLY'
         WHEN 'QUARTERLY'  THEN 'QUARTERLY'
         WHEN 'Q'          THEN 'QUARTERLY'
         WHEN 'QTR'        THEN 'QUARTERLY'
         WHEN 'QLY'        THEN 'QUARTERLY'
         WHEN 'MONTHLY'    THEN 'MONTHLY'
         WHEN 'M'          THEN 'MONTHLY'
         WHEN 'MTH'        THEN 'MONTHLY'
         WHEN 'MLY'        THEN 'MONTHLY'
       END;

UPDATE POLICIES
   SET DATA_ISSUE = LTRIM(DATA_ISSUE || '; Premium mode "' || TRIM(LEGACY_PREMIUM_MODE) || '" is not an instalment mode we service', '; ')
 WHERE PREMIUM_MODE IS NULL;

-- Strip an optional 'Rs.' / 'INR' prefix, thousands separators and padding.
UPDATE POLICIES
   SET PREMIUM_AMOUNT = TO_NUMBER(
         REPLACE(REGEXP_REPLACE(UPPER(TRIM(LEGACY_PREMIUM_AMOUNT)), '^(RS\.?|INR)\s*', ''), ',', '')
         DEFAULT NULL ON CONVERSION ERROR)
 WHERE REGEXP_LIKE(REPLACE(REGEXP_REPLACE(UPPER(TRIM(LEGACY_PREMIUM_AMOUNT)), '^(RS\.?|INR)\s*', ''), ',', ''),
                   '^-?[0-9]+(\.[0-9]{1,2})?$');

UPDATE POLICIES
   SET DATA_ISSUE = LTRIM(DATA_ISSUE || '; Premium amount on record ("' || NVL(TRIM(LEGACY_PREMIUM_AMOUNT), 'blank') || '") is missing, zero or negative', '; '),
       PREMIUM_AMOUNT = NULL
 WHERE PREMIUM_AMOUNT IS NULL OR PREMIUM_AMOUNT <= 0;

UPDATE POLICIES
   SET DATA_ISSUE = LTRIM(DATA_ISSUE || '; No next due date on record (legacy status "' || LEGACY_STATUS || '")', '; ')
 WHERE NEXT_DUE_DATE IS NULL;

UPDATE POLICIES p
   SET DATA_ISSUE = LTRIM(DATA_ISSUE || '; Customer ' || CUSTOMER_ID || ' does not exist', '; ')
 WHERE NOT EXISTS (SELECT 1 FROM CUSTOMERS c WHERE c.CUSTOMER_ID = p.CUSTOMER_ID);

-- 'SL-2024-000120' and 'sl-2024-000120' are two different policies (different
-- customers, plans and start dates) sharing one number. We cannot renumber a
-- policy the customer holds a document for, so both are flagged and the later
-- one records which policy it clashes with. See UX_POLICIES_POLICY_NO in V005.
UPDATE POLICIES SET POLICY_NO = UPPER(TRIM(POLICY_NO));

MERGE INTO POLICIES p
USING (
  SELECT POLICY_ID,
         MIN(POLICY_ID) OVER (PARTITION BY POLICY_NO) AS FIRST_ID,
         COUNT(*)       OVER (PARTITION BY POLICY_NO) AS N
    FROM POLICIES
) d
ON (p.POLICY_ID = d.POLICY_ID AND d.N > 1)
WHEN MATCHED THEN UPDATE
   SET p.POLICY_NO_CONFLICT_OF = CASE WHEN d.POLICY_ID <> d.FIRST_ID THEN d.FIRST_ID END,
       p.DATA_ISSUE = LTRIM(p.DATA_ISSUE || '; Policy number ' || p.POLICY_NO || ' is shared with another policy', '; ');

-- The contractual day of month instalments fall on. Where the current due date
-- agrees with the commencement day (allowing for a short-month clamp, e.g. a
-- 31st policy due on 30 Sep) we keep the commencement day; otherwise the legacy
-- schedule has drifted and we anchor on the current due date's day.
UPDATE POLICIES
   SET DUE_DAY =
       CASE
         WHEN NEXT_DUE_DATE IS NULL THEN EXTRACT(DAY FROM COMMENCEMENT_DATE)
         WHEN EXTRACT(DAY FROM NEXT_DUE_DATE) = EXTRACT(DAY FROM COMMENCEMENT_DATE) THEN EXTRACT(DAY FROM COMMENCEMENT_DATE)
         WHEN NEXT_DUE_DATE = LAST_DAY(NEXT_DUE_DATE)
          AND EXTRACT(DAY FROM COMMENCEMENT_DATE) > EXTRACT(DAY FROM NEXT_DUE_DATE) THEN EXTRACT(DAY FROM COMMENCEMENT_DATE)
         ELSE EXTRACT(DAY FROM NEXT_DUE_DATE)
       END;

COMMIT;
