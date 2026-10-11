import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import AuthBrand from '../../components/AuthBrand';
import { Eye, EyeOff, CheckCircle, ArrowLeft } from 'lucide-react';

export default function ResetPassword() {
  const navigate = useNavigate();
  const { session, finishRecovery } = useAuth();
  const [password,  setPassword]  = useState('');
  const [confirm,   setConfirm]   = useState('');
  const [showPass,  setShowPass]  = useState(false);
  const [loading,   setLoading]   = useState(false);
  const [error,     setError]     = useState('');
  const [done,      setDone]      = useState(false);

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    if (password.length < 8) { setError('Password must be at least 8 characters.'); return; }
    if (password !== confirm) { setError('Passwords do not match.'); return; }
    setLoading(true);
    const { error: err } = await supabase.auth.updateUser({ password });
    setLoading(false);
    if (err) setError(err.message);
    else {
      setDone(true);
      finishRecovery();
      setTimeout(() => navigate('/', { replace: true }), 2500);
    }
  }

  // Still resolving the recovery token from the URL
  if (session === undefined) {
    return <div className="fullscreen-loader" role="status"><div className="spinner" /></div>;
  }

  return (
    <div className="auth-page">
      <div className="auth-card">
        <AuthBrand />

        {!session && !done ? (
          <>
            <h1 className="auth-title">Link expired</h1>
            <p className="auth-subtitle">
              This password reset link is invalid or has expired. Request a new one.
            </p>
            <Link to="/forgot-password" className="btn btn-primary btn-lg w-full" style={{ justifyContent: 'center' }}>
              Request new link
            </Link>
            <div className="auth-footer">
              <Link to="/login" className="inline-flex items-center gap-4"><ArrowLeft size={14} /> Back to sign in</Link>
            </div>
          </>
        ) : done ? (
          <div style={{ textAlign: 'center', padding: '16px 0' }}>
            <CheckCircle size={40} color="var(--color-success)" style={{ margin: '0 auto 16px' }} />
            <h1 className="auth-title">Password updated</h1>
            <p className="auth-subtitle">Redirecting to dashboard…</p>
          </div>
        ) : (
          <>
            <h1 className="auth-title">Set new password</h1>
            <p className="auth-subtitle">Choose a strong password for your account.</p>

            {error && <div className="alert alert-error" role="alert" style={{ marginBottom: 20 }}>{error}</div>}

            <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              <div className="form-group">
                <label className="form-label form-label-required" htmlFor="rp-password">New password</label>
                <div style={{ position: 'relative' }}>
                  <input id="rp-password" type={showPass ? 'text' : 'password'}
                    className="form-input" required minLength={8} autoComplete="new-password"
                    value={password} onChange={e => setPassword(e.target.value)}
                    style={{ paddingRight: 40 }} placeholder="Min. 8 characters" />
                  <button type="button" className="password-toggle"
                    onClick={() => setShowPass(v => !v)}
                    aria-label={showPass ? 'Hide password' : 'Show password'}>
                    {showPass ? <EyeOff size={16} /> : <Eye size={16} />}
                  </button>
                </div>
              </div>
              <div className="form-group">
                <label className="form-label form-label-required" htmlFor="rp-confirm">Confirm password</label>
                <input id="rp-confirm" type="password" className="form-input" required autoComplete="new-password"
                  value={confirm} onChange={e => setConfirm(e.target.value)} placeholder="Re-enter password" />
              </div>
              <button id="rp-submit" type="submit"
                className={`btn btn-primary btn-lg w-full${loading ? ' btn-loading' : ''}`}
                disabled={loading} style={{ justifyContent: 'center', marginTop: 4 }}>
                {loading ? 'Saving…' : 'Set new password'}
              </button>
            </form>
          </>
        )}
      </div>
    </div>
  );
}
