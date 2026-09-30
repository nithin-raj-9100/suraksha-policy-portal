# Code review — `legacy/paymentService.js`

This file is in production. Do not fix it; review it.

Severity: `Critical` (money, data loss, security) · `High` · `Medium` · `Low`.

Several of these are not hypothetical: the legacy data shows their fingerprints.
Where that is the case I say so.

---

### 1. Premium modes other than exactly `'M'`, `'Q'`, `'H'` are treated as yearly

**Severity:** Critical

**What:** `let days = 365; if (mode == 'M') ... else if (mode == 'Q') ... else if (mode == 'H')`.
The data holds 25 spellings of four modes (`'monthly'`, `'Mly'`, `'mth'`,
`' Quarterly'`, `'QTR'`, `'half yearly'`, `'SEMI-ANNUAL'` …). Only 19 of 194
policies use exactly `M`, `Q` or `H`. Everything else falls through to 365 days.

**Why it matters in production:** a customer on a ₹1,500 *monthly* policy stored
as `'monthly'` pays once at the counter and their next due date jumps a full
year. The system then shows them as paid-up for eleven months they have not
paid for. The insurer is carrying risk it is not being paid for, the customer
gets no reminder, and when someone finally notices, the "fix" is a demand for
eleven months of arrears from a customer who did nothing wrong. It happens
silently on every such payment, every day, and each one corrupts the only
record of what is owed.

**Fix:** normalise the mode once, in the database, against a reference table
(`PREMIUM_MODES` with period and grace), with a foreign key so an unknown mode
cannot be stored. Fail loudly on an unknown mode rather than defaulting.

---

### 2. Payment and due-date update are two separate commits, with no lock

**Severity:** Critical

**What:** the `INSERT INTO PAYMENTS` and the `UPDATE POLICIES` each run with
`autoCommit: true`. Nothing locks the policy row between reading `nextDue` and
writing the new one.

**Why it matters in production:**
- If the process dies, the connection drops or the `UPDATE` fails after the
  `INSERT` committed, the money is recorded but the policy still shows the
  instalment unpaid. The next clerk takes the same premium again. This has
  already happened: policy 5024 has payment 700466 for the 17 July instalment
  and still showed 17 July as unpaid.
- Two clerks serving the same customer (or one clerk plus the online channel)
  both read the same `nextDue`, both pass every check, both insert a payment
  for the same instalment, and both write the same new due date. Two payments,
  one period of cover. The customer is charged twice and the second payment is
  invisible in the due-date logic, so nobody is prompted to refund it.

**Fix:** one transaction: lock the policy (`SELECT … FOR UPDATE`), re-check the
rules against the locked row, insert, update, commit once. A unique constraint
on `(POLICY_ID, COVERS_DUE_DATE)` as the last line of defence. This is what
`RECORD_PAYMENT` does.

---

### 3. Idempotency is check-then-insert with no constraint

**Severity:** Critical

**What:** `SELECT … WHERE IDEMPOTENCY_KEY = …`, then later `INSERT`. There is no
unique constraint on the key and no lock between the two statements.

**Why it matters in production:** the whole point of the key is to survive a
double-click or a network retry, and those two requests arrive milliseconds
apart. Both run the `SELECT` before either has inserted, both see nothing,
both insert. The data proves it: payments 700467 and 700468 on policy 5034 share
key `BR-RETRY-7C41E9AA`, three seconds apart, ₹36,000 each. The customer paid
₹72,000 for one annual premium.

**Fix:** make the key unique in the database and let the insert be the check:
insert the key first, and on a unique-violation read back and return the
original result. The second request then waits for the first to commit instead
of racing it.

---

### 4. SQL injection in three places

**Severity:** Critical

**What:** `idemKey`, `policyId` and `search` are concatenated into SQL strings.
`search` comes straight from the branch dashboard's search box.

**Why it matters in production:** anyone who can type in the search box can run
arbitrary `SELECT`s: `' UNION SELECT FULL_NAME || PAN || MOBILE, … FROM CUSTOMERS --`
returns every customer's PAN and mobile number on screen. That is a reportable
personal-data breach under the DPDP Act, from an internal tool, with no
exploit skill required. `idemKey` is a request header, so it is attacker-
controlled by anything that can call the service. Separately, a customer
called O'Brien breaks search for everyone who types their name. Every
concatenated statement is also a new hard parse, which on Oracle means shared
pool churn and latch contention under load.

**Fix:** bind variables everywhere (`:key`, `:pid`, `:pattern`), and escape
`%`/`_` in the search term.

---

### 5. Connections leak on every error path

**Severity:** Critical

