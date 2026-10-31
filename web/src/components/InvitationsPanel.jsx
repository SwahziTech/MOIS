import { useEffect, useState } from 'react';
import { Copy } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { manageUsers, roleLabel } from '../lib/manageUsers';
import { tableDate } from '../lib/format';
import ErrorState from './ErrorState';
import Modal from './Modal';

const COLS = 'id, kind, first_name, last_name, role_id, expires_at, status, claimed_at, created_at';

/*
 * Invitations and reset links (migration 100, 2026-10-31), newest first. Who
 * they were for and where they stand: waiting, expired, used or cancelled. The
 * link and code show once, when made, so a lost one is cancelled and remade.
 */
export default function InvitationsPanel({ roles }) {
  const [rows, setRows] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState('');

  async function load() {
    setError('');
    const { data, error: err } = await supabase.from('user_invitations').select(COLS).order('created_at', { ascending: false });
    if (err) { console.error(err); setError("We couldn't load invitations."); setRows([]); return; }
    setRows(data || []);
  }
  useEffect(() => { load(); }, []);

  async function cancel(id) {
    setBusy(id); setError('');
    try { await manageUsers({ action: 'cancel_invitation', id }); await load(); }
    catch (e) { setError(e.message); }
    setBusy('');
  }

  const expired = r => r.status === 'waiting' && new Date(r.expires_at) < new Date();
  const statusOf = r => (r.status === 'claimed' ? { text: `Used ${tableDate(r.claimed_at)}`, cls: 'badge-success' }
    : r.status === 'cancelled' ? { text: 'Cancelled', cls: 'badge-neutral' }
    : expired(r) ? { text: 'Expired', cls: 'badge-neutral' }
    : { text: 'Waiting', cls: 'badge-info' });
  const roleName = id => roleLabel(roles.find(x => x.id === id)?.name);

  return (
    <div className="card">
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      {rows === null ? <div className="card-body"><span className="skeleton" /></div> : error && rows.length === 0 ? <ErrorState message={error} onRetry={load} /> : (
        <div className="table-container">
          <table>
            <thead><tr><th>Person</th><th>For</th><th>Date</th><th>Status</th><th aria-label="Actions" /></tr></thead>
            <tbody>
              {rows.length === 0 ? <tr><td colSpan={5} className="text-muted">No invitations yet.</td></tr> : rows.map(r => {
                const st = statusOf(r);
                return (
                  <tr key={r.id}>
                    <td>{[r.first_name, r.last_name].filter(Boolean).join(' ') || '—'}</td>
                    <td>{r.kind === 'reset' ? 'Password reset' : roleName(r.role_id)}</td>
                    <td>{tableDate(r.created_at)}</td>
                    <td><span className={`badge ${st.cls}`}>{st.text}</span></td>
                    <td style={{ textAlign: 'right' }}>
                      {r.status === 'waiting' && !expired(r) && <button type="button" className="btn btn-ghost btn-sm" disabled={busy === r.id} onClick={() => cancel(r.id)}>Cancel</button>}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

/* A link and code just made: shown once, to copy and send */
export function InvitationReady({ ready, onClose }) {
  const [copied, setCopied] = useState('');
  async function copy(what, text) {
    try { await navigator.clipboard.writeText(text); setCopied(what); }
    catch { setCopied(''); window.prompt('Copy this', text); }
  }
  return (
    <Modal title={ready.title} onClose={onClose} footer={<button type="button" className="btn btn-primary" onClick={onClose}>Done</button>}>
      <div className="modal-form">
        <p className="text-sm">Works once and lasts 48 hours. Send it only to this person: whoever uses it first gets this {ready.reset ? 'reset' : 'account'}. It won&apos;t be shown again.</p>
        <div className="inv-code">{ready.code}</div>
        <div className="inv-actions">
          <button type="button" className="btn btn-primary" onClick={() => copy('link', ready.link)}><Copy size={14} /> {copied === 'link' ? 'Link copied' : 'Copy link'}</button>
          <button type="button" className="btn btn-outline" onClick={() => copy('code', ready.code)}><Copy size={14} /> {copied === 'code' ? 'Code copied' : 'Copy code'}</button>
        </div>
      </div>
    </Modal>
  );
}
