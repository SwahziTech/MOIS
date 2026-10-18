import { useEffect, useMemo, useState } from 'react';
import { Factory, Plus } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { dbErrorMessage } from '../lib/masterData';
import { loadInventoryRefs, qtyText, orgToday, warehouseLabel } from '../lib/inventory';
import PageShell from '../components/PageShell';
import { PageTabs } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import NumberInput from '../components/NumberInput';
import { SkeletonRow } from '../components/LoadingSpinner';

const LOAD_ERROR = "We couldn't load production. Please try again.";
const num = v => (String(v ?? '').trim() === '' ? null : Number(v));
const round = (n, d = 4) => Math.round(n * 10 ** d) / 10 ** d;
// Recipe figures vs stock counts: a material whose counts move more than this
// share of its recipe-based use is highlighted (a display threshold, not a rule)
const VARIANCE_SHOWN = 0.10;

/*
 * Production (migration 042). A batch is one mix/session — one product,
 * one colour, cast together; a branch has many a day. Materials: cement
 * bags counted, the rest from the recipe × bags (both issued from the
 * store). Pieces cure in the Curing store (not sellable) until the quality
 * release moves the passed ones into Finished Goods.
 */
export default function Production() {
  const { organization, canAt, canManage } = useAuth();
  const { branchId, branchName, inBranch } = useBranch();
  const today = orgToday(organization?.timezone);

  const [tab,      setTab]      = useState('curing');
  const [refs,     setRefs]     = useState(null);
  const [batches,  setBatches]  = useState([]);
  const [reasons,  setReasons]  = useState([]);
  const [recipes,  setRecipes]  = useState([]);
  const [variance, setVariance] = useState([]);
  const [flags,    setFlags]    = useState({});    // batch id → open review flag reason
  const [people,   setPeople]   = useState({});
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [recording, setRecording] = useState(false);
  const [releasing, setReleasing] = useState(null);
  const [voiding,   setVoiding]   = useState(null);
  const [busyId,    setBusyId]    = useState(null);
  const [rowError,  setRowError]  = useState('');
  const [curingDays, setCuringDays] = useState(14);

  async function load() {
    setError('');
    const byBranch = q => (branchId ? q.eq('branch_id', branchId) : q);
    try {
      const [r, b, rr, rv, va, fl] = await Promise.all([
        loadInventoryRefs(),
        byBranch(supabase.from('production_batches').select('*, materials:production_batch_materials(*), rejects:production_batch_rejects(*)'))
          .order('batch_date', { ascending: false }).order('created_at', { ascending: false }).limit(500),
        supabase.from('reject_reasons').select('id, name, status, display_order').order('display_order').order('name'),
        byBranch(supabase.from('recipe_versions').select('id, branch_id, category_id, color_id, version_number, effective_date, status, items:recipe_items(material_id, quantity, unit_id), products:recipe_version_products(product_id)').eq('status', 'active')),
        byBranch(supabase.from('production_material_variance').select('*')),
        supabase.from('review_flags').select('entity_id, reason').eq('entity_type', 'production_batch').eq('status', 'open'),
      ]);
      const err = b.error || rr.error || rv.error || va.error || fl.error;
      if (err) throw err;
      setRefs(r);
      const { data: o } = await supabase.from('organizations').select('curing_days').eq('id', organization.id).maybeSingle();
      if (o?.curing_days != null) setCuringDays(o.curing_days);
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

  const here = batches.filter(b => inBranch(b.branch_id));
  const curing = here.filter(b => b.status === 'curing');
  const waitingMaterials = here.filter(b => b.status !== 'void' && !b.materials_movement_id && b.materials?.length);
  const done = here.filter(b => b.status !== 'curing');
  const shown = tab === 'curing' ? curing : tab === 'materials' ? waitingMaterials : done;
  const canRecord = !!branchId && canAt('production.create', branchId, null);

  const productName = b => `${refs?.items[`p:${b.product_id}`]?.name ?? '—'}${b.color_id ? ` ${refs?.colorById[b.color_id]?.name ?? ''}` : ''}`;
  const canIssue = b => canAt('inventory.issue', b.branch_id, b.raw_warehouse_id) || canAt('production.create', b.branch_id, null);

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
      description={branchId ? `Batches cast at ${branchName}: materials used, pieces cast, curing and quality release.` : 'Batches cast at every branch: materials used, pieces cast, curing and quality release.'}
      primaryAction={canRecord && (
        <button type="button" className="btn btn-primary" disabled={!refs} onClick={() => setRecording(true)}>
          <Plus size={14} /> Record batch
        </button>
      )}>
      <PageTabs value={tab} onChange={setTab} tabs={[
        ['curing', `Curing (${curing.length})`],
        ...(waitingMaterials.length ? [['materials', `Materials to issue (${waitingMaterials.length})`]] : []),
        ['done', 'Released & void'],
        ['variance', 'Material variance'],
      ]} />
      {rowError && <div className="alert alert-error mb-8" role="alert">{rowError}</div>}

      <div className="card">
        {error ? <ErrorState message={error} onRetry={load} /> : tab === 'variance' ? (
          <VarianceTable rows={variance.filter(v => inBranch(v.branch_id))} refs={refs} loading={loading} />
        ) : (
          <div className="table-container">
            <table>
              <thead><tr>
                <th>Date</th><th>Product</th><th style={{ textAlign: 'right' }}>Bags</th><th style={{ textAlign: 'right' }}>Pieces</th>
                <th>Yield check</th><th>{tab === 'done' ? 'Released' : 'Curing until'}</th><th>Status</th><th aria-label="Actions" />
              </tr></thead>
              <tbody>
                {loading ? <SkeletonRow cols={8} /> : shown.length === 0 ? (
                  <tr><td colSpan={8}><EmptyState icon={Factory}
                    title={tab === 'curing' ? 'Nothing curing' : tab === 'materials' ? 'No materials waiting' : 'No released batches yet'}
                    description={tab === 'curing' ? 'Batches cast appear here until their quality release.' : ''} /></td></tr>
                ) : shown.map(b => {
                  const flagged = flags[b.id];
                  const inBand = b.yield_min == null ? null : b.pieces_cast >= b.yield_min && b.pieces_cast <= b.yield_max;
                  const rejected = (b.rejects || []).reduce((s, r) => s + r.pieces, 0);
                  return (
                    <tr key={b.id} className={b.status === 'void' ? 'text-muted' : ''}>
                      <td>{b.batch_date}<div className="text-xs text-muted">{people[b.created_by] ?? ''}</div></td>
                      <td style={{ fontWeight: 500 }}>{productName(b)}</td>
                      <td style={{ textAlign: 'right' }}>{qtyText(b.cement_bags)}</td>
                      <td style={{ textAlign: 'right' }}>
                        {qtyText(b.pieces_cast)}
                        {b.status === 'released' && <div className="text-xs text-muted">{b.pieces_passed} passed{rejected ? ` · ${rejected} rejected` : ''}</div>}
                      </td>
                      <td>
                        {inBand == null ? <span className="text-xs text-muted">No yield per bag set</span>
                          : inBand ? <span className="badge badge-success">In band</span>
                          : <span className="badge badge-warning" title={flagged}>Outside {Math.round(b.yield_min)}–{Math.round(b.yield_max)}</span>}
                      </td>
                      <td>{b.status === 'released' ? b.released_on : b.status === 'void' ? '—' : (
                        <>{b.curing_until}{b.curing_until <= today && <div className="text-xs" style={{ color: 'var(--color-success)' }}>Ready to release</div>}</>
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

      {recording && refs && (
        <BatchModal refs={refs} recipes={recipes} branchId={branchId} curingDays={curingDays} today={today}
          onClose={() => setRecording(false)} onSaved={async () => { setRecording(false); setTab('curing'); await load(); }} />
      )}
      {releasing && refs && (
        <ReleaseModal batch={releasing} name={productName(releasing)} refs={refs} reasons={reasons} today={today}
          onClose={() => setReleasing(null)} onSaved={async () => { setReleasing(null); await load(); }} />
      )}
      {voiding && (
        <VoidModal batch={voiding} name={productName(voiding)} onClose={() => setVoiding(null)} onSaved={async () => { setVoiding(null); await load(); }} />
      )}
    </PageShell>
  );
}

/** Record one batch: product, bags, pieces, and its materials (counted / from the recipe) */
function BatchModal({ refs, recipes, branchId, curingDays, today, onClose, onSaved }) {
  const { canAt } = useAuth();
  const stores = refs.warehouses.filter(w => w.status === 'active' && w.branch_id === branchId);
  const rawStores = stores.filter(w => w.type === 'raw_materials' || w.type === 'general');
  const curingStore = stores.find(w => w.type === 'wip');
  const canBackdate = canAt('inventory.adjust', branchId, null);
  const products = useMemo(() => Object.values(refs.items)
    .filter(i => i.kind === 'product' && i.status === 'active' && refs.carriedByBranch?.[branchId]?.has(i.id))
    .sort((a, b) => a.name.localeCompare(b.name)), [refs, branchId]);

  const [date,     setDate]     = useState(today);
  const [productId, setProductId] = useState('');
  const [colorId,  setColorId]  = useState('');
  const [rawId,    setRawId]    = useState(rawStores.find(w => w.type === 'raw_materials')?.id ?? rawStores[0]?.id ?? '');
  const [bags,     setBags]     = useState('');
  const [pieces,   setPieces]   = useState('');
  const [notes,    setNotes]    = useState('');
  const [issueNow, setIssueNow] = useState(true);
  const [lines,    setLines]    = useState([]);   // { materialId, unitId, perBag, quantity, source, counted }
  const [band,     setBand]     = useState(null);
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');

  const product = refs.items[`p:${productId}`];
  const colours = product?.colorIds || [];
  // The branch's active recipe for the product's category + colour (the server picks the same)
  const recipe = useMemo(() => {
    if (!product || (colours.length && !colorId)) return null;
    const c = recipes.filter(r => r.branch_id === branchId && r.category_id === product.categoryId && (r.color_id ?? '') === (colorId || ''));
    return c.sort((a, b) => (b.products.some(x => x.product_id === product.id) - a.products.some(x => x.product_id === product.id))
      || String(b.effective_date ?? '').localeCompare(String(a.effective_date ?? '')) || b.version_number - a.version_number)[0] ?? null;
  }, [product, colorId, recipes, branchId, colours.length]);

  // A new recipe: its lines, cement (bags) counted, the rest from the recipe
  useEffect(() => {
    setLines((recipe?.items || []).map(it => {
      const isBag = refs.unitById[it.unit_id]?.symbol?.toLowerCase() === 'bag' && Number(it.quantity) === 1;
      return { materialId: it.material_id, unitId: it.unit_id, perBag: Number(it.quantity), quantity: '', source: isBag ? 'counted' : 'recipe', bagLine: isBag, edited: false };
    }));
  }, [recipe, refs]);
  // Recipe figures follow the bags until edited; the cement line is the bags
  const b = num(bags);
  const shownQty = l => (l.edited ? l.quantity : b != null ? String(round(l.perBag * b)) : '');

  useEffect(() => {
    if (!productId || !branchId) { setBand(null); return; }
    let live = true;
    supabase.rpc('product_yield_band', { p_product_id: productId, p_branch_id: branchId }).then(({ data }) => { if (live) setBand(data?.[0] ?? null); });
    return () => { live = false; };
  }, [productId, branchId]);
  const expMin = band?.yield_min != null && b != null ? Math.round(b * band.yield_min) : null;
  const expMax = band?.yield_max != null && b != null ? Math.round(b * band.yield_max) : null;
  const p = num(pieces);
  const outOfBand = expMin != null && p != null && (p < expMin || p > expMax);

  async function save(e) {
    e.preventDefault();
    setError('');
    if (!productId) { setError('Choose the product.'); return; }
    if (colours.length && !colorId) { setError('Choose the colour.'); return; }
    if (!recipe) { setError(`No active recipe for this product${colorId ? ' and colour' : ''} at this branch — add one under Recipes.`); return; }
    if (!curingStore) { setError('This branch has no curing store.'); return; }
    if (!(b > 0)) { setError('Enter the bags of cement used.'); return; }
    if (p == null || p < 0 || !Number.isInteger(p)) { setError('Enter the pieces cast (a whole number).'); return; }
    const mats = lines.map(l => ({ material_id: l.materialId, unit_id: l.unitId, quantity: num(shownQty(l)) ?? 0,
      source: l.bagLine || l.edited ? 'counted' : 'recipe' }));
    if (mats.some(m => !(m.quantity >= 0))) { setError('Material quantities must be zero or more.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('record_production_batch', { p: {
      batch_date: date, product_id: productId, color_id: colorId || null, recipe_version_id: recipe.id,
      raw_warehouse_id: rawId, curing_warehouse_id: curingStore.id, cement_bags: b, pieces_cast: p,
      notes: notes.trim() || null, issue_materials: issueNow, materials: mats,
    } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't record this batch. Please try again.")); return; }
    onSaved();
  }

  return (
    <Modal title="Record batch" onClose={onClose} size="lg"
      footer={<>
        {error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="batch-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy}>Record batch</button>
      </>}>
      <form id="batch-form" className="modal-form" onSubmit={save}>
        <p className="text-sm text-muted">One mix: one product, one colour, cast together. Several mixes a day are several batches.</p>
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="bt-date">Date</label>
            <input id="bt-date" type="date" className="form-input" max={today} value={date} disabled={!canBackdate} onChange={e => setDate(e.target.value)} />
            {!canBackdate && <span className="form-hint">Today — an earlier date needs an admin.</span>}
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="bt-raw">Materials from</label>
            <select id="bt-raw" className="form-input" value={rawId} onChange={e => setRawId(e.target.value)}>
              {rawStores.map(w => <option key={w.id} value={w.id}>{w.name}</option>)}
            </select>
          </div>
        </div>
        <div className="form-row">
          <div className="form-group" style={{ flex: 2 }}>
            <label className="form-label" htmlFor="bt-product">Product</label>
            <select id="bt-product" className="form-input" value={productId} onChange={e => { setProductId(e.target.value); setColorId(''); }}>
              <option value="" disabled>Choose…</option>
              {products.map(i => <option key={i.id} value={i.id}>{i.name} · {i.category}</option>)}
            </select>
          </div>
          {colours.length > 0 && (
            <div className="form-group">
              <label className="form-label" htmlFor="bt-colour">Colour</label>
              <select id="bt-colour" className="form-input" value={colorId} onChange={e => setColorId(e.target.value)}>
                <option value="" disabled>Choose…</option>
                {colours.map(c => <option key={c} value={c}>{refs.colorById[c]?.name}</option>)}
              </select>
            </div>
          )}
        </div>
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="bt-bags">Bags of cement (counted)</label>
            <NumberInput id="bt-bags" step="any" min="0" className="form-input" placeholder="e.g. 4 or 0.5" value={bags} onChange={e => setBags(e.target.value)} />
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="bt-pieces">Pieces cast</label>
            <NumberInput id="bt-pieces" step="1" min="0" className="form-input" value={pieces} onChange={e => setPieces(e.target.value)} />
            {expMin != null && (
              <span className={`form-hint${outOfBand ? ' text-warning' : ''}`}>
                Expected {expMin}–{expMax} ({+band.average_yield_per_bag} ± {+band.yield_tolerance} per bag).{outOfBand ? ' Outside the band — it will be flagged for review.' : ''}
              </span>
            )}
            {productId && band && band.yield_min == null && <span className="form-hint">No yield per bag set for this size — no check.</span>}
          </div>
        </div>

        <section>
          <h3 className="modal-section-title">Materials used</h3>
          {!productId ? <p className="text-sm text-muted">Choose the product first.</p>
            : !recipe ? <p className="text-sm text-warning">No active recipe for this {colours.length && !colorId ? 'product — choose the colour' : 'product at this branch — add one under Recipes'}.</p>
            : (
              <>
                <div className="table-container">
                  <table>
                    <thead><tr><th>Material</th><th style={{ textAlign: 'right' }}>Recipe × bags</th><th>Used</th><th>From</th></tr></thead>
                    <tbody>
                      {lines.map((l, i) => {
                        const sym = refs.unitById[l.unitId]?.symbol ?? '';
                        return (
                          <tr key={l.materialId}>
                            <td style={{ fontWeight: 500 }}>{refs.items[`m:${l.materialId}`]?.name ?? '—'}</td>
                            <td style={{ textAlign: 'right' }} className="text-muted">{b != null ? `${qtyText(round(l.perBag * b))} ${sym}` : `${qtyText(l.perBag)} ${sym} per bag`}</td>
                            <td>
                              <span className="flex items-center gap-4">
                                <NumberInput step="any" min="0" className="form-input" style={{ width: 110 }} aria-label={`${refs.items[`m:${l.materialId}`]?.name} used`}
                                  value={l.bagLine && !l.edited ? (bags ?? '') : shownQty(l)}
                                  onChange={e => setLines(ls => ls.map((x, j) => (j === i ? { ...x, quantity: e.target.value, edited: true } : x)))} />
                                <span className="text-xs text-muted">{sym}</span>
                              </span>
                            </td>
                            <td>
                              {l.bagLine || l.edited ? <span className="badge badge-accent">Counted</span> : <span className="badge badge-neutral">Recipe</span>}
                              {l.edited && !l.bagLine && (
                                <button type="button" className="btn btn-ghost btn-sm" onClick={() => setLines(ls => ls.map((x, j) => (j === i ? { ...x, quantity: '', edited: false } : x)))}>Use recipe</button>
                              )}
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
                <p className="text-xs text-muted mt-8">Cement is counted. The rest follows the recipe × bags until you type what was actually used. Stock counts later show how close the recipe figures are (Material variance).</p>
                <label className="text-sm flex items-center gap-8 mt-8">
                  <input type="checkbox" checked={issueNow} onChange={e => setIssueNow(e.target.checked)} />
                  Take these materials out of {refs.warehouses.find(w => w.id === rawId)?.name ?? 'the store'} now
                </label>
                {!issueNow && <span className="form-hint">The storekeeper issues them later (Materials to issue).</span>}
              </>
            )}
        </section>

        <div className="form-group">
          <label className="form-label" htmlFor="bt-notes">Notes (optional)</label>
          <input id="bt-notes" className="form-input" value={notes} onChange={e => setNotes(e.target.value)} />
        </div>
        {curingStore && <p className="text-xs text-muted">The pieces go into {warehouseLabel(curingStore)} — not sellable until released after {curingDays} days of curing.</p>}
      </form>
    </Modal>
  );
}

/** Quality release: every cast piece passes or is rejected with a reason */
function ReleaseModal({ batch, name, refs, reasons, today, onClose, onSaved }) {
  const fgStores = refs.warehouses.filter(w => w.status === 'active' && w.branch_id === batch.branch_id && w.type === 'finished_goods');
  const [fgId, setFgId] = useState(fgStores[0]?.id ?? '');
  const [date, setDate] = useState(today);
  const [passed, setPassed] = useState('');
  const [rejects, setRejects] = useState({});
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const active = reasons.filter(r => r.status === 'active');
  const rejected = Object.values(rejects).reduce((s, v) => s + (num(v) ?? 0), 0);
  const early = date < batch.curing_until;

  async function save(e) {
    e.preventDefault();
    setError('');
    const pp = num(passed);
    if (pp == null || pp < 0) { setError('Enter the pieces that passed.'); return; }
    if (pp + rejected !== batch.pieces_cast) { setError(`Passed and rejected must add up to the ${batch.pieces_cast} pieces cast.`); return; }
    if (early && !note.trim()) { setError(`Curing runs until ${batch.curing_until} — say why it is released early.`); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('release_production_batch', { p_batch: batch.id, p: {
      fg_warehouse_id: fgId, release_date: date, pieces_passed: pp, note: note.trim() || null,
      rejects: Object.entries(rejects).filter(([, v]) => num(v) > 0).map(([reason_id, v]) => ({ reason_id, pieces: num(v) })),
    } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't release this batch. Please try again.")); return; }
    onSaved();
  }

  return (
    <Modal title={`Release ${name} · ${batch.batch_date}`} onClose={onClose}
      footer={<>
        {error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="release-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy}>Release</button>
      </>}>
      <form id="release-form" className="modal-form" onSubmit={save}>
        <p className="text-sm text-muted">{batch.pieces_cast} pieces cast · curing until {batch.curing_until}. Passed pieces move into Finished Goods; rejected ones leave stock.</p>
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="rl-passed">Passed</label>
            <NumberInput id="rl-passed" step="1" min="0" className="form-input" value={passed} onChange={e => setPassed(e.target.value)} />
          </div>
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
        <section>
          <h3 className="modal-section-title">Rejected</h3>
          <div className="form-row" style={{ flexWrap: 'wrap' }}>
            {active.map(r => (
              <div key={r.id} className="form-group" style={{ minWidth: 120 }}>
                <label className="form-label" htmlFor={`rj-${r.id}`}>{r.name}</label>
                <NumberInput id={`rj-${r.id}`} step="1" min="0" className="form-input" placeholder="0" value={rejects[r.id] ?? ''}
                  onChange={e => setRejects(x => ({ ...x, [r.id]: e.target.value }))} />
              </div>
            ))}
          </div>
          <p className={`text-sm${num(passed) != null && num(passed) + rejected !== batch.pieces_cast ? ' text-warning' : ' text-muted'}`}>
            {num(passed) ?? 0} passed + {rejected} rejected = {(num(passed) ?? 0) + rejected} of {batch.pieces_cast} cast
          </p>
        </section>
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
