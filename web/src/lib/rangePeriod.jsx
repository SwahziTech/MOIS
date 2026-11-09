import { useState } from 'react';
import { useSessionPeriod } from './sessionPeriod';
import { periodRange } from './periods';
import PeriodBar from '../components/PeriodBar';

/*
 * A page whose period is a date range (Reports, Statements, Cash flow, Print lists, a customer's
 * statement): the standard bar, This month first, the last pick kept until the app closes, and
 * "Dates…" for any from–to (2026-11-09, the user: the agreed format on every page).
 */
export const LONGER = [['quarter', 'This quarter'], ['year', 'This year'], ['30', 'Last 30 days'], ['90', 'Last 90 days'], ['all', 'All time'], ['custom', 'Dates…']];

export function useRangePeriod(id, today, { fallback = 'month', start = null } = {}) {
  const [key, setKey] = useSessionPeriod(id, start ? 'custom' : fallback);
  const [custom, setCustom] = useState(start ?? [`${today.slice(0, 7)}-01`, today]);
  const [from, to] = key === 'custom' ? custom : periodRange(key, today);
  const bar = (extra = LONGER) => (
    <>
      <PeriodBar value={key} onChange={setKey} today={today} extra={extra} range={[from, to === '9999-12-31' ? today : to]} />
      {key === 'custom' && (
        <div className="period-custom">
          <input type="date" className="form-input" aria-label="From" max={custom[1]} value={custom[0]} onChange={e => setCustom([e.target.value || custom[0], custom[1]])} />
          <span className="pl-help">to</span>
          <input type="date" className="form-input" aria-label="To" min={custom[0]} max={today} value={custom[1]} onChange={e => setCustom([custom[0], e.target.value || custom[1]])} />
        </div>
      )}
    </>
  );
  return { key, setKey, from, to: to === '9999-12-31' ? today : to, setRange: r => { setCustom(r); setKey('custom'); }, bar };
}
