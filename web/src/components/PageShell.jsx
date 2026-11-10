import { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { useAuth } from '../hooks/useAuth';
import { useEmbedded } from '../lib/urlTab';
import { groupOf, atEntry, NAV, navActive, hrefOf } from './Sidebar';
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
  // Back (2026-11-03): one step back through the pages, tabs and reports opened in MOIS; hidden on the first page
  const canGoBack = (window.history.state?.idx ?? 0) > 0;
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
  const crumbsInBar = barEl && createPortal(
    <nav className="tm-crumb" aria-label="Breadcrumb">
      {canGoBack && <button type="button" className="page-back" title="Back to where you were" onClick={() => navigate(-1)}><ArrowLeft size={14} /> Back</button>}
      <Link to="/">Home</Link>
      {(section?.section || subtitle) && section?.section !== 'Home' && (section?.section ?? subtitle) !== title && <><ChevronRight size={12} />{sectionItem ? <Link to={hrefOf(sectionItem, can)}>{section.section}</Link> : <span>{subtitle}</span>}</>}
      {title && <><ChevronRight size={12} /><strong className="truncate">{title}</strong></>}
    </nav>, barEl);
  return (
    <main className={`page-content animate-fadeIn${barEl ? ' has-top-crumbs' : ''}`}>
      {crumbsInBar}
      <nav className="page-breadcrumb" aria-label="Breadcrumb">
        {canGoBack && <button type="button" className="page-back" title="Back to where you were" onClick={() => navigate(-1)}><ArrowLeft size={14} /> Back</button>}
        <Link to="/">Home</Link>
        {subtitle && (
          <>
            <ChevronRight size={12} />
            <span>{subtitle}</span>
          </>
        )}
      </nav>
      <div className="page-header page-header-row">
        <div className="page-header-text">
          <h1 className="page-title">{title}{onSettings && (
            <button type="button" className="page-settings" aria-label={`${title} settings`} title={`${title} settings`} onClick={onSettings}><SettingsIcon size={17} /></button>
          )}</h1>
          {description && <p className="page-description">{description}</p>}
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
