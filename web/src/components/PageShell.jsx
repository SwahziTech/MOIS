import { Link } from 'react-router-dom';
import { ChevronRight } from 'lucide-react';

/**
 * PageShell — the standard page frame (2026-10-17). No top bar: the page
 * opens with its breadcrumb ("Home › section"), then the <h1> and a
 * one-line description on the left and the page's main "+ New" action on
 * the right. The light/dark switch lives in the sidebar header.
 */
export default function PageShell({ title, subtitle, description, primaryAction, actions, children }) {
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
          <h1 className="page-title">{title}</h1>
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
