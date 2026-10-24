import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Factory } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { dbErrorMessage } from '../lib/masterData';
import { loadInventoryRefs, qtyText, orgToday, byMaterialOrder } from '../lib/inventory';
import PageShell from '../components/PageShell';
import { PageTabs } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import NumberInput from '../components/NumberInput';
import { SkeletonRow } from '../components/LoadingSpinner';
import DayLog from '../components/production/DayLog';
import CapacityPlanner from '../components/production/CapacityPlanner';

const LOAD_ERROR = "We couldn't load production. Please try again.";
const num = v => (String(v ?? '').trim() === '' ? null : Number(v));
const round = (n, d = 4) => Math.round(n * 10 ** d) / 10 ** d;
// Recipe figures vs stock counts: a material whose counts move more than this
// share of its recipe-based use is highlighted (a display threshold, not a rule)
const VARIANCE_SHOWN = 0.10;

/*
 * Production (migrations 042, 043). A batch is one mix/session: a main
 * product and colour, plus any leftovers cast from the same mix; a branch
 * has many a day, logged on "Log batches" and saved together. Materials:
 * cement bags counted, the rest from the recipe × bags. Pieces cure in the
 * Curing store (not sellable) until the quality release moves the passed
 * ones into Finished Goods, product by product.
 */
