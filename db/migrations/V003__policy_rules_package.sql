--------------------------------------------------------------------------------
-- V003  POLICY_RULES: the date and status rules, in one place
--
-- Used by V_POLICY_STATUS (what the clerk sees) and RECORD_PAYMENT (what the
-- database will accept), so the two can never disagree.
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE POLICY_RULES AS

  c_business_tz      CONSTANT VARCHAR2(30) := 'Asia/Kolkata';
  c_due_window_days  CONSTANT PLS_INTEGER  := 30;
  c_revival_months   CONSTANT PLS_INTEGER  := 24;

  -- Today's calendar date in IST, whatever time zone the DB host runs in.
  FUNCTION business_today RETURN DATE;

  -- Moves a due date forward by p_months, landing on p_due_day or on the last
  -- day of the target month if it is shorter. Unlike ADD_MONTHS this does not
  -- stick to month-end: ADD_MONTHS(30-APR, 1) is 31-MAY, and ADD_MONTHS(28-FEB, 1)
  -- is 31-MAR, which silently moves a 28th or 30th policy onto the 31st.
  FUNCTION add_period(p_date DATE, p_months PLS_INTEGER, p_due_day PLS_INTEGER)
    RETURN DATE DETERMINISTIC;

  -- PAID | DUE | IN_GRACE | LAPSED, or NULL when it cannot be derived.
  FUNCTION derive_status(p_next_due DATE, p_grace_days PLS_INTEGER, p_today DATE)
    RETURN VARCHAR2 DETERMINISTIC;

  -- Last day on which a lapsed policy may still be revived (inclusive).
  FUNCTION revival_deadline(p_first_unpaid DATE) RETURN DATE DETERMINISTIC;

  -- Instalments a payment taken today must cover: every due date on or before
  -- today (revival takes them all at once), and never fewer than one.
  FUNCTION instalments_payable(p_next_due DATE, p_period_months PLS_INTEGER,
                               p_due_day PLS_INTEGER, p_today DATE)
    RETURN PLS_INTEGER DETERMINISTIC;

  -- 1234567.5 -> '₹12,34,567.50' (Indian digit grouping) for clerk messages.
  FUNCTION format_inr(p_amount NUMBER) RETURN VARCHAR2 DETERMINISTIC;

  FUNCTION format_date(p_date DATE) RETURN VARCHAR2 DETERMINISTIC;

END POLICY_RULES;
/

CREATE OR REPLACE PACKAGE BODY POLICY_RULES AS

  FUNCTION business_today RETURN DATE IS
  BEGIN
    RETURN TRUNC(CAST(SYSTIMESTAMP AT TIME ZONE c_business_tz AS DATE));
  END;

  FUNCTION add_period(p_date DATE, p_months PLS_INTEGER, p_due_day PLS_INTEGER)
    RETURN DATE DETERMINISTIC
  IS
    l_month_start DATE;
  BEGIN
    IF p_date IS NULL OR p_months IS NULL OR p_due_day IS NULL THEN
      RETURN NULL;
    END IF;
    -- ADD_MONTHS is safe on the 1st: the 1st is never a month-end.
    l_month_start := ADD_MONTHS(TRUNC(p_date, 'MM'), p_months);
    RETURN l_month_start + LEAST(p_due_day, EXTRACT(DAY FROM LAST_DAY(l_month_start))) - 1;
  END;

  FUNCTION derive_status(p_next_due DATE, p_grace_days PLS_INTEGER, p_today DATE)
    RETURN VARCHAR2 DETERMINISTIC
  IS
  BEGIN
    IF p_next_due IS NULL OR p_today IS NULL THEN
      RETURN NULL;
    ELSIF p_next_due > p_today + c_due_window_days THEN
      RETURN 'PAID';
    ELSIF p_next_due >= p_today THEN
      RETURN 'DUE';
    ELSIF p_grace_days IS NULL THEN
      RETURN NULL;
    ELSIF p_today <= p_next_due + p_grace_days THEN
      RETURN 'IN_GRACE';
    ELSE
      RETURN 'LAPSED';
    END IF;
  END;

  FUNCTION revival_deadline(p_first_unpaid DATE) RETURN DATE DETERMINISTIC IS
  BEGIN
    RETURN add_period(p_first_unpaid, c_revival_months, EXTRACT(DAY FROM p_first_unpaid));
  END;

  FUNCTION instalments_payable(p_next_due DATE, p_period_months PLS_INTEGER,
                               p_due_day PLS_INTEGER, p_today DATE)
    RETURN PLS_INTEGER DETERMINISTIC
  IS
    l_count PLS_INTEGER := 0;
  BEGIN
    IF p_next_due IS NULL OR p_period_months IS NULL OR p_due_day IS NULL THEN
      RETURN NULL;
    END IF;
    WHILE add_period(p_next_due, l_count * p_period_months, p_due_day) <= p_today LOOP
      l_count := l_count + 1;
      EXIT WHEN l_count > 1200;
    END LOOP;
    RETURN GREATEST(l_count, 1);
  END;

  FUNCTION format_inr(p_amount NUMBER) RETURN VARCHAR2 DETERMINISTIC IS
  BEGIN
    RETURN UNISTR('\20B9') || TO_CHAR(p_amount, 'FM99,99,99,99,990.00');
  END;

  FUNCTION format_date(p_date DATE) RETURN VARCHAR2 DETERMINISTIC IS
  BEGIN
    RETURN TO_CHAR(p_date, 'DD Mon YYYY', 'NLS_DATE_LANGUAGE=ENGLISH');
  END;

END POLICY_RULES;
/
SHOW ERRORS
