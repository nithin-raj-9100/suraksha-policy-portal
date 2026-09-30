'use strict';

const test = require('node:test');
const assert = require('node:assert');
const validate = require('../src/validate');
const { fromOracle } = require('../src/errors');

test('amount accepts whole rupees and paise', () => {
  assert.strictEqual(validate.amount(12500), 12500);
  assert.strictEqual(validate.amount(12500.5), 12500.5);
  assert.strictEqual(validate.amount('12500.00'), 12500);
});

test('amount rejects what a clerk could mistype', () => {
  for (const bad of [0, -1, 0.001, 1e21, '12,500', '', null, undefined, 'abc', NaN, '1e5']) {
    assert.throws(() => validate.amount(bad), /amount in rupees/, `accepted ${bad}`);
  }
});

test('search wildcards are literal', () => {
  assert.strictEqual(validate.likePattern('50%_off'), '%50\\%\\_OFF%');
});

test('list query defaults and bounds', () => {
  assert.deepStrictEqual(validate.listQuery({}), { page: 1, pageSize: 20, status: null, search: null });
  assert.strictEqual(validate.listQuery({ status: 'in_grace' }).status, 'IN_GRACE');
  assert.strictEqual(validate.listQuery({ search: '  rajesh   patel ' }).search, 'rajesh patel');
  assert.throws(() => validate.listQuery({ pageSize: '101' }));
  assert.throws(() => validate.listQuery({ page: '0' }));
  assert.throws(() => validate.listQuery({ status: 'ACTIVE' }));
});

test('dueDate must be a real calendar date', () => {
  assert.strictEqual(validate.isoDate('2028-02-29', 'dueDate'), '2028-02-29');
  assert.throws(() => validate.isoDate('2027-02-29', 'dueDate'));
  assert.throws(() => validate.isoDate('29/02/2028', 'dueDate'));
});

test('business errors from the procedure map to 4xx with their code', () => {
  const e = fromOracle(new Error('ORA-20006: AMOUNT_MISMATCH: The premium due is exactly ₹6,000.00.\nORA-06512: at "SURAKSHA.RECORD_PAYMENT", line 60'));
  assert.strictEqual(e.status, 422);
  assert.strictEqual(e.code, 'AMOUNT_MISMATCH');
  assert.strictEqual(e.field, 'amount');
  assert.strictEqual(e.message, 'The premium due is exactly ₹6,000.00.');
});

test('connectivity failures are 503, unknown errors are left for the 500 handler', () => {
  assert.strictEqual(fromOracle(new Error('NJS-040: connection request timeout')).status, 503);
  assert.strictEqual(fromOracle(new Error('ORA-00942: table or view does not exist')), null);
});
