import { Link } from 'react-router-dom';
import { ChevronRight } from 'lucide-react';
import ThemeToggle from './ThemeToggle';

/**
 * PageShell — consistent topbar + page header + content wrapper.
 *
 * Topbar:  page title (left) · actions + theme toggle (right)
 * Header:  breadcrumb ("Home › section") and the page <h1>
 */
export default function PageShell({ title, subtitle, actions, children }) {
  return (
    <>
      <header className="topbar">
        <div className="topbar-title">{title}</div>
        <div className="topbar-actions">
          {actions}
          <ThemeToggle />
        </div>
      </header>
      <main className="page-content animate-fadeIn">
        <div className="page-header">
          <nav className="page-breadcrumb" aria-label="Breadcrumb">
            <Link to="/">Home</Link>
            {subtitle && (
              <>
                <ChevronRight size={12} />
                <span>{subtitle}</span>
              </>
            )}
          </nav>
          <h1 className="page-title">{title}</h1>
        </div>
        {children}
      </main>
    </>
  );
}
