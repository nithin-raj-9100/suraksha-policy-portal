import React, { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { listPolicies } from './api.js';
import StatusBadge, { STATUS } from './StatusBadge.jsx';
import { formatDate, formatINR, statusDetail } from './format.js';

const PAGE_SIZE = 20;
const FILTERS = [{ value: '', label: 'All' }, ...Object.keys(STATUS).map((value) => ({ value, label: STATUS[value].label }))];

export default function PolicyList() {
  // Filter, search and page live in the URL so Back, refresh and a shared
  // link all return to the same view.
  const [params, setParams] = useSearchParams();
  const status = params.get('status') || '';
  const search = params.get('search') || '';
  const page = Math.max(1, Number(params.get('page')) || 1);

  const [searchInput, setSearchInput] = useState(search);
  const [state, setState] = useState({ loading: true, error: null, data: null });
  const [reloadToken, setReloadToken] = useState(0);

  function update(changes) {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(changes)) {
      if (v === '' || v === null || v === undefined || (k === 'page' && v === 1)) next.delete(k);
      else next.set(k, String(v));
    }
    setParams(next, { replace: 'search' in changes });
  }

  function goToPage(n) {
    update({ page: n });
    window.scrollTo({ top: 0 });
  }

  useEffect(() => {
    setSearchInput(search);
  }, [search]);

  useEffect(() => {
    const t = setTimeout(() => {
      if (searchInput.trim() !== search) update({ search: searchInput.trim(), page: 1 });
    }, 300);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchInput]);

  useEffect(() => {
    // Abort the previous request so a slow, stale response cannot overwrite a newer one.
    const ctrl = new AbortController();
    setState((s) => ({ ...s, loading: true, error: null }));
    listPolicies({ status, search, page, pageSize: PAGE_SIZE }, ctrl.signal)
      .then((data) => setState({ loading: false, error: null, data }))
      .catch((error) => {
        if (error.name !== 'AbortError') setState((s) => ({ ...s, loading: false, error }));
      });
    return () => ctrl.abort();
  }, [status, search, page, reloadToken]);

  const { loading, error, data } = state;

  return (
    <div>
      <h1>Policies</h1>

      <div className="toolbar">
        <div className="filters" role="group" aria-label="Filter by status">
          {FILTERS.map((f) => (
            <button
              key={f.value || 'all'}
              type="button"
              className={'filter' + (status === f.value ? ' active' : '')}
              aria-pressed={status === f.value}
              onClick={() => update({ status: f.value, page: 1 })}
            >
              {f.value && <StatusBadge status={f.value} />}
              {!f.value && f.label}
            </button>
          ))}
        </div>

        <label className="search">
          <span className="visually-hidden">Search</span>
          <input
            type="search"
            placeholder="Policy number or customer name"
            value={searchInput}
            maxLength={100}
            onChange={(e) => setSearchInput(e.target.value)}
          />
        </label>
      </div>

      {error && (
        <div className="alert alert-error" role="alert">
          <p>Could not load policies. {error.message}</p>
          <button type="button" onClick={() => setReloadToken((n) => n + 1)}>Try again</button>
        </div>
      )}

      {!error && !data && loading && <p className="muted" role="status">Loading policies…</p>}

      {data && (
        <>
          <p className="muted summary" role="status" aria-live="polite">
            {loading ? 'Updating…' : `${data.total} ${data.total === 1 ? 'policy' : 'policies'}`}
            {status && ` · ${STATUS[status].label}`}
            {search && ` · matching “${search}”`}
          </p>

          {data.items.length === 0 ? (
            <div className="empty">
              <p>No policies match these filters.</p>
              {(status || search) && (
                <button type="button" onClick={() => { setSearchInput(''); update({ status: '', search: '', page: 1 }); }}>
                  Clear filters
                </button>
              )}
            </div>
          ) : (
            <table className={'table' + (loading ? ' is-loading' : '')}>
              <thead>
                <tr>
                  <th>Policy</th>
                  <th>Customer</th>
                  <th>Plan</th>
                  <th>Mode</th>
                  <th className="num">Premium</th>
                  <th>Next due</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {data.items.map((p) => (
                  <tr key={p.id}>
                    <td><Link to={`/policies/${p.id}`}>{p.policyNo}</Link></td>
                    <td>{p.customerName || <span className="muted">Unknown customer</span>}</td>
                    <td>{p.planName}</td>
                    <td>{p.premiumModeLabel || '—'}</td>
                    <td className="num">{formatINR(p.premiumAmount)}</td>
                    <td>{formatDate(p.nextDueDate)}</td>
                    <td>
                      <StatusBadge status={p.status} />
                      <div className="status-detail">{statusDetail(p)}</div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}

          <nav className="pager" aria-label="Pages">
            <button type="button" disabled={page <= 1 || loading} onClick={() => goToPage(page - 1)}>
              ← Previous
            </button>
            <span>Page {Math.min(page, data.totalPages)} of {data.totalPages}</span>
            <button type="button" disabled={page >= data.totalPages || loading} onClick={() => goToPage(page + 1)}>
              Next →
            </button>
          </nav>
        </>
      )}
    </div>
  );
}
