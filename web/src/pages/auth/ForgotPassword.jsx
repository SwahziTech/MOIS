import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../../hooks/useAuth';
import AuthShell from '../../components/AuthShell';
import { Mail, ArrowLeft, CheckCircle } from 'lucide-react';

export default function ForgotPassword() {
  const { resetPassword } = useAuth();
  const [email,   setEmail]   = useState('');
  const [loading, setLoading] = useState(false);
  const [error,   setError]   = useState('');
  const [sent,    setSent]    = useState(false);
  const [askManager, setAskManager] = useState(false);   // a username has no email to reset by

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    if (!email.includes('@')) { setAskManager(true); return; }
    setLoading(true);
    const { error: err } = await resetPassword(email.trim());
    setLoading(false);
    if (err) setError(err.message);
    else setSent(true);
  }

  return (
    <AuthShell>

      {askManager ? (
        <div style={{ textAlign: 'center', padding: '16px 0' }}>
          <h1 className="auth-title">Ask for a reset link</h1>
          <p className="auth-subtitle">
            Accounts with a username reset by a one-time link. Ask your Branch Manager or the Technical admin for one.
          </p>
        </div>
      ) : sent ? (
        <div style={{ textAlign: 'center', padding: '16px 0' }}>
          <CheckCircle size={40} color="var(--color-success)" style={{ margin: '0 auto 16px' }} />
          <h1 className="auth-title">Check your email</h1>
          <p className="auth-subtitle">
            A password reset link has been sent to <strong>{email}</strong>.
            Check your inbox and follow the link to reset your password.
          </p>
        </div>
      ) : (
        <>
          <h1 className="auth-title">Reset password</h1>
          <p className="auth-subtitle">
            Enter your email address or username.
          </p>

          {error && (
            <div className="alert alert-error" style={{ marginBottom: 20 }}>{error}</div>
          )}

          <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
            <div className="form-group">
              <label className="form-label" htmlFor="reset-email">
                Email or username
              </label>
              <input id="reset-email" type="text" className="form-input" required
                value={email} onChange={e => setEmail(e.target.value)}
                autoComplete="username" autoCapitalize="none" spellCheck={false} placeholder="you@company.com or username" />
            </div>
            <button id="reset-submit" type="submit"
              className={`btn btn-primary btn-lg w-full${loading ? ' btn-loading' : ''}`}
              disabled={loading} style={{ justifyContent: 'center' }}>
              {!loading && <Mail size={16} />}
              {loading ? 'Sending…' : 'Continue'}
            </button>
          </form>
        </>
      )}

      <div className="auth-footer" style={{ marginTop: 24 }}>
        <Link to="/login" style={{ display: 'inline-flex', alignItems: 'center', gap: 4, color: 'var(--text-primary)', fontWeight: 500 }}>
          <ArrowLeft size={14} /> Back to sign in
        </Link>
      </div>
    </AuthShell>
  );
}
