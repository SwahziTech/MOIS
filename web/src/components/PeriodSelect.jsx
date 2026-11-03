import { useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { weekPeriods, weekLabel, periodRange, keyForRange } from '../lib/periods';

/*
 * The period of a dated list (2026-11-03, the user): opens on This week, or on
 * the period a dashboard card sent (?from=&to=&label=). Small — one compact
 * dropdown, never a row of its own.
 */
export function usePeriod(today, fallback = 'week') {
  const [params] = useSearchParams();
  const sent = params.get('from') && params.get('to') ? { from: params.get('from'), to: params.get('to'), label: params.get('label') || 'Chosen period' } : null;
  // a sent period that is one of the usual choices opens on that choice
  const known = sent && keyForRange(sent.from, sent.to, today);
  const url = known ? null : sent;
  const [key, setKey] = useState(known || (url ? 'range' : fallback));
  const [from, to] = key === 'range' && url ? [url.from, url.to] : periodRange(key, today);
  return { key, setKey, from, to, url, has: d => !!d && d >= from && d <= to };
}

/** extra: [[key, label]] after the week periods (keys periodRange knows: month, lastmonth, 30, 90, all) */
export default function PeriodSelect({ period, today, extra = [], style }) {
  return (
    <select className="form-input period-select" aria-label="Period" style={style} value={period.key} onChange={e => period.setKey(e.target.value)}>
      {period.url && <option value="range">{period.url.label}</option>}
      {weekPeriods(today).map(p => <option key={p.value} value={p.value}>{p.label}</option>)}
      {extra.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
    </select>
  );
}

export const periodText = (period, today, extra = []) => weekLabel(period.key, today)
  ?? (period.key === 'range' ? period.url?.label : null) ?? extra.find(x => x[0] === period.key)?.[1] ?? '';
