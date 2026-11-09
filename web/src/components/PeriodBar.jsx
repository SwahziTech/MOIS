import { ChevronLeft, ChevronRight } from 'lucide-react';
import { weekPeriods, weekLabel, periodRange } from '../lib/periods';
import { dateText } from '../lib/format';

/*
 * LOCKED (2026-11-09, the user): the one period design for every page with a time period —
 * the Director view's bar: ‹ › arrows, the period's name and its dates, a This month button
 * when away from it, and the dropdown on the right. Opens on This month (usePeriod /
 * useSessionPeriod remember the last pick until the app closes).
 *
 * value / onChange: the period key. extra: [[key, label]] after the usual periods (30, 90, all…).
 * range: [from, to] when the page works its dates out itself (quarter, year, custom).
 * sentLabel: the name of a period a dashboard card sent (key 'range').
 */
const STEPS_BACK = today => {
  const n = (new Date(`${today}T00:00:00Z`).getUTCDay() + 6) % 7;   // days since Monday
  const days = Array.from({ length: n + 1 }, (_, i) => (i === 0 ? 'today' : i === 1 ? 'yesterday' : null))
    .map((k, i) => k ?? `day:${new Date(new Date(`${today}T00:00:00Z`).getTime() - i * 864e5).toISOString().slice(0, 10)}`);
  return [...days, 'lastweek', 'lastmonth'];
};
const LAST_OF = { week: 'lastweek', month: 'lastmonth' };

export default function PeriodBar({ value, onChange, today, extra = [], range = null, sentLabel = null, className = '' }) {
  const steps = STEPS_BACK(today);
  const at = steps.indexOf(value);
  const earlier = at >= 0 ? steps[at + 1] : LAST_OF[value];
  const later = at >= 0 ? (at === 0 ? null : steps[at - 1]) : Object.keys(LAST_OF).find(k => LAST_OF[k] === value) ?? (value === 'week' || value === 'month' ? 'today' : null);
  const label = value === 'range' ? sentLabel : weekLabel(value, today) ?? extra.find(x => x[0] === value)?.[1] ?? '';
  const [from, to] = range ?? (value === 'range' ? [null, null] : periodRange(value, today));
  const note = !from || from === '0000-01-01' ? '' : from === to ? dateText(from) : `${dateText(from)} – ${dateText(to)}`;
  const usual = weekPeriods(today);
  return (
    <div className={`dd-period period-bar ${className}`}>
      <button type="button" className="dd-step" aria-label="Earlier" disabled={!earlier} onClick={() => onChange(earlier)}><ChevronLeft size={18} /></button>
      <button type="button" className="dd-step" aria-label="Later" disabled={!later} onClick={() => onChange(later)}><ChevronRight size={18} /></button>
      <span><strong>{label}</strong>{note ? ` · ${note}` : ''}</span>
      {value !== 'month' && <button type="button" className="btn btn-outline btn-sm dd-reset" onClick={() => onChange('month')}>This month</button>}
      <select className="form-input dd-select" aria-label="Period" value={value} onChange={e => onChange(e.target.value)}>
        {value === 'range' && <option value="range">{sentLabel}</option>}
        <optgroup label="Monthly">{usual.slice(0, 2).map(p => <option key={p.value} value={p.value}>{p.label}</option>)}</optgroup>
        <optgroup label="Weekly">{usual.slice(2).map(p => <option key={p.value} value={p.value}>{p.label}</option>)}</optgroup>
        {extra.length > 0 && <optgroup label="Longer">{extra.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</optgroup>}
      </select>
    </div>
  );
}

/*
 * The same bar for pickers that step through a list — months (Payroll, Returns, Profit & loss)
 * or pay periods (casual pay sheets): ‹ › step through the list, the name and its dates, a
 * button back to the newest, the dropdown on the right. options: [{ value, label, note }], newest first.
 */
export function StepBar({ options, value, onChange, nowLabel = 'This month', className = '' }) {
  const at = options.findIndex(o => o.value === value);
  const cur = options[at];
  return (
    <div className={`dd-period period-bar ${className}`}>
      <button type="button" className="dd-step" aria-label="Earlier" disabled={at < 0 || at >= options.length - 1} onClick={() => onChange(options[at + 1].value)}><ChevronLeft size={18} /></button>
      <button type="button" className="dd-step" aria-label="Later" disabled={at <= 0} onClick={() => onChange(options[at - 1].value)}><ChevronRight size={18} /></button>
      <span><strong>{cur?.label ?? '—'}</strong>{cur?.note ? ` · ${cur.note}` : ''}</span>
      {at > 0 && <button type="button" className="btn btn-outline btn-sm dd-reset" onClick={() => onChange(options[0].value)}>{nowLabel}</button>}
      <select className="form-input dd-select" aria-label="Period" value={value} onChange={e => onChange(e.target.value)}>
        {options.map(o => <option key={o.value} value={o.value}>{o.label}{o.note ? ` · ${o.note}` : ''}</option>)}
      </select>
    </div>
  );
}

/* Months back from today as StepBar options: 'YYYY-MM', "This month" / "October 2026" */
export function monthOptions(today, count = 12) {
  const out = []; let [y, m] = today.slice(0, 7).split('-').map(Number);
  for (let i = 0; i < count; i++) {
    const v = `${y}-${String(m).padStart(2, '0')}`;
    const name = new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });
    out.push({ value: v, label: i === 0 ? 'This month' : i === 1 ? 'Last month' : name, note: i < 2 ? name : '' });
    m -= 1; if (m === 0) { m = 12; y -= 1; }
  }
  return out;
}
