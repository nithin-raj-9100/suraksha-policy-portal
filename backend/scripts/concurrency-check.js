'use strict';

// Fires simultaneous payment requests at the running API and reports what
// happened. Records real payments: run it against a disposable database.
//
//   node scripts/concurrency-check.js <policyId> <amount> [parallel=10]

const [policyId, amount, parallel = '10'] = process.argv.slice(2);
if (!policyId || !amount) {
  console.error('usage: node scripts/concurrency-check.js <policyId> <amount> [parallel]');
  process.exit(1);
}
const BASE = process.env.API_URL || 'http://localhost:3001';
const n = Number(parallel);

async function pay(key, dueDate) {
  const res = await fetch(`${BASE}/policies/${policyId}/payments`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': key },
    body: JSON.stringify({ amount: Number(amount), channel: 'BRANCH', dueDate }),
  });
  const body = await res.json();
  return { status: res.status, code: body.error ? body.error.code : body.result, paymentId: body.paymentId };
}

function summarise(label, results) {
  const tally = {};
  for (const r of results) tally[`${r.status} ${r.code}`] = (tally[`${r.status} ${r.code}`] || 0) + 1;
  const ids = new Set(results.filter((r) => r.paymentId).map((r) => r.paymentId));
  console.log(label, tally, 'distinct payment ids:', [...ids]);
  return ids.size;
}

(async () => {
  const before = await (await fetch(`${BASE}/policies/${policyId}`)).json();
  const dueDate = before.policy.nextDueDate;
  console.log(`policy ${policyId}: ${before.policy.status}, next due ${dueDate}, ${before.payments.length} payments`);

  const run = Date.now().toString(36);
  const sameKey = await Promise.all(Array.from({ length: n }, () => pay(`cc-${run}-same`, dueDate)));
  const a = summarise(`${n} x same key:     `, sameKey);

  const diffKeys = await Promise.all(Array.from({ length: n }, (_, i) => pay(`cc-${run}-${i}`, dueDate)));
  const b = summarise(`${n} x different keys:`, diffKeys);

  const after = await (await fetch(`${BASE}/policies/${policyId}`)).json();
  const added = after.payments.length - before.payments.length;
  console.log(`policy ${policyId}: ${after.policy.status}, next due ${after.policy.nextDueDate}, ${added} payment row(s) added`);

  const ok = a <= 1 && b === 0;
  console.log(ok ? 'OK: at most one payment recorded' : 'PROBLEM: more than one payment recorded');
  process.exit(ok ? 0 : 1);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
