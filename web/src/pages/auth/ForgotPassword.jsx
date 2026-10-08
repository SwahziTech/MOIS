import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../../hooks/useAuth';
import { Mail, ArrowLeft, CheckCircle } from 'lucide-react';

export default function ForgotPassword() {
  const { resetPassword } = useAuth();
  const [email,   setEmail]   = useState('');
  const [loading, setLoading] = useState(false);
  const [error,   setError]   = useState('');
  const [sent,    setSent]    = useState(false);

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    setLoading(true);
    const { error: err } = await resetPassword(email.trim());
    setLoading(false);
    if (err) setError(err.message);
    else setSent(true);
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

        {sent ? (
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
              Enter your email address and we&apos;ll send you a reset link.
            </p>

            {error && (
              <div className="alert alert-error" style={{ marginBottom: 20 }}>{error}</div>
            )}

            <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
              <div className="form-group">
                <label className="form-label form-label-required" htmlFor="reset-email">
                  Email address
                </label>
                <input id="reset-email" type="email" className="form-input" required
                  value={email} onChange={e => setEmail(e.target.value)}
                  autoComplete="email" placeholder="you@stumarcot.co.tz" />
              </div>
              <button id="reset-submit" type="submit"
                className={`btn btn-primary btn-lg w-full${loading ? ' btn-loading' : ''}`}
                disabled={loading} style={{ justifyContent: 'center' }}>
                {!loading && <Mail size={16} />}
                {loading ? 'Sending…' : 'Send reset link'}
              </button>
            </form>
          </>
        )}

        <div className="auth-footer" style={{ marginTop: 24 }}>
          <Link to="/login" style={{ display: 'inline-flex', alignItems: 'center', gap: 4, color: 'var(--color-khaki-dark)', fontWeight: 500 }}>
            <ArrowLeft size={14} /> Back to sign in
          </Link>
        </div>
      </div>
    </div>
  );
}
