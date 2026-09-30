'use strict';

const oracledb = require('oracledb');

oracledb.outFormat = oracledb.OUT_FORMAT_OBJECT;
oracledb.fetchAsString = [oracledb.CLOB];

let pool = null;

async function initPool() {
  if (pool) return pool;
  pool = await oracledb.createPool({
    user: process.env.DB_USER || 'suraksha',
    password: process.env.DB_PASSWORD || 'suraksha',
    connectString: process.env.DB_CONNECT_STRING || 'localhost:1521/FREEPDB1',
    poolMin: Number(process.env.DB_POOL_MIN || 2),
    poolMax: Number(process.env.DB_POOL_MAX || 10),
    poolIncrement: 1,
    // Fail a request after 10s waiting for a connection instead of hanging the
    // counter indefinitely when the pool is exhausted.
    queueTimeout: 10000,
  });
  return pool;
}

/**
 * Borrows a connection for the duration of fn and always gives it back, on the
 * error path too. Anything fn did not commit is rolled back explicitly before
 * release, so a failed request can never leave locks or half-done work on a
 * connection the next request will pick up.
 */
async function withConnection(fn) {
  const p = await initPool();
  const conn = await p.getConnection();
  try {
    return await fn(conn);
  } catch (err) {
    try {
      await conn.rollback();
    } catch (rollbackErr) {
      console.error('rollback failed', rollbackErr.message);
    }
    throw err;
  } finally {
    await conn.close();
  }
}

async function closePool() {
  if (pool) {
    await pool.close(10);
    pool = null;
  }
}

module.exports = { oracledb, initPool, withConnection, closePool };
