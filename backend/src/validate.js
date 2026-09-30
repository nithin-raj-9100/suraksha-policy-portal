'use strict';

const { AppError } = require('./errors');

const STATUSES = ['PAID', 'DUE', 'IN_GRACE', 'LAPSED'];
const CHANNELS = ['BRANCH', 'ONLINE', 'AGENT', 'AUTO-DEBIT'];
const MAX_PAGE_SIZE = 100;

function bad(message, field) {
  return new AppError(400, 'INVALID_REQUEST', message, field);
}

function positiveInt(value, fallback, name) {
  if (value === undefined || value === '') return fallback;
  if (!/^\d{1,9}$/.test(String(value)) || Number(value) < 1) {
    throw bad(`${name} must be a whole number of 1 or more.`, name);
  }
  return Number(value);
}

function listQuery(q) {
  const page = positiveInt(q.page, 1, 'page');
  const pageSize = positiveInt(q.pageSize, 20, 'pageSize');
  if (pageSize > MAX_PAGE_SIZE) throw bad(`pageSize can be at most ${MAX_PAGE_SIZE}.`, 'pageSize');

  let status = null;
  if (q.status !== undefined && q.status !== '') {
    status = String(q.status).toUpperCase();
    if (!STATUSES.includes(status)) throw bad(`status must be one of ${STATUSES.join(', ')}.`, 'status');
  }

  let search = null;
  if (q.search !== undefined) {
    search = String(q.search).trim().replace(/\s+/g, ' ');
    if (search.length > 100) throw bad('search can be at most 100 characters.', 'search');
    if (search === '') search = null;
  }

  return { page, pageSize, status, search };
}

// '%' and '_' typed by a clerk are literal characters, not wildcards.
function likePattern(search) {
  return '%' + search.toUpperCase().replace(/[\\%_]/g, (c) => '\\' + c) + '%';
}

function policyId(value) {
  if (!/^\d{1,12}$/.test(String(value))) {
    throw new AppError(404, 'POLICY_NOT_FOUND', `No policy with id ${String(value).slice(0, 40)} exists.`);
  }
  return Number(value);
}

function idempotencyKey(value) {
  if (value === undefined || value === '') {
    throw new AppError(400, 'IDEMPOTENCY_KEY_REQUIRED', 'Every payment request needs an Idempotency-Key header.');
  }
  if (!/^[\x21-\x7E]{1,64}$/.test(value)) {
    throw bad('Idempotency-Key must be 1 to 64 printable characters without spaces.');
  }
  return value;
}

// Accepts 12500, 12500.5, "12500.00". Rejects 1e5, -1, 0.001, "12,500".
function amount(value) {
  const text = typeof value === 'number' ? String(value) : typeof value === 'string' ? value.trim() : '';
  if (!/^\d{1,10}(\.\d{1,2})?$/.test(text) || Number(text) <= 0) {
    throw bad('Enter the amount in rupees, greater than zero, with at most two decimal places.', 'amount');
  }
  return Number(text);
}

function channel(value) {
  if (value === undefined || value === null || value === '') return 'BRANCH';
  const c = String(value).toUpperCase();
  if (!CHANNELS.includes(c)) throw bad(`channel must be one of ${CHANNELS.join(', ')}.`, 'channel');
  return c;
}

function isoDate(value, name) {
  if (value === undefined || value === null || value === '') return null;
  const s = String(value);
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
  const d = m && new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  if (!d || d.getUTCFullYear() !== +m[1] || d.getUTCMonth() !== +m[2] - 1 || d.getUTCDate() !== +m[3]) {
    throw bad(`${name} must be a date in YYYY-MM-DD form.`, name);
  }
  return s;
}

function paymentRequest(req) {
  const body = req.body || {};
  return {
    policyId: policyId(req.params.id),
    key: idempotencyKey(req.get('Idempotency-Key')),
    amount: amount(body.amount),
    channel: channel(body.channel),
    dueDate: isoDate(body.dueDate, 'dueDate'),
  };
}

module.exports = { listQuery, likePattern, policyId, paymentRequest, amount, isoDate, STATUSES, CHANNELS };
