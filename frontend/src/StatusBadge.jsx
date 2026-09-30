import React from 'react';

export const STATUS = {
  PAID: { label: 'Paid up', icon: '✓' },
  DUE: { label: 'Due', icon: '●' },
  IN_GRACE: { label: 'In grace', icon: '!' },
  LAPSED: { label: 'Lapsed', icon: '✕' },
};

// Icon and word carry the meaning; colour only reinforces it.
export default function StatusBadge({ status }) {
  const s = STATUS[status] || { label: 'Needs review', icon: '?' };
  return (
    <span className={`badge badge-${(status || 'unknown').toLowerCase()}`}>
      <span className="badge-icon" aria-hidden="true">{s.icon}</span>
      {s.label}
    </span>
  );
}
