import { createContext, createElement, useContext } from 'react';
import { useSearchParams } from 'react-router-dom';

/*
 * A page's tab kept in the address (?tab=…), 2026-10-30: the sidebar opens
 * a page on one of its tabs (Planner, Invoices, Attendance, Payroll) and
 * marks the right entry as the tab changes. Other ?params are kept.
 * 2026-11-03: each tab change is a step Back can retrace (pass true to replace instead).
 * 2026-11-03: a page shown inside another (the secretary's dashboard tabs) keeps
 * its tab under its own name (?view=), with its own first tab — see Embedded.
 */
const Embed = createContext(null);   // { param, fallback } while a page is shown inside another

/** Show a whole page inside another: no heading of its own, its tab under ?<param>= */
export function Embedded({ param = 'view', fallback, children }) {
  return createElement(Embed.Provider, { value: { param, fallback } }, children);
}
export const useEmbedded = () => !!useContext(Embed);

export function useUrlTab(fallback) {
  const embed = useContext(Embed);
  const key = embed?.param ?? 'tab';
  const [params, setParams] = useSearchParams();
  const tab = params.get(key) || embed?.fallback || fallback;
  const setTab = (t, replace = false) => setParams(p => {
    const next = new URLSearchParams(p);
    if (t) next.set(key, t); else next.delete(key);
    return next;
  }, { replace });
  return [tab, setTab];
}
