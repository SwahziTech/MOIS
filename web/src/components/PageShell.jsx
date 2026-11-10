import { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { useAuth } from '../hooks/useAuth';
import { useEmbedded } from '../lib/urlTab';
import { groupOf, atEntry, NAV, navActive, hrefOf } from './Sidebar';
import { useOpenTabs } from '../lib/crumbs';
import { ArrowLeft, ChevronRight, Settings as SettingsIcon } from 'lucide-react';

/**
 * PageShell — the standard page frame (2026-10-17). No top bar: the page
 * opens with its breadcrumb ("Home › section"), then the <h1> and a
 * one-line description on the left and the page's main "+ New" action on
 * the right. The light/dark switch lives in the sidebar header.
 */
// onSettings: a small ⚙ beside the heading opens the page's own settings (2026-10-25)
// a page that shares a sidebar entry with others (Review queue, Products, Procurement, Cash flow) shows them as tabs under the heading (2026-10-30)
export default function PageShell({ title, subtitle, description, primaryAction, actions, onSettings, children }) {
  const loc = useLocation();
  const navigate = useNavigate();
  const embedded = useEmbedded();
  const { can } = useAuth();
  const group = groupOf(loc);
  const siblings = (group?.group || []).filter(g => !g.perm || can(g.perm));
  // the top menu (2026-11-10, the user): Back and "Home › section › this page" sit in its bar; each step can be clicked
  const [barEl, setBarEl] = useState(() => (document.body.classList.contains('menu-top') ? document.getElementById('tm-crumbs') : null));
  useEffect(() => {
    const check = () => setBarEl(document.body.classList.contains('menu-top') ? document.getElementById('tm-crumbs') : null);
    check();
    window.addEventListener('mois:menu-mode', check);
    return () => window.removeEventListener('mois:menu-mode', check);
  }, []);
  const section = NAV.find(sec => sec.items.some(i => navActive(i, loc)));
  const sectionItem = section?.items.find(i => (!i.perm || can(i.perm)));
  // inside the secretary's dashboard (2026-11-03): no heading of its own — its buttons, then the page
  if (embedded) return (
    <div className="page-embedded">
      {(primaryAction || actions) && <div className="page-embedded-actions">{actions}{primaryAction}</div>}
      {children}
    </div>
  );
  // the heading (2026-11-10, the user): the path from Home to where you are — section, page, open tab(s); each step but
  // the last can be clicked. No Back button: the browser's own back arrow goes back.
  const openTabs = useOpenTabs();
  const steps = [];
  const sec = section?.section && section.section !== 'Home' ? section.section : subtitle && subtitle !== 'Overview' ? subtitle : null;
  if (sec && sec !== title) steps.push({ label: sec, to: sectionItem ? hrefOf(sectionItem, can) : null });
  if (title && title !== 'Dashboard') steps.push({ label: title, to: loc.pathname });
  for (const t of openTabs) if (t && t !== steps[steps.length - 1]?.label) steps.push({ label: t });
  const path = cls => (
    <nav className={cls} aria-label="You are here">
      <Link to="/">Home</Link>
      {steps.map((st, i) => (
        <span key={i} className="crumb-step"><ChevronRight size={14} />
          {i === steps.length - 1 ? <strong>{st.label}</strong> : st.to ? <Link to={st.to}>{st.label}</Link> : <span>{st.label}</span>}
        </span>
      ))}
    </nav>
  );
  const crumbsInBar = barEl && createPortal(path('tm-crumb'), barEl);
  return (
    <main className={`page-content animate-fadeIn${barEl ? ' has-top-crumbs' : ''}`}>
      {crumbsInBar}
      {!barEl && path('page-path')}
      <div className="page-header page-header-row">
        <div className="page-header-text">
          {/* the page's name is in the path above; the heading stays for screen readers (2026-11-10) */}
          <h1 className="sr-only">{title}</h1>
          {onSettings && <button type="button" className="page-settings" aria-label={`${title} settings`} title={`${title} settings`} onClick={onSettings}><SettingsIcon size={17} /> Settings</button>}
        </div>
        {(primaryAction || actions) && (
          <div className="page-primary-action">{actions}{primaryAction}</div>
        )}
      </div>
      {siblings.length > 1 && (
        <nav className="page-group" aria-label={group.label}>
          {siblings.map(g => (
            <Link key={g.to} to={g.to} className={`page-group-tab${atEntry(g, loc) ? ' is-on' : ''}`} aria-current={atEntry(g, loc) ? 'page' : undefined}>{g.label}</Link>
          ))}
        </nav>
      )}
      {children}
    </main>
  );
}
