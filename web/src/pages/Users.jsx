import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { roleLabel } from '../lib/manageUsers';
import PageShell from '../components/PageShell';
import { ListToolbar, PageTabs } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import InviteUserModal from '../components/InviteUserModal';
import ManageUserModal from '../components/ManageUserModal';
import InvitationsPanel, { InvitationReady } from '../components/InvitationsPanel';
import { manageUsers } from '../lib/manageUsers';
import { isHiddenEmail } from '../lib/authId';
import { scopeLabel } from '../components/AccessFields';
import { SkeletonRow } from '../components/LoadingSpinner';
import { Users, Search, ShieldCheck, UserPlus } from 'lucide-react';
import { tableDate } from '../lib/format';

const LOAD_ERROR = "We couldn't load this page. Please try again.";

export default function UsersPage() {
  const { organization, session, can, hasRole } = useAuth();
  const { branchId, inBranch } = useBranch();
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
  const [tab,        setTab]        = useState('users');
  const [ready,      setReady]      = useState(null);   // an invitation or reset link just made: shown once
  const [listKey,    setListKey]    = useState(0);

  // invitations: the Technical admin; a Branch Manager for their own branch (100)
  const isBM = hasRole('branch_manager');
  const canInvite = hasRole('owner') || isBM;
  async function makeReset(u) {
    setNotice('');
    try {
      const r = await manageUsers({ action: 'create_reset', user_id: u.id, origin: window.location.origin });
      setReady({ ...r, title: `Reset link for ${[u.first_name, u.last_name].filter(Boolean).join(' ') || u.username}`, reset: true });
    } catch (e) { setNotice(e.message); }
  }
  const canManage = can('users.manage');

  async function load({ quiet = false } = {}) {
    if (!quiet) setLoading(true);
    setError('');
    // Embeds via the user_roles.user_id → profiles.id FK (migration 013).
    const [userRes, roleRes, branchRes, whRes] = await Promise.all([
      supabase
        .from('profiles')
        .select(`
          *,
          user_roles(
            id, branch_id, warehouse_id,
            role:roles(id, name),
            branch:branches(name),
            warehouse:warehouses(name)
          )
        `)
        .eq('organization_id', organization.id)
        .order('created_at', { ascending: false }),   // newest on top (2026-10-25)
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

  // With a branch picked: people with a role there, plus org-wide people
  // (Directors, Technical admin), who can act on every branch
  const whBranch = Object.fromEntries(warehouses.map(w => [w.id, w.branch_id]));
  const reaches = g => (!g.branch_id && !g.warehouse_id) || inBranch(g.branch_id || whBranch[g.warehouse_id]);
  const inView = branchId ? users.filter(u => (u.user_roles || []).some(reaches)) : users;
  const filtered = !search
    ? inView
    : inView.filter(u => {
        const q = search.toLowerCase();
        return `${u.first_name} ${u.last_name}`.toLowerCase().includes(q) ||
               (u.email || '').toLowerCase().includes(q) || (u.username || '').includes(q);
      });

  const managing = users.find(u => u.id === managingId);

  function formatDate(str) {
    return tableDate(str) ?? '—';
  }

  return (
    <PageShell
      title="Users"
      subtitle="Organization"
      description="Who can sign in, their role and which branch or store it covers."
      primaryAction={canInvite && (
        <button type="button" className="btn btn-primary" onClick={() => { setNotice(''); setInviting(true); }}>
          <UserPlus size={14} /> Invite person
        </button>
      )}
    >
      {canInvite && <PageTabs tabs={[['users', 'Users'], ['invitations', 'Invitations']]} value={tab} onChange={setTab} />}
      {tab === 'invitations' ? <InvitationsPanel key={listKey} roles={roles} /> : <>
      <ListToolbar id="users-search" search={search} onSearch={setSearch} placeholder="Search name, email or username…" />
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
                  {(canManage || canInvite) && <th aria-label="Actions" />}
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  Array.from({ length: 4 }).map((_, i) => <SkeletonRow key={i} cols={canManage || canInvite ? 5 : 4} />)
                ) : filtered.length === 0 ? (
                  <tr>
                    <td colSpan={canManage || canInvite ? 5 : 4}>
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
                    const shownId = u.username || (isHiddenEmail(u.email) ? '' : u.email);
                    const initials = `${(u.first_name || '')[0] || ''}${(u.last_name || '')[0] || ''}`.toUpperCase()
                      || (shownId || '?')[0].toUpperCase();
                    return (
                      <tr key={u.id}>
                        <td>
                          <div className="flex items-center gap-8">
                            <div className="user-avatar">{initials}</div>
                            <div>
                              <div style={{ fontWeight: 500 }}>{fullName || shownId || 'Unnamed user'}</div>
                              {fullName && shownId && <div className="text-muted text-sm">{shownId}</div>}
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
                        {(canManage || canInvite) && (
                          <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                            {canInvite && u.username && <button type="button" className="btn btn-ghost btn-sm" onClick={() => makeReset(u)}>Reset link</button>}
                            {canManage && <button type="button" className="btn btn-outline btn-sm" onClick={() => { setNotice(''); setManagingId(u.id); }}>
                              Manage
                            </button>}
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

      </>}

      {ready && <InvitationReady ready={ready} onClose={() => setReady(null)} />}

      {inviting && (
        <InviteUserModal
          roles={isBM && !hasRole('owner') ? roles.filter(r => ['secretary', 'storekeeper', 'sales_user'].includes(r.name)) : roles}
          branches={branches} warehouses={warehouses}
          onReady={r => { setInviting(false); setReady(r); setListKey(k => k + 1); }}
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
