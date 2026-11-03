import { useSearchParams } from 'react-router-dom';

/*
 * A page's tab kept in the address (?tab=…), 2026-10-30: the sidebar opens
 * a page on one of its tabs (Planner, Invoices, Attendance, Payroll) and
 * marks the right entry as the tab changes. Other ?params are kept.
 * 2026-11-03: each tab change is a step Back can retrace (pass true to replace instead).
 */
export function useUrlTab(fallback) {
  const [params, setParams] = useSearchParams();
  const tab = params.get('tab') || fallback;
  const setTab = (t, replace = false) => setParams(p => {
    const next = new URLSearchParams(p);
    if (t) next.set('tab', t); else next.delete('tab');
    return next;
  }, { replace });
  return [tab, setTab];
}
