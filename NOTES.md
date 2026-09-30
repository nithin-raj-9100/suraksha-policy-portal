# NOTES

---

## How to run this

From a clean clone:

```bash
# 1. Database (first start takes 3-6 minutes)
docker compose up -d
docker compose logs -f oracle          # wait for "DATABASE IS READY TO USE!", then Ctrl-C

# 2. Migrations: applies db/migrations/V*.sql in order, once each
./db/migrate.sh

# 3. (optional) SQL checks for the rules and RECORD_PAYMENT; everything is rolled back
./db/test.sh

# 4. Backend  (terminal 2)
cd backend && cp .env.example .env && npm install && npm run dev
npm test                               # unit tests for validation and error mapping

# 5. Frontend (terminal 3)
cd frontend && npm install && npm run dev   # http://localhost:5173
```

`db/migrate.sh` runs each file through `sqlplus` inside the container as
`SURAKSHA`, stops at the first error (including PL/SQL compile errors, which
sqlplus would otherwise only warn about) and records applied versions in
`SCHEMA_MIGRATIONS`, so running it again is a no-op. Oracle DDL is not
transactional: if a migration fails half-way, `docker compose down -v` and start
again rather than re-running it.

Concurrency check against the running API (it records real payments):

```bash
cd backend && node scripts/concurrency-check.js 5006 24000 20
```

**The seed ages.** `02_seed.sql` sets every date relative to `SYSDATE` at load
time. The statuses below, and the boundary cases `db/test.sh` relies on (5001
on its last day of grace, 5008 on the last day of its revival window …), are
only true on the day the database was created. On a later day, `docker compose
down -v` and start again.

---

## Schema changes

Migrations, in order:

| File | What |
|---|---|
| `V001__premium_modes_and_policy_cleanup.sql` | `PREMIUM_MODES` reference table (period, grace). Legacy text columns renamed `LEGACY_PREMIUM_MODE` / `LEGACY_PREMIUM_AMOUNT`; typed `PREMIUM_MODE` / `PREMIUM_AMOUNT NUMBER(12,2)` added under the original names and populated. `DATA_ISSUE`, `DUE_DAY`, `POLICY_NO_CONFLICT_OF` added. Policy numbers upper-cased. |
| `V002__customers_cleanup.sql` | `CHAR` length semantics; names/PAN/email trimmed and normalised; `PAN_CONFLICT_OF`, `DATA_ISSUE`. |
| `V003__policy_rules_package.sql` | `POLICY_RULES`: IST business date, month arithmetic, status, revival deadline, instalments payable, INR formatting. |
| `V004__payments_reconcile_and_idempotency.sql` | `PAYMENT_SUSPENSE`; bad payment rows moved there; policy 5024 reconciled; `PAYMENT_REQUESTS` (idempotency ledger), back-filled from legacy payments. |
| `V005__constraints_and_indexes.sql` | Constraints and indexes below. |
| `V006__record_payment.sql` | `RECORD_PAYMENT`. |
| `V007__policy_status_view.sql` | `V_POLICY_STATUS`. |

Constraints added (V005):

