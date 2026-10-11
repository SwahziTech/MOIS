import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useAuth } from '../../hooks/useAuth';
import AuthShell from '../../components/AuthShell';
import { Eye, EyeOff, UserPlus, MailCheck } from 'lucide-react';

export default function Signup() {
  const { signUp }   = useAuth();
  const navigate     = useNavigate();

  const [firstName, setFirstName] = useState('');
  const [lastName,  setLastName]  = useState('');
  const [email,     setEmail]     = useState('');
  const [password,  setPassword]  = useState('');
  const [showPass,  setShowPass]  = useState(false);
  const [loading,   setLoading]   = useState(false);
  const [error,     setError]     = useState('');
  const [pendingConfirm, setPendingConfirm] = useState(false);

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    if (password.length < 8) {
      setError('Password must be at least 8 characters.');
      return;
    }
    setLoading(true);
    const { data, error: err } = await signUp(email.trim(), password, {
      first_name: firstName.trim(),
      last_name:  lastName.trim(),
    });
    setLoading(false);
    if (err) {
      setError(err.message);
    } else if (data.session) {
      // Email confirmation disabled in Supabase — already signed in
      navigate('/', { replace: true });
    } else {
      // Email confirmation enabled — no session until the link is clicked
      setPendingConfirm(true);
    }
  }

  return (
    <AuthShell>

      {pendingConfirm ? (
        <div style={{ textAlign: 'center', padding: '16px 0' }}>
          <MailCheck size={40} color="var(--color-success)" style={{ margin: '0 auto 16px' }} />
          <h1 className="auth-title">Confirm your email</h1>
          <p className="auth-subtitle">
            We sent a confirmation link to <strong>{email}</strong>. Open it to activate your account, then sign in.
          </p>
          <Link to="/login" className="btn btn-primary btn-lg w-full" style={{ justifyContent: 'center' }}>Go to sign in</Link>
        </div>
      ) : (<>
      <h1 className="auth-title">Create account</h1>
      <p className="auth-subtitle">Join your organisation on MOIS</p>

      {error && (
        <div className="alert alert-error" role="alert" style={{ marginBottom: 20 }}>
          {error}
        </div>
      )}

      <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <div className="form-group">
            <label className="form-label" htmlFor="signup-firstname">First name</label>
            <input id="signup-firstname" type="text" className="form-input" required
              value={firstName} onChange={e => setFirstName(e.target.value)}
              autoComplete="given-name" placeholder="Juma" />
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="signup-lastname">Last name</label>
            <input id="signup-lastname" type="text" className="form-input"
              value={lastName} onChange={e => setLastName(e.target.value)}
              autoComplete="family-name" placeholder="Mwangi" />
          </div>
        </div>

        <div className="form-group">
          <label className="form-label" htmlFor="signup-email">Email address</label>
          <input id="signup-email" type="email" className="form-input" required
            value={email} onChange={e => setEmail(e.target.value)}
            autoComplete="email" placeholder="you@company.com" />
        </div>

        <div className="form-group">
          <label className="form-label" htmlFor="signup-password">Password</label>
          <div style={{ position: 'relative' }}>
            <input id="signup-password" type={showPass ? 'text' : 'password'}
              className="form-input" required minLength={8}
              value={password} onChange={e => setPassword(e.target.value)}
              autoComplete="new-password" placeholder="Min. 8 characters"
              style={{ paddingRight: 40 }} />
            <button type="button" className="password-toggle"
              onClick={() => setShowPass(v => !v)}
              aria-label={showPass ? 'Hide password' : 'Show password'}>
              {showPass ? <EyeOff size={16} /> : <Eye size={16} />}
            </button>
          </div>
          <div className="form-hint">Minimum 8 characters</div>
        </div>

        <button id="signup-submit" type="submit"
          className={`btn btn-primary btn-lg w-full${loading ? ' btn-loading' : ''}`}
          disabled={loading} style={{ justifyContent: 'center', marginTop: 4 }}>
          {!loading && <UserPlus size={16} />}
          {loading ? 'Creating account…' : 'Create account'}
        </button>
      </form>

      <div className="auth-footer">
        Already have an account? <Link to="/login">Sign in</Link>
      </div>
      </>)}
    </AuthShell>
  );
}
