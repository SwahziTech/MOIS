import { useEffect, useState } from 'react';
import { X, Plus } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { useBranch } from '../../hooks/useBranch';
import { dbErrorMessage } from '../../lib/masterData';

/**
 * Electricity meters of a branch (072): the LUKU meter number, the machines
 * each one feeds, and how its units split — all production, or a baseline of
 * units a day (the office and other period use) with what is above it
 * production (high-low). Kept with Expenses (⚙); tokens are Electricity expenses.
 */
export default function PowerMetersCard() {
  const { organization, canAt } = useAuth();
  const { branchId, branches } = useBranch();
  const [branch, setBranch] = useState(branchId || branches[0]?.id || '');
  const [data, setData] = useState(null);   // null = loading; { ready: false } before 072
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => { if (!branch && (branchId || branches[0]?.id)) setBranch(branchId || branches[0].id); }, [branchId, branches]); // eslint-disable-line react-hooks/exhaustive-deps
  const canEdit = branch && (canAt('procurement.receive', branch, null) || canAt('production.create', branch, null) || canAt('products.manage', branch, null));

  async function load() {
    if (!branch) return;
    const [m, mm, x] = await Promise.all([
      supabase.from('power_meters').select('*').eq('branch_id', branch).order('name'),
      supabase.from('power_meter_machines').select('meter_id, machine_id'),
      supabase.from('machines').select('id, name, status').eq('branch_id', branch).order('name'),
    ]);
    if (m.error) { setData({ ready: false }); return; }
    setData({ ready: true, meters: m.data || [], links: mm.data || [], machines: x.data || [] });
  }
  useEffect(() => { setData(null); load(); }, [branch]); // eslint-disable-line react-hooks/exhaustive-deps

  async function run(q, after) {
    setError(''); setBusy(true);
    const { error: err } = await q;
    setBusy(false);
    if (err) { setError(err.code === '23505' ? 'That name is already on the list, or the machine is already on another meter.' : dbErrorMessage(err)); return; }
    after?.();
    load();
  }

  if (data && !data.ready) return null;   // before 072
  return (
    <section className="card">
      <div className="card-header" style={{ gap: 8 }}>
        <h2 className="card-title">Electricity meters</h2>
        {branches.length > 1 && (
          <select className="form-input" style={{ maxWidth: 160, marginLeft: 'auto' }} aria-label="Branch" value={branch} onChange={e => setBranch(e.target.value)}>
            {branches.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}
          </select>
        )}
      </div>
      <div className="card-body" style={{ paddingTop: 6 }}>
        <p className="text-xs text-muted mb-8">Each LUKU meter and the machines it feeds. "All production": every unit goes into product cost. "Baseline": that many units a day are office/period use (a running cost) and only what the day used above it is production. Tokens are recorded as Electricity expenses; readings come from the daily report.</p>
        {!data ? <p className="text-sm text-muted">Loading…</p> : (
          <>
            {data.meters.length === 0 && <p className="text-sm text-muted">No meters yet.</p>}
            {data.meters.map(m => {
              const fed = data.links.filter(l => l.meter_id === m.id).map(l => data.machines.find(x => x.id === l.machine_id)).filter(Boolean);
              const taken = new Set(data.links.map(l => l.machine_id));
              return (
                <div key={m.id} className="ptc-item">
                  <div className="ptc-head">
                    <strong className={m.status === 'inactive' ? 'text-muted' : ''}>{m.name}{m.status === 'inactive' && <span className="text-xs"> · retired</span>}</strong>
                    <span className="ptc-crew">no.
                      <input className="form-input" style={{ width: 130 }} aria-label={`${m.name} meter number`} placeholder="—" disabled={!canEdit || busy} defaultValue={m.meter_no ?? ''}
                        onBlur={e => { const v = e.target.value.trim() || null; if (v !== m.meter_no) run(supabase.from('power_meters').update({ meter_no: v }).eq('id', m.id)); }} />
                    </span>
                    <span className="ptc-crew">
                      <select className="form-input" style={{ width: 150 }} aria-label={`${m.name} split`} disabled={!canEdit || busy} value={m.split_mode}
                        onChange={e => run(supabase.from('power_meters').update({ split_mode: e.target.value }).eq('id', m.id))}>
                        <option value="production">All production</option><option value="baseline">Baseline a day</option>
                      </select>
                    </span>
                    {m.split_mode === 'baseline' && (
                      <span className="ptc-crew">
                        <input className="form-input" style={{ width: 64 }} inputMode="decimal" aria-label={`${m.name} baseline units a day`} placeholder="—" disabled={!canEdit || busy}
                          defaultValue={m.baseline_units_per_day != null ? String(Number(m.baseline_units_per_day)) : ''}
                          onBlur={e => {
                            const t = e.target.value.trim(); const v = t === '' ? null : Number(t);
                            if (v !== null && !(v >= 0)) { setError('The baseline is units a day, 0 or more.'); return; }
                            if (v !== (m.baseline_units_per_day == null ? null : Number(m.baseline_units_per_day))) run(supabase.from('power_meters').update({ baseline_units_per_day: v }).eq('id', m.id));
                          }} /> units a day
                      </span>
                    )}
                    {canEdit && (
                      <span className="ptc-actions">
                        <button type="button" className="btn btn-ghost btn-sm" disabled={busy}
                          onClick={() => run(supabase.from('power_meters').update({ status: m.status === 'active' ? 'inactive' : 'active' }).eq('id', m.id))}>
                          {m.status === 'active' ? 'Retire' : 'Bring back'}</button>
                      </span>
                    )}
                  </div>
                  <div className="ptc-chips">
                    {fed.length === 0 && <span className="text-xs text-muted">Feeds no machine yet</span>}
                    {fed.map(x => (
                      <span key={x.id} className="ptc-chip">{x.name}
                        {canEdit && <button type="button" aria-label={`${x.name} not on ${m.name}`} disabled={busy}
                          onClick={() => run(supabase.from('power_meter_machines').delete().eq('meter_id', m.id).eq('machine_id', x.id))}><X size={11} /></button>}
                      </span>
                    ))}
                    {canEdit && m.status === 'active' && (
                      <select className="form-input ptc-sel" aria-label={`A machine on ${m.name}`} value="" disabled={busy}
                        onChange={e => e.target.value && run(supabase.from('power_meter_machines').insert({ meter_id: m.id, machine_id: e.target.value, organization_id: organization?.id }))}>
                        <option value="">+ Machine…</option>
                        {data.machines.filter(x => x.status === 'active' && !taken.has(x.id)).map(x => <option key={x.id} value={x.id}>{x.name}</option>)}
                      </select>
                    )}
                  </div>
                </div>
              );
            })}
            {canEdit && (
              <div className="ptc-item">
                <span className="ptc-add">
                  <input className="form-input" placeholder="New meter (e.g. its zone)" value={text} onChange={e => setText(e.target.value)}
                    onKeyDown={e => { if (e.key === 'Enter' && text.trim()) { e.preventDefault(); run(supabase.from('power_meters').insert({ organization_id: organization?.id, branch_id: branch, name: text.trim() }), () => setText('')); } }} />
                  <button type="button" className="btn btn-ghost btn-sm" aria-label="Add meter" disabled={busy || !text.trim()}
                    onClick={() => run(supabase.from('power_meters').insert({ organization_id: organization?.id, branch_id: branch, name: text.trim() }), () => setText(''))}><Plus size={14} /></button>
                </span>
              </div>
            )}
            {error && <p className="text-xs text-error">{error}</p>}
          </>
        )}
      </div>
    </section>
  );
}
