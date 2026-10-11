import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import { SkeletonRow } from '../components/LoadingSpinner';
import { Users, Search, ShieldCheck } from 'lucide-react';

const LOAD_ERROR = "We couldn't load this page. Please try again.";

export default function UsersPage() {
  const { organization } = useAuth();
  const [users,   setUsers]   = useState([]);
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [search,  setSearch]  = useState('');

  async function load() {
    setLoading(true);
    setError('');
    // Two queries instead of an embed: user_roles.user_id references
    // auth.users, not profiles, so PostgREST cannot join them (PGRST200)
    // until migration 013 adds the FK.
    const [profRes, rolesRes] = await Promise.all([
      supabase
        .from('profiles')
        .select('id, first_name, last_name, phone, status, created_at')
        .eq('organization_id', organization.id)
        .order('created_at'),
      supabase
        .from('user_roles')
        .select('user_id, role:roles(name)')
        .eq('organization_id', organization.id),
    ]);
    const err = profRes.error || rolesRes.error;
    if (err) { console.error(err); setError(LOAD_ERROR); setLoading(false); return; }
    const rolesByUser = {};
    for (const ur of rolesRes.data || []) (rolesByUser[ur.user_id] ||= []).push(ur);
    setUsers((profRes.data || []).map(p => ({ ...p, user_roles: rolesByUser[p.id] || [] })));
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  const filtered = !search
    ? users
    : users.filter(u => {
        const name = `${u.first_name} ${u.last_name}`.toLowerCase();
        return name.includes(search.toLowerCase());
      });

  function getRoleNames(u) {
    return [...new Set(
      (u.user_roles || []).map(ur => ur.role?.name).filter(Boolean)
    )];
  }

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
              placeholder="Search users…"
              value={search}
              onChange={e => setSearch(e.target.value)}
            />
          </div>
        </div>
      }
    >
      <div className="card">
        {error ? (
          <ErrorState message={error} onRetry={load} />
        ) : (
          <div className="table-container">
            <table>
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Role(s)</th>
                  <th>Phone</th>
                  <th>Joined</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  Array.from({ length: 4 }).map((_, i) => <SkeletonRow key={i} cols={5} />)
                ) : filtered.length === 0 ? (
                  <tr>
                    <td colSpan={5}>
                      <EmptyState
                        icon={Users}
                        title="No users found"
                        description={
                          search
                            ? `No users match "${search}".`
                            : 'No users belong to this organization yet.'
                        }
                      />
                    </td>
                  </tr>
                ) : (
                  filtered.map(u => {
                    const roles = getRoleNames(u);
                    const initials = `${(u.first_name || '')[0] || ''}${(u.last_name || '')[0] || ''}`.toUpperCase() || '?';
                    const fullName = [u.first_name, u.last_name].filter(Boolean).join(' ') || u.id.slice(0, 8);
                    return (
                      <tr key={u.id}>
                        <td>
                          <div className="flex items-center gap-8">
                            <div style={{
                              width: 32, height: 32,
                              borderRadius: '50%',
                              background: 'var(--color-khaki)',
                              color: 'var(--color-charcoal)',
                              display: 'flex', alignItems: 'center', justifyContent: 'center',
                              fontSize: 'var(--text-xs)', fontWeight: 700, flexShrink: 0,
                            }}>
                              {initials}
                            </div>
                            <span style={{ fontWeight: 500 }}>{fullName}</span>
                          </div>
                        </td>
                        <td>
                          <div className="flex gap-4" style={{ flexWrap: 'wrap' }}>
                            {roles.length > 0
                              ? roles.map(r => (
                                  <span key={r} className="badge badge-accent">
                                    <ShieldCheck size={10} strokeWidth={2} />
                                    {r}
                                  </span>
                                ))
                              : <span style={{ color: 'var(--text-muted)' }}>—</span>
                            }
                          </div>
                        </td>
                        <td>{u.phone || <span style={{ color: 'var(--text-muted)' }}>—</span>}</td>
                        <td style={{ color: 'var(--text-muted)' }}>{formatDate(u.created_at)}</td>
                        <td>
                          <span className={`badge ${u.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>
                            {u.status}
                          </span>
                        </td>
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
    </PageShell>
  );
}
