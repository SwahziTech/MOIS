import { useEffect, useMemo, useState } from 'react';
import { Plus, Users } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import EmptyState from '../EmptyState';

/*
 * Teams (HR › Staff, 2026-10-30): a branch's production teams — new, rename,
 * remove. LOCKED (same day): a team has no fixed members — A may be b, j, g
 * today and d, f, e tomorrow — so the people are ticked on each batch.
 * Production staff are those whose pay is part of product cost; others
 * (driver, secretary) aren't listed in production. Removing keeps the team
 * on past batches (retired, not deleted). Each team shows who worked in it on
 * its latest batch day — read from the batches, never a fixed list.
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
  const [lastDay, setLastDay] = useState({});   // team id → { date, ids }: who worked in it on its latest batch day

  async function load() {
    setError('');
    const { data, error: err } = await supabase.from('production_teams')
      .select('id, name, status, branch_id').order('name');
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
        <span className="pl-help" title="Teams change day to day, so the people are ticked on each batch from the production staff. A removed team stays on past batches.">Who worked is ticked on each batch.</span>
      </div>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      {!branchId && <div className="alert alert-warning">Choose a branch to add teams.</div>}
      <section className="sk">
        {teams === null ? Array.from({ length: 3 }).map((_, i) => <div key={i} className="sk-card"><span className="skeleton" /></div>)
        : here.length === 0 ? <div className="card"><EmptyState icon={Users} title="No teams yet" description="Create a team; its people are ticked on each batch." /></div>
        : here.map(t => {
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
                    {t.status !== 'active' && <span className="pl-help">removed</span>}
                    {(() => {
                      const ld = lastDay[t.id];
                      if (!ld) return <span className="pl-help">no batches yet</span>;
                      const names = [...ld.ids].map(id => staff.find(x => x.id === id)?.full_name).filter(Boolean).sort();
                      const day = new Date(`${ld.date}T00:00:00Z`).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', timeZone: 'UTC' });
                      return (
                        <span className="tm-worked" title="Who was ticked on this team's batches that day — it changes day to day">
                          <span className="pl-help">Worked {day}:</span>
                          {names.length ? names.map(n => <span key={n} className="ptc-chip">{n}</span>) : <span className="pl-help">nobody ticked</span>}
                        </span>
                      );
                    })()}
                    {canEdit && (
                      <span className="tm-actions">
                        {t.status === 'active' && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setRenaming({ id: t.id, name: t.name })}>Edit</button>}
                        <button type="button" className="btn btn-ghost btn-sm" disabled={busy}
                          onClick={() => run(supabase.from('production_teams').update({ status: t.status === 'active' ? 'inactive' : 'active' }).eq('id', t.id))}>
                          {t.status === 'active' ? 'Remove team' : 'Bring back'}</button>
                      </span>
                    )}
                  </>
                )}
              </div>
            </div>
          );
        })}
      </section>
    </>
  );
}
