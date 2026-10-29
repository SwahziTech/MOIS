import { useEffect, useMemo, useState } from 'react';
import { Plus, X, Users } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import EmptyState from '../EmptyState';

/*
 * Teams (HR › Staff, 2026-10-30): a branch's production teams and their usual
 * members, kept here — rename, add or take out members, remove a team.
 * A batch starts with its team's members ticked; who worked can still be
 * changed on each batch (087), as teams change day to day. Removing keeps
 * the team and members on past batches (retired, not deleted).
 */
export default function TeamsPanel({ staff, branchId, inBranch }) {
  const { organization, canAt } = useAuth();
  const canEdit = !!branchId && (canAt('production.create', branchId, null) || canAt('products.manage', branchId, null));
  const [teams, setTeams] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [newName, setNewName] = useState('');
  const [renaming, setRenaming] = useState(null);   // { id, name }
  const [showRetired, setShowRetired] = useState(false);

  async function load() {
    setError('');
    const { data, error: err } = await supabase.from('production_teams')
      .select('id, name, status, branch_id, members:production_team_members(id, name, status, staff_id)').order('name');
    if (err) { console.error(err); setError("We couldn't load the teams."); setTeams([]); return; }
    setTeams(data || []);
  }
  useEffect(() => { load(); }, []);
  async function run(q) {
    setError(''); setBusy(true);
    const { error: err } = await q;
    setBusy(false);
    if (err) { setError(err.code === '23505' ? 'That name is already used.' : dbErrorMessage(err)); return false; }
    await load();
    return true;
  }

  const here = useMemo(() => (teams || []).filter(t => inBranch(t.branch_id) && (showRetired || t.status === 'active')), [teams, inBranch, showRetired]);
  const working = staff.filter(s => s.status === 'active' && (!branchId || s.branch_id === branchId));
  const activeMembers = t => t.members.filter(m => m.status === 'active');
  const inTeams = new Set(here.filter(t => t.status === 'active').flatMap(t => activeMembers(t).map(m => m.staff_id)));
  const nameOf = m => staff.find(s => s.id === m.staff_id)?.full_name ?? m.name;

  async function addTeam() {
    if (!newName.trim()) return;
    if (await run(supabase.from('production_teams').insert({ organization_id: organization?.id, branch_id: branchId, name: newName.trim() }))) setNewName('');
  }
  // add a member: the staff member's row back to active, or a new row linked to them
  async function addMember(t, staffId) {
    const st = staff.find(s => s.id === staffId);
    if (!st) return;
    const old = t.members.find(m => m.staff_id === staffId);
    await run(old ? supabase.from('production_team_members').update({ status: 'active' }).eq('id', old.id)
      : supabase.from('production_team_members').insert({ organization_id: organization?.id, team_id: t.id, name: st.full_name, staff_id: st.id }));
  }

  return (
    <>
      {teams !== null && (
        <div className="mm-stats">
          <div className="mm-stat"><span className="pl-label">Teams</span><strong>{here.filter(t => t.status === 'active').length}</strong><span className="pl-help">{branchId ? 'at the branch' : 'every branch'}</span></div>
          <div className="mm-stat"><span className="pl-label">In a team</span><strong>{inTeams.size}</strong><span className="pl-help">people</span></div>
          <div className="mm-stat"><span className="pl-label">Not in a team</span><strong>{working.filter(s => !inTeams.has(s.id)).length}</strong><span className="pl-help">working staff</span></div>
        </div>
      )}
      <div className="flex items-center gap-8" style={{ margin: '12px 0', flexWrap: 'wrap' }}>
        {canEdit && <>
          <input className="form-input" style={{ maxWidth: 240 }} placeholder="New team, e.g. Juma team" value={newName} onChange={e => setNewName(e.target.value)}
            onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); addTeam(); } }} />
          <button type="button" className="btn btn-primary btn-sm" disabled={busy || !newName.trim()} onClick={addTeam}><Plus size={14} /> New team</button>
        </>}
        <label className="text-sm flex items-center gap-8" style={{ marginLeft: 'auto' }}><input type="checkbox" checked={showRetired} onChange={e => setShowRetired(e.target.checked)} /> Show removed teams</label>
        <span className="pl-help" title="A batch starts with its team's members ticked; who worked can still be changed on each batch. A removed team stays on past batches.">Members are ticked on a batch to start; change them per batch.</span>
      </div>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      {!branchId && <div className="alert alert-warning">Choose a branch to add teams.</div>}
      <section className="sk">
        {teams === null ? Array.from({ length: 3 }).map((_, i) => <div key={i} className="sk-card"><span className="skeleton" /></div>)
        : here.length === 0 ? <div className="card"><EmptyState icon={Users} title="No teams yet" description="Create a team, then add its usual members." /></div>
        : here.map(t => {
          const members = activeMembers(t);
          const others = working.filter(s => s.branch_id === t.branch_id && !members.some(m => m.staff_id === s.id))
            .sort((a, b) => (inTeams.has(a.id) ? 1 : 0) - (inTeams.has(b.id) ? 1 : 0) || a.full_name.localeCompare(b.full_name));
          return (
            <div key={t.id} className={`card tm-card${t.status !== 'active' ? ' is-inactive' : ''}`}>
              <div className="tm-head">
                {renaming?.id === t.id ? (
                  <>
                    <input className="form-input" style={{ maxWidth: 240 }} autoFocus value={renaming.name} onChange={e => setRenaming({ ...renaming, name: e.target.value })} />
                    <button type="button" className="btn btn-primary btn-sm" disabled={busy || !renaming.name.trim()}
                      onClick={async () => { if (await run(supabase.from('production_teams').update({ name: renaming.name.trim() }).eq('id', t.id))) setRenaming(null); }}>Save</button>
                    <button type="button" className="btn btn-ghost btn-sm" onClick={() => setRenaming(null)}>Cancel</button>
                  </>
                ) : (
                  <>
                    <strong>{t.name}</strong>
                    <span className="pl-help">{members.length} member{members.length === 1 ? '' : 's'}{t.status !== 'active' ? ' · removed' : ''}</span>
                    {canEdit && (
                      <span className="tm-actions">
                        {t.status === 'active' && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setRenaming({ id: t.id, name: t.name })}>Rename</button>}
                        <button type="button" className="btn btn-ghost btn-sm" disabled={busy}
                          onClick={() => run(supabase.from('production_teams').update({ status: t.status === 'active' ? 'inactive' : 'active' }).eq('id', t.id))}>
                          {t.status === 'active' ? 'Remove team' : 'Bring back'}</button>
                      </span>
                    )}
                  </>
                )}
              </div>
              <div className="tm-members">
                {members.length === 0 && <span className="pl-help">No members yet.</span>}
                {members.map(m => (
                  <span key={m.id} className="ptc-chip">{nameOf(m)}
                    {canEdit && t.status === 'active' && <button type="button" aria-label={`Take ${nameOf(m)} out of ${t.name}`} title="Take out of the team" disabled={busy}
                      onClick={() => run(supabase.from('production_team_members').update({ status: 'inactive' }).eq('id', m.id))}><X size={11} /></button>}
                  </span>
                ))}
                {canEdit && t.status === 'active' && (
                  <select className="form-input ptc-sel" aria-label={`Add a member to ${t.name}`} value="" disabled={busy}
                    onChange={e => e.target.value && addMember(t, e.target.value)}>
                    <option value="">+ Add member…</option>
                    {others.map(s => <option key={s.id} value={s.id}>{s.full_name}{inTeams.has(s.id) ? ' (in another team)' : ''}</option>)}
                  </select>
                )}
              </div>
            </div>
          );
        })}
      </section>
    </>
  );
}
