import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../../lib/supabase';
import { Eye, EyeOff, CheckCircle } from 'lucide-react';

export default function ResetPassword() {
  const navigate = useNavigate();
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
      setTimeout(() => navigate('/'), 2500);
    }
  }

  return (
    <div className="auth-page">
      <div className="auth-card">
        <div className="auth-logo">
          <div className="auth-logo-mark">SC</div>
          <div>
            <div style={{ fontWeight: 700, fontSize: 'var(--text-md)' }}>Stumarcot</div>
            <div style={{ fontSize: 'var(--text-xs)', color: 'var(--text-muted)', letterSpacing: '0.05em', textTransform: 'uppercase' }}>MOIS</div>
          </div>
        </div>

        {done ? (
          <div style={{ textAlign: 'center', padding: '16px 0' }}>
            <CheckCircle size={40} color="var(--color-success)" style={{ margin: '0 auto 16px' }} />
            <h1 className="auth-title">Password updated</h1>
            <p className="auth-subtitle">Redirecting to dashboard…</p>
          </div>
        ) : (
          <>
            <h1 className="auth-title">Set new password</h1>
            <p className="auth-subtitle">Choose a strong password for your account.</p>

            {error && <div className="alert alert-error" style={{ marginBottom: 20 }}>{error}</div>}

            <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              <div className="form-group">
                <label className="form-label form-label-required" htmlFor="rp-password">New password</label>
                <div style={{ position: 'relative' }}>
                  <input id="rp-password" type={showPass ? 'text' : 'password'}
                    className="form-input" required minLength={8}
                    value={password} onChange={e => setPassword(e.target.value)}
                    style={{ paddingRight: 40 }} placeholder="Min. 8 characters" />
                  <button type="button" tabIndex={-1}
                    onClick={() => setShowPass(v => !v)}
                    style={{ position: 'absolute', right: 10, top: '50%', transform: 'translateY(-50%)', color: 'var(--text-muted)', background: 'none', border: 'none', cursor: 'pointer', display: 'flex' }}>
                    {showPass ? <EyeOff size={16} /> : <Eye size={16} />}
                  </button>
                </div>
              </div>
              <div className="form-group">
                <label className="form-label form-label-required" htmlFor="rp-confirm">Confirm password</label>
                <input id="rp-confirm" type="password" className="form-input" required
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