| Change | Why |
|---|---|
| `NOT NULL` on the columns every row needs | The legacy schema allowed a payment with no policy, amount or date. |
| `CK_CUSTOMERS_PAN_FORMAT`, `CK_CUSTOMERS_MOBILE`, `CK_CUSTOMERS_EMAIL`, `CK_CUSTOMERS_NAME_TRIMMED` | Format rules the cleanup established; keeps them established. |
| `FK_POLICIES_MODE` → `PREMIUM_MODES` | One place defines the modes, their period and grace. An unknown mode cannot be stored. |
| `CK_POLICIES_POLICY_NO` (`= UPPER(TRIM(...))`) | Makes the unique index below case-insensitive in effect, and lets search use a plain `LIKE`. |
| `CK_POLICIES_PREMIUM`, `CK_POLICIES_SUM_ASSURED` (> 0) | A zero or negative premium made it into the legacy data. |
| `CK_POLICIES_DUE_DAY` (1..31), `CK_POLICIES_DATES_ARE_DATES` (`d = TRUNC(d)`), `CK_POLICIES_DUE_AFTER_START` | Due dates are calendar dates; a time component would silently break every `<=` comparison. |
| `CK_POLICIES_SERVICEABLE` | A policy may lack a mode, premium or due date only while it carries a `DATA_ISSUE` saying why. |
| `FK_POLICIES_CUSTOMER` **ENABLE NOVALIDATE** | Enforced for every new/changed row; tolerates the one legacy orphan (5021). Verified an `UPDATE` of 5021's due date still succeeds. |
| `FK_PAYMENTS_POLICY`, `FK_PAYMENTS_REQUEST`, `FK_PAYMENT_REQUESTS_POLICY` | Referential integrity for money. |
| `CK_PAYMENTS_AMOUNT`, `CK_PAYMENTS_CHANNEL`, `CK_PAYMENTS_COVERS` | |
| `UQ_PAYMENTS_INSTALMENT (POLICY_ID, COVERS_DUE_DATE)` | An instalment is paid once. The last line of defence against a double charge whatever the application does. |
| `PK_PAYMENT_REQUESTS (IDEMPOTENCY_KEY)` | The idempotency guarantee. See below for why it is not a unique key on `PAYMENTS`. |

Indexes, and the query each one serves (plans checked with `EXPLAIN PLAN`):

| Index | Query it serves |
|---|---|
| `UX_POLICIES_POLICY_NO (POLICY_NO, NVL2(POLICY_NO_CONFLICT_OF, POLICY_ID, NULL))` | Integrity: one policy per number. The expression lets the two known legacy clashes coexist (the second carries the id it clashes with) while any new duplicate collides on `(number, NULL)`. |
| `UX_CUSTOMERS_PAN (PAN, NVL2(PAN_CONFLICT_OF, CUSTOMER_ID, NULL))` | Integrity: one customer per PAN, same pattern for the three legacy rows sharing a PAN. |
| `IX_POLICIES_CUSTOMER (CUSTOMER_ID)` | `GET /policies/:id` → "other policies of this customer": `V_POLICY_STATUS WHERE CUSTOMER_ID = :cid` (plan: `INDEX RANGE SCAN IX_POLICIES_CUSTOMER`). Also the FK index on `POLICIES.CUSTOMER_ID`. |
| `UQ_PAYMENTS_INSTALMENT (POLICY_ID, COVERS_DUE_DATE)` (from the constraint) | Payment history: `PAYMENTS WHERE POLICY_ID = :id ORDER BY PAID_AT DESC` uses its leading column (plan: range scan + sort of a handful of rows). I did not add `(POLICY_ID, PAID_AT)` for the sort: a policy has tens of payments, not thousands. |
| `IX_PAYMENTS_IDEM_KEY (IDEMPOTENCY_KEY)` | `POST /policies/:id/payments` reads back the receipts for the key (`PAYMENTS WHERE IDEMPOTENCY_KEY = :key`), on first request and on replay. Also the FK index for `FK_PAYMENTS_REQUEST`. |

Deliberately **not** indexed:

- **Search** (`POLICY_NO LIKE '%x%' OR UPPER(CUSTOMER_NAME) LIKE '%x%'`). A
  leading wildcard cannot use a B-tree. At 194 rows a full scan is instant. At
  scale: Oracle Text, or prefix search on policy number.
- **Status filter.** Status is computed from `NEXT_DUE_DATE` and today, so an
  index on the status would be stale by tomorrow. Each status is a range of
  `NEXT_DUE_DATE` for a given day, so at scale I would add an index on
  `NEXT_DUE_DATE` and have the list query add the matching coarse range
  predicate. Not worth it at this size, and an index without that predicate
  would not be used.

## Concurrency

What stops two simultaneous payments on the same policy from both succeeding,
in order:

