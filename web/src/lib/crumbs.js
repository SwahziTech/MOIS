import { useEffect, useState } from 'react';

/*
 * The page heading is a path from Home to where you are (2026-11-10, the user):
 * "Home › HR › Payroll › Employees". The page-level tabs on screen (PageTabs, not
 * nested) report their open tab here; the heading lists them in screen order.
 */
const open = new Map();   // element → label
const emit = () => window.dispatchEvent(new Event('mois:crumbs'));
const clean = l => String(l ?? '').replace(/\s*\(\d+\)\s*$/, '').trim();

export function reportTab(el, label) {
  if (!el) return () => {};
  open.set(el, clean(label)); emit();
  return () => { open.delete(el); emit(); };
}

export function useOpenTabs() {
  const read = () => [...open.entries()].filter(([el]) => el.isConnected)
    .sort(([a], [b]) => (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1)).map(([, l]) => l).filter(Boolean);
  const [tabs, setTabs] = useState(read);
  useEffect(() => {
    const on = () => setTabs(read());
    on();
    window.addEventListener('mois:crumbs', on);
    return () => window.removeEventListener('mois:crumbs', on);
  }, []);
  return tabs;
}
