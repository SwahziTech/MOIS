import { useSearchParams } from 'react-router-dom';

/*
 * A page's tab kept in the address (?tab=…), 2026-10-30: the sidebar opens
 * a page on one of its tabs (Planner, Invoices, Attendance, Payroll) and
 * marks the right entry as the tab changes. Other ?params are kept.
 */
export function useUrlTab(fallback) {
  const [params, setParams] = useSearchParams();
  const tab = params.get('tab') || fallback;
  const setTab = t => setParams(p => {
    const next = new URLSearchParams(p);
    if (t) next.set('tab', t); else next.delete('tab');
    return next;
  }, { replace: true });
  return [tab, setTab];
}
