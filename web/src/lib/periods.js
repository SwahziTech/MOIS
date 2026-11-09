/*
 * The periods every dated list and dashboard offers first: This month (the
 * default, 2026-11-09, the user — was This week), Last month, This week, then
 * each day of it — Today, Yesterday, the weekday names back to Monday — and
 * Last week. Weeks start on Monday. Longer periods follow, each page's own.
 */
const utc = d => new Date(`${d}T00:00:00Z`);
const shift = (d, n) => new Date(utc(d).getTime() + n * 864e5).toISOString().slice(0, 10);
export const mondayOf = d => shift(d, -((utc(d).getUTCDay() + 6) % 7));

/** This week, its days back to Monday, last week → [{ value, label }] */
export function weekPeriods(today) {
  const n = (utc(today).getUTCDay() + 6) % 7;   // days since Monday
  const days = Array.from({ length: n + 1 }, (_, i) => shift(today, -i)).map((d, i) => ({
    value: i === 0 ? 'today' : i === 1 ? 'yesterday' : `day:${d}`,
    label: i === 0 ? 'Today' : i === 1 ? 'Yesterday' : utc(d).toLocaleDateString('en-GB', { weekday: 'long', timeZone: 'UTC' }),
  }));
  return [{ value: 'month', label: 'This month' }, { value: 'lastmonth', label: 'Last month' }, { value: 'week', label: 'This week' }, ...days, { value: 'lastweek', label: 'Last week' }];
}

/** A week period's first and last day ([from, to]); null for any other key */
export function weekRange(key, today) {
  const mon = mondayOf(today);
  if (key === 'week') return [mon, today];
  if (key === 'today') return [today, today];
  if (key === 'yesterday') { const y = shift(today, -1); return [y, y]; }
  if (key === 'lastweek') return [shift(mon, -7), shift(mon, -1)];
  if (String(key).startsWith('day:')) { const d = key.slice(4); return [d, d]; }
  return null;
}

/** The label of a usual period (undefined for another key) */
export const weekLabel = (key, today) => weekPeriods(today).find(p => p.value === key)?.label;

/** [from, to] for a period key: a week period, else n days back to today ('all' = everything) */
export function periodRange(key, today) {
  const wk = weekRange(key, today);
  if (wk) return wk;
  if (key === 'all') return ['0000-01-01', '9999-12-31'];
  if (key === 'month') return [`${today.slice(0, 7)}-01`, today];
  if (key === 'quarter') { const m = Number(today.slice(5, 7)); const q = Math.floor((m - 1) / 3) * 3 + 1; return [`${today.slice(0, 4)}-${String(q).padStart(2, '0')}-01`, today]; }
  if (key === 'year') return [`${today.slice(0, 4)}-01-01`, today];
  if (key === 'lastmonth') { const first = `${today.slice(0, 7)}-01`; return [`${shift(first, -1).slice(0, 7)}-01`, shift(first, -1)]; }
  return [shift(today, -Number(key)), today];
}

/** The period key whose dates are exactly [from, to] (a card's period sent in a link), or null */
export function keyForRange(from, to, today) {
  const keys = weekPeriods(today).map(p => p.value);
  return keys.find(k => { const [a, b] = periodRange(k, today); return a === from && b === to; }) ?? null;
}
