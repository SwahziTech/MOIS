import { useState } from 'react';
import { useNavigate, Link, useLocation } from 'react-router-dom';
import { useAuth } from '../../hooks/useAuth';
import AuthShell from '../../components/AuthShell';
import GoogleButton from '../../components/GoogleButton';
import { Eye, EyeOff } from 'lucide-react';

export default function Login() {
  const { signIn } = useAuth();
  const navigate   = useNavigate();
  const location   = useLocation();
  const from       = location.state?.from?.pathname || '/';

  const [email,    setEmail]    = useState('');
  const [password, setPassword] = useState('');
  const [showPass, setShowPass] = useState(false);
  const [loading,  setLoading]  = useState(false);
  const [error,    setError]    = useState('');

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    setLoading(true);
    const { error: err } = await signIn(email.trim(), password);
    setLoading(false);
    if (err) {
      setError(err.message);
    } else {
      navigate(from, { replace: true });
    }
  }

  return (
    <AuthShell>
      <h1 className="auth-title">Sign in</h1>
      <p className="auth-subtitle">Manufacturing Operating Intelligent System</p>

      {error && (
        <div className="alert alert-error" role="alert" style={{ marginBottom: 20 }}>
          {error}
        </div>
      )}

      <GoogleButton onError={setError} />

      <form onSubmit={handleSubmit} className="auth-form">
        <div className="form-group">
          <label className="form-label" htmlFor="login-email">Email or username</label>
          <input
            id="login-email"
            type="text"
            className="form-input"
            placeholder="you@example.com or username"
            autoComplete="username"
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            required
            value={email}
            onChange={e => setEmail(e.target.value)}
          />
        </div>

        <div className="form-group">
          <label className="form-label" htmlFor="login-password">Password</label>
          <div style={{ position: 'relative' }}>
            <input
              id="login-password"
              type={showPass ? 'text' : 'password'}
              className="form-input"
              placeholder="Enter your password"
              autoComplete="current-password"
              required
              value={password}
              onChange={e => setPassword(e.target.value)}
              style={{ paddingRight: 44 }}
            />
            <button
              type="button"
              className="password-toggle"
              onClick={() => setShowPass(v => !v)}
              aria-label={showPass ? 'Hide password' : 'Show password'}
            >
              {showPass ? <EyeOff size={16} /> : <Eye size={16} />}
            </button>
          </div>
        </div>

        <Link to="/forgot-password" className="auth-link auth-forgot">Forgot password?</Link>

        <button
          id="login-submit"
          type="submit"
          className={`btn btn-primary btn-lg w-full auth-submit${loading ? ' btn-loading' : ''}`}
          disabled={loading}
        >
          {loading ? 'Signing in…' : 'Sign in'}
        </button>
      </form>

      <div className="auth-footer">
        Have an invitation? <Link to="/invite">Create your login</Link>
      </div>
    </AuthShell>
  );
}
