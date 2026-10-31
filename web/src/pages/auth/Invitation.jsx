import { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { Eye, EyeOff } from 'lucide-react';
import { useAuth } from '../../hooks/useAuth';
import { manageUsers, roleLabel } from '../../lib/manageUsers';
import AuthShell from '../../components/AuthShell';

const MIN_PASSWORD = 8;

/*
 * Creating your own login from an invitation (migration 100, 2026-10-31):
 * /invite?t=<link token>, or /invite to type a code. The person chooses email
 * or username and a password; a reset link only asks for the new password.
 * Signs them in when done. No company name here (sign-in screens rule).
 */
export default function Invitation() {
  const { signIn } = useAuth();
  const [params] = useSearchParams();
  const token = params.get('t');
  const [code, setCode] = useState('');
  const [invite, setInvite] = useState(null);
  const [checking, setChecking] = useState(!!token);
  const [error, setError] = useState('');
  const [method, setMethod] = useState('username');
  const [email, setEmail] = useState('');
  const [username, setUsername] = useState('');
  const [free, setFree] = useState(null);       // { available, reason } for the username typed
  const [password, setPassword] = useState('');
  const [showPass, setShowPass] = useState(false);
  const [saving, setSaving] = useState(false);
  const proof = token ? { token } : { code };

  async function check() {
    setError(''); setChecking(true);
    try { setInvite(await manageUsers({ action: 'invitation_check', ...proof })); }
    catch (e) { setError(e.message); }
    setChecking(false);
  }
  useEffect(() => { if (token) check(); }, [token]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    setFree(null);
    const name = username.trim();
    if (!invite || invite.kind !== 'invite' || method !== 'username' || !name) return undefined;
    const timer = setTimeout(async () => {
      try { setFree(await manageUsers({ action: 'username_available', ...proof, username: name })); }
      catch { setFree(null); }
    }, 400);
    return () => clearTimeout(timer);
  }, [username, method, invite]); // eslint-disable-line react-hooks/exhaustive-deps

  async function submit(e) {
    e.preventDefault();
    setError('');
    if (password.length < MIN_PASSWORD) { setError(`Use at least ${MIN_PASSWORD} characters for your password.`); return; }
    setSaving(true);
    try {
      const done = await manageUsers({
        action: 'invitation_claim', ...proof, method,
        email: email.trim(), username: username.trim(), password,
      });
      // signed in, the sign-in layout sends them on to the app
      const { error: err } = await signIn(done.sign_in, password);
      if (err) setError('Your login is ready. Please sign in.');
    } catch (err) { setError(err.message); }
    setSaving(false);
  }

  const back = <div className="auth-footer"><Link to="/login">Back to sign in</Link></div>;
  const failure = error && <div className="alert alert-error" role="alert" style={{ marginBottom: 20 }}>{error}</div>;

  if (checking) return <AuthShell><p className="auth-subtitle">Checking your invitation…</p></AuthShell>;

  if (!invite) {
    return (
      <AuthShell>
        <h1 className="auth-title">Your invitation</h1>
        <p className="auth-subtitle">{token ? 'This link can\'t be used.' : 'Type the code you were given.'}</p>
        {failure}
        {!token && (
          <form className="auth-form" onSubmit={e => { e.preventDefault(); check(); }}>
            <div className="form-group">
              <label className="form-label" htmlFor="invite-code">Invitation code</label>
              <input id="invite-code" className="form-input" required autoFocus autoCapitalize="characters" autoComplete="off" spellCheck={false}
                placeholder="MOIS-7K4QPX" value={code} onChange={e => setCode(e.target.value)} />
            </div>
            <button type="submit" className="btn btn-primary btn-lg w-full auth-submit">Continue</button>
          </form>
        )}
        {back}
      </AuthShell>
    );
  }

  const isReset = invite.kind === 'reset';
  const passwordField = (
    <div className="form-group">
      <label className="form-label" htmlFor="invite-password">{isReset ? 'New password' : 'Password'}</label>
      <div style={{ position: 'relative' }}>
        <input id="invite-password" type={showPass ? 'text' : 'password'} className="form-input" required minLength={MIN_PASSWORD}
          autoComplete="new-password" placeholder={`At least ${MIN_PASSWORD} characters`} value={password}
          onChange={e => setPassword(e.target.value)} style={{ paddingRight: 44 }} />
        <button type="button" className="password-toggle" onClick={() => setShowPass(v => !v)} aria-label={showPass ? 'Hide password' : 'Show password'}>
          {showPass ? <EyeOff size={16} /> : <Eye size={16} />}
        </button>
      </div>
    </div>
  );

  return (
    <AuthShell>
      <h1 className="auth-title">{isReset ? 'Set a new password' : `Welcome, ${invite.first_name}`}</h1>
      <p className="auth-subtitle">{isReset ? <>For <strong>{invite.username}</strong></> : [roleLabel(invite.role), invite.branch].filter(Boolean).join(' · ')}</p>
      {failure}
      <form className="auth-form" onSubmit={submit}>
        {!isReset && (
          <div className="form-group">
            <span className="form-label">Sign in with</span>
            <div className="auth-choice">
              <button type="button" className={`btn ${method === 'username' ? 'btn-primary' : 'btn-outline'}`} aria-pressed={method === 'username'} onClick={() => setMethod('username')}>Username</button>
              <button type="button" className={`btn ${method === 'email' ? 'btn-primary' : 'btn-outline'}`} aria-pressed={method === 'email'} onClick={() => setMethod('email')}>Email</button>
            </div>
          </div>
        )}
        {!isReset && method === 'username' && (
          <div className="form-group">
            <label className="form-label" htmlFor="invite-username">Username</label>
            <input id="invite-username" className="form-input" required autoCapitalize="none" autoCorrect="off" spellCheck={false} autoComplete="username"
              value={username} onChange={e => setUsername(e.target.value)} />
            {free && <div className={`form-hint ${free.available ? 'text-success' : 'text-warning'}`}>{free.available ? 'Available' : free.reason || 'That username is taken. Try another.'}</div>}
          </div>
        )}
        {!isReset && method === 'email' && (
          <div className="form-group">
            <label className="form-label" htmlFor="invite-email-own">Email address</label>
            <input id="invite-email-own" type="email" className="form-input" required autoComplete="email" value={email} onChange={e => setEmail(e.target.value)} />
          </div>
        )}
        {passwordField}
        <button type="submit" className={`btn btn-primary btn-lg w-full auth-submit${saving ? ' btn-loading' : ''}`}
          disabled={saving || (!isReset && method === 'username' && free?.available === false)}>
          {saving ? 'Saving…' : isReset ? 'Save new password' : 'Create my account'}
        </button>
      </form>
      {back}
    </AuthShell>
  );
}
