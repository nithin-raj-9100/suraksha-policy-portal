// Vite proxies /api to the backend (see vite.config.js).
const BASE = '/api';

export class ApiError extends Error {
  constructor({ status, code, message, field }) {
    super(message);
    this.status = status;
    this.code = code;
    this.field = field;
  }

  // True when we cannot know whether the server acted on the request.
  get outcomeUnknown() {
    return this.status === 0 || this.status >= 500;
  }
}

export async function getJson(path, options = {}) {
  let res;
  try {
    res = await fetch(BASE + path, {
      ...options,
      headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    });
  } catch (err) {
    if (err.name === 'AbortError') throw err;
    throw new ApiError({ status: 0, code: 'NETWORK_ERROR', message: 'Could not reach the server. Check the connection and try again.' });
  }

  const text = await res.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = null;
  }

  if (!res.ok) {
    const e = (body && body.error) || {};
    throw new ApiError({
      status: res.status,
      code: e.code || 'HTTP_' + res.status,
      message: e.message || `The server answered ${res.status} ${res.statusText}.`,
      field: e.field,
    });
  }
  return body;
}

export function listPolicies({ status, search, page, pageSize }, signal) {
  const q = new URLSearchParams();
  if (status) q.set('status', status);
  if (search) q.set('search', search);
  q.set('page', String(page));
  q.set('pageSize', String(pageSize));
  return getJson('/policies?' + q.toString(), { signal });
}

export function getPolicy(id, signal) {
  return getJson('/policies/' + encodeURIComponent(id), { signal });
}

// The key identifies one payment attempt, not one HTTP request: PaymentForm
// reuses it for retries of the same attempt and makes a new one otherwise.
export function recordPayment(id, { amount, channel, dueDate }, idempotencyKey, signal) {
  return getJson('/policies/' + encodeURIComponent(id) + '/payments', {
    method: 'POST',
    headers: { 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ amount, channel, dueDate }),
    signal,
  });
}

export function newIdempotencyKey() {
  if (globalThis.crypto && crypto.randomUUID) return crypto.randomUUID();
  return 'k-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 12);
}
