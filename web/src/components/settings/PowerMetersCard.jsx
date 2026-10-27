import { useEffect, useState } from 'react';
import { X, Plus } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { useBranch } from '../../hooks/useBranch';
import { dbErrorMessage } from '../../lib/masterData';

/**
 * Electricity meters of a branch (072): the LUKU meter number, the machines
 * each one feeds, and the share of its units used outside production (the
 * office…), which never goes into product cost.
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
  const canEdit = branch && (canAt('production.create', branch, null) || canAt('products.manage', branch, null));

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
        <p className="text-xs text-muted mb-8">Each LUKU meter, the machines it feeds, and the share of its units used by the office or anything not production — that share stays a running cost. Readings and tokens are recorded on the Electricity page.</p>
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
                    <span className="ptc-crew">office / not production
                      <input className="form-input" style={{ width: 56 }} inputMode="decimal" aria-label={`${m.name} share not production`} disabled={!canEdit || busy} defaultValue={String(Number(m.office_share_pct))}
                        onBlur={e => {
                          const v = Number(e.target.value.trim() || 0);
                          if (!(v >= 0 && v <= 100)) { setError('The office share is a % from 0 to 100.'); return; }
                          if (v !== Number(m.office_share_pct)) run(supabase.from('power_meters').update({ office_share_pct: v }).eq('id', m.id));
                        }} />%
                    </span>
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
