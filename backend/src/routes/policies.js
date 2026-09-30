'use strict';

const express = require('express');
const { withConnection, oracledb } = require('../db');
const { AppError } = require('../errors');
const validate = require('../validate');

const router = express.Router();

const wrap = (fn) => (req, res, next) => fn(req, res, next).catch(next);

// Dates leave the database as 'YYYY-MM-DD' text and PAID_AT as ISO-8601 UTC.
// node-oracledb would otherwise turn DATE/TIMESTAMP into JS Dates in the Node
// process's local time zone, which shifts a due date by a day in IST and
// re-interprets UTC PAID_AT values as local time.
const POLICY_COLUMNS = `
  v.POLICY_ID,
  v.POLICY_NO,
  v.CUSTOMER_ID,
  v.CUSTOMER_NAME,
  v.PLAN_NAME,
  v.PREMIUM_MODE,
  v.PREMIUM_MODE_LABEL,
  v.GRACE_DAYS,
  v.PREMIUM_AMOUNT,
  v.SUM_ASSURED,
  TO_CHAR(v.COMMENCEMENT_DATE, 'YYYY-MM-DD')     AS COMMENCEMENT_DATE,
  TO_CHAR(v.NEXT_DUE_DATE, 'YYYY-MM-DD')         AS NEXT_DUE_DATE,
  TO_CHAR(v.FIRST_UNPAID_DUE_DATE, 'YYYY-MM-DD') AS FIRST_UNPAID_DUE_DATE,
  TO_CHAR(v.GRACE_END_DATE, 'YYYY-MM-DD')        AS GRACE_END_DATE,
  v.DERIVED_STATUS,
  TO_CHAR(v.REVIVAL_DEADLINE, 'YYYY-MM-DD')      AS REVIVAL_DEADLINE,
  v.INSTALMENTS_PAYABLE,
  v.AMOUNT_PAYABLE,
  v.DATA_ISSUE,
  TO_CHAR(v.BUSINESS_DATE, 'YYYY-MM-DD')         AS BUSINESS_DATE`;

const PAYMENT_COLUMNS = `
  PAYMENT_ID,
  AMOUNT,
  TO_CHAR(PAID_AT, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS PAID_AT,
  TO_CHAR(COVERS_DUE_DATE, 'YYYY-MM-DD')         AS COVERS_DUE_DATE,
  CHANNEL,
  IDEMPOTENCY_KEY`;

function toPolicy(r) {
  return {
    id: r.POLICY_ID,
    policyNo: r.POLICY_NO,
    customerId: r.CUSTOMER_ID,
    customerName: r.CUSTOMER_NAME,
    planName: r.PLAN_NAME,
    premiumMode: r.PREMIUM_MODE,
    premiumModeLabel: r.PREMIUM_MODE_LABEL,
    graceDays: r.GRACE_DAYS,
    premiumAmount: r.PREMIUM_AMOUNT,
    sumAssured: r.SUM_ASSURED,
    commencementDate: r.COMMENCEMENT_DATE,
    nextDueDate: r.NEXT_DUE_DATE,
    firstUnpaidDueDate: r.FIRST_UNPAID_DUE_DATE,
    graceEndDate: r.GRACE_END_DATE,
    status: r.DERIVED_STATUS,
    revivalDeadline: r.REVIVAL_DEADLINE,
    instalmentsPayable: r.INSTALMENTS_PAYABLE,
    amountPayable: r.AMOUNT_PAYABLE,
    dataIssue: r.DATA_ISSUE,
    businessDate: r.BUSINESS_DATE,
  };
}

function toPayment(r) {
  return {
    id: r.PAYMENT_ID,
    amount: r.AMOUNT,
    paidAt: r.PAID_AT,
    coversDueDate: r.COVERS_DUE_DATE,
    channel: r.CHANNEL,
  };
}

function maskPan(pan) {
  return pan ? pan.slice(0, 3) + '****' + pan.slice(-3) : null;
}

/**
 * GET /policies?status=&search=&page=&pageSize=
 */
router.get('/', wrap(async (req, res) => {
  const { page, pageSize, status, search } = validate.listQuery(req.query);

  const where = [];
  const binds = {};
  if (status) {
    where.push('v.DERIVED_STATUS = :status');
    binds.status = status;
  }
  if (search) {
    where.push(`(v.POLICY_NO LIKE :pattern ESCAPE '\\' OR UPPER(v.CUSTOMER_NAME) LIKE :pattern ESCAPE '\\')`);
    binds.pattern = validate.likePattern(search);
  }
  const whereSql = where.length ? 'WHERE ' + where.join(' AND ') : '';

  const result = await withConnection(async (conn) => {
    const rows = await conn.execute(
      `SELECT ${POLICY_COLUMNS}, COUNT(*) OVER () AS TOTAL_COUNT
         FROM V_POLICY_STATUS v
         ${whereSql}
        ORDER BY v.NEXT_DUE_DATE NULLS LAST, v.POLICY_ID
       OFFSET :offset ROWS FETCH NEXT :limit ROWS ONLY`,
      { ...binds, offset: (page - 1) * pageSize, limit: pageSize },
    );
    if (rows.rows.length > 0) return { rows: rows.rows, total: rows.rows[0].TOTAL_COUNT };

    // A page past the end has no rows to carry the window count.
    const count = await conn.execute(`SELECT COUNT(*) AS N FROM V_POLICY_STATUS v ${whereSql}`, binds);
    return { rows: [], total: count.rows[0].N };
  });

  res.json({
    items: result.rows.map(toPolicy),
    page,
    pageSize,
    total: result.total,
    totalPages: Math.max(1, Math.ceil(result.total / pageSize)),
  });
}));

