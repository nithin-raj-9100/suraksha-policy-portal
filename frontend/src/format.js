const inr = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', minimumFractionDigits: 2 });

export function formatINR(amount) {
  return amount === null || amount === undefined ? '—' : inr.format(amount);
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// Business dates arrive as 'YYYY-MM-DD'. They are calendar dates, so they are
// formatted from their parts: going through new Date() would shift them by a
// day for anyone whose browser is west of UTC.
export function formatDate(iso) {
  if (!iso) return '—';
  const [y, m, d] = iso.split('-').map(Number);
  return `${d} ${MONTHS[m - 1]} ${y}`;
}

const ist = new Intl.DateTimeFormat('en-IN', {
  timeZone: 'Asia/Kolkata',
  day: 'numeric',
  month: 'short',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
});

// PAID_AT is UTC; the branch reads IST.
export function formatTimestampIST(isoUtc) {
  return isoUtc ? ist.format(new Date(isoUtc)) + ' IST' : '—';
}

function utcDay(iso) {
  const [y, m, d] = iso.split('-').map(Number);
  return Date.UTC(y, m - 1, d);
}

export function daysBetween(fromIso, toIso) {
  return Math.round((utcDay(toIso) - utcDay(fromIso)) / 86400000);
}

function plural(n, word) {
  return `${n} ${word}${n === 1 ? '' : 's'}`;
}

// One line a clerk can read next to the status: how urgent is this?
export function statusDetail(p) {
  if (!p.status || !p.nextDueDate) return p.dataIssue ? 'Records need correcting' : '';
  const today = p.businessDate;
  switch (p.status) {
    case 'PAID':
    case 'DUE': {
      const n = daysBetween(today, p.nextDueDate);
      return n === 0 ? 'Due today' : `Due in ${plural(n, 'day')}`;
    }
    case 'IN_GRACE': {
      const n = daysBetween(today, p.graceEndDate);
      return n === 0 ? 'Last day of grace' : `Grace ends in ${plural(n, 'day')}`;
    }
    case 'LAPSED': {
      if (p.revivalDeadline && daysBetween(today, p.revivalDeadline) >= 0) {
        return `Revivable until ${formatDate(p.revivalDeadline)}`;
      }
      return 'Revival window closed';
    }
    default:
      return '';
  }
}
