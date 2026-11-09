import { useState } from 'react';
import PeriodBar from './PeriodBar';
import { useSearchParams, useLocation } from 'react-router-dom';
import { useSessionPeriod } from '../lib/sessionPeriod';
import { weekPeriods, weekLabel, periodRange, keyForRange } from '../lib/periods';

/*
 * The period of a dated list: opens on This month (2026-11-09), the person's last pick
 * on this page, or the period a dashboard card sent (?from=&to=&label=). Small — one compact
 * dropdown, never a row of its own.
 */
export function usePeriod(today, fallback = 'month') {
  const [params] = useSearchParams();
  const { pathname } = useLocation();
  const sent = params.get('from') && params.get('to') ? { from: params.get('from'), to: params.get('to'), label: params.get('label') || 'Chosen period' } : null;
  // a sent period that is one of the usual choices opens on that choice
  const known = sent && keyForRange(sent.from, sent.to, today);
  const url = known ? null : sent;
  const [saved, setSaved] = useSessionPeriod(pathname, fallback);   // remembered until the app closes
  const [sent0, setSent0] = useState(known || (url ? 'range' : null));   // a card's period wins on arrival
  const key = sent0 ?? saved;
  const setKey = v => { if (v === 'range') { setSent0('range'); return; } setSent0(null); setSaved(v); };
  const [from, to] = key === 'range' && url ? [url.from, url.to] : periodRange(key, today);
  return { key, setKey, from, to, url, has: d => !!d && d >= from && d <= to };
}

/** extra: [[key, label]] after the usual periods (keys periodRange knows: month, lastmonth, 30, 90, all) */
export default function PeriodSelect({ period, today, extra = [] }) {
  // the standard period bar (LOCKED 2026-11-09)
  return <PeriodBar value={period.key} onChange={period.setKey} today={today} extra={extra} range={[period.from, period.to]} sentLabel={period.url?.label} />;
}

export const periodText = (period, today, extra = []) => weekLabel(period.key, today)
  ?? (period.key === 'range' ? period.url?.label : null) ?? extra.find(x => x[0] === period.key)?.[1] ?? '';