export default function Production() {
  const { organization, canAt, canManage } = useAuth();
  const { branchId, branchName, inBranch } = useBranch();
  const today = orgToday(organization?.timezone);

  const [tab,      setTab]      = useState(null);   // opens on Log batches for those who record
  const [refs,     setRefs]     = useState(null);
  const [batches,  setBatches]  = useState([]);
  const [reasons,  setReasons]  = useState([]);
  const [recipes,  setRecipes]  = useState([]);
  const [variance, setVariance] = useState([]);
  const [flags,    setFlags]    = useState({});    // batch id → open review flag reason
  const [people,   setPeople]   = useState({});
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [releasing, setReleasing] = useState(null);
  const [voiding,   setVoiding]   = useState(null);
  const [busyId,    setBusyId]    = useState(null);
  const [rowError,  setRowError]  = useState('');
  const [curingDays, setCuringDays] = useState(14);
  const [minCuring, setMinCuring] = useState(null);   // fewest days before release (054); null = none
  const [preset, setPreset] = useState(null);   // product (and colour) sent from the simulator or Stock
  // Stock's "Produce" opens the production form with that product (?produce=<id>)
  const [params, setParams] = useSearchParams();
  useEffect(() => {
    const id = params.get('produce');
    if (!id) return;
    setPreset({ productId: id, colorId: '', at: Date.now() });
    setTab('log');
    setParams({}, { replace: true });
  }, [params]); // eslint-disable-line react-hooks/exhaustive-deps

  async function load() {
    setError('');
    const byBranch = q => (branchId ? q.eq('branch_id', branchId) : q);
    try {
      const [r, b, rr, rv, va, fl] = await Promise.all([
        loadInventoryRefs(),
        byBranch(supabase.from('production_batches').select('*, materials:production_batch_materials(*), outputs:production_batch_outputs(*), rejects:production_batch_rejects(*)'))
          .order('batch_date', { ascending: false }).order('created_at', { ascending: false }).limit(500),
        supabase.from('reject_reasons').select('id, name, status, display_order').order('display_order').order('name'),
        byBranch(supabase.from('recipe_versions').select('id, branch_id, category_id, color_id, version_number, effective_date, status, items:recipe_items(material_id, quantity, unit_id), products:recipe_version_products(product_id)').eq('status', 'active')),
        byBranch(supabase.from('production_material_variance').select('*')),
        supabase.from('review_flags').select('entity_id, reason').eq('entity_type', 'production_batch').eq('status', 'open'),
      ]);
      const err = b.error || rr.error || rv.error || va.error || fl.error;
      if (err) throw err;
      setRefs(r);
      const { data: o } = await supabase.from('organizations').select('*').eq('id', organization.id).maybeSingle();
      if (o?.curing_days != null) setCuringDays(o.curing_days);
      setMinCuring(o?.min_curing_days ?? null);
      setBatches(b.data || []);
      setReasons(rr.data || []);
      setRecipes(rv.data || []);
      setVariance(va.data || []);
      setFlags(Object.fromEntries((fl.data || []).map(f => [f.entity_id, f.reason])));
      const ids = [...new Set((b.data || []).map(x => x.created_by).filter(Boolean))];
      if (ids.length) {
        const { data: ppl } = await supabase.from('profiles').select('id, first_name, last_name, email').in('id', ids);
        setPeople(Object.fromEntries((ppl || []).map(p => [p.id, [p.first_name, p.last_name].filter(Boolean).join(' ') || p.email])));
      }
    } catch (e) {
      console.error(e);
      setError(LOAD_ERROR);
    }
    setLoading(false);
  }
  useEffect(() => { setLoading(true); load(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  const canRecord = !!branchId && canAt('production.create', branchId, null);
  const current = tab ?? (canRecord ? 'log' : 'curing');
  const here = batches.filter(b => inBranch(b.branch_id));
  const curing = here.filter(b => b.status === 'curing');
  const waitingMaterials = here.filter(b => b.status !== 'void' && !b.materials_movement_id && b.materials?.length);
  const done = here.filter(b => b.status !== 'curing');
  const shown = current === 'curing' ? curing : current === 'materials' ? waitingMaterials : done;

  const productName = b => `${refs?.items[`p:${b.product_id}`]?.name ?? '—'}${b.color_id ? ` ${refs?.colorById[b.color_id]?.name ?? ''}` : ''}`;
  const leftoversOf = b => (b.outputs || []).filter(o => !o.is_primary);
  // How often each product is cast at the branch: the picker lists the frequent ones first
  const usage = {};
  for (const b of batches.filter(x => x.status !== 'void' && x.branch_id === branchId)) {
    const ids = new Set([b.product_id, ...(b.outputs || []).map(o => o.product_id)]);
    for (const id of ids) usage[id] = (usage[id] || 0) + 1;
  }
  const canIssue = b => canAt('inventory.issue', b.branch_id, b.raw_warehouse_id) || canAt('production.create', b.branch_id, null);

  // Release several at once (SwahziTech, 2026-10-24): ready batches, every piece passed — rejects go through Release… one by one
  const [picked, setPicked] = useState(() => new Set());
  const [bulk, setBulk] = useState(null);   // { running, done, failed: [{ name, error }] } while/after releasing
  // any curing batch can be picked; one released before its curing ends needs a reason (asked once for all)
  const plusDays = (d, n) => new Date(new Date(`${d}T00:00:00Z`).getTime() + n * 864e5).toISOString().slice(0, 10);
  const readyOn = b => (minCuring != null ? plusDays(b.batch_date, minCuring) : b.curing_until);
  // with a minimum (054) a batch can be picked from that day; without one, any curing batch (early ones need a reason)
  const readyToRelease = b => b.status === 'curing' && canAt('production.complete', b.branch_id, null) && (minCuring == null || readyOn(b) <= today);
  const ready = curing.filter(readyToRelease);
  const [bulkNote, setBulkNote] = useState('');
  const earlyPicked = minCuring != null ? [] : ready.filter(b => picked.has(b.id) && b.curing_until > today);
  const togglePick = id => setPicked(s0 => { const n = new Set(s0); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  async function releaseMany() {
    const list = ready.filter(b => picked.has(b.id));
    const failed = [];
    setBulk({ running: true, done: 0, total: list.length, failed });
    for (const b of list) {
      const fg = refs.warehouses.find(w => w.status === 'active' && w.type === 'finished_goods' && w.branch_id === b.branch_id);
      const { error: err } = await supabase.rpc('release_production_batch', { p_batch: b.id, p: {
        fg_warehouse_id: fg?.id ?? null, release_date: today, note: minCuring == null && b.curing_until > today ? bulkNote.trim() : null,
        outputs: (b.outputs || []).map(o => ({ output_id: o.id, pieces_passed: o.pieces_cast, rejects: [] })),
      } });
      if (err) failed.push({ name: `${b.batch_date} · ${productName(b)}`, error: dbErrorMessage(err) });
      setBulk(x => ({ ...x, done: x.done + 1, failed: [...failed] }));
    }
    setBulk(x => ({ ...x, running: false }));
    setPicked(new Set());
    setBulkNote('');
    await load();
  }

  async function issue(b) {
    setRowError('');
    setBusyId(b.id);
    const { error: err } = await supabase.rpc('issue_production_materials', { p_batch: b.id });
    setBusyId(null);
    if (err) { setRowError(dbErrorMessage(err, "We couldn't issue the materials. Please try again.")); return; }
    load();
  }

  return (
    <PageShell title="Production" subtitle="Production"
      description={branchId ? `Batches cast at ${branchName}: materials used, pieces cast, curing and quality release.` : 'Batches cast at every branch — pick a branch in the sidebar to log batches.'}>
      <PageTabs value={current} onChange={setTab} tabs={[
        ...(canRecord ? [['log', 'Production']] : []),
        ['curing', `Curing (${curing.length})`],
        ...(waitingMaterials.length ? [['materials', `Materials to issue (${waitingMaterials.length})`]] : []),
        ['done', 'Released & void'],
        ['variance', 'Material variance'],
        ['planner', 'Orders & planner'],
      ]} />
      {rowError && <div className="alert alert-error mb-8" role="alert">{rowError}</div>}

      {current === 'planner' ? (
        !branchId ? <div className="card"><EmptyState icon={Factory} title="Pick a branch" description="Capacity is per branch — pick one in the sidebar." /></div>
          : !refs ? <div className="card"><div className="card-body"><span className="skeleton" /></div></div>
          : <CapacityPlanner refs={refs} recipes={recipes} branchId={branchId} branchName={branchName} today={today} batches={batches} usage={usage}
              onOpenForm={canRecord ? (pr => { setPreset({ ...pr, at: Date.now() }); setTab('log'); }) : null} />
      ) : current === 'log' ? (
        error ? <div className="card"><ErrorState message={error} onRetry={load} /></div>
          : !refs ? <div className="card"><div className="card-body"><span className="skeleton" /></div></div>
          : <DayLog refs={refs} recipes={recipes} branchId={branchId} branchName={branchName} today={today} curingDays={curingDays} usage={usage} preset={preset}
              onSaved={async () => { setTab('curing'); await load(); }} />
      ) : (
      <div className="card">
        {error ? <ErrorState message={error} onRetry={load} /> : current === 'variance' ? (
          <VarianceTable rows={variance.filter(v => inBranch(v.branch_id))
            .sort((a, b) => byMaterialOrder(refs?.items[`m:${a.material_id}`] ?? {}, refs?.items[`m:${b.material_id}`] ?? {}))} refs={refs} loading={loading} />
        ) : (
          <div className="table-container">
            {current === 'curing' && ready.length > 0 && (
              <div className="bulk-bar">
                <label className="bulk-all"><input type="checkbox" checked={ready.length > 0 && ready.every(b => picked.has(b.id))}
                  onChange={e => setPicked(e.target.checked ? new Set(ready.map(b => b.id)) : new Set())} /> Select all ({ready.length})</label>
                <span className="pl-help">{picked.size ? `${picked.size} selected` : 'Tick batches to release them together — every piece passes.'}</span>
                <button type="button" className="btn btn-primary btn-sm" disabled={!picked.size || bulk?.running} onClick={() => setBulk({ confirm: true })}>
                  Release selected ({picked.size})
                </button>
              </div>
            )}
            <table>
              <thead><tr>
                {current === 'curing' && <th aria-label="Select" style={{ width: 32 }} />}
                <th>Date</th><th>Product</th><th style={{ textAlign: 'right' }}>Bags</th><th style={{ textAlign: 'right' }}>Pieces</th>
                <th>Yield check</th><th>{current === 'done' ? 'Released' : 'Curing until'}</th><th>Status</th><th aria-label="Actions" />
              </tr></thead>
              <tbody>
                {loading ? <SkeletonRow cols={current === 'curing' ? 9 : 8} /> : shown.length === 0 ? (
                  <tr><td colSpan={current === 'curing' ? 9 : 8}><EmptyState icon={Factory}
                    title={current === 'curing' ? 'Nothing curing' : current === 'materials' ? 'No materials waiting' : 'No released batches yet'}
                    description={current === 'curing' ? 'Batches cast appear here until their quality release.' : ''} /></td></tr>
                ) : shown.map(b => {
                  const flagged = flags[b.id];
                  // the bags used against the band the products' yields give (043)
                  const inBand = b.theoretical_bags == null ? null : b.cement_bags >= b.bags_min - 1e-9 && (b.bags_max == null || b.cement_bags <= b.bags_max + 1e-9);
                  const rejected = (b.rejects || []).reduce((s, r) => s + r.pieces, 0);
                  const passed = (b.outputs || []).reduce((s, o) => s + (o.pieces_passed ?? 0), 0);
                  return (
                    <tr key={b.id} className={b.status === 'void' ? 'text-muted' : ''}>
                      {current === 'curing' && (
                        <td>{readyToRelease(b) && <input type="checkbox" aria-label={`Select ${productName(b)} ${b.batch_date}`} checked={picked.has(b.id)} onChange={() => togglePick(b.id)} />}</td>
                      )}
                      <td>{b.batch_date}<div className="text-xs text-muted">{people[b.created_by] ?? ''}</div></td>
                      <td><span style={{ fontWeight: 500 }}>{productName(b)}</span>
                        {leftoversOf(b).length > 0 && <div className="text-xs text-muted">+ {leftoversOf(b).map(o => `${o.pieces_cast} ${refs?.items[`p:${o.product_id}`]?.name ?? ''}`).join(', ')}</div>}</td>
                      <td style={{ textAlign: 'right' }}>{qtyText(b.cement_bags)}</td>
                      <td style={{ textAlign: 'right' }}>
                        {qtyText(b.pieces_cast)}
                        {b.status === 'released' && <div className="text-xs text-muted">{passed} passed{rejected ? ` · ${rejected} rejected` : ''}</div>}
                      </td>
                      <td>
                        {inBand == null ? <span className="text-xs text-muted">No yield per bag set</span>
                          : <span className={`badge ${inBand ? 'badge-success' : 'badge-warning'}`} title={flagged}>
                              {Math.round((b.theoretical_bags / b.cement_bags) * 1000) / 10}%{inBand ? '' : ' — outside'}
                            </span>}
                      </td>
                      <td>{b.status === 'released' ? b.released_on : b.status === 'void' ? '—' : (
                        <>{b.curing_until}{readyOn(b) <= today
                          ? <div className="text-xs" style={{ color: 'var(--color-success)' }}>Ready to release</div>
                          : minCuring != null && <div className="text-xs text-muted">ready {readyOn(b)}</div>}</>
                      )}</td>
                      <td>
                        <span className={`badge ${b.status === 'curing' ? 'badge-accent' : b.status === 'released' ? 'badge-success' : 'badge-neutral'}`}>
                          {b.status === 'curing' ? 'Curing' : b.status === 'released' ? 'Released' : 'Void'}
                        </span>
                        {!b.materials_movement_id && b.status !== 'void' && b.materials?.length > 0 && <div className="text-xs text-muted">Materials not issued yet</div>}
                        {b.status === 'void' && <div className="text-xs text-muted">{b.void_reason}</div>}
                      </td>
                      <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                        {!b.materials_movement_id && b.status !== 'void' && b.materials?.length > 0 && canIssue(b) && (
                          <button type="button" className={`btn btn-outline btn-sm${busyId === b.id ? ' btn-loading' : ''}`} disabled={busyId === b.id} onClick={() => issue(b)}>Issue materials</button>
                        )}
                        {b.status === 'curing' && canAt('production.complete', b.branch_id, null) && (
                          <button type="button" className="btn btn-primary btn-sm" onClick={() => setReleasing(b)}>Release…</button>
                        )}
                        {b.status === 'curing' && canManage('inventory.adjust') && (
                          <button type="button" className="btn btn-ghost btn-sm" onClick={() => setVoiding(b)}>Void…</button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
      )}

      {bulk && (
        <Modal title={bulk.confirm ? `Release ${picked.size} batch${picked.size === 1 ? '' : 'es'}?` : bulk.running ? 'Releasing…' : 'Released'}
          onClose={() => { if (!bulk.running) setBulk(null); }}
          footer={bulk.confirm ? <>
            <button type="button" className="btn btn-outline" onClick={() => setBulk(null)}>Cancel</button>
            <button type="button" className="btn btn-primary" disabled={earlyPicked.length > 0 && !bulkNote.trim()} onClick={releaseMany}>Release — all pieces pass</button>
          </> : <button type="button" className="btn btn-primary" disabled={bulk.running} onClick={() => setBulk(null)}>Close</button>}>
          {bulk.confirm ? (
            <div className="flex flex-col gap-8">
              <p className="text-sm">Every piece of these batches passes and moves into Finished Goods today. A batch with rejects: use its own <strong>Release…</strong> instead.</p>
              {earlyPicked.length > 0 && (
                <label className="pe-field"><span>{earlyPicked.length} of them {earlyPicked.length === 1 ? 'is' : 'are'} still curing — why release early? (required)</span>
                  <input className="form-input" autoFocus value={bulkNote} placeholder="e.g. 7 days only" onChange={e => setBulkNote(e.target.value)} /></label>
              )}
              <table className="rd-table"><tbody>
                {ready.filter(b => picked.has(b.id)).map(b => (
                  <tr key={b.id}><td>{b.batch_date}</td><td>{productName(b)}{leftoversOf(b).length > 0 && <span className="pl-help"> + {leftoversOf(b).map(o => refs?.items[`p:${o.product_id}`]?.name).join(', ')}</span>}</td>
                    <td className="num"><strong>{qtyText(b.pieces_cast)}</strong> pcs</td><td className="num pl-help">{minCuring == null && b.curing_until > today ? `early · until ${b.curing_until}` : 'ready'}</td></tr>
                ))}
              </tbody></table>
            </div>
          ) : (
            <div className="flex flex-col gap-8">
              <p className="text-sm">{bulk.done} of {bulk.total} done{bulk.running ? '…' : '.'} {!bulk.running && bulk.failed.length === 0 && 'All released.'}</p>
              {bulk.failed.length > 0 && (
                <div className="alert alert-error"><strong>Not released:</strong>
                  <ul style={{ margin: '4px 0 0 18px' }}>{bulk.failed.map((f, i) => <li key={i}>{f.name} — {f.error}</li>)}</ul></div>
              )}
            </div>
          )}
        </Modal>
      )}
      {releasing && refs && (
        <ReleaseModal batch={releasing} name={productName(releasing)} refs={refs} reasons={reasons} today={today} minFrom={minCuring != null ? readyOn(releasing) : null}
          onClose={() => setReleasing(null)} onSaved={async () => { setReleasing(null); await load(); }} />
      )}
      {voiding && (
        <VoidModal batch={voiding} name={productName(voiding)} onClose={() => setVoiding(null)} onSaved={async () => { setVoiding(null); await load(); }} />
      )}
    </PageShell>
  );
}

/**
 * Quality release, product by product: every cast piece passes unless it is
 * entered as a reject (with its reason) — passed = cast − rejects, worked out
 * here, never typed (SwahziTech, 2026-10-22).
 */
function ReleaseModal({ batch, name, refs, reasons, today, minFrom = null, onClose, onSaved }) {
  const fgStores = refs.warehouses.filter(w => w.status === 'active' && w.branch_id === batch.branch_id && w.type === 'finished_goods');
  const outputs = [...(batch.outputs || [])].sort((a, b) => b.is_primary - a.is_primary);
  const [fgId, setFgId] = useState(fgStores[0]?.id ?? '');
  const [date, setDate] = useState(today);
  const [rejects, setRejects] = useState({});   // `${output id}|${reason id}` → pieces
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const active = reasons.filter(r => r.status === 'active');
  // with a minimum curing period (054): not before it, no reason needed after it; without one, early needs a reason
  const tooSoon = minFrom != null && date < minFrom;
  const early = minFrom == null && date < batch.curing_until;
  const rejectedOf = o => active.reduce((s, r) => s + (num(rejects[`${o.id}|${r.id}`]) ?? 0), 0);
  const passedOf = o => o.pieces_cast - rejectedOf(o);
  const nameOf = o => `${refs.items[`p:${o.product_id}`]?.name ?? '—'}${o.color_id ? ` ${refs.colorById[o.color_id]?.name ?? ''}` : ''}`;

  async function save(e) {
    e.preventDefault();
    setError('');
    for (const o of outputs) {
      if (passedOf(o) < 0) { setError(`${nameOf(o)}: more rejects than the ${o.pieces_cast} pieces cast.`); return; }
    }
    if (tooSoon) { setError(`It cures at least until ${minFrom} — release from then.`); return; }
    if (early && !note.trim()) { setError(`Curing runs until ${batch.curing_until} — say why it is released early.`); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('release_production_batch', { p_batch: batch.id, p: {
      fg_warehouse_id: fgId, release_date: date, note: note.trim() || null,
      outputs: outputs.map(o => ({ output_id: o.id, pieces_passed: passedOf(o),
        rejects: active.filter(r => num(rejects[`${o.id}|${r.id}`]) > 0).map(r => ({ reason_id: r.id, pieces: num(rejects[`${o.id}|${r.id}`]) })) })),
    } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't release this batch. Please try again.")); return; }
    onSaved();
  }

  return (
    <Modal title={`Release ${name} · ${batch.batch_date}`} onClose={onClose} size="lg"
      footer={<>
        {error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="release-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy}>Release</button>
      </>}>
      <form id="release-form" className="modal-form" onSubmit={save}>
        <p className="text-sm text-muted">Curing until {batch.curing_until}. All pieces pass unless you enter rejects — passed pieces move into Finished Goods; rejected ones leave stock.</p>
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="rl-fg">Into</label>
            <select id="rl-fg" className="form-input" value={fgId} onChange={e => setFgId(e.target.value)}>
              {fgStores.map(w => <option key={w.id} value={w.id}>{w.name}</option>)}
            </select>
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="rl-date">Date</label>
            <input id="rl-date" type="date" className="form-input" min={batch.batch_date} max={today} value={date} onChange={e => setDate(e.target.value)} />
          </div>
        </div>
        <div className="table-container">
          <table>
            <thead><tr><th>Product</th><th style={{ textAlign: 'right' }}>Cast</th>{active.map(r => <th key={r.id}>{r.name}</th>)}<th style={{ textAlign: 'right' }}>Passed</th></tr></thead>
            <tbody>
              {outputs.map(o => {
                const pp = passedOf(o);
                return (
                  <tr key={o.id}>
                    <td style={{ fontWeight: 500 }}>{nameOf(o)}{!o.is_primary && <div className="text-xs text-muted">leftover</div>}</td>
                    <td style={{ textAlign: 'right' }}>{qtyText(o.pieces_cast)}</td>
                    {active.map(r => (
                      <td key={r.id}><NumberInput step="1" min="0" className="form-input" style={{ width: 70 }} placeholder="0" aria-label={`${nameOf(o)} ${r.name}`}
                        value={rejects[`${o.id}|${r.id}`] ?? ''} onChange={e => setRejects(x => ({ ...x, [`${o.id}|${r.id}`]: e.target.value }))} /></td>
                    ))}
                    <td style={{ textAlign: 'right' }}><strong className={pp < 0 ? 'text-error' : ''}>{qtyText(pp)}</strong>{rejectedOf(o) > 0 && <div className="text-xs text-muted">{qtyText(rejectedOf(o))} rejected</div>}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
        <div className="form-group">
          <label className="form-label" htmlFor="rl-note">{early ? 'Why released early? (required)' : 'Note (optional)'}</label>
          <input id="rl-note" className="form-input" value={note} onChange={e => setNote(e.target.value)} />
        </div>
      </form>
    </Modal>
  );
}

function VoidModal({ batch, name, onClose, onSaved }) {
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function save() {
    setError('');
    if (!reason.trim()) { setError('Give a reason.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('void_production_batch', { p_batch: batch.id, p_reason: reason.trim() });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  return (
    <Modal title={`Void ${name} · ${batch.batch_date}`} onClose={onClose}
      footer={<>
        {error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Keep it</button>
        <button type="button" className={`btn btn-danger-outline${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Void batch</button>
      </>}>
      <div className="modal-form">
        <p className="text-sm">Voiding reverses the pieces put into curing and the materials taken out of the store. The batch stays on record, marked void.</p>
        <input className="form-input" placeholder="Reason" aria-label="Reason for voiding" value={reason} onChange={e => setReason(e.target.value)} />
      </div>
    </Modal>
  );
}

/** Recipe figures set against stock counts, per material */
function VarianceTable({ rows, refs, loading }) {
  return (
    <div className="table-container">
      <table>
        <thead><tr>
          <th>Material</th><th style={{ textAlign: 'right' }}>Batches</th><th style={{ textAlign: 'right' }}>Counted use</th>
          <th style={{ textAlign: 'right' }}>From recipe</th><th style={{ textAlign: 'right' }}>Stock counts since</th><th>Reading</th>
        </tr></thead>
        <tbody>
          {loading ? <SkeletonRow cols={6} /> : rows.length === 0 ? (
            <tr><td colSpan={6}><EmptyState icon={Factory} title="No production yet" description="Once batches use materials, their recipe figures are compared here with what stock counts find." /></td></tr>
          ) : rows.map(v => {
            const item = refs?.items[`m:${v.material_id}`];
            const sym = refs?.unitById[item?.stockUnitId]?.symbol ?? '';
            const rec = Number(v.recipe_use ?? 0);
            const corr = Number(v.count_corrections ?? 0);
            const share = rec > 0 ? corr / rec : null;
            return (
              <tr key={`${v.branch_id}|${v.material_id}`}>
                <td style={{ fontWeight: 500 }}>{item?.name ?? '—'}</td>
                <td style={{ textAlign: 'right' }}>{v.batches}</td>
                <td style={{ textAlign: 'right' }}>{v.counted_use != null ? `${qtyText(round(v.counted_use))} ${sym}` : '—'}</td>
                <td style={{ textAlign: 'right' }}>{v.recipe_use != null ? `${qtyText(round(v.recipe_use))} ${sym}` : '—'}</td>
                <td style={{ textAlign: 'right' }}>{v.last_count ? <>{corr >= 0 ? '+' : ''}{qtyText(round(corr))} {sym}<div className="text-xs text-muted">last count {v.last_count}</div></> : <span className="text-muted">no count yet</span>}</td>
                <td>
                  {!v.last_count ? <span className="text-xs text-muted">Count the store to compare</span>
                    : share == null ? <span className="text-xs text-muted">Counted for real</span>
                    : Math.abs(share) > VARIANCE_SHOWN
                      ? <span className="badge badge-warning">{corr < 0 ? 'Using more than the recipe' : 'Using less than the recipe'} ({Math.round(Math.abs(share) * 100)}%)</span>
                      : <span className="badge badge-success">Close to the recipe</span>}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
