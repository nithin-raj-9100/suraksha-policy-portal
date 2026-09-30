--------------------------------------------------------------------------------
-- Checks for POLICY_RULES and RECORD_PAYMENT against the seeded data.
-- Everything is rolled back at the end.
--
--   ./db/test.sh
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
SET DEFINE OFF

DECLARE
  g_failures PLS_INTEGER := 0;
  l_pid      NUMBER;
  l_next     DATE;
  l_result   VARCHAR2(30);
  l_n        NUMBER;
  l_count    NUMBER;

  PROCEDURE check_that(p_name VARCHAR2, p_ok BOOLEAN) IS
  BEGIN
    IF p_ok THEN
      DBMS_OUTPUT.PUT_LINE('PASS  ' || p_name);
    ELSE
      DBMS_OUTPUT.PUT_LINE('FAIL  ' || p_name);
      g_failures := g_failures + 1;
    END IF;
  END;

  PROCEDURE check_date(p_name VARCHAR2, p_actual DATE, p_expected DATE) IS
  BEGIN
    check_that(p_name || ' = ' || TO_CHAR(p_expected, 'YYYY-MM-DD') || ' (got ' || TO_CHAR(p_actual, 'YYYY-MM-DD') || ')',
               p_actual = p_expected);
  END;

  PROCEDURE pay(p_policy NUMBER, p_amount NUMBER, p_key VARCHAR2, p_expected DATE DEFAULT NULL) IS
  BEGIN
    RECORD_PAYMENT(p_policy, p_amount, p_key, 'BRANCH', p_expected, l_pid, l_next, l_result, l_n);
  END;

  PROCEDURE expect_error(p_name VARCHAR2, p_code VARCHAR2, p_policy NUMBER, p_amount NUMBER,
                         p_key VARCHAR2, p_expected DATE DEFAULT NULL) IS
  BEGIN
    pay(p_policy, p_amount, p_key, p_expected);
    check_that(p_name || ' -> ' || p_code || ' (but it succeeded)', FALSE);
  EXCEPTION
    WHEN OTHERS THEN
      check_that(p_name || ' -> ' || p_code, INSTR(SQLERRM, p_code || ':') > 0);
      IF INSTR(SQLERRM, p_code || ':') = 0 THEN
        DBMS_OUTPUT.PUT_LINE('      got: ' || SQLERRM);
      END IF;
  END;

  FUNCTION today RETURN DATE IS BEGIN RETURN POLICY_RULES.business_today; END;
  FUNCTION due_of(p_policy NUMBER) RETURN DATE IS
    d DATE;
  BEGIN
    SELECT NEXT_DUE_DATE INTO d FROM POLICIES WHERE POLICY_ID = p_policy;
    RETURN d;
  END;
