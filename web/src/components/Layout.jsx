import { Outlet, Navigate, useLocation } from 'react-router-dom';
import { Building2, LogOut } from 'lucide-react';
import { useAuth } from '../hooks/useAuth';
import Sidebar from './Sidebar';
import AuthBrand from './AuthBrand';

// Full-screen spinner shown during auth session resolution
function FullscreenLoader() {
  return (
    <div className="fullscreen-loader" role="status">
      <div className="spinner" />
      <div className="fullscreen-loader-label">Loading…</div>
    </div>
  );
}

/**
 * Signed in, but not attached to an active organization. Every tenant table
 * is scoped by profiles.organization_id, so there is nothing to show yet.
 */
function NoOrganization({ inactive, deactivated }) {
  const { session, signOut } = useAuth();
  return (
    <div className="auth-page">
      <div className="auth-card">
        <AuthBrand />
        <div className="empty-state" style={{ padding: '8px 0 0' }}>
          <div className="empty-state-icon"><Building2 size={22} strokeWidth={1.5} /></div>
          <h1 className="auth-title">
            {deactivated ? 'Account deactivated' : inactive ? 'Organization unavailable' : 'No organization yet'}
          </h1>
          <p className="empty-state-desc">
            {deactivated
              ? 'Your account has been deactivated. Contact your company administrator if this is a mistake.'
              : inactive
              ? 'Your organization is not active. Contact your MOIS administrator.'
              : <>You are signed in as <strong>{session?.user?.email}</strong>, but your account
                  has not been added to an organization. Ask your company administrator to add you.</>}
          </p>
          <button type="button" className="btn btn-outline mt-8" onClick={() => signOut()}>
            <LogOut size={14} /> Sign out
          </button>
        </div>
      </div>
    </div>
  );
}

/** Wraps authenticated pages — redirects to /login if not authenticated */
export function ProtectedLayout() {
  const { isAuthenticated, loading, recovering, profile, organization } = useAuth();
  const location = useLocation();

  if (loading) return <FullscreenLoader />;
  if (!isAuthenticated) return <Navigate to="/login" state={{ from: location }} replace />;
  if (recovering) return <Navigate to="/reset-password" replace />;
  if (profile && profile.status !== 'active') return <NoOrganization deactivated />;
  if (!profile?.organization_id || !organization) return <NoOrganization />;
  if (organization.status !== 'active') return <NoOrganization inactive />;

  return (
    <>
      <Sidebar />
      <div className="main-wrapper">
        <Outlet />
      </div>
    </>
  );
}

/** Wraps auth pages — redirects to / if already authenticated */
export function AuthLayout() {
  const { isAuthenticated, loading, recovering } = useAuth();

  if (loading) return <FullscreenLoader />;
  if (isAuthenticated) return <Navigate to={recovering ? '/reset-password' : '/'} replace />;

  return <Outlet />;
}