**What:** `conn.close()` is called on the happy paths only. There is no
`try/finally`. Any exception after `getConnection()` leaves the connection
checked out forever. Examples that throw today: a policy id that does not
exist (`row` is `undefined`, `row[4]` throws `TypeError`); `Math.random()`
colliding with an existing `PAYMENT_ID` (ORA-00001); any network blip mid-query.

**Why it matters in production:** the pool has `poolMax: 4`. Four bad requests,
from anywhere in the branch, and the pool is empty. Every subsequent request
waits on `getConnection()` until it times out (60 s by default), so the whole
branch tool freezes for everyone, and stays frozen until someone restarts the
process. It looks like "the database is down" and the real cause is invisible.

**Fix:** `try { … } finally { await conn.close(); }` around every borrowed
connection (and a rollback before release), ideally in one helper so it cannot
be forgotten.

---

### 6. `parseFloat` on a free-text premium, compared with `!=`

**Severity:** Critical

**What:** `const premium = parseFloat(row[4]); if (amount != premium) …`.
`PREMIUM_AMOUNT` is text such as `'4,200.00'`, `'Rs. 24,000.00'`,
`'INR 3,200.00'`.

**Why it matters in production:**
- `parseFloat('4,200.00')` is `4`. A ₹4,200 premium is rejected when the
  customer pays ₹4,200, and **accepted** when someone enters ₹4. The policy is
  then moved forward as fully paid for a four-rupee payment.
- `parseFloat('Rs. 24,000.00')` is `NaN`, and `x != NaN` is always true, so
  those policies can never take a payment at all. The clerk sees "Amount does
  not match premium", tries again, and the customer walks away.
- `!=` coerces, so `"6000"` (a string from JSON) passes, and floating-point
  equality on money is fragile in general.

**Fix:** store the premium as `NUMBER(12,2)`, compare as a number in the
database, and give the clerk the expected amount in the rejection.

---

### 7. The grace period is wrong for monthly policies and wrong at the boundary

**Severity:** High

**What:** `graceEnd = nextDue + 30 days; if (today > graceEnd) lapsed`, with
`today = new Date()`.

**Why it matters in production:**
- Monthly policies get 30 days of grace instead of 15. For 15 days after a
  monthly policy has lapsed, the counter accepts an ordinary premium as if it
  were on time, skipping the revival process and whatever underwriting it
  implies. Claims made in that window are covered by a policy that should not
  have been in force.
- `nextDue` comes back from node-oracledb as midnight, so `graceEnd` is midnight
  at the **start** of the last day. Any payment after 00:00 on the final day of
  grace is refused, although the rule is that the last day counts. Those
  customers are wrongly told their policy lapsed.
- On a server running in UTC, "today" changes at 05:30 IST. A customer who pays
  at 00:30 IST the day after grace ends is accepted as on time. The data has one
  of these: payment 700465 on policy 5023 was taken at 00:30 IST on the day
  after grace ended.

**Fix:** grace per mode from reference data; compare calendar **dates** in IST
(`today_ist <= due_date + grace_days`), not timestamps in server time.

---

### 8. Periods are counted in days, not calendar months

**Severity:** High

**What:** monthly = 30 days, quarterly = 90, half-yearly = 180, yearly = 365.

**Why it matters in production:** due dates drift away from the contract.
31 January + 30 days is 2 March, not 28/29 February. A monthly policy loses
about five days a year; a yearly one slips a day every leap year. Customers get
reminders on the wrong day, and grace and lapse are computed from the wrong
date, so a policy can lapse days before the contract says it should. The legacy
data shows it: in 181 of 191 policies the day of the next due date no longer
matches the commencement day.

**Fix:** add calendar months, clamped to the end of short months, anchored on
the policy's due day so 31 Jan → 28 Feb → 31 Mar (plain `ADD_MONTHS` also
drifts: 28 Feb → 31 Mar for a 28th policy).

---

### 9. No revival window and no revival amount

**Severity:** High

**What:** any policy past `nextDue + 30` is rejected as lapsed.
`FIRST_UNPAID_DUE_DATE` is read and never used.

**Why it matters in production:** lapsed policies inside the two-year revival
window cannot be revived at the counter at all, so the branch loses renewals it
is allowed to take and customers lose cover they are entitled to restore.
Combined with #1 and #7, some lapsed policies are wrongly accepted with a single
premium instead of all arrears.

**Fix:** allow revival until `FIRST_UNPAID_DUE_DATE + 2 years`, and require
exactly all pending instalments in one transaction.

---

### 10. A reused key returns someone else's payment as success

**Severity:** High

**What:** the duplicate check looks only at the key, not at the policy or amount,
and returns `{ ok: true, duplicate: true, paymentId }`.