/**
 * GET /policies/:id
 */
router.get('/:id', wrap(async (req, res) => {
  const id = validate.policyId(req.params.id);

  const body = await withConnection(async (conn) => {
    const pol = await conn.execute(`SELECT ${POLICY_COLUMNS} FROM V_POLICY_STATUS v WHERE v.POLICY_ID = :id`, { id });
    if (pol.rows.length === 0) {
      throw new AppError(404, 'POLICY_NOT_FOUND', `No policy with id ${id} exists.`);
    }
    const policy = toPolicy(pol.rows[0]);

    const cust = await conn.execute(
      `SELECT CUSTOMER_ID, FULL_NAME, PAN, EMAIL, MOBILE, CITY, DATA_ISSUE
         FROM CUSTOMERS WHERE CUSTOMER_ID = :cid`,
      { cid: policy.customerId },
    );

    const pays = await conn.execute(
      `SELECT ${PAYMENT_COLUMNS} FROM PAYMENTS
        WHERE POLICY_ID = :id
        ORDER BY PAID_AT DESC, PAYMENT_ID DESC`,
      { id },
    );

    const others = await conn.execute(
      `SELECT ${POLICY_COLUMNS} FROM V_POLICY_STATUS v
        WHERE v.CUSTOMER_ID = :cid AND v.POLICY_ID <> :id
        ORDER BY v.POLICY_NO`,
      { cid: policy.customerId, id },
    );

    const c = cust.rows[0];
    return {
      policy,
      customer: c
        ? {
            id: c.CUSTOMER_ID,
            name: c.FULL_NAME,
            panMasked: maskPan(c.PAN),
            email: c.EMAIL,
            mobile: c.MOBILE,
            city: c.CITY,
            dataIssue: c.DATA_ISSUE,
          }
        : null,
      payments: pays.rows.map(toPayment),
      otherPolicies: others.rows.map(toPolicy),
    };
  });

  res.json(body);
}));

/**
 * POST /policies/:id/payments
 * Header: Idempotency-Key
 * Body:   { amount, channel?, dueDate? }
 *
 * dueDate is the instalment the clerk is paying (the nextDueDate they were
 * shown). Optional for API compatibility; the UI always sends it. When it no
 * longer matches, the payment is refused with 409 DUE_DATE_CHANGED.
 *
 * 201 for a new payment; 200 with Idempotent-Replayed: true for a repeat.
 */
router.post('/:id/payments', wrap(async (req, res) => {
  const p = validate.paymentRequest(req);

  const outcome = await withConnection(async (conn) => {
    const call = await conn.execute(
      `DECLARE
         l_next_due DATE;
       BEGIN
         RECORD_PAYMENT(
           P_POLICY_ID    => :policyId,
           P_AMOUNT       => :amount,
           P_IDEM_KEY     => :key,
           P_CHANNEL      => :channel,
           P_EXPECTED_DUE => TO_DATE(:dueDate, 'YYYY-MM-DD'),
           O_PAYMENT_ID   => :paymentId,
           O_NEXT_DUE     => l_next_due,
           O_RESULT       => :result,
           O_INSTALMENTS  => :instalments);
         :nextDue := TO_CHAR(l_next_due, 'YYYY-MM-DD');
       END;`,
      {
        policyId: p.policyId,
        amount: p.amount,
        key: p.key,
        channel: p.channel,
        dueDate: p.dueDate,
        paymentId: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER },
        result: { dir: oracledb.BIND_OUT, type: oracledb.STRING, maxSize: 30 },
        instalments: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER },
        nextDue: { dir: oracledb.BIND_OUT, type: oracledb.STRING, maxSize: 10 },
      },
      { autoCommit: true },
    );

    const receipts = await conn.execute(
      `SELECT ${PAYMENT_COLUMNS} FROM PAYMENTS
        WHERE IDEMPOTENCY_KEY = :key
        ORDER BY COVERS_DUE_DATE`,
      { key: p.key },
    );

    return { ...call.outBinds, receipts: receipts.rows.map(toPayment) };
  });

  const replayed = outcome.result === 'ALREADY_RECORDED';
  if (replayed) res.set('Idempotent-Replayed', 'true');
  res.status(replayed ? 200 : 201).json({
    result: outcome.result,
    policyId: p.policyId,
    paymentId: outcome.paymentId,
    instalments: outcome.instalments,
    nextDueDate: outcome.nextDue,
    payments: outcome.receipts,
  });
}));

module.exports = router;
