import { Link } from 'react-router-dom';
import { ChevronRight, Settings as SettingsIcon } from 'lucide-react';

/**
 * PageShell — the standard page frame (2026-10-17). No top bar: the page
 * opens with its breadcrumb ("Home › section"), then the <h1> and a
 * one-line description on the left and the page's main "+ New" action on
 * the right. The light/dark switch lives in the sidebar header.
 */
// onSettings: a small ⚙ beside the heading opens the page's own settings (2026-10-25)
export default function PageShell({ title, subtitle, description, primaryAction, actions, onSettings, children }) {
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
      {children}
    </main>
  );
}
