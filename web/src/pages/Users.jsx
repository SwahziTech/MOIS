import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { roleLabel } from '../lib/manageUsers';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import InviteUserModal from '../components/InviteUserModal';
import ManageUserModal from '../components/ManageUserModal';
import { scopeLabel } from '../components/AccessFields';
import { SkeletonRow } from '../components/LoadingSpinner';
import { Users, Search, ShieldCheck, UserPlus } from 'lucide-react';

const LOAD_ERROR = "We couldn't load this page. Please try again.";

export default function UsersPage() {
  const { organization, session, can, hasRole } = useAuth();
  const [users,      setUsers]      = useState([]);
  const [roles,      setRoles]      = useState([]);
  const [branches,   setBranches]   = useState([]);
  const [warehouses, setWarehouses] = useState([]);
  const [loading,    setLoading]    = useState(true);
  const [error,      setError]      = useState('');
  const [notice,     setNotice]     = useState('');
  const [search,     setSearch]     = useState('');
  const [inviting,   setInviting]   = useState(false);
  const [managingId, setManagingId] = useState(null);

  const canInvite = can('users.invite');
  const canManage = can('users.manage');

  async function load({ quiet = false } = {}) {
    if (!quiet) setLoading(true);
    setError('');
    // Embeds via the user_roles.user_id → profiles.id FK (migration 013).
    const [userRes, roleRes, branchRes, whRes] = await Promise.all([
      supabase
        .from('profiles')
        .select(`
          id, first_name, last_name, email, phone, status, created_at,
          user_roles(
            id, branch_id, warehouse_id,
            role:roles(id, name),
            branch:branches(name),
            warehouse:warehouses(name)
          )
        `)
        .eq('organization_id', organization.id)
        .order('created_at'),
      supabase.from('roles').select('id, name').order('name'),
      supabase.from('branches').select('id, name').eq('status', 'active').order('name'),
      supabase.from('warehouses').select('id, name, branch_id').eq('status', 'active').order('name'),
    ]);
    const err = userRes.error || roleRes.error || branchRes.error || whRes.error;
    if (err) { console.error(err); setError(LOAD_ERROR); setLoading(false); return; }
    setUsers(userRes.data || []);
    // Only owners may grant the owner role (enforced server-side too)
    setRoles((roleRes.data || []).filter(r => r.name !== 'owner' || hasRole('owner')));
    setBranches(branchRes.data || []);
    setWarehouses(whRes.data || []);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  const filtered = !search
    ? users
    : users.filter(u => {
        const q = search.toLowerCase();
        return `${u.first_name} ${u.last_name}`.toLowerCase().includes(q) ||
               (u.email || '').toLowerCase().includes(q);
      });

  const managing = users.find(u => u.id === managingId);

  function formatDate(str) {
    return str ? new Date(str).toLocaleDateString('en-TZ', { day: 'numeric', month: 'short', year: 'numeric' }) : '—';
  }

  return (
    <PageShell
      title="Users"
      subtitle="Organisation"
      actions={
        <div className="flex items-center gap-8">
          <div className="search-wrapper">
            <Search size={14} className="search-icon" />
            <input
              id="users-search"
              type="search"
              className="search-input"
              placeholder="Search name or email…"
              aria-label="Search users"
              value={search}
              onChange={e => setSearch(e.target.value)}
            />
          </div>
          {canInvite && (
            <button type="button" className="btn btn-primary" onClick={() => { setNotice(''); setInviting(true); }}>
              <UserPlus size={14} /> Invite user
            </button>
          )}
        </div>
      }
    >
      {notice && <div className="alert alert-success mb-16" role="status">{notice}</div>}

      <div className="card">
        {error ? (
          <ErrorState message={error} onRetry={load} />
        ) : (
          <div className="table-container">
            <table>
              <thead>
                <tr>
                  <th>User</th>
                  <th>Access</th>
                  <th>Joined</th>
                  <th>Status</th>
                  {canManage && <th aria-label="Actions" />}
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  Array.from({ length: 4 }).map((_, i) => <SkeletonRow key={i} cols={canManage ? 5 : 4} />)
                ) : filtered.length === 0 ? (
                  <tr>
                    <td colSpan={canManage ? 5 : 4}>
                      <EmptyState
                        icon={Users}
                        title="No users found"
                        description={search ? `No users match "${search}".` : 'No users belong to this organization yet.'}
                      />
                    </td>
                  </tr>
                ) : (
                  filtered.map(u => {
                    const fullName = [u.first_name, u.last_name].filter(Boolean).join(' ');
                    const initials = `${(u.first_name || '')[0] || ''}${(u.last_name || '')[0] || ''}`.toUpperCase()
                      || (u.email || '?')[0].toUpperCase();
                    return (
                      <tr key={u.id}>
                        <td>
                          <div className="flex items-center gap-8">
                            <div className="user-avatar">{initials}</div>
                            <div>
                              <div style={{ fontWeight: 500 }}>{fullName || u.email || 'Unnamed user'}</div>
                              {fullName && u.email && <div className="text-muted text-sm">{u.email}</div>}
                            </div>
                          </div>
                        </td>
                        <td>
                          <div className="flex gap-4" style={{ flexWrap: 'wrap' }}>
                            {u.user_roles.length > 0
                              ? u.user_roles.map(g => (
                                  <span key={g.id} className="badge badge-accent" title={scopeLabel(g)}>
                                    <ShieldCheck size={10} strokeWidth={2} />
                                    {roleLabel(g.role?.name)}
                                    <span className="badge-scope">· {scopeLabel(g)}</span>
                                  </span>
                                ))
                              : <span className="text-muted">No access</span>}
                          </div>
                        </td>
                        <td className="text-muted">{formatDate(u.created_at)}</td>
                        <td>
                          <span className={`badge ${u.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>
                            {u.status}
                          </span>
                        </td>
                        {canManage && (
                          <td style={{ textAlign: 'right' }}>
                            <button type="button" className="btn btn-outline btn-sm" onClick={() => { setNotice(''); setManagingId(u.id); }}>
                              Manage
                            </button>
                          </td>
                        )}
                      </tr>
                    );
                  })
                )}
              </tbody>
            </table>
            {!loading && filtered.length > 0 && (
              <div style={{ padding: '10px 14px', borderTop: '1px solid var(--border)', fontSize: 'var(--text-xs)', color: 'var(--text-muted)' }}>
                {filtered.length} user{filtered.length !== 1 ? 's' : ''}
              </div>
            )}
          </div>
        )}
      </div>

      {inviting && (
        <InviteUserModal
          roles={roles} branches={branches} warehouses={warehouses}
          onClose={() => setInviting(false)}
          onInvited={async result => {
            setInviting(false);
            setNotice(result.invited
              ? 'Invitation sent. The user appears here now and can sign in once they open the email link.'
              : 'Existing account added to your organization.');
            await load({ quiet: true });
          }}
        />
      )}

      {managing && (
        <ManageUserModal
          user={managing}
          organizationId={organization.id}
          roles={roles} branches={branches} warehouses={warehouses}
          isSelf={managing.id === session?.user?.id}
          onClose={() => setManagingId(null)}
          onChanged={() => load({ quiet: true })}
        />
      )}
    </PageShell>
  );
}
