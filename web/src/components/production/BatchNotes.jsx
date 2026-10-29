import { useEffect, useMemo, useState } from 'react';
import { Users, Cog, UserCheck } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { dbErrorMessage } from '../../lib/masterData';

/**
 * Production tracking for one batch (migration 056), in the batch's note zone
 * (SwahziTech, 2026-10-25): who made it, on what, and the note ("thrown
 * away" was removed the same day). Team and machine are required but start filled — the
 * last team used at the branch, the machine that makes the product — so a
 * normal batch needs no taps.
 *
 * Who worked (087, 2026-10-28): teams change week to week, even day to day,
 * so a team is a name only and the people are ticked on each batch from the
 * branch's production staff — those marked at work that day first. LOCKED
 * (2026-10-30, the user): choosing a team ticks its active members (HR ›
 * Staff › Teams › Edit, 093); the user unticks anyone who didn't work on the
 * batch — that's for the batch only, they stay active in the team (they may
 * be on another task for hours or the day). Members are listed first.
 * Staff not in production (driver, secretary — "pay part of product cost"
 * unticked, 092) aren't listed. A new labourer added here becomes a casual in
 * HR › Staff (pay set there).
 *
 * value: { teamId, workerIds (staff ids), machineId, notes }
 */
export function useProductionLists(branchId) {
  const [lists, setLists] = useState(null);   // null = loading; { ready: false } before 056
  async function load() {
    if (!branchId) return;
    const [t, m, mp, pp] = await Promise.all([
      supabase.from('production_teams').select('id, name, status, members:production_team_members(staff_id, status)').eq('branch_id', branchId).order('name'),
      supabase.from('machines').select('*').eq('branch_id', branchId).order('name'),
      supabase.from('machine_products').select('machine_id, product_id'),
      supabase.from('production_people').select('*').eq('branch_id', branchId).order('full_name'),
    ]);
    if (t.error || m.error) { setLists({ ready: false, teams: [], machines: [], links: [], people: [], norms: {} }); return; }
    // labour norms (057): bags a person per product at this branch — the screens work without them
    const n = await supabase.from('branch_products').select('product_id, bags_per_person_min, bags_per_person_max').eq('branch_id', branchId);
    const norms = Object.fromEntries((n.error ? [] : n.data || []).filter(x => x.bags_per_person_min != null || x.bags_per_person_max != null)
      .map(x => [x.product_id, { min: Number(x.bags_per_person_min ?? x.bags_per_person_max), max: Number(x.bags_per_person_max ?? x.bags_per_person_min) }]));
    setLists({ ready: true, teams: t.data || [], machines: m.data || [], links: mp.data || [], people: pp.error ? [] : pp.data || [], norms });
  }
  useEffect(() => { load(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps
  return [lists, load];
}

const lastKey = (kind, branchId, extra = '') => `mois.batchnotes.${kind}.${branchId}${extra ? `.${extra}` : ''}`;
const remember = (k, v) => { try { localStorage.setItem(k, v); } catch { /* private window */ } };
const recall = k => { try { return localStorage.getItem(k); } catch { return null; } };

/** The people on a batch (staff ids, 087) */
export function peopleOf(teams, teamId, workerIds) {
  return workerIds || [];
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

/** The team's name and how many worked: "Juma team (5 people)" */
export function teamLabel(lists, teamId, workerIds) {
  const t = lists?.teams?.find(x => x.id === teamId);
  if (!t) return null;
  return workerIds?.length ? `${t.name} (${workerIds.length} ${workerIds.length === 1 ? 'person' : 'people'})` : t.name;
}

export default function BatchNotes({ branchId, organizationId, productId, date, lists, reload, value, onChange }) {
  const set = patch => onChange({ ...value, ...patch });
  const teams = (lists?.teams || []).filter(t => t.status === 'active');
  const allMachines = (lists?.machines || []).filter(m => m.status === 'active');
  // machines that make this product; all the branch's machines until one is linked
  const linked = allMachines.filter(m => lists.links.some(l => l.machine_id === m.id && l.product_id === productId));
  const machines = linked.length ? linked : allMachines;
  const [editing, setEditing] = useState(null);   // 'workers' | 'newTeam' | 'newMachine'
  const [text, setText] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [present, setPresent] = useState({});     // staff id → day fraction marked at work on the batch's date

  // production staff only (092: in_production_cost; before 092 the flag is absent and everyone shows)
  const active = useMemo(() => (lists?.people || []).filter(p => p.status === 'active' && p.in_production_cost !== false), [lists]);
  // a team's active members (production staff still working) — ticked when the team is chosen
  const membersOf = teamId => ((lists?.teams || []).find(t => t.id === teamId)?.members || [])
    .filter(m => m.status === 'active' && m.staff_id && active.some(p => p.id === m.staff_id)).map(m => m.staff_id);

  // Start filled: the last team used here (or the only one); the machine last used for this product (or the only one)
  useEffect(() => {
    if (!lists?.ready || value.teamId) return;
    const last = recall(lastKey('team', branchId));
    const pick = teams.find(t => t.id === last) ?? (teams.length === 1 ? teams[0] : null);
    if (pick) set({ teamId: pick.id, workerIds: value.workerIds?.length ? value.workerIds : membersOf(pick.id) });
  }, [lists, branchId, value.teamId]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!lists?.ready || !productId) return;
    if (value.machineId && machines.some(m => m.id === value.machineId)) return;
    const last = recall(lastKey('machine', branchId, productId));
    const pick = machines.find(m => m.id === last) ?? (machines.length === 1 ? machines[0] : null);
    set({ machineId: pick?.id ?? '' });
  }, [lists, branchId, productId]); // eslint-disable-line react-hooks/exhaustive-deps
  // who is marked at work that day (HR › Staff › Attendance) is listed first
  useEffect(() => {
    if (!lists?.ready || !date) return;
    supabase.from('production_presence').select('staff_id, day_fraction').eq('branch_id', branchId).eq('work_date', date)
      .then(({ data }) => setPresent(Object.fromEntries((data || []).map(a => [a.staff_id, Number(a.day_fraction)]))));
  }, [lists, branchId, date]);

  async function run(fn) {
    setError(''); setBusy(true);
    try { await fn(); } catch (e) { setError(e.code === '23505' ? 'That name is already on the list.' : dbErrorMessage(e)); }
    setBusy(false);
  }
  const must = ({ data, error: err }) => { if (err) throw err; return data; };

  function pickTeam(id) {
    if (id === '+') { setEditing('newTeam'); setText(''); return; }
    remember(lastKey('team', branchId), id);
    // its active members ticked; untick anyone not on this batch (they stay in the team)
    set({ teamId: id, workerIds: membersOf(id) });
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
    await reload();
    remember(lastKey('team', branchId), t.id);
    set({ teamId: t.id, workerIds: value.workerIds || [] });
    setEditing('workers'); setText('');
  });
  const createMachine = () => run(async () => {
    const m = must(await supabase.from('machines').insert({ organization_id: organizationId, branch_id: branchId, name: text.trim() }).select('id').single());
    if (productId) await supabase.from('machine_products').insert({ machine_id: m.id, product_id: productId, organization_id: organizationId });
    await reload();
    remember(lastKey('machine', branchId, productId), m.id);
    set({ machineId: m.id });
    setEditing(null);
  });
  // a labourer not on the staff list yet: added as a casual (pay is set in HR › Staff)
  const addPerson = () => run(async () => {
    const id = must(await supabase.rpc('add_production_person', { p_branch: branchId, p_name: text.trim() }));
    setText('');
    await reload();
    if (!(value.workerIds || []).includes(id)) set({ workerIds: [...(value.workerIds || []), id] });
  });

  const worked = value.workerIds || [];
  const toggleWorker = id => set({ workerIds: worked.includes(id) ? worked.filter(x => x !== id) : [...worked, id] });
  // the team's active members first (not ticked), then those at work that day, then the rest; ticked people who have since left still show
  const inTeam = useMemo(() => new Set(((lists?.teams || []).find(t => t.id === value.teamId)?.members || [])
    .filter(m => m.status === 'active' && m.staff_id).map(m => m.staff_id)), [lists, value.teamId]);
  const listed = useMemo(() => {
    const extra = (lists?.people || []).filter(p => p.status !== 'active' && worked.includes(p.id));
    return [...active, ...extra].sort((a, b) => (inTeam.has(b.id) ? 1 : 0) - (inTeam.has(a.id) ? 1 : 0)
      || (present[b.id] ? 1 : 0) - (present[a.id] ? 1 : 0) || a.full_name.localeCompare(b.full_name));
  }, [active, lists, worked, present, inTeam]);
  const atWork = listed.filter(p => present[p.id]);

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
            {teams.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
            <option value="+">+ New team…</option>
          </select>
        </span>
        <span className={`bn-chip${worked.length ? '' : ' is-missing'}`}>
          <UserCheck size={14} className="bn-ico" aria-hidden="true" />
          <button type="button" className="bn-edit" onClick={() => setEditing(editing === 'workers' ? null : 'workers')}>
            {editing === 'workers' ? 'done' : worked.length ? `${worked.length} ${worked.length === 1 ? 'person' : 'people'} worked` : 'who worked…'}</button>
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
      {editing === 'workers' && (
        <div className="bn-panel bn-workers">
          <span className="pl-help">
            Tick who worked on this batch.{atWork.length ? ` ${atWork.length} marked at work on ${date} are listed first.` : ''}
            {worked.length > 0 && <> <button type="button" className="link-btn" onClick={() => set({ workerIds: [] })}>Untick all</button></>}
            {atWork.length > 0 && <> · <button type="button" className="link-btn" onClick={() => set({ workerIds: [...new Set([...worked, ...atWork.map(p => p.id)])] })}>Tick everyone at work</button></>}
          </span>
          <div className="bn-people">
            {listed.length === 0 && <span className="pl-help">No staff at this branch yet — add a name below.</span>}
            {listed.map(p => (
              <label key={p.id} className={`bn-person${present[p.id] || inTeam.has(p.id) ? '' : ' is-helper'}${inTeam.has(p.id) ? ' is-member' : ''}`} title={inTeam.has(p.id) ? 'In this team' : undefined}>
                <input type="checkbox" checked={worked.includes(p.id)} onChange={() => toggleWorker(p.id)} /> {p.full_name}
                {present[p.id] === 0.5 && <span className="pl-help">(½ day)</span>}
                {p.status !== 'active' && <span className="pl-help">(left)</span>}
              </label>
            ))}
          </div>
          <div className="flex items-center gap-8">
            <input className="form-input bn-sel" placeholder="Someone new, e.g. a casual labourer" value={text} onChange={e => setText(e.target.value)}
              onKeyDown={e => { if (e.key === 'Enter' && text.trim()) { e.preventDefault(); addPerson(); } }} />
            <button type="button" className="btn btn-outline btn-sm" disabled={busy || !text.trim()} onClick={addPerson}>Add</button>
            <span className="pl-help">Added as a casual in HR › Staff, where their pay is set.</span>
          </div>
        </div>
      )}
      {error && <p className="text-xs text-error">{error}</p>}
    </div>
  );
}
