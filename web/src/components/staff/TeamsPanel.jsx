import { useEffect, useMemo, useState } from 'react';
import { Plus, Users, X } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import EmptyState from '../EmptyState';
import Modal from '../Modal';

/*
 * Teams (HR › Staff, 2026-10-30): a branch's production teams. Edit renames a
 * team and keeps its members — add, deactivate (still in the team, off for
 * now), remove (taken out — status 'removed', kept for the record, 093). Members are a list to pick from: a batch
 * lists the team's active members first but ticks nobody — who worked is
 * chosen on each batch, as crews change day to day. Only production staff
 * (pay part of product cost) can be members; driver, secretary… aren't
 * listed. Each team also shows who worked in it on its latest batch day.
 * Removing a team keeps it on past batches (retired, not deleted).
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
    const b = await supabase.from('production_batches').select('team_id, batch_date, worker_ids').neq('status', 'void').not('team_id', 'is', null)
      .order('batch_date', { ascending: false }).limit(500);
    const by = {};
    for (const x of b.data || []) {
      const cur = by[x.team_id];
      if (!cur) by[x.team_id] = { date: x.batch_date, ids: new Set(x.worker_ids || []) };
      else if (cur.date === x.batch_date) (x.worker_ids || []).forEach(id => cur.ids.add(id));
    }
    setLastDay(by);
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
        <span className="pl-help" title="A batch lists the team's active members first but ticks nobody — who worked is chosen on each batch. A removed team stays on past batches.">Who worked is ticked on each batch.</span>
      </div>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      {!branchId && <div className="alert alert-warning">Choose a branch to add teams.</div>}
      <section className="sk">
        {teams === null ? Array.from({ length: 3 }).map((_, i) => <div key={i} className="sk-card"><span className="skeleton" /></div>)
        : here.length === 0 ? <div className="card"><EmptyState icon={Users} title="No teams yet" description="Create a team, then add its members under Edit." /></div>
        : here.map(t => {
          const members = t.members.filter(m => m.staff_id && m.status !== 'removed').sort((a, b) => (a.status === b.status ? nameOf(a).localeCompare(nameOf(b)) : a.status === 'active' ? -1 : 1));
          const ld = lastDay[t.id];
          const worked = ld ? [...ld.ids].map(id => staff.find(x => x.id === id)?.full_name).filter(Boolean).sort() : [];
          const day = ld ? new Date(`${ld.date}T00:00:00Z`).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', timeZone: 'UTC' }) : null;
          return (
            <div key={t.id} className={`card tm-card${t.status !== 'active' ? ' is-inactive' : ''}`}>
              <div className="tm-head">
                <strong>{t.name}</strong>
                {t.status !== 'active' && <span className="pl-help">removed</span>}
                <span className="tm-worked">
                  <span className="pl-help">Members:</span>
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

/* A team's Edit: its name; members added, deactivated (kept, off for now) or removed */
function TeamEdit({ team, staff, allStaff, organizationId, teams, onClose, onChanged }) {
  const [name, setName] = useState(team.name);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const nameOf = m => allStaff.find(s => s.id === m.staff_id)?.full_name ?? m.name;
  const members = team.members.filter(m => m.staff_id && m.status !== 'removed').sort((a, b) => nameOf(a).localeCompare(nameOf(b)));
  const otherTeam = id => teams.filter(t => t.id !== team.id && t.status === 'active' && t.members.some(m => m.staff_id === id && m.status === 'active')).map(t => t.name)[0];
  const addable = staff.filter(s => !members.some(m => m.staff_id === s.id)).sort((a, b) => a.full_name.localeCompare(b.full_name));

  async function run(q) {
    setError(''); setBusy(true);
    const { error: err } = await q;
    setBusy(false);
    if (err) { setError(err.code === '23505' ? 'That name is already used.' : dbErrorMessage(err)); return false; }
    await onChanged();
    return true;
  }
  const add = id => {
    const s = staff.find(x => x.id === id); if (!s) return;
    const old = team.members.find(m => m.staff_id === id);   // removed before: brought back
    run(old ? supabase.from('production_team_members').update({ status: 'active' }).eq('id', old.id)
      : supabase.from('production_team_members').insert({ organization_id: organizationId, team_id: team.id, name: s.full_name, staff_id: s.id }));
  };

  return (
    <Modal title={`Edit ${team.name}`} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}<button type="button" className="btn btn-outline" onClick={onClose}>Done</button></>}>
      <div className="modal-form">
        <div className="form-row">
          <label className="pe-field" style={{ flex: 1 }}><span>Team name</span><input className="form-input" value={name} onChange={e => setName(e.target.value)} /></label>
          <button type="button" className="btn btn-primary btn-sm" style={{ alignSelf: 'flex-end' }} disabled={busy || !name.trim() || name.trim() === team.name}
            onClick={() => run(supabase.from('production_teams').update({ name: name.trim() }).eq('id', team.id))}>Save name</button>
        </div>
        <div>
          <span className="pl-label">Members</span>
          <div className="table-container" style={{ marginTop: 6 }}>
            <table>
              <tbody>
                {members.length === 0 ? <tr><td className="text-muted">No members yet — add them below.</td></tr>
                : members.map(m => (
                  <tr key={m.id} className={m.status !== 'active' ? 'is-inactive' : ''}>
                    <td><strong>{nameOf(m)}</strong>{m.status !== 'active' && <span className="pl-help"> · deactivated</span>}</td>
                    <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                      <button type="button" className="btn btn-ghost btn-sm" disabled={busy}
                        onClick={() => run(supabase.from('production_team_members').update({ status: m.status === 'active' ? 'inactive' : 'active' }).eq('id', m.id))}>
                        {m.status === 'active' ? 'Deactivate' : 'Activate'}</button>
                      <button type="button" className="btn btn-ghost btn-sm" disabled={busy} title="Take out of the team" aria-label={`Remove ${nameOf(m)}`}
                        onClick={() => run(supabase.from('production_team_members').update({ status: 'removed' }).eq('id', m.id))}><X size={13} /> Remove</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
        <label className="pe-field"><span>Add a member (production staff)</span>
          <select className="form-input" value="" disabled={busy} onChange={e => e.target.value && add(e.target.value)}>
            <option value="">Choose…</option>
            {addable.map(s => <option key={s.id} value={s.id}>{s.full_name}{otherTeam(s.id) ? ` (in ${otherTeam(s.id)})` : ''}</option>)}
          </select></label>
        <p className="pl-help">A batch lists this team's active members first; nobody is ticked for you — tick who worked that day.</p>
      </div>
    </Modal>
  );
}
