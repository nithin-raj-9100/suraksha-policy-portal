'use strict';

require('dotenv').config();
const crypto = require('crypto');
const express = require('express');
const cors = require('cors');

const { initPool, withConnection, closePool } = require('./db');
const { AppError, fromOracle } = require('./errors');
const policies = require('./routes/policies');

const app = express();
app.use(cors({ exposedHeaders: ['Idempotent-Replayed', 'X-Request-Id'] }));

app.use((req, res, next) => {
  req.id = crypto.randomUUID();
  res.set('X-Request-Id', req.id);
  const started = Date.now();
  res.on('finish', () => {
    console.log(`${req.id} ${req.method} ${req.originalUrl} ${res.statusCode} ${Date.now() - started}ms`);
  });
  next();
});

app.use(express.json({ limit: '10kb' }));

app.get('/health', async (req, res) => {
  try {
    const r = await withConnection((c) => c.execute('SELECT 1 AS OK FROM DUAL'));
    res.json({ status: 'ok', db: r.rows[0] });
  } catch (err) {
    res.status(503).json({ status: 'down', error: err.message });
  }
});

app.use('/policies', policies);

app.use((req, res) => {
  res.status(404).json({ error: { code: 'NOT_FOUND', message: `No route for ${req.method} ${req.path}` } });
});

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  let e = err instanceof AppError ? err : fromOracle(err);

  if (!e && err.type === 'entity.parse.failed') {
    e = new AppError(400, 'INVALID_REQUEST', 'The request body is not valid JSON.');
  }

  if (!e) {
    console.error(req.id, err);
    e = new AppError(500, 'INTERNAL', `Something went wrong on our side. Nothing was recorded unless the payment history shows it. Reference ${req.id}.`);
  }

  res.status(e.status).json({ error: { code: e.code, message: e.message, field: e.field, requestId: req.id } });
});

const port = Number(process.env.PORT || 3001);

initPool()
  .then(() => {
    app.listen(port, () => console.log(`API listening on http://localhost:${port}`));
  })
  .catch((err) => {
    console.error('Could not start: database unreachable.', err.message);
    process.exit(1);
  });

async function shutdown() {
  await closePool();
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
