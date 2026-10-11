import { useState } from 'react';
import { Plus, Trash2, ShieldCheck, UserX, UserCheck } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { manageUsers, roleLabel } from '../lib/manageUsers';
import Modal from './Modal';
import AccessFields, { EMPTY_ACCESS, scopeLabel } from './AccessFields';

/**
 * Edit one user's access (role grants scoped to branch/warehouse) and
 * account status. Grants are written directly (RLS: owners only, and a
 * trigger keeps role/branch/warehouse inside the same organization);
 * status goes through the manage-users Edge Function.
 */
export default function ManageUserModal({ user, organizationId, roles, branches, warehouses, isSelf, onClose, onChanged }) {
  const [access,     setAccess]     = useState(EMPTY_ACCESS);
  const [busy,       setBusy]       = useState(false);
  const [error,      setError]      = useState('');
  const [confirming, setConfirming] = useState(false);

  const name = [user.first_name, user.last_name].filter(Boolean).join(' ') || user.email;
  const deactivating = user.status === 'active';

  async function run(fn) {
    setError('');
    setBusy(true);
    try {
      await fn();
      await onChanged();
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  const addAccess = e => {
    e.preventDefault();
    return run(async () => {
      const { error: err } = await supabase.from('user_roles').insert({
        user_id: user.id,
        organization_id: organizationId,
        role_id: access.role_id,
        branch_id: access.branch_id || null,
        warehouse_id: access.warehouse_id || null,
      });
      if (err) {
        console.error('grant failed', err);
        throw new Error(err.code === '23505'
          ? 'This user already has that access.'
          : "We couldn't add this access. Only owners can change access.");
      }
      setAccess(EMPTY_ACCESS);
    });
  };

  const removeAccess = grantId => run(async () => {
    const { error: err } = await supabase.from('user_roles').delete().eq('id', grantId);
    if (err) {
      console.error('revoke failed', err);
      throw new Error("We couldn't remove this access. Please try again.");
    }
  });

  const toggleStatus = () => run(async () => {
    await manageUsers({ action: 'set_status', user_id: user.id, status: deactivating ? 'inactive' : 'active' });
    setConfirming(false);
  });

  return (
    <Modal title={`Manage ${name}`} onClose={onClose}
      footer={<button type="button" className="btn btn-outline" onClick={onClose}>Done</button>}>
      <div className="modal-form">
        {error && <div className="alert alert-error" role="alert">{error}</div>}

        <section>
          <h3 className="modal-section-title">Access</h3>
          {user.user_roles.length === 0 ? (
            <p className="text-muted text-sm">No access yet — this user cannot see any modules.</p>
          ) : (
            <ul className="grant-list">
              {user.user_roles.map(g => {
                const lockOwn = isSelf && g.role?.name === 'owner';
                return (
                  <li key={g.id} className="grant-row">
                    <span className="badge badge-accent"><ShieldCheck size={10} strokeWidth={2} />{roleLabel(g.role?.name)}</span>
                    <span className="text-sm">{scopeLabel(g)}</span>
                    <button type="button" className="icon-btn" disabled={busy || lockOwn}
                      onClick={() => removeAccess(g.id)}
                      aria-label={`Remove ${roleLabel(g.role?.name)} access`}
                      title={lockOwn ? 'You cannot remove your own owner access' : 'Remove access'}>
                      <Trash2 size={14} />
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </section>

        <form onSubmit={addAccess} className="modal-subform">
          <h3 className="modal-section-title">Add access</h3>
          <AccessFields idPrefix="grant" roles={roles} branches={branches} warehouses={warehouses}
            value={access} onChange={setAccess} />
          <button type="submit" className="btn btn-outline" disabled={busy || !access.role_id}>
            <Plus size={14} /> Add access
          </button>
        </form>

        {!isSelf && (
          <section>
            <h3 className="modal-section-title">Account</h3>
            {!confirming ? (
              <button type="button" className={`btn ${deactivating ? 'btn-outline btn-danger-outline' : 'btn-outline'}`}
                disabled={busy} onClick={() => setConfirming(true)}>
                {deactivating ? <UserX size={14} /> : <UserCheck size={14} />}
                {deactivating ? 'Deactivate user' : 'Reactivate user'}
              </button>
            ) : (
              <div className="confirm-box" role="alert">
                <p className="text-sm">
                  {deactivating
                    ? `${name} will immediately lose access to MOIS and cannot sign in. Their records stay intact.`
                    : `${name} will be able to sign in again with their existing access.`}
                </p>
                <div className="flex gap-8">
                  <button type="button" className={`btn ${deactivating ? 'btn-danger' : 'btn-primary'}${busy ? ' btn-loading' : ''}`}
                    disabled={busy} onClick={toggleStatus}>
                    {deactivating ? 'Yes, deactivate' : 'Yes, reactivate'}
                  </button>
                  <button type="button" className="btn btn-outline" disabled={busy} onClick={() => setConfirming(false)}>Cancel</button>
                </div>
              </div>
            )}
          </section>
        )}
      </div>
    </Modal>
  );
}
