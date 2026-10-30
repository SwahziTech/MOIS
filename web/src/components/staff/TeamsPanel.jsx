import { useEffect, useMemo, useState } from 'react';
import { Plus, Users } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import EmptyState from '../EmptyState';
import Modal from '../Modal';
import { dateText } from '../../lib/format';

/*
 * Teams (HR › Staff, 2026-10-30): a branch's production teams. Edit renames a
 * team and keeps its members — add, deactivate (still in the team, off for
 * now), remove (taken out — status 'removed', kept for the record, 093). Members are a list to pick from: a batch
 * lists the team's active members first but ticks nobody — who worked is
 * chosen on each batch, as crews change day to day. Only production staff
 * (pay part of product cost) can be members; driver, secretary… aren't
 * listed. Each team also shows who worked in it on its latest batch day.
 * Removing a team keeps it on past batches (retired, not deleted).
 * Edits are for today and the days ahead: a recorded batch keeps its team and
 * people as they were (093 stores their names on the batch).
 */
export default function TeamsPanel({ staff, branchId, inBranch }) {
  const { organization, canAt } = useAuth();
  const canEdit = !!branchId && (canAt('production.create', branchId, null) || canAt('products.manage', branchId, null));
  const [teams, setTeams] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [newName, setNewName] = useState('');
  const [editingId, setEditingId] = useState(null);
  const [showRetired, setShowRetired] = useState(false);
  const [lastDay, setLastDay] = useState({});   // team id → { date, ids }: who worked in it on its latest batch day

  async function load() {
    setError('');
    const { data, error: err } = await supabase.from('production_teams')
      .select('id, name, status, branch_id, members:production_team_members(id, name, status, staff_id)').order('name');
    if (err) { console.error(err); setError("We couldn't load the teams."); setTeams([]); return; }
    setTeams(data || []);
    const b = await supabase.from('production_batches').select('*').neq('status', 'void').not('team_id', 'is', null)
      .order('batch_date', { ascending: false }).limit(500);
    const by = {};
    for (const x of b.data || []) {
      const cur = by[x.team_id];
      // the names as recorded on the batch (093), else today's names
      const names = x.worker_names ?? (x.worker_ids || []).map(id => staff.find(p => p.id === id)?.full_name).filter(Boolean);
      if (!cur) by[x.team_id] = { date: x.batch_date, ids: new Set(names) };
      else if (cur.date === x.batch_date) names.forEach(n => cur.ids.add(n));
    }
    setLastDay(by);
  }
  useEffect(() => { load(); }, [staff.length]); // eslint-disable-line react-hooks/exhaustive-deps -- names need the staff list
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
  const prodStaff = working.filter(s => s.in_production_cost);
  const nameOf = m => staff.find(s => s.id === m.staff_id)?.full_name ?? m.name;
  const editing = (teams || []).find(t => t.id === editingId);

  async function addTeam() {
    if (!newName.trim()) return;
    if (await run(supabase.from('production_teams').insert({ organization_id: organization?.id, branch_id: branchId, name: newName.trim() }))) setNewName('');
  }

  return (
    <>
      {teams !== null && (
        <div className="mm-stats">
          <div className="mm-stat"><span className="pl-label">Teams</span><strong>{here.filter(t => t.status === 'active').length}</strong><span className="pl-help">{branchId ? 'at the branch' : 'every branch'}</span></div>
          <div className="mm-stat"><span className="pl-label">Production staff</span><strong>{prodStaff.length}</strong><span className="pl-help">ticked on batches</span></div>
          <div className="mm-stat"><span className="pl-label">Not in production</span><strong>{working.length - prodStaff.length}</strong><span className="pl-help" title="Driver, secretary… — 'pay part of product cost' unticked in their staff details">not listed on batches</span></div>
        </div>
      )}
      <div className="flex items-center gap-8" style={{ margin: '12px 0', flexWrap: 'wrap' }}>
        {canEdit && <>
          <input className="form-input" style={{ maxWidth: 240 }} placeholder="New team, e.g. Juma team" value={newName} onChange={e => setNewName(e.target.value)}
            onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); addTeam(); } }} />
          <button type="button" className="btn btn-primary btn-sm" disabled={busy || !newName.trim()} onClick={addTeam}><Plus size={14} /> New team</button>
        </>}
        <label className="text-sm flex items-center gap-8" style={{ marginLeft: 'auto' }}><input type="checkbox" checked={showRetired} onChange={e => setShowRetired(e.target.checked)} /> Show removed teams</label>
        <span className="pl-help" title="Choosing a team on a batch ticks its active members; untick anyone who didn't work on that batch — they stay in the team. A removed team stays on past batches.">A team's active members are ticked on its batches.</span>
      </div>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      {!branchId && <div className="alert alert-warning">Choose a branch to add teams.</div>}
      <section className="sk">
        {teams === null ? Array.from({ length: 3 }).map((_, i) => <div key={i} className="sk-card"><span className="skeleton" /></div>)
        : here.length === 0 ? <div className="card"><EmptyState icon={Users} title="No teams yet" description="Create a team, then add its members under Edit." /></div>
        : here.map(t => {
          const members = t.members.filter(m => m.staff_id && m.status !== 'removed').sort((a, b) => (a.status === b.status ? nameOf(a).localeCompare(nameOf(b)) : a.status === 'active' ? -1 : 1));
          const ld = lastDay[t.id];
          const worked = ld ? [...ld.ids].sort() : [];
          const day = ld ? dateText(ld.date) : null;
          return (
            <div key={t.id} className={`card tm-card${t.status !== 'active' ? ' is-inactive' : ''}`}>
              <div className="tm-head">
                <strong>{t.name}</strong>
                {t.status !== 'active' && <span className="pl-help">removed</span>}
                <span className="tm-worked">
                  {/* how many are in the team; deactivated ones counted apart */}
                  <span className="pl-help">Members ({members.filter(m => m.status === 'active').length}{members.some(m => m.status !== 'active') ? ` + ${members.filter(m => m.status !== 'active').length} off` : ''}):</span>
                  {members.length ? members.map(m => <span key={m.id} className={`ptc-chip${m.status !== 'active' ? ' is-off' : ''}`} title={m.status !== 'active' ? 'Deactivated' : undefined}>{nameOf(m)}</span>)
                    : <span className="pl-help">none yet</span>}
                </span>
                {canEdit && (
                  <span className="tm-actions">
                    {t.status === 'active' && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditingId(t.id)}>Edit</button>}
                    <button type="button" className="btn btn-ghost btn-sm" disabled={busy}
                      onClick={() => run(supabase.from('production_teams').update({ status: t.status === 'active' ? 'inactive' : 'active' }).eq('id', t.id))}>
                      {t.status === 'active' ? 'Remove team' : 'Bring back'}</button>
                  </span>
                )}
              </div>
              <div className="tm-last pl-help" title="Who was ticked on this team's batches that day">
                {ld ? <>Worked {day}: {worked.length ? worked.join(', ') : 'nobody ticked'}</> : 'No batches yet'}
              </div>
            </div>
          );
        })}
      </section>
      {editing && <TeamEdit team={editing} staff={prodStaff.filter(s => s.branch_id === editing.branch_id)} allStaff={staff} organizationId={organization?.id}
        teams={teams} onClose={() => setEditingId(null)} onChanged={load} />}
    </>
  );
}