1. **Row lock.** `RECORD_PAYMENT` starts with
   `SELECT … FROM POLICIES WHERE POLICY_ID = :id FOR UPDATE WAIT 10`. The second
   session blocks until the first commits, then reads the *updated* row. All
   checks run against the locked row, never against something read earlier.
2. **Expected due date.** The UI sends the due date the clerk was looking at
   (`dueDate`). After the first payment commits, the second session sees a
   different `NEXT_DUE_DATE` and is refused with `409 DUE_DATE_CHANGED` ("the
   instalment due on … has already been paid, possibly at another counter").
   This matters most for monthly policies: after a payment the next monthly due
   date is ~30 days away, which is still `DUE`, so without this check the second
   clerk would legitimately pay *next* month.
3. **Nothing due.** Without `dueDate` (e.g. a raw API caller), a yearly,
   half-yearly or quarterly policy is `PAID` after the first payment and the
   second gets `422 NOTHING_DUE`.
4. **`UQ_PAYMENTS_INSTALMENT`.** Even if all of the above were bypassed, the same
   instalment cannot be inserted twice.

Locks are always taken policy row first, then the idempotency key, so two calls
cannot deadlock each other. `WAIT 10` turns a stuck lock into `409 POLICY_BUSY`
instead of a hung counter.

How I tested it:
- `db/test.sh`: sequential cases in one session (replay, stale due date, nothing due).
- `backend/scripts/concurrency-check.js 5006 24000 20`: 20 simultaneous requests
  with one key → 1 × `201 RECORDED`, 19 × `200 ALREADY_RECORDED`, one payment row.
  Then 20 simultaneous with different keys → 20 × `409 DUE_DATE_CHANGED`.
- 8 simultaneous `curl`s with different keys on fresh monthly policy 5030 →
  1 × 201, 7 × 409. 4 simultaneous without `dueDate` on monthly 5086 → 1 × 201,
  3 × 422 `NOTHING_DUE` (next due was 41 days out after the first).
- In the browser: double-click on "Record payment" → one `POST` in the API log.

Known gap: an API caller that omits `dueDate` on a monthly policy whose *next*
instalment is within 30 days after paying can pay two months in a row with two
different keys. That is arguably correct (it is an advance payment of a
different instalment), but it is why the UI always sends `dueDate`. If the API
had only one client I would make `dueDate` required.

## Idempotency

- **Where:** in the database. `RECORD_PAYMENT` inserts the key into
  `PAYMENT_REQUESTS` (primary key) *after* taking the policy lock. A duplicate
  raises `DUP_VAL_ON_INDEX`; the procedure reads the stored row and returns its
  result. A concurrent duplicate blocks on the uncommitted key and gets the
  duplicate error once the first commits, so it never races.
- **Why a separate table** and not `UNIQUE` on `PAYMENTS.IDEMPOTENCY_KEY`: a
  revival writes one `PAYMENTS` row per instalment for one request. So the key
  is unique in `PAYMENT_REQUESTS`, and `PAYMENTS.IDEMPOTENCY_KEY` is a foreign
  key to it. Legacy payments were back-filled as `SOURCE = 'LEGACY'` so their
  keys count as used too.
- **What a repeat returns:** `200` with header `Idempotent-Replayed: true` and
  the same body as the first response (`result: "ALREADY_RECORDED"`, same
  payment id, next due date, receipts). A first success is `201`.
- **Same key, different request** (other policy or amount): `422
  IDEMPOTENCY_KEY_REUSED`, nothing recorded.
- **Rejections are not stored.** A business-rule rejection rolls back the whole
  call, including the key, so retrying the same key re-evaluates. That is safe
  because a rejection had no effect.
- **In the browser**, a key identifies one payment *attempt*. It is created on
  first submit and kept for every retry while the outcome is unknown (network
  error, 30 s timeout, 5xx, `POLICY_BUSY`), so "try again" can never charge
  twice. It is discarded after a success, after a definite rejection, or when
  the clerk edits the amount or channel (a different payment).

## Data issues

The first, naive `V001__constraints_and_indexes.sql` (in git history, output in
`db/logs/V001-first-run.txt`) failed 8 of 11 statements. One "passed" and was
worse than failing: `UNIQUE (PAN)` succeeded because `'ABCDE1234F'`,
`'abcde1234f'` and `' ABCDE1234F '` are different strings. A constraint that
protects nothing.

What I found, and what I did. General rule: never delete money, never guess a
value, flag what I cannot fix.

| What you found | What you did |
|---|---|
| `PREMIUM_MODE` in 25 spellings (`'Mly'`, `' Quarterly'`, `'SEMI-ANNUAL'`, `'  YEARLY '`, `'HY'`, …) | Mapped every one to the four modes (strip non-letters, upper-case, lookup). Raw value kept in `LEGACY_PREMIUM_MODE`. |
| One policy (5018) with mode `SINGLE` | Single-premium is not one of R1's modes; there are no instalments to service. `PREMIUM_MODE` left NULL, `DATA_ISSUE` set, payments refused. |
| `PREMIUM_AMOUNT` as text: `'4,200.00'`, `'Rs. 24,000.00'`, `'INR 3,200.00'`, `'  60000 '` | Parsed into `NUMBER(12,2)` (strip `Rs.`/`INR`, commas, padding; must match `^-?\d+(\.\d{1,2})?$`). Raw text kept. The column could not be `MODIFY`'d in place (ORA-01439), hence rename + new column. |
| Premium missing (5014), `'0'` (5015), `'-2,500.00'` (5016) | Flagged, premium NULL, payments refused. 5016 has three payments of ₹2,500, so the sign is probably a typo, but a migration should not decide a premium. |
| No `NEXT_DUE_DATE`: 5011 (legacy status SURRENDERED), 5012 (MATURED), 5013 (**ACTIVE**) | Status cannot be derived; shown as "Needs review", payments refused. I used `LEGACY_STATUS` only to write the explanation, never for status. 5013 is the worrying one: "active" with no due date. |
| Policy number `SL-2024-000120` and `sl-2024-000120` on two different policies (5019, 5020): different customers, plans, start dates. `SL-2024-000119` does not exist, so 5019 was probably meant to be `…119`. | Cannot renumber a policy the customer holds a document for. Both flagged; 5020 records `POLICY_NO_CONFLICT_OF = 5019`; unique index allows exactly this pair. |
| Policy 5021 → customer 999999, which does not exist | Kept (it is real business); flagged; FK added `ENABLE NOVALIDATE`. I would not invent a customer row. |
| PAN `ABCDE1234F` on customers 1151/1152/1153 (in three casings/paddings). It is also the sample PAN from Income Tax documentation. | Normalised. Not merged: they have different mobiles and emails, and it may be a placeholder typed by staff rather than one person. Merging is a KYC decision. Flagged with `PAN_CONFLICT_OF`. |
| Names with double spaces / trailing spaces; casing like `'rAJESH  mehta'` | Whitespace collapsed. Casing left alone (INITCAP would mangle real names; search is case-insensitive anyway). |
| `'Hiral Patel / હિરલ પટેલ'`: 23 characters, 39 bytes; columns were `VARCHAR2(n BYTE)` | Name/email/city moved to `CHAR` semantics so a full Gujarati name fits. |
| Payment 700469 for policy 888888, which does not exist | Moved to `PAYMENT_SUSPENSE` ("unallocated"). |
| Payments 700467 and 700468 on 5034: same key `BR-RETRY-7C41E9AA`, same instalment, 3 s apart, ₹36,000 each. A double charge. | 700467 stands; 700468 to suspense as a refund candidate. |
| Payment 700465 on 5023 was taken at 00:30 **IST** the day after grace ended (19:00 UTC, still "on time" in UTC). Policy still shows that instalment unpaid. | By R3 it was late; the policy had lapsed. Moved to suspense ("refund, or apply to revival"). 5023 stays lapsed and revivable. |
| Payment 700466 on 5024: paid at 23:30 IST on the last day of grace (on time), but the policy still showed that instalment unpaid | The legacy two-commit bug: the payment committed, the due-date update did not. Policy advanced by one quarter (now `DUE`, 17 Oct). |
| `FIRST_UNPAID_DUE_DATE` later than `NEXT_DUE_DATE` on 5008, 5009, 5010 (by 70-89 days). Impossible: the next unpaid instalment cannot be newer than the oldest unpaid one. | Left as is and followed the spec: the revival window is measured from `FIRST_UNPAID_DUE_DATE`. These three sit exactly at 730/731/729 days, so they look like deliberate boundary cases. Using `NEXT_DUE_DATE` would refuse all three. No check constraint added for this invariant because these rows would fail it. |
| In 181 of 191 policies the due date's day no longer matches the commencement day | Consistent with the legacy +30/+90/+180/+365-day arithmetic drifting schedules. `DUE_DAY` keeps the commencement day where the current due date still agrees with it (allowing a short-month clamp), else the current due date's day, so we do not jump a due date to "fix" it. |
| 51 legacy payments cover due dates later than the policy's `NEXT_DUE_DATE`; 33 cover due dates before commencement; payment history generally does not reconcile with the policies | Treated legacy history as informational; status comes from the policy row. If a new payment would collide with such a legacy row, `UQ_PAYMENTS_INSTALMENT` refuses it with `INSTALMENT_ALREADY_PAID` ("refer to Operations"), which is the right outcome for data nobody can explain. |
| Payments that do not equal the premium: 700471/700472 on 5041 (₹1,200.10 and ₹1,200.20 on a ₹3,200 premium), 700470 on 5061 (₹9,000 on ₹18,000) | Left in history. Evidence that the legacy system did not enforce R5 (`parseFloat` bug, see REVIEW #6). |
| `LEGACY_STATUS` in five spellings (`ACTIVE`, `active`, `IN FORCE` …) | Ignored, per R4. |
| 49 customers have no policy | Nothing to do; noted. |

## Decisions and trade-offs

- **Today is the IST calendar date** (`SYSTIMESTAMP AT TIME ZONE 'Asia/Kolkata'`),
  whatever the DB host or Node runs in. All rules compare **dates**, never
  timestamps, so "the last day counts" (R3) holds for a payment at 23:59 IST.
  `PAID_AT` is written as `SYS_EXTRACT_UTC(SYSTIMESTAMP)`.
- **Dates never cross the driver as JS `Date`s.** node-oracledb converts
  `DATE`/`TIMESTAMP` using the Node process's time zone; a due date fetched in
  IST serialises to the previous day in UTC JSON. All dates leave SQL via
  `TO_CHAR` (`YYYY-MM-DD`, or ISO UTC for `PAID_AT`) and are bound back as text.
  The browser formats `YYYY-MM-DD` from its parts for the same reason.
- **Status boundaries** (R4 read literally): `PAID` if due > today + 30; `DUE` if
  today ≤ due ≤ today + 30 (so due in exactly 30 days is `DUE`, and due today is
  `DUE`, "not yet past"); `IN_GRACE` if due < today ≤ due + grace; `LAPSED` after.
- **Revival window is inclusive** of its last day (2 years from
  `FIRST_UNPAID_DUE_DATE`, or `NEXT_DUE_DATE` if that is NULL), by analogy with
  R3. Computed with the same month arithmetic, so 29 Feb 2024 → 28 Feb 2026.
- **Revival** = every instalment due on or before today, paid together, in one
  transaction, as one `PAYMENTS` row per instalment (each exactly the modal
  premium, so R5 and R6 still hold per instalment). The amount must equal
  `n × premium` exactly; the error tells the clerk `n`, the premium and the
  total. A lapsed policy with a single overdue instalment revives with one
  premium.
- **Payments are accepted only when something is due** (`DUE`, `IN_GRACE`,
  revivable `LAPSED`). Advance payments on a `PAID` policy are refused with the
  date from which they can be taken. The spec does not mention advance
  premiums; refusing is the conservative reading and also closes the race in (3)
  above.
- **Month arithmetic** anchors on the policy's due day, clamped to short months:
  31 Jan → 28/29 Feb → 31 Mar. I did not use `ADD_MONTHS` because it is sticky at
  month-end: `ADD_MONTHS(28-FEB, 1)` is 31 Mar and `ADD_MONTHS(30-APR, 1)` is
  31 May, which moves a 28th or 30th policy onto the 31st for ever. Ambiguity:
  is a policy that commenced on 30 Sep a "30th" policy or a "month-end" policy?
  I chose "30th" (Oct 30, not Oct 31), which is how I understand Indian insurers
  compute due dates from the date of commencement.
- **Procedure signature** gained `P_EXPECTED_DUE` (optional, see Concurrency) and
  `O_INSTALMENTS` (> 1 on revival). It does not commit; the API calls it with
  `autoCommit: true`, and any error rolls back the whole call.
- **Errors**: the procedure raises `ORA-200nn: CODE: message`. The message is
  written for a clerk (amounts in ₹ with Indian grouping, dates as "30 Sep 2026").
  The API maps codes to HTTP: 400 bad input, 404 not found, 409 conflicts
  (`DUE_DATE_CHANGED`, `POLICY_BUSY`, `INSTALMENT_ALREADY_PAID`), 422 business
  rules, 503 database unreachable, 500 otherwise. Body:
  `{ error: { code, message, field?, requestId } }`.
- **Rules live in one PL/SQL package** used by both the view and the procedure,
  so the screen and the database cannot disagree about what is payable. The
  cost is PL/SQL calls per row in the view (fine at this size; `PRAGMA UDF` or
  inlining the `CASE` would be the next step).
- **Flagged policies are listed and viewable but refuse payment.** At a counter,
  telling the clerk "refer to Operations" beats taking money against a record
  that is wrong.
- **PAN is masked** in the API (`ABC****34F`). A counter screen does not need it.
- **List order** is next due date, oldest first, so the most overdue policies
  are at the top. It is also a stable order for pagination (tie-break on id).
- The API returns the total via `COUNT(*) OVER ()` in the same statement as the
  page, so the count and rows are one consistent snapshot. A page past the end
  falls back to a separate count.

## Not done / next

- **An API/integration test suite** against a disposable database (Testcontainers),
  including the concurrency script as an automated test. Right now those
  checks are `db/test.sh` + a script + manual `curl`s.
- **A `today` override for tests**, so boundary tests do not depend on the seed
  having been loaded today (see "The seed ages").
- **A nightly job** that sets `FIRST_UNPAID_DUE_DATE` when a due date passes
  unpaid. Today the view and procedure fall back to `NEXT_DUE_DATE` when it is
  NULL, which is correct but means the column is only as good as the legacy
  data.
- **Operations screens** for `DATA_ISSUE` policies and `PAYMENT_SUSPENSE` (refund
  / apply), and a proper customer-merge flow for the PAN clash.
- **Receipt printing**, and an audit column for which clerk recorded a payment
  (needs authentication, which is out of scope here).
- Oracle Text for search if the book grows; the `NEXT_DUE_DATE` range predicate
  for the status filter (see indexes).
- Make `dueDate` required on the payment API once the UI is the only client.

## AI usage

- **Tool:** Claude Code (Anthropic, Claude Opus model) in the terminal.
- **What it did:** read the brief and starter repo, profiled the seed data with
  SQL, and wrote the first drafts of all of it: the migrations and
  `POLICY_RULES`/`RECORD_PAYMENT`/`V_POLICY_STATUS`, the SQL test script, the
  Express routes and error mapping, the React screens, and first drafts of
  `REVIEW.md` and this file. It also ran the migrations against the container,
  the SQL checks, the concurrency script and a browser check of the payment form.
- **What I did:** _(fill in honestly: what you reviewed, changed, rejected or
  rewrote, and which decisions were yours.)_
