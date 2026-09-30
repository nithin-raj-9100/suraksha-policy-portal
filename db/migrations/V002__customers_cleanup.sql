--------------------------------------------------------------------------------
-- V002  Customers: character semantics, normalised PAN, PAN clashes flagged
--------------------------------------------------------------------------------

-- The database is AL32UTF8 with BYTE length semantics. 'Hiral Patel / હિરલ પટેલ'
-- is 23 characters but 39 bytes; a full Gujarati name would not fit in
-- VARCHAR2(120 BYTE). Lengths are in characters from here on.
ALTER TABLE CUSTOMERS MODIFY (
  FULL_NAME VARCHAR2(120 CHAR),
  EMAIL     VARCHAR2(120 CHAR),
  CITY      VARCHAR2(60 CHAR)
);

ALTER TABLE CUSTOMERS ADD (
  PAN_CONFLICT_OF  NUMBER,
  DATA_ISSUE       VARCHAR2(400 CHAR)
);

-- Whitespace only. Casing ('rAJESH  mehta', 'RAJESH PATEL') is left alone:
-- INITCAP would mangle real names and search is case-insensitive anyway.
UPDATE CUSTOMERS
   SET FULL_NAME = REGEXP_REPLACE(TRIM(FULL_NAME), '\s{2,}', ' '),
       PAN       = UPPER(TRIM(PAN)),
       EMAIL     = LOWER(TRIM(EMAIL)),
       MOBILE    = TRIM(MOBILE),
       CITY      = TRIM(CITY);

-- 1151/1152/1153 share PAN ABCDE1234F once case and padding are removed. It is
-- also the sample PAN printed in Income Tax documentation, so this may be a
-- placeholder typed in by staff rather than one person entered three times.
-- Merging customers is a KYC decision, not a migration's; flag and keep all.
MERGE INTO CUSTOMERS c
USING (
  SELECT CUSTOMER_ID,
         MIN(CUSTOMER_ID) OVER (PARTITION BY PAN) AS FIRST_ID,
         COUNT(*)         OVER (PARTITION BY PAN) AS N,
         LISTAGG(CUSTOMER_ID, ', ') WITHIN GROUP (ORDER BY CUSTOMER_ID) OVER (PARTITION BY PAN) AS IDS
    FROM CUSTOMERS
) d
ON (c.CUSTOMER_ID = d.CUSTOMER_ID AND d.N > 1)
WHEN MATCHED THEN UPDATE
   SET c.PAN_CONFLICT_OF = CASE WHEN d.CUSTOMER_ID <> d.FIRST_ID THEN d.FIRST_ID END,
       c.DATA_ISSUE = 'PAN ' || c.PAN || ' is shared by customers ' || d.IDS;

ALTER TABLE CUSTOMERS MODIFY (PAN VARCHAR2(10));

COMMIT;