/*
 * A team's Edit: its name, and its members as a tick list of the branch's
 * production staff — tick to add, untick to take out (status 'removed', kept
 * for the record); a member can be deactivated (still in the team, off for
 * now). Members first, then the rest. Changes save as they're made.
 */
function TeamEdit({ team, staff, allStaff, organizationId, teams, onClose, onChanged }) {
  const [name, setName] = useState(team.name);
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');
  const [search, setSearch] = useState('');
  const memberOf = id => team.members.find(m => m.staff_id === id);
  const inTeam = id => { const m = memberOf(id); return m && m.status !== 'removed'; };
  const otherTeam = id => teams.filter(t => t.id !== team.id && t.status === 'active' && t.members.some(m => m.staff_id === id && m.status === 'active')).map(t => t.name)[0];
  // members who aren't production staff any more still show, so they can be taken out
  const extra = team.members.filter(m => m.staff_id && m.status !== 'removed' && !staff.some(s => s.id === m.staff_id))
    .map(m => allStaff.find(s => s.id === m.staff_id) || { id: m.staff_id, full_name: m.name });
  const people = [...staff, ...extra]
    .filter(p => !search.trim() || p.full_name.toLowerCase().includes(search.trim().toLowerCase()))
    .sort((a, b) => (inTeam(b.id) ? 1 : 0) - (inTeam(a.id) ? 1 : 0) || a.full_name.localeCompare(b.full_name));
  const count = team.members.filter(m => m.staff_id && m.status !== 'removed').length;

  async function run(key, q) {
    setError(''); setBusy(key);
    const { error: err } = await q;
    setBusy('');
    if (err) { setError(err.code === '23505' ? 'That name is already used.' : dbErrorMessage(err)); return false; }
    await onChanged();
    return true;
  }
  function toggle(p) {
    const m = memberOf(p.id);
    if (inTeam(p.id)) return run(p.id, supabase.from('production_team_members').update({ status: 'removed' }).eq('id', m.id));
    return run(p.id, m ? supabase.from('production_team_members').update({ status: 'active' }).eq('id', m.id)
      : supabase.from('production_team_members').insert({ organization_id: organizationId, team_id: team.id, name: p.full_name, staff_id: p.id }));
  }

  return (
    <Modal title={`Edit ${team.name}`} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}<button type="button" className="btn btn-outline" onClick={onClose}>Done</button></>}>
      <div className="modal-form">
        <div className="form-row">
          <label className="pe-field" style={{ flex: 1 }}><span>Team name</span><input className="form-input" value={name} onChange={e => setName(e.target.value)} /></label>
          <button type="button" className="btn btn-primary btn-sm" style={{ alignSelf: 'flex-end' }} disabled={!!busy || !name.trim() || name.trim() === team.name}
            onClick={() => run('name', supabase.from('production_teams').update({ name: name.trim() }).eq('id', team.id))}>Save name</button>
        </div>
        <div className="flex items-center gap-8">
          <span className="pl-label">Members ({count})</span>
          <input className="form-input" style={{ marginLeft: 'auto', maxWidth: 220 }} placeholder="Search name…" value={search} onChange={e => setSearch(e.target.value)} />
        </div>
        <div className="tm-ticks">
          {people.length === 0 && <span className="pl-help">No production staff at this branch{search ? ' by that name' : ''}.</span>}
          {people.map(p => {
            const m = memberOf(p.id); const on = inTeam(p.id); const off = on && m.status === 'inactive';
            return (
              <div key={p.id} className={`tm-tick${on ? ' is-on' : ''}${off ? ' is-off' : ''}`}>
                <label>
                  <input type="checkbox" checked={!!on} disabled={busy === p.id} onChange={() => toggle(p)} />
                  <span>{p.full_name}</span>
                  {!on && otherTeam(p.id) && <span className="pl-help">in {otherTeam(p.id)}</span>}
                  {off && <span className="pl-help">deactivated</span>}
                </label>
                {on && (
                  <button type="button" className="btn btn-ghost btn-sm" disabled={busy === p.id}
                    onClick={() => run(p.id, supabase.from('production_team_members').update({ status: off ? 'active' : 'inactive' }).eq('id', m.id))}>
                    {off ? 'Activate' : 'Deactivate'}</button>
                )}
              </div>
            );
          })}
        </div>
        <p className="pl-help">Tick to add, untick to take out. Choosing this team on a batch ticks its active members — untick anyone not on that batch (they stay in the team). Recorded batches never change.</p>
      </div>
    </Modal>
  );
}
