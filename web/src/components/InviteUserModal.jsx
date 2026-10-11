import { useState } from 'react';
import { Send } from 'lucide-react';
import Modal from './Modal';
import AccessFields, { EMPTY_ACCESS } from './AccessFields';
import { manageUsers } from '../lib/manageUsers';

export default function InviteUserModal({ roles, branches, warehouses, onClose, onInvited }) {
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
      title="Invite user"
      onClose={onClose}
      footer={
        <>
          <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
          <button type="submit" form="invite-form" className={`btn btn-primary${saving ? ' btn-loading' : ''}`} disabled={saving}>
            {!saving && <Send size={14} />} Send invitation
          </button>
        </>
      }
    >
      <form id="invite-form" onSubmit={handleSubmit} className="modal-form">
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        <div className="form-group">
          <label className="form-label" htmlFor="invite-email">Email address</label>
          <input id="invite-email" type="email" className="form-input" required autoFocus
            value={email} onChange={e => setEmail(e.target.value)} placeholder="name@company.com" />
          <div className="form-hint">They receive an email link to set a password. If they already signed up (e.g. with Google), they are added directly.</div>
        </div>
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="invite-first">First name</label>
            <input id="invite-first" className="form-input" value={firstName} onChange={e => setFirstName(e.target.value)} />
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="invite-last">Last name</label>
            <input id="invite-last" className="form-input" value={lastName} onChange={e => setLastName(e.target.value)} />
          </div>
        </div>
        <AccessFields idPrefix="invite" roles={roles} branches={branches} warehouses={warehouses}
          value={access} onChange={setAccess} />
      </form>
    </Modal>
  );
}
