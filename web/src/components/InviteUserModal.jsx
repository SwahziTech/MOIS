import { useState } from 'react';
import { Send } from 'lucide-react';
import Modal from './Modal';
import AccessFields, { EMPTY_ACCESS } from './AccessFields';
import { manageUsers } from '../lib/manageUsers';

/*
 * Invite a person (migration 100): a link and a code they use to create their
 * own login, or, with an email address, the email invitation as before.
 */
export default function InviteUserModal({ roles, branches, warehouses, onClose, onInvited, onReady }) {
  const [email,     setEmail]     = useState('');
  const [firstName, setFirstName] = useState('');
  const [lastName,  setLastName]  = useState('');
  const [access,    setAccess]    = useState(EMPTY_ACCESS);
  const [saving,    setSaving]    = useState(false);
  const [error,     setError]     = useState('');

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    setSaving(true);
    try {
      if (!email.trim()) {
        const made = await manageUsers({
          action: 'create_invitation',
          first_name: firstName.trim(),
          last_name: lastName.trim(),
          role_id: access.role_id,
          branch_id: access.branch_id || null,
          warehouse_id: access.warehouse_id || null,
          origin: window.location.origin,
        });
        onReady({ ...made, title: `Send this to ${firstName.trim()}` });
        return;
      }
      const result = await manageUsers({
        action: 'invite',
        email: email.trim(),
        first_name: firstName.trim(),
        last_name: lastName.trim(),
        role_id: access.role_id,
        branch_id: access.branch_id || null,
        warehouse_id: access.warehouse_id || null,
        // Invite link signs the user in; they choose a password there
        redirect_to: `${window.location.origin}/reset-password`,
      });
      onInvited(result);
    } catch (err) {
      setError(err.message);
      setSaving(false);
    }
  }

  return (
    <Modal
      title="Invite a person"
      onClose={onClose}
      footer={
        <>
          <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
          <button type="submit" form="invite-form" className={`btn btn-primary${saving ? ' btn-loading' : ''}`} disabled={saving}>
            {!saving && <Send size={14} />} {email.trim() ? 'Send by email' : 'Create invitation'}
          </button>
        </>
      }
    >
      <form id="invite-form" onSubmit={handleSubmit} className="modal-form">
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="invite-first">First name</label>
            <input id="invite-first" className="form-input" required autoFocus value={firstName} onChange={e => setFirstName(e.target.value)} />
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="invite-last">Last name</label>
            <input id="invite-last" className="form-input" value={lastName} onChange={e => setLastName(e.target.value)} />
          </div>
        </div>
        <AccessFields idPrefix="invite" roles={roles} branches={branches} warehouses={warehouses}
          value={access} onChange={setAccess} />
        <div className="form-group">
          <label className="form-label" htmlFor="invite-email">Email address (optional)</label>
          <input id="invite-email" type="email" className="form-input"
            value={email} onChange={e => setEmail(e.target.value)} placeholder="name@company.com" />
          <div className="form-hint">Leave it empty to get a link and code to send yourself, by WhatsApp for example. They create their own login, with an email or a username.</div>
        </div>
      </form>
    </Modal>
  );
}
