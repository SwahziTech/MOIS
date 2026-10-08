import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useAuth } from '../../hooks/useAuth';
import { Eye, EyeOff, UserPlus } from 'lucide-react';

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
  const [success,   setSuccess]   = useState(false);

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    if (password.length < 8) {
      setError('Password must be at least 8 characters.');
      return;
    }
    setLoading(true);
    const { error: err } = await signUp(email.trim(), password, {
      first_name: firstName.trim(),
      last_name:  lastName.trim(),
    });
    setLoading(false);
    if (err) {
      setError(err.message);
    } else {
      // Email verification is OFF in dev — redirect to dashboard
      navigate('/', { replace: true });
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

        <h1 className="auth-title">Create account</h1>
        <p className="auth-subtitle">Join your organisation on MOIS</p>

        {error && (
          <div className="alert alert-error" style={{ marginBottom: 20 }}>
            {error}
          </div>
        )}

        <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <div className="form-group">
              <label className="form-label form-label-required" htmlFor="signup-firstname">First name</label>
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
            <label className="form-label form-label-required" htmlFor="signup-email">Email address</label>
            <input id="signup-email" type="email" className="form-input" required
              value={email} onChange={e => setEmail(e.target.value)}
              autoComplete="email" placeholder="you@stumarcot.co.tz" />
          </div>

          <div className="form-group">
            <label className="form-label form-label-required" htmlFor="signup-password">Password</label>
            <div style={{ position: 'relative' }}>
              <input id="signup-password" type={showPass ? 'text' : 'password'}
                className="form-input" required minLength={8}
                value={password} onChange={e => setPassword(e.target.value)}
                autoComplete="new-password" placeholder="Min. 8 characters"
                style={{ paddingRight: 40 }} />
              <button type="button" tabIndex={-1}
                onClick={() => setShowPass(v => !v)}
                aria-label={showPass ? 'Hide password' : 'Show password'}
                style={{
                  position: 'absolute', right: 10, top: '50%',
                  transform: 'translateY(-50%)',
                  color: 'var(--text-muted)', background: 'none',
                  border: 'none', cursor: 'pointer', display: 'flex',
                }}>
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
      </div>
    </div>
  );
}