**Why it matters in production:** if a key is ever reused (a client bug, a
hard-coded key, a copy-pasted request), a payment for policy B is reported as
successful using policy A's payment id. The clerk hands over a receipt, the
customer leaves, and no money was recorded against B. B later lapses.

**Fix:** store policy and amount with the key; a repeat with different values
is an error, not a success.

---

### 11. Payment ids from `Math.random()`

**Severity:** High

**What:** `PAYMENT_ID = Math.floor(Math.random() * 100000000)`.

**Why it matters in production:** by the birthday bound, collisions become
likely after roughly 10,000 payments. A collision is an ORA-00001 that is not
caught, so the request crashes *and* leaks the connection (#5). Receipt numbers
are also not ordered, which makes reconciliation with the bank harder. And it
ignores `SEQ_PAYMENT_ID`, which exists for this.

**Fix:** use the sequence.

---

### 12. `SYSTIMESTAMP` into a UTC column

**Severity:** Medium

**What:** `PAID_AT` is documented as UTC; the insert writes `SYSTIMESTAMP`
into a plain `TIMESTAMP`, which drops the offset and stores the database
host's local time.

**Why it matters in production:** on a DB host set to IST, every new row is
5h30m off from the legacy rows, silently. Every on-time/late judgement and
every "paid on" date on a receipt is then wrong for payments near midnight,
and the column no longer means one thing.

**Fix:** `SYS_EXTRACT_UTC(SYSTIMESTAMP)`, or a `TIMESTAMP WITH TIME ZONE` column.

---

### 13. Dates cross the driver as JS `Date`s

**Severity:** Medium

**What:** `nextDue` is fetched as a JS `Date` and `newDue` is bound back as one,
with `setDate()` arithmetic in the Node process's time zone.

**Why it matters in production:** node-oracledb converts `DATE` using the
Node process's time zone. If the app server's `TZ` differs from what whoever
wrote the data assumed (or changes during a migration to a new host), due dates
are written back shifted by a day. That moves grace and lapse by a day for
every policy touched, with nothing in the logs.

**Fix:** keep date arithmetic in the database, or move dates as `YYYY-MM-DD`
strings.

---

### 14. `listPoliciesWithTotals` is N+1, unpaginated and sums money in floats

**Severity:** Medium

**What:** one query for all matching policies, then one query per policy for its
payments, holding a connection throughout; no paging; totals summed in JS;
`LIKE` is case-sensitive.

**Why it matters in production:** with 194 policies it is 195 round trips; with
a real book of business it is hundreds of thousands, holding one of only four
pooled connections (#5) for minutes, starving payments at the counter. JS
floating-point sums of rupees drift in the paise. A clerk searching "rajesh"
does not find "Rajesh Patel", and totals include duplicate and orphaned rows.

**Fix:** one query with `SUM() … GROUP BY` or a join, `OFFSET/FETCH` paging,
`UPPER()` on both sides, bind variables.

---

### 15. Logs contain customer data and keys

**Severity:** Medium

**What:** every request logs the whole policy row and the idempotency key.

**Why it matters in production:** logs are usually kept longer and guarded less
than the database. Customer ids, premiums and policy numbers in plain text
logs widen the blast radius of any log leak, and idempotency keys in logs are
replayable request identifiers.

**Fix:** log a request id, the policy id and the outcome; nothing else.

---

### 16. Errors are strings with no codes; `init()` is not guarded

**Severity:** Low

**What:** failures come back as `{ ok: false, error: 'Policy has lapsed' }`;
callers cannot tell a business rule from an outage. `pool` is `undefined` if
anything calls `recordPayment` before `init()` resolves.

**Why it matters in production:** the HTTP layer cannot map these to
meaningful status codes, so retries and alerting treat "wrong amount" the same
as "database down". The first requests after a restart crash with
`Cannot read properties of undefined`.

**Fix:** typed errors with a machine-readable code, and start listening only
after the pool is ready.

---

## If you had to fix one thing before Monday

**#1, the mode fall-through.** The others are serious, but they need an unlucky
event (a double-click, a crash, a malicious search). #1 needs nothing: every
counter payment on a policy whose mode is not literally `M`, `Q` or `H` pushes
the due date a year ahead, today. That is 175 of 194 policies (the ones whose
premium text also survives `parseFloat`, #6, are the ones taking payments). Each one silently
creates months of unpaid cover and a record that is wrong in a way that only
gets harder to unwind the longer it runs. The fix is small and low-risk (map
the known spellings, refuse anything unknown) and can ship alone.

I would ship #4 (bind variables) in the same release: it is equally
mechanical, and a data leak from the search box is the one issue that could
become public.
