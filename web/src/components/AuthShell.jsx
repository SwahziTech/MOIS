import AuthBrand from './AuthBrand';

/**
 * Split-screen layout for sign in / sign up / password screens:
 * form on the left, SwahziTech product panel on the right (hidden on
 * narrow screens). Platform branding only — no tenant names.
 */
export default function AuthShell({ children }) {
  return (
    <div className="auth-split">
      <main className="auth-split-form">
        <div className="auth-split-inner">
          <AuthBrand />
          {children}
        </div>
      </main>

      <aside className="auth-split-hero">
        <div className="auth-split-hero-inner">
          <span className="auth-hero-badge">SwahziTech</span>
          <h2 className="auth-hero-title">Manufacturing operations, reimagined.</h2>
          <p className="auth-hero-text">
            Track production, manage inventory, control pricing—all in one platform
            built for Tanzanian manufacturers.
          </p>
        </div>
      </aside>
    </div>
  );
}
