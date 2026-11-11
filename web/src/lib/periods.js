/*
 * The periods every dated list and dashboard offers first: This month (the
 * default, 2026-11-09, the user — was This week), Last month, This week, then
 * each day of it — Today, Yesterday, the weekday names back to Monday — and
 * Last week. Weeks start on Monday. Longer periods follow, each page's own.
 */
const utc = d => new Date(`${d}T00:00:00Z`);
const shift = (d, n) => new Date(utc(d).getTime() + n * 864e5).toISOString().slice(0, 10);
export const mondayOf = d => shift(d, -((utc(d).getUTCDay() + 6) % 7));
// the work week (2026-11-11, the user): Monday to Saturday is work; a Sunday (emergencies) opens the week, as on the
// casuals' pay sheets (115) — so a week runs Sunday to Saturday, and Saturday is its last working day
export const sundayOf = d => shift(d, -utc(d).getUTCDay());

/** This week, its days back to Monday, last week → [{ value, label }] */
export function weekPeriods(today) {
  const dow = utc(today).getUTCDay();
  const n = dow === 0 ? 0 : dow - 1;   // the week's days so far, back to Monday (a Sunday is its own first day)
  const days = Array.from({ length: n + 1 }, (_, i) => shift(today, -i)).map((d, i) => ({
    value: i === 0 ? 'today' : i === 1 ? 'yesterday' : `day:${d}`,
    label: i === 0 ? 'Today' : i === 1 ? 'Yesterday' : utc(d).toLocaleDateString('en-GB', { weekday: 'long', timeZone: 'UTC' }),
  }));
  return [{ value: 'month', label: 'This month' }, { value: 'lastmonth', label: 'Last month' }, { value: 'week', label: 'This week' }, ...days, { value: 'lastweek', label: 'Last week' }];
}

/** A week period's first and last day ([from, to]); null for any other key */
export function weekRange(key, today) {
  const sun = sundayOf(today);
  if (key === 'week') return [sun, today];
  if (key === 'today') return [today, today];
  if (key === 'yesterday') { const y = shift(today, -1); return [y, y]; }
  if (key === 'lastweek') return [shift(sun, -7), shift(sun, -1)];
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

/*
 * The dates beside a period's name, short (2026-11-10, the user): a whole month is just its
 * month ("Nov"); a stretch of days "Nov 2 – Nov 7" (the year only when it isn't this year);
 * one day "Nov 11".
 */
const MON = d => new Date(`${d}T00:00:00Z`).toLocaleDateString('en-GB', { month: 'short', timeZone: 'UTC' }).replace('Sept', 'Sep');
const lastOfMonth = d => { const x = new Date(`${d.slice(0, 7)}-01T00:00:00Z`); x.setUTCMonth(x.getUTCMonth() + 1); x.setUTCDate(0); return x.toISOString().slice(0, 10); };
export function shortRange(from, to, today) {
  if (!from || !to || from === '0000-01-01') return '';
  const yr = d => (d.slice(0, 4) !== String(today).slice(0, 4) ? ` ${d.slice(0, 4)}` : '');
  const day = d => `${MON(d)} ${Number(d.slice(8))}${yr(d)}`;
  if (from === to) return day(from);
  // a week opens on Sunday; its label shows the working days, Monday to Saturday
  if (utc(from).getUTCDay() === 0 && shift(from, 1) <= to) from = shift(from, 1);
  if (from === to) return day(from);
  // a whole month (or this month so far)
  if (from.slice(8) === '01' && from.slice(0, 7) === to.slice(0, 7) && (to === lastOfMonth(to) || to === today)) return `${MON(from)}${yr(from)}`;
  return `${day(from)} – ${day(to)}`;
}
