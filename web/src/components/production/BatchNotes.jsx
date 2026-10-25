import { useEffect, useMemo, useState } from 'react';
import { Users, Cog, X } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { dbErrorMessage } from '../../lib/masterData';

/**
 * Production tracking for one batch (migration 056), in the batch's note zone
 * (SwahziTech, 2026-10-25): who made it, on what, and the note ("thrown
 * away" was removed the same day). Team and machine are required but start filled — the
 * last team used at the branch, the machine that makes the product — so a
 * normal batch needs no taps. A team is created once and picked after; who
 * worked is recorded only when it differs from the team.
 *
 * value: { teamId, workerIds (null = whole team), machineId, notes }
 */
export function useProductionLists(branchId) {
  const [lists, setLists] = useState(null);   // null = loading; { ready: false } before 056
  async function load() {
    if (!branchId) return;
    const [t, m, mp] = await Promise.all([
      supabase.from('production_teams').select('id, name, status, members:production_team_members(id, name, status)').eq('branch_id', branchId).order('name'),
      supabase.from('machines').select('*').eq('branch_id', branchId).order('name'),
      supabase.from('machine_products').select('machine_id, product_id'),
    ]);
    if (t.error || m.error) { setLists({ ready: false, teams: [], machines: [], links: [], norms: {} }); return; }
    // labour norms (057): bags a person per product at this branch — the screens work without them
    const n = await supabase.from('branch_products').select('product_id, bags_per_person_min, bags_per_person_max').eq('branch_id', branchId);
    const norms = Object.fromEntries((n.error ? [] : n.data || []).filter(x => x.bags_per_person_min != null || x.bags_per_person_max != null)
      .map(x => [x.product_id, { min: Number(x.bags_per_person_min ?? x.bags_per_person_max), max: Number(x.bags_per_person_max ?? x.bags_per_person_min) }]));
    setLists({ ready: true, teams: t.data || [], machines: m.data || [], links: mp.data || [], norms });
  }
  useEffect(() => { load(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps
  return [lists, load];
}

const lastKey = (kind, branchId, extra = '') => `mois.batchnotes.${kind}.${branchId}${extra ? `.${extra}` : ''}`;
const remember = (k, v) => { try { localStorage.setItem(k, v); } catch { /* private window */ } };
const recall = k => { try { return localStorage.getItem(k); } catch { return null; } };

/** The people on a batch: who worked when that was changed, else the team's members (ids) */
export function peopleOf(teams, teamId, workerIds) {
  if (workerIds) return workerIds;
  const t = (teams || []).find(x => x.id === teamId);
  return t ? t.members.filter(m => m.status !== 'inactive').map(m => m.id) : [];
}

/**
 * People a day's batches should take by the labour norms (057): a machine
 * with a crew counts its crew once a day, whatever the bags; any other batch
 * needs its bags ÷ the product's bags a person. → { min, max, missing } —
 * missing: batches without a norm (left out).
 * batches: [{ machineId, productId, bags }]
 */
export function labourNorm(lists, batches) {
  let min = 0, max = 0, missing = 0;
  const crews = new Set();
  for (const b of batches) {
    const m = lists?.machines?.find(x => x.id === b.machineId);
    if (m && (m.crew_min || m.crew_max)) {
      if (!crews.has(m.id)) { crews.add(m.id); min += m.crew_min ?? m.crew_max; max += m.crew_max ?? m.crew_min; }
      continue;
    }
    const n = lists?.norms?.[b.productId];
    if (!n) { missing += 1; continue; }
    min += b.bags / n.max; max += b.bags / n.min;
  }
  return { min: Math.ceil(min - 1e-9), max: Math.ceil(max - 1e-9), missing };
}

/** The team's name, and who worked when that was changed: "Juma team (2 of 3)" */
export function teamLabel(lists, teamId, workerIds) {
  const t = lists?.teams?.find(x => x.id === teamId);
  if (!t) return null;
  const active = t.members.filter(m => m.status === 'active');
  return workerIds ? `${t.name} (${workerIds.length} of ${active.length})` : t.name;
}

export default function BatchNotes({ branchId, organizationId, productId, lists, reload, value, onChange }) {
  const set = patch => onChange({ ...value, ...patch });
  const teams = (lists?.teams || []).filter(t => t.status === 'active');
  const team = teams.find(t => t.id === value.teamId);
  const allMachines = (lists?.machines || []).filter(m => m.status === 'active');
  // machines that make this product; all the branch's machines until one is linked
  const linked = allMachines.filter(m => lists.links.some(l => l.machine_id === m.id && l.product_id === productId));
  const machines = linked.length ? linked : allMachines;
  const [editing, setEditing] = useState(null);   // 'workers' | 'newTeam' | 'newMachine'
  const [text, setText] = useState('');
  const [members, setMembers] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  // Start filled: the last team used here (or the only one); the machine last used for this product (or the only one)
  useEffect(() => {
    if (!lists?.ready || value.teamId) return;
    const last = recall(lastKey('team', branchId));
    const pick = teams.find(t => t.id === last) ?? (teams.length === 1 ? teams[0] : null);
    if (pick) set({ teamId: pick.id, workerIds: null });
  }, [lists, branchId, value.teamId]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!lists?.ready || !productId) return;
    if (value.machineId && machines.some(m => m.id === value.machineId)) return;
    const last = recall(lastKey('machine', branchId, productId));
    const pick = machines.find(m => m.id === last) ?? (machines.length === 1 ? machines[0] : null);
    set({ machineId: pick?.id ?? '' });
  }, [lists, branchId, productId]); // eslint-disable-line react-hooks/exhaustive-deps

  async function run(fn) {
    setError(''); setBusy(true);
    try { await fn(); } catch (e) { setError(e.code === '23505' ? 'That name is already on the list.' : dbErrorMessage(e)); }
    setBusy(false);
  }
  const must = ({ data, error: err }) => { if (err) throw err; return data; };

  function pickTeam(id) {
    if (id === '+') { setEditing('newTeam'); setText(''); setMembers(''); return; }
    remember(lastKey('team', branchId), id);
    set({ teamId: id, workerIds: null });
  }
  async function pickMachine(id) {
    if (id === '+') { setEditing('newMachine'); setText(''); return; }
    set({ machineId: id });
    if (!id || !productId) return;
    remember(lastKey('machine', branchId, productId), id);
    // learn which machines make the product: picking one links it
    if (!lists.links.some(l => l.machine_id === id && l.product_id === productId)) {
      await supabase.from('machine_products').insert({ machine_id: id, product_id: productId, organization_id: organizationId });
      reload();
    }
  }
  const createTeam = () => run(async () => {
    const t = must(await supabase.from('production_teams').insert({ organization_id: organizationId, branch_id: branchId, name: text.trim() }).select('id').single());
    const names = members.split(',').map(s => s.trim()).filter(Boolean);
    if (names.length) must(await supabase.from('production_team_members').insert(names.map(name => ({ organization_id: organizationId, team_id: t.id, name }))));
    await reload();
    remember(lastKey('team', branchId), t.id);
    set({ teamId: t.id, workerIds: null });
    setEditing(null);
  });
  const createMachine = () => run(async () => {
    const m = must(await supabase.from('machines').insert({ organization_id: organizationId, branch_id: branchId, name: text.trim() }).select('id').single());
    if (productId) await supabase.from('machine_products').insert({ machine_id: m.id, product_id: productId, organization_id: organizationId });
    await reload();
    remember(lastKey('machine', branchId, productId), m.id);
    set({ machineId: m.id });
    setEditing(null);
  });
  const addMember = () => run(async () => {
    must(await supabase.from('production_team_members').insert({ organization_id: organizationId, team_id: team.id, name: text.trim() }));
    setText('');
    await reload();
  });
  const leaveTeam = id => run(async () => {   // left for good: kept on past batches
    must(await supabase.from('production_team_members').update({ status: 'inactive' }).eq('id', id));
    if (value.workerIds) set({ workerIds: value.workerIds.filter(x => x !== id) });
    await reload();
  });

  // who worked: the team's members (ticked = worked) and helpers from the branch's other teams
  const activeMembers = team ? team.members.filter(m => m.status === 'active') : [];
  const helpers = useMemo(() => teams.filter(t => t.id !== value.teamId).flatMap(t => t.members.filter(m => m.status === 'active').map(m => ({ ...m, team: t.name }))), [teams, value.teamId]);
  const worked = value.workerIds ?? activeMembers.map(m => m.id);
  function toggleWorker(id) {
    const next = worked.includes(id) ? worked.filter(x => x !== id) : [...worked, id];
    const whole = next.length === activeMembers.length && activeMembers.every(m => next.includes(m.id));
    set({ workerIds: whole ? null : next });
  }

  if (!lists) return null;
  const noteInput = (
    <input className="form-input bn-note" placeholder="Note (optional)" aria-label="Batch note" value={value.notes} onChange={e => set({ notes: e.target.value })} />
  );
  if (!lists.ready) return <div className="bn">{noteInput}</div>;   // before 056: the note only

  return (
    <div className="bn">
      <div className="bn-strip">
        <span className={`bn-chip${value.teamId ? '' : ' is-missing'}`}>
          <Users size={14} className="bn-ico" aria-hidden="true" />
          <select className="bn-chip-sel" aria-label="Team" value={value.teamId} onChange={e => pickTeam(e.target.value)}>
            {!value.teamId && <option value="">{teams.length ? 'Team…' : 'No team yet'}</option>}
            {teams.map(t => <option key={t.id} value={t.id}>{t.id === value.teamId ? teamLabel(lists, t.id, value.workerIds) : t.name}</option>)}
            <option value="+">+ New team…</option>
          </select>
          {team && <button type="button" className="bn-edit" onClick={() => setEditing(editing === 'workers' ? null : 'workers')}>{editing === 'workers' ? 'done' : 'who worked'}</button>}
        </span>
        <span className={`bn-chip${value.machineId ? '' : ' is-missing'}`}>
          <Cog size={14} className="bn-ico" aria-hidden="true" />
          <select className="bn-chip-sel" aria-label="Machine" value={value.machineId} onChange={e => pickMachine(e.target.value)}>
            {!value.machineId && <option value="">{allMachines.length ? 'Machine…' : 'No machine yet'}</option>}
            {machines.map(m => <option key={m.id} value={m.id}>{m.name}</option>)}
            {linked.length > 0 && allMachines.filter(m => !linked.includes(m)).map(m => <option key={m.id} value={m.id}>{m.name} (other)</option>)}
            <option value="+">+ New machine…</option>
          </select>
        </span>
        {noteInput}
      </div>

      {editing === 'newTeam' && (
        <div className="bn-panel">
          <input className="form-input bn-sel" autoFocus placeholder="Team name, e.g. Juma team" value={text} onChange={e => setText(e.target.value)} />
          <input className="form-input" style={{ flex: 2 }} placeholder="Members, separated by commas (optional)" value={members} onChange={e => setMembers(e.target.value)} />
          <button type="button" className="btn btn-primary btn-sm" disabled={busy || !text.trim()} onClick={createTeam}>Create team</button>
          <button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditing(null)}>Cancel</button>
        </div>
      )}
      {editing === 'newMachine' && (
        <div className="bn-panel">
          <input className="form-input bn-sel" autoFocus placeholder="Machine or line, e.g. Press 1" value={text} onChange={e => setText(e.target.value)} />
          <button type="button" className="btn btn-primary btn-sm" disabled={busy || !text.trim()} onClick={createMachine}>Add machine</button>
          <button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditing(null)}>Cancel</button>
        </div>
      )}
      {editing === 'workers' && team && (
        <div className="bn-panel bn-workers">
          <span className="pl-help">Untick anyone away for this batch; tick a helper. The team stays as it is.</span>
          <div className="bn-people">
            {activeMembers.map(m => (
              <label key={m.id} className="bn-person"><input type="checkbox" checked={worked.includes(m.id)} onChange={() => toggleWorker(m.id)} /> {m.name}
                <button type="button" className="bn-x" title="Left the team for good" aria-label={`${m.name} left the team`} onClick={() => leaveTeam(m.id)}><X size={11} /></button></label>
            ))}
            {helpers.map(m => (
              <label key={m.id} className="bn-person is-helper"><input type="checkbox" checked={worked.includes(m.id)} onChange={() => toggleWorker(m.id)} /> {m.name} <span className="pl-help">({m.team})</span></label>
            ))}
          </div>
          <div className="flex items-center gap-8">
            <input className="form-input bn-sel" placeholder={`New member of ${team.name}`} value={text} onChange={e => setText(e.target.value)} />
            <button type="button" className="btn btn-outline btn-sm" disabled={busy || !text.trim()} onClick={addMember}>Add to team</button>
          </div>
        </div>
      )}
      {error && <p className="text-xs text-error">{error}</p>}
    </div>
  );
}
