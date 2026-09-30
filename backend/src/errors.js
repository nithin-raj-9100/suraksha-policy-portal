'use strict';

class AppError extends Error {
  constructor(status, code, message, field) {
    super(message);
    this.status = status;
    this.code = code;
    this.field = field;
  }
}

// Business-rule errors raised by RECORD_PAYMENT as "ORA-200nn: CODE: message".
const BUSINESS_ERRORS = {
  POLICY_NOT_FOUND: { status: 404 },
  POLICY_NOT_SERVICEABLE: { status: 422 },
  DUE_DATE_CHANGED: { status: 409 },
  NOTHING_DUE: { status: 422 },
  REVIVAL_WINDOW_EXPIRED: { status: 422 },
  AMOUNT_MISMATCH: { status: 422, field: 'amount' },
  IDEMPOTENCY_KEY_REUSED: { status: 422 },
  INVALID_REQUEST: { status: 400 },
  POLICY_BUSY: { status: 409 },
  INSTALMENT_ALREADY_PAID: { status: 409 },
};

const UNAVAILABLE = [
  /^NJS-040/, // connection request timeout (pool queue)
  /^NJS-500/, // connection to the database was closed
  /^NJS-503/, // connection refused
  /^NJS-510/, // connect timeout
  /^NJS-521/, // connection reset
  /^ORA-12514/,
  /^ORA-12541/,
  /^ORA-03113/,
  /^ORA-03114/,
];

function fromOracle(err) {
  const firstLine = String(err.message || '').split('\n')[0];

  const m = /^ORA-20\d{3}: ([A-Z_]+): (.*)$/.exec(firstLine);
  if (m && BUSINESS_ERRORS[m[1]]) {
    const { status, field } = BUSINESS_ERRORS[m[1]];
    return new AppError(status, m[1], m[2], field);
  }

  if (UNAVAILABLE.some((re) => re.test(firstLine))) {
    return new AppError(503, 'DATABASE_UNAVAILABLE', 'The policy database is not reachable right now. Please try again in a minute.');
  }

  return null;
}

module.exports = { AppError, fromOracle, BUSINESS_ERRORS };
