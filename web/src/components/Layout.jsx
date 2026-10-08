import { Outlet, Navigate, useLocation } from 'react-router-dom';
import { useAuth } from '../hooks/useAuth';
import Sidebar from './Sidebar';

// Full-screen spinner shown during auth session resolution
function FullscreenLoader() {
  return (
    <div style={{
      minHeight: '100vh',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      background: 'var(--color-charcoal)',
    }}>
      <div style={{ textAlign: 'center' }}>
        <div className="spinner" style={{ margin: '0 auto 16px', borderTopColor: 'var(--color-khaki)' }} />
        <div style={{ color: 'rgba(255,255,255,0.4)', fontSize: 'var(--text-sm)' }}>Loading...</div>
      </div>
    </div>
  );
}

/** Wraps authenticated pages — redirects to /login if not authenticated */
export function ProtectedLayout() {
  const { isAuthenticated, loading } = useAuth();
  const location = useLocation();

  if (loading) return <FullscreenLoader />;
  if (!isAuthenticated) return <Navigate to="/login" state={{ from: location }} replace />;

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
  const { isAuthenticated, loading } = useAuth();

  if (loading) return <FullscreenLoader />;
  if (isAuthenticated) return <Navigate to="/" replace />;

  return <Outlet />;
}
