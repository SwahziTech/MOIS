import { useEffect, useState } from 'react';
import { X, Plus } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { useBranch } from '../../hooks/useBranch';
import { dbErrorMessage } from '../../lib/masterData';

/**
 * Production teams & machines of a branch (056), kept here as well as on
 * the spot in the batch form: rename, members in and out, retire, and which
 * products a machine makes (the batch form offers those first).
 */
export default function ProductionTeamsCard() {
  const { organization, canAt } = useAuth();
  const { branchId, branches } = useBranch();
  const [branch, setBranch] = useState(branchId || branches[0]?.id || '');
  const [data, setData] = useState(null);   // null = loading; { ready: false } before 056
  const [renaming, setRenaming] = useState(null);   // { table, id, name }
  const [text, setText] = useState({});     // input key → text
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => { if (!branch && (branchId || branches[0]?.id)) setBranch(branchId || branches[0].id); }, [branchId, branches]); // eslint-disable-line react-hooks/exhaustive-deps
  const canEdit = branch && (canAt('production.create', branch, null) || canAt('products.manage', branch, null));

  async function load() {
    if (!branch) return;
    const [t, m, mp, bp] = await Promise.all([
      supabase.from('production_teams').select('id, name, status, members:production_team_members(id, name, status)').eq('branch_id', branch).order('name'),
      supabase.from('machines').select('*').eq('branch_id', branch).order('name'),
      supabase.from('machine_products').select('machine_id, product_id'),
      supabase.from('branch_products').select('product_id, product:products(canonical_name)').eq('branch_id', branch).eq('status', 'active'),
    ]);
    if (t.error || m.error) { setData({ ready: false }); return; }
    setData({ ready: true, teams: t.data || [], machines: m.data || [], links: mp.data || [],
      products: (bp.data || []).map(x => ({ id: x.product_id, name: x.product?.canonical_name ?? '—' })).sort((a, b) => a.name.localeCompare(b.name)) });
  }
  useEffect(() => { setData(null); load(); }, [branch]); // eslint-disable-line react-hooks/exhaustive-deps

  async function run(q, clear) {
    setError(''); setBusy(true);
    const { error: err } = await q;
    setBusy(false);
    if (err) { setError(err.code === '23505' ? 'That name is already on the list.' : dbErrorMessage(err)); return; }
    if (clear) setText(x => ({ ...x, [clear]: '' }));
    setRenaming(null);
    load();
  }
  const org = organization?.id;
  const input = (k, placeholder, onAdd) => (
    <span className="ptc-add">
      <input className="form-input" placeholder={placeholder} value={text[k] ?? ''} onChange={e => setText(x => ({ ...x, [k]: e.target.value }))}
        onKeyDown={e => { if (e.key === 'Enter' && (text[k] ?? '').trim()) { e.preventDefault(); onAdd(text[k].trim()); } }} />
      <button type="button" className="btn btn-ghost btn-sm" aria-label={placeholder} disabled={busy || !(text[k] ?? '').trim()} onClick={() => onAdd(text[k].trim())}><Plus size={14} /></button>
    </span>
  );
  const nameLine = (table, row, extra) => (
    <div className="ptc-head">
      {renaming?.id === row.id ? (
        <>
          <input className="form-input" style={{ maxWidth: 220 }} aria-label="Name" value={renaming.name} onChange={e => setRenaming({ ...renaming, name: e.target.value })} />
          <button type="button" className="btn btn-primary btn-sm" disabled={busy || !renaming.name.trim()} onClick={() => run(supabase.from(table).update({ name: renaming.name.trim() }).eq('id', row.id))}>Save</button>
          <button type="button" className="btn btn-ghost btn-sm" onClick={() => setRenaming(null)}>Cancel</button>
        </>
      ) : (
        <>
          <strong className={row.status === 'inactive' ? 'text-muted' : ''}>{row.name}{row.status === 'inactive' && <span className="text-xs"> · retired</span>}</strong>
          {extra}
          {canEdit && (
            <span className="ptc-actions">
              <button type="button" className="btn btn-ghost btn-sm" onClick={() => setRenaming({ id: row.id, name: row.name })}>Rename</button>
              <button type="button" className="btn btn-ghost btn-sm" disabled={busy}
                onClick={() => run(supabase.from(table).update({ status: row.status === 'active' ? 'inactive' : 'active' }).eq('id', row.id))}>
                {row.status === 'active' ? 'Retire' : 'Bring back'}</button>
            </span>
          )}
        </>
      )}
    </div>
  );

  if (data && !data.ready) return null;   // before 056
  return (
    <section className="card">
      <div className="card-header" style={{ gap: 8 }}>
        <h2 className="card-title">Production teams & machines</h2>
        {branches.length > 1 && (
          <select className="form-input" style={{ maxWidth: 160, marginLeft: 'auto' }} aria-label="Branch" value={branch} onChange={e => setBranch(e.target.value)}>
            {branches.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}
          </select>
        )}
      </div>
      <div className="card-body" style={{ paddingTop: 6 }}>
        <p className="text-xs text-muted mb-8">Every batch records its team and machine. Retired ones stay on past batches. New ones can also be added in the batch form. A machine's crew (e.g. 9-12) is the people it takes to run, whatever the bags — products without it use their bags a person (Products).</p>
        {!data ? <p className="text-sm text-muted">Loading…</p> : (
          <>
            <h3 className="ptc-title">Teams</h3>
            {data.teams.length === 0 && <p className="text-sm text-muted">No teams yet.</p>}
            {data.teams.map(t => (
              <div key={t.id} className="ptc-item">
                {nameLine('production_teams', t)}
                <div className="ptc-chips">
                  {t.members.filter(m => m.status === 'active').map(m => (
                    <span key={m.id} className="ptc-chip">{m.name}
                      {canEdit && <button type="button" aria-label={`${m.name} left the team`} title="Left the team" disabled={busy}
                        onClick={() => run(supabase.from('production_team_members').update({ status: 'inactive' }).eq('id', m.id))}><X size={11} /></button>}
                    </span>
                  ))}
                  {canEdit && t.status === 'active' && input(`m:${t.id}`, 'Add member', name => run(supabase.from('production_team_members').insert({ organization_id: org, team_id: t.id, name }), `m:${t.id}`))}
                </div>
              </div>
            ))}
            {canEdit && <div className="ptc-item">{input('team', 'New team', name => run(supabase.from('production_teams').insert({ organization_id: org, branch_id: branch, name }), 'team'))}</div>}

            <h3 className="ptc-title">Machines / lines</h3>
            {data.machines.length === 0 && <p className="text-sm text-muted">No machines yet.</p>}
            {data.machines.map(m => {
              const made = data.links.filter(l => l.machine_id === m.id).map(l => data.products.find(p => p.id === l.product_id)).filter(Boolean);
              return (
                <div key={m.id} className="ptc-item">
                  {nameLine('machines', m, 'crew_min' in m && (
                    <span className="ptc-crew">crew
                      <input className="form-input" aria-label={`${m.name} crew`} placeholder="—" disabled={!canEdit || busy}
                        defaultValue={m.crew_min != null ? (m.crew_min === m.crew_max ? String(m.crew_min) : `${m.crew_min}-${m.crew_max}`) : ''}
                        onBlur={e => {
                          const v = e.target.value.trim(); const c = v === '' ? null : v.split(/[-–]/).map(x => Number(x.trim()));
                          if (c && (c.length > 2 || c.some(x => !(Number.isInteger(x) && x > 0)) || (c.length === 2 && c[0] > c[1]))) { setError('Crew: whole people, like 12 or 9-12, or blank.'); return; }
                          const lo = c ? c[0] : null, hi = c ? c[c.length - 1] : null;
                          if (lo !== m.crew_min || hi !== m.crew_max) run(supabase.from('machines').update({ crew_min: lo, crew_max: hi }).eq('id', m.id));
                        }} />
                    </span>
                  ))}
                  <div className="ptc-chips">
                    {made.length === 0 && <span className="text-xs text-muted">Makes any product</span>}
                    {made.map(p => (
                      <span key={p.id} className="ptc-chip">{p.name}
                        {canEdit && <button type="button" aria-label={`Not made on ${m.name}`} disabled={busy}
                          onClick={() => run(supabase.from('machine_products').delete().eq('machine_id', m.id).eq('product_id', p.id))}><X size={11} /></button>}
                      </span>
                    ))}
                    {canEdit && m.status === 'active' && (
                      <select className="form-input ptc-sel" aria-label={`A product made on ${m.name}`} value="" disabled={busy}
                        onChange={e => e.target.value && run(supabase.from('machine_products').insert({ machine_id: m.id, product_id: e.target.value, organization_id: org }))}>
                        <option value="">+ Product…</option>
                        {data.products.filter(p => !made.includes(p)).map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
                      </select>
                    )}
                  </div>
                </div>
              );
            })}
            {canEdit && <div className="ptc-item">{input('machine', 'New machine or line', name => run(supabase.from('machines').insert({ organization_id: org, branch_id: branch, name }), 'machine'))}</div>}
            {error && <p className="text-xs text-error">{error}</p>}
          </>
        )}
      </div>
    </section>
  );
}
