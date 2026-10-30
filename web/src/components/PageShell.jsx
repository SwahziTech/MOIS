import { Link, useLocation } from 'react-router-dom';
import { useAuth } from '../hooks/useAuth';
import { groupOf, atEntry } from './Sidebar';
import { ChevronRight, Settings as SettingsIcon } from 'lucide-react';

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
  const { can } = useAuth();
  const group = groupOf(loc);
  const siblings = (group?.group || []).filter(g => !g.perm || can(g.perm));
  return (
    <main className="page-content animate-fadeIn">
      <nav className="page-breadcrumb" aria-label="Breadcrumb">
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