BEGIN
  DBMS_OUTPUT.PUT_LINE('-- R6 month arithmetic');
  check_date('31 Jan + 1 month',             POLICY_RULES.add_period(DATE '2025-01-31', 1, 31), DATE '2025-02-28');
  check_date('31 Jan + 1 month (leap year)', POLICY_RULES.add_period(DATE '2024-01-31', 1, 31), DATE '2024-02-29');
  check_date('28 Feb (a 31st policy) + 1',   POLICY_RULES.add_period(DATE '2025-02-28', 1, 31), DATE '2025-03-31');
  check_date('28 Feb (a 30th policy) + 1',   POLICY_RULES.add_period(DATE '2025-02-28', 1, 30), DATE '2025-03-30');
  check_date('30 Apr (a 30th policy) + 1',   POLICY_RULES.add_period(DATE '2025-04-30', 1, 30), DATE '2025-05-30');
  check_date('30 Nov (a 31st policy) + 3',   POLICY_RULES.add_period(DATE '2025-11-30', 3, 31), DATE '2026-02-28');
  check_date('31 Aug + 6 months',            POLICY_RULES.add_period(DATE '2025-08-31', 6, 31), DATE '2026-02-28');
  check_date('29 Feb 2024 + 12 months',      POLICY_RULES.add_period(DATE '2024-02-29', 12, 29), DATE '2025-02-28');
  check_date('29 Feb 2024 + 48 months',      POLICY_RULES.add_period(DATE '2024-02-29', 48, 29), DATE '2028-02-29');

  DBMS_OUTPUT.PUT_LINE('-- R2/R4 status boundaries (fixed dates)');
  check_that('due in 31 days -> PAID',        POLICY_RULES.derive_status(DATE '2026-01-01' + 31, 30, DATE '2026-01-01') = 'PAID');
  check_that('due in 30 days -> DUE',         POLICY_RULES.derive_status(DATE '2026-01-01' + 30, 30, DATE '2026-01-01') = 'DUE');
  check_that('due today -> DUE',              POLICY_RULES.derive_status(DATE '2026-01-01', 30, DATE '2026-01-01') = 'DUE');
  check_that('1 day overdue -> IN_GRACE',     POLICY_RULES.derive_status(DATE '2026-01-01', 30, DATE '2026-01-02') = 'IN_GRACE');
  check_that('last day of 30-day grace',      POLICY_RULES.derive_status(DATE '2026-01-01', 30, DATE '2026-01-31') = 'IN_GRACE');
  check_that('day after 30-day grace',        POLICY_RULES.derive_status(DATE '2026-01-01', 30, DATE '2026-02-01') = 'LAPSED');
  check_that('last day of 15-day grace',      POLICY_RULES.derive_status(DATE '2026-01-01', 15, DATE '2026-01-16') = 'IN_GRACE');
  check_that('day after 15-day grace',        POLICY_RULES.derive_status(DATE '2026-01-01', 15, DATE '2026-01-17') = 'LAPSED');

  DBMS_OUTPUT.PUT_LINE('-- R7 revival window');
  check_date('deadline from 29 Feb 2024', POLICY_RULES.revival_deadline(DATE '2024-02-29'), DATE '2026-02-28');
  check_date('deadline from 15 Mar 2024', POLICY_RULES.revival_deadline(DATE '2024-03-15'), DATE '2026-03-15');

  DBMS_OUTPUT.PUT_LINE('-- RECORD_PAYMENT on seeded policies');

  -- 5001: quarterly, today is the last day of grace (R3).
  expect_error('5001 part-payment',  'AMOUNT_MISMATCH', 5001, 5999,  'test-5001-a');
  expect_error('5001 over-payment',  'AMOUNT_MISMATCH', 5001, 6001,  'test-5001-b');
  expect_error('5001 stale due date', 'DUE_DATE_CHANGED', 5001, 6000, 'test-5001-c', today - 29);
  pay(5001, 6000, 'test-5001-ok', today - 30);
  check_that('5001 on last day of grace -> RECORDED', l_result = 'RECORDED' AND l_n = 1);
  check_date('5001 next due moved one quarter', l_next, POLICY_RULES.add_period(today - 30, 3, 31));

  pay(5001, 6000, 'test-5001-ok');
  check_that('5001 same key again -> ALREADY_RECORDED', l_result = 'ALREADY_RECORDED');
  SELECT COUNT(*) INTO l_count FROM PAYMENTS WHERE IDEMPOTENCY_KEY = 'test-5001-ok';
  check_that('5001 replay created no second payment', l_count = 1);

  expect_error('same key, different amount', 'IDEMPOTENCY_KEY_REUSED', 5001, 7000, 'test-5001-ok');
  expect_error('same key, different policy', 'IDEMPOTENCY_KEY_REUSED', 5003, 2000, 'test-5001-ok');
  expect_error('legacy key replayed on other policy', 'IDEMPOTENCY_KEY_REUSED', 5003, 2000, 'BR-RETRY-7C41E9AA');
  expect_error('5001 again, new key, stale due date', 'DUE_DATE_CHANGED', 5001, 6000, 'test-5001-d', today - 30);
  expect_error('5001 again, new key, nothing due', 'NOTHING_DUE', 5001, 6000, 'test-5001-e');

  -- 5002: quarterly, one day past grace -> lapsed; revival of its one instalment.
  pay(5002, 4200, 'test-5002');
  check_that('5002 lapsed yesterday, revived with 1 instalment', l_result = 'RECORDED' AND l_n = 1);

  -- 5003 monthly, last day of its 15-day grace. 5004 one day past.
  pay(5003, 2000, 'test-5003');
  check_that('5003 monthly on last grace day -> RECORDED', l_result = 'RECORDED');

  -- 5007: yearly, due in 31 days -> nothing due.
  expect_error('5007 due in 31 days', 'NOTHING_DUE', 5007, 36000, 'test-5007');

  -- 5008/5009/5010: revival window measured from FIRST_UNPAID_DUE_DATE.
  expect_error('5008 revival with a single premium', 'AMOUNT_MISMATCH', 5008, 12000, 'test-5008-a');
  pay(5008, 60000, 'test-5008-b');
  check_that('5008 revived on the last day of the window (5 instalments)', l_result = 'RECORDED' AND l_n = 5);
  SELECT COUNT(*) INTO l_count FROM PAYMENTS WHERE IDEMPOTENCY_KEY = 'test-5008-b';
  check_that('5008 revival wrote 5 payment rows', l_count = 5);
  check_that('5008 no longer lapsed', due_of(5008) > today);
  expect_error('5009 one day outside the window', 'REVIVAL_WINDOW_EXPIRED', 5009, 45000, 'test-5009');

  -- Flagged data.
  expect_error('5014 has no premium on record', 'POLICY_NOT_SERVICEABLE', 5014, 12500, 'test-5014');
  expect_error('5018 single premium',           'POLICY_NOT_SERVICEABLE', 5018, 60000, 'test-5018');
  expect_error('unknown policy',                'POLICY_NOT_FOUND', 424242, 100, 'test-none');

  -- Input validation.
  expect_error('amount with 3 decimals', 'INVALID_REQUEST', 5006, 24000.005, 'test-5006-a');
  expect_error('negative amount',        'INVALID_REQUEST', 5006, -1, 'test-5006-b');

  ROLLBACK;
  IF g_failures > 0 THEN
    RAISE_APPLICATION_ERROR(-20900, g_failures || ' check(s) failed');
  END IF;
  DBMS_OUTPUT.PUT_LINE('all checks passed');
END;
/
EXIT
