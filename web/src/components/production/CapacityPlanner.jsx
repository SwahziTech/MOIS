import { useEffect, useMemo, useState } from 'react';
import { Plus, Trash2, AlertTriangle, Gauge, Factory, ClipboardList, Pencil } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import { qtyText, byMaterialOrder } from '../../lib/inventory';
import { categoryTools, productOrder } from '../../lib/categories';
import NumberInput from '../NumberInput';
import ProductPicker from './ProductPicker';

const num = v => (String(v ?? '').trim() === '' ? null : Number(v));
const round = (n, d = 2) => Math.round(n * 10 ** d) / 10 ** d;
const addDays = (iso, n) => new Date(new Date(`${iso}T00:00:00Z`).getTime() + n * 864e5).toISOString().slice(0, 10);
const STATUS_LABEL = { open: 'Open', completed: 'Completed', cancelled: 'Cancelled' };

/**
 * Production orders (048) with the capacity simulator (045) that plans them.
 * The simulator turns a target (m² or pieces) into casting days, a
 * ready-by date and the raw materials needed; "Add to order" puts it on a
 * new or open order. Each order shows, per product, planned · cast ·
 * curing · passed · rejected, and whether it can be ready by its due date
 * with the branch's molds. An order completes itself when every line's
 * passed pieces reach the plan. Branch managers and admins plan orders;
 * batches count towards them from the production form.
 */
export default function CapacityPlanner({ refs, recipes, branchId, today, usage = {}, onOpenForm }) {
  const { canAt, organization } = useAuth();
  const canPlan = canAt('production.plan', branchId, null);
  const [capacity, setCapacity] = useState({});   // product id → { molds, bags_per_day_min, bags_per_day_max }
  const [bands, setBands] = useState({});
  const [stock, setStock] = useState({});
  const [sizes, setSizes] = useState({});
  const [wastani, setWastani] = useState({});
  const [perSqm, setPerSqm] = useState({});       // product id → pieces per m²
  const [curingDays, setCuringDays] = useState(14);
  const [orders, setOrders] = useState(null);     // null = loading; false = 048 not live
  const [progress, setProgress] = useState({});   // line id → { cast_pieces, curing, passed, rejected }
  const [show, setShow] = useState('open');
  const [draft, setDraft] = useState(null);       // { id?, order_no?, reference, due_date, notes, lines: [{ productId, colorId, pieces, sqm }] }
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [note, setNote] = useState('');
  // the simulator: one product and a target
  const [sim, setSim] = useState({ productId: '', colorId: '', target: '', unit: 'pcs' });   // target in sim.unit: 'sqm' | 'pcs'
  const [simPicking, setSimPicking] = useState(false);
  const rawStore = refs.warehouses.find(w => w.status === 'active' && w.branch_id === branchId && w.type === 'raw_materials');

  useEffect(() => {
    let live = true;
    Promise.all([
      supabase.from('organizations').select('curing_days').eq('id', organization.id).maybeSingle(),
      supabase.from('branch_product_capacity').select('product_id, molds, bags_per_day_min, bags_per_day_max').eq('branch_id', branchId),
      rawStore ? supabase.from('stock_balances').select('material_id, quantity').eq('warehouse_id', rawStore.id).not('material_id', 'is', null) : Promise.resolve({ data: [] }),
      supabase.from('product_specs').select('product_id, spec_id, average_yield_per_bag, pcs_per_sqm'),
      supabase.from('product_size_specs').select('id, size_cm'),
    ]).then(([o, c, st, ps, ss]) => {
      if (!live) return;
      if (o.data?.curing_days != null) setCuringDays(o.data.curing_days);
      setCapacity(Object.fromEntries((c.data || []).map(x => [x.product_id, x])));
      setStock(Object.fromEntries((st.data || []).map(x => [x.material_id, Number(x.quantity)])));
      const sizeOf = Object.fromEntries((ss.data || []).map(x => [x.id, x.size_cm]));
      setWastani(Object.fromEntries((ps.data || []).map(x => [x.product_id, x.average_yield_per_bag])));
      setPerSqm(Object.fromEntries((ps.data || []).filter(x => Number(x.pcs_per_sqm) > 0).map(x => [x.product_id, Number(x.pcs_per_sqm)])));
      setSizes(Object.fromEntries((ps.data || []).filter(x => sizeOf[x.spec_id]).map(x => [x.product_id, sizeOf[x.spec_id]])));
    });
    return () => { live = false; };
  }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  async function loadOrders() {
    const { data, error: err } = await supabase.from('production_orders')
      .select('*, lines:production_order_lines(id, product_id, color_id, pieces, sqm, display_order)')
      .eq('branch_id', branchId).order('order_no', { ascending: false });
    if (err) { setOrders(false); return; }
    setOrders(data || []);
    const ids = (data || []).map(o => o.id);
    if (!ids.length) { setProgress({}); return; }
    const { data: g } = await supabase.from('production_order_line_progress').select('*').in('order_id', ids);
    setProgress(Object.fromEntries((g || []).map(x => [x.line_id, x])));
  }
  useEffect(() => { setOrders(null); setDraft(null); loadOrders(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  // each product's yield band at this branch (the branch's own wastani wins)
  useEffect(() => {
    [sim.productId, ...(draft?.lines || []).map(l => l.productId)].filter(Boolean).forEach(async id => {
      if (bands[id] !== undefined) return;
      const { data } = await supabase.rpc('product_yield_band', { p_product_id: id, p_branch_id: branchId });
      setBands(b => ({ ...b, [id]: data?.[0] ?? null }));
    });
  }); // eslint-disable-line react-hooks/exhaustive-deps

  const cats = useMemo(() => categoryTools(refs.categoryRows), [refs]);
  const carried = useMemo(() => Object.values(refs.items)
    .filter(i => i.kind === 'product' && i.status === 'active' && refs.carriedByBranch?.[branchId]?.has(i.id))
    .map(i => ({ ...i, size: i.size || sizes[i.id] })).sort(productOrder(cats)), [refs, branchId, cats, sizes]);
  const recipeFor = (item, colorId) => recipes
    .filter(r => r.branch_id === branchId && r.category_id === item.categoryId && (r.color_id ?? '') === (colorId || ''))
    .sort((a, b) => (b.products.some(x => x.product_id === item.id) - a.products.some(x => x.product_id === item.id)) || b.version_number - a.version_number)[0] ?? null;
  const factorOf = (materialId, unitId) => {
    const it = refs.items[`m:${materialId}`];
    return it?.units.find(u => u.id === unitId)?.factor ?? (unitId === it?.stockUnitId ? 1 : null);
  };
  const nameOf = (productId, colorId) => `${refs.items[`p:${productId}`]?.name ?? '—'}${colorId ? ` ${refs.colorById[colorId]?.name ?? ''}` : ''}`;

  // ---- simulator: target pieces → casting days, curing, materials
  const simItem = refs.items[`p:${sim.productId}`];
  const simW = bands[sim.productId]?.average_yield_per_bag;
  const simCap = capacity[sim.productId];
  // the target is typed in m² when the product has pieces per m², and worked in pieces
  const simPerSqm = perSqm[sim.productId];
  const inSqm = sim.unit === 'sqm' && simPerSqm > 0;
  const typed = num(sim.target) ?? 0;
  const target = inSqm ? Math.ceil(typed * simPerSqm - 1e-9) : typed;
  const simBags = simW > 0 ? target / simW : null;
  // Molds are the only daily limit; a press product's bags a day is a guide only
  const perDayMax = simCap?.molds ?? null;
  const days = perDayMax ? Math.ceil(target / perDayMax) : null;
  const readyBy = days ? addDays(today, days - 1 + curingDays) : null;
  const simRecipe = simItem && (!simItem.colorIds?.length || sim.colorId) ? recipeFor(simItem, sim.colorId) : null;
  const simMaterials = !simRecipe || simBags == null ? [] : simRecipe.items
    .filter(it => refs.items[`m:${it.material_id}`]?.inRecipes !== false)
    .map(it => {
      const qty = Number(it.quantity) * simBags;
      const f = factorOf(it.material_id, it.unit_id);
      const have = f ? (stock[it.material_id] ?? 0) / f : null;
      return { item: refs.items[`m:${it.material_id}`] ?? { name: '—' }, qty, unit: refs.unitById[it.unit_id]?.symbol ?? '', short: have != null && qty > have + 1e-9, shortBy: have != null ? qty - have : 0 };
    })
    .sort((a, b) => byMaterialOrder(a.item, b.item));
  const capLine = simCap?.molds ? `${qtyText(simCap.molds)} molds${simItem?.size ? ` (${simItem.size})` : ''} — ${qtyText(simCap.molds)} pcs a day`
    : simCap?.bags_per_day_max || simCap?.bags_per_day_min ? `About ${qtyText(simCap.bags_per_day_min ?? simCap.bags_per_day_max)}–${qtyText(simCap.bags_per_day_max ?? simCap.bags_per_day_min)} bags a day — a guide, not a limit`
    : null;
  const simReady = simItem && target > 0 && (!simItem.colorIds?.length || sim.colorId);

  // ---- orders
  function addToOrder() {
    if (!simReady) return;
    const line = { productId: sim.productId, colorId: sim.colorId || '', pieces: String(target), sqm: inSqm ? String(typed) : '' };
    setNote(''); setError('');
    setDraft(d => {
      const base = d ?? { reference: '', due_date: '', notes: '', lines: [] };
      const at = base.lines.findIndex(l => l.productId === line.productId && (l.colorId || '') === line.colorId);
      const lines = at >= 0
        ? base.lines.map((l, i) => (i === at ? { ...l, pieces: String((num(l.pieces) ?? 0) + target), sqm: '' } : l))
        : [...base.lines, line];
      return { ...base, lines };
    });
    setSim(x => ({ ...x, target: '' }));
  }
  function editOrder(o) {
    setNote(''); setError('');
    setDraft({ id: o.id, order_no: o.order_no, reference: o.reference ?? '', due_date: o.due_date ?? '', notes: o.notes ?? '',
      lines: [...o.lines].sort((a, b) => a.display_order - b.display_order)
        .map(l => ({ productId: l.product_id, colorId: l.color_id ?? '', pieces: String(l.pieces), sqm: l.sqm != null ? String(l.sqm) : '' })) });
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }
  const setLine = (i, patch) => setDraft(d => ({ ...d, lines: d.lines.map((l, j) => (j === i ? { ...l, ...patch } : l)) }));

  async function saveOrder() {
    setError(''); setNote('');
    setBusy(true);
    const { error: err } = await supabase.rpc('save_production_order', { p: {
      id: draft.id ?? null, branch_id: branchId, reference: draft.reference, due_date: draft.due_date || null, notes: draft.notes,
      lines: draft.lines.map(l => ({ product_id: l.productId, color_id: l.colorId || null, pieces: num(l.pieces), sqm: num(l.sqm) })),
    } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't save the order. Please try again.")); return; }
    setNote(draft.id ? `Order ${draft.order_no} saved.` : 'Order saved.');
    setDraft(null);
    loadOrders();
  }
  async function setStatus(o, status) {
    setError(''); setNote('');
    const why = status === 'cancelled' ? window.prompt(`Cancel order ${o.order_no}? Say why (optional):`, '') : '';
    if (why === null) return;
    const { error: err } = await supabase.rpc('set_production_order_status', { p_order: o.id, p_status: status, p_note: why || null });
    if (err) { setError(dbErrorMessage(err)); return; }
    loadOrders();
  }

  // How each order stands: per line what is left to cast, and whether the molds can make the due date
  const shownOrders = (orders || []).filter(o => o.status === show);
  const counts = (orders || []).reduce((m, o) => ({ ...m, [o.status]: (m[o.status] ?? 0) + 1 }), {});
  function standing(o) {
    let lastReady = null, unknown = false, anyLeft = false;
    const lines = [...o.lines].sort((a, b) => a.display_order - b.display_order).map(l => {
      const g = progress[l.id] ?? { cast_pieces: 0, curing: 0, passed: 0, rejected: 0 };
      const toCast = Math.max(0, l.pieces - g.passed - g.curing);
      const molds = capacity[l.product_id]?.molds;
      if (toCast > 0) {
        anyLeft = true;
        if (molds) { const r = addDays(today, Math.ceil(toCast / molds) - 1 + curingDays); if (!lastReady || r > lastReady) lastReady = r; }
        else unknown = true;
      }
      return { ...l, ...g, toCast, pct: Math.min(100, Math.round((g.passed / l.pieces) * 100)), curingPct: Math.min(100, Math.round(((g.passed + g.curing) / l.pieces) * 100)) };
    });
    const late = o.status === 'open' && o.due_date && lastReady && lastReady > o.due_date;
    return { lines, lastReady, unknown, anyLeft, late };
  }

  return (
    <div className="pl">
      {simPicking && (
        <ProductPicker title="Select finished product" items={carried} cats={cats} usage={usage} wastani={wastani} capacity={capacity}
          onClose={() => setSimPicking(false)} onPick={id => { setSimPicking(false); setSim(x => ({ ...x, productId: id, colorId: '', target: '', unit: perSqm[id] > 0 ? 'sqm' : 'pcs' })); }} />
      )}

      {/* ---- orders ---- */}
      <section className="pl-card">
        <div className="pl-subhead">
          <h3 className="pl-title"><ClipboardList size={14} /> Production orders</h3>
          <div className="flex gap-8 items-center" style={{ flexWrap: 'wrap' }}>
            {['open', 'completed', 'cancelled'].map(s => (
              <button key={s} type="button" className={`filter-chip${show === s ? ' is-on' : ''}`} onClick={() => setShow(s)}>{STATUS_LABEL[s]}{counts[s] ? ` (${counts[s]})` : ''}</button>
            ))}
            {canPlan && orders !== false && !draft && <button type="button" className="btn btn-primary btn-sm" onClick={() => setDraft({ reference: '', due_date: '', notes: '', lines: [] })}><Plus size={13} /> New order</button>}
          </div>
        </div>
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        {note && <p className="text-sm text-success" role="status">{note}</p>}
        {orders === null ? <span className="skeleton" />
          : orders === false ? <div className="pl-empty">Production orders aren't switched on yet (migration 048).</div>
          : shownOrders.length === 0 ? <div className="pl-empty">{show === 'open' ? (canPlan ? 'No open orders — plan one with the simulator below, then "Add to order".' : 'No open orders.') : `No ${STATUS_LABEL[show].toLowerCase()} orders.`}</div>
          : shownOrders.map(o => {
            const st = standing(o);
            return (
              <div key={o.id} className="po">
                <div className="po-head">
                  <strong>Order {o.order_no}</strong>
                  {o.reference && <span>{o.reference}</span>}
                  {o.due_date && <span className="pl-help">due {o.due_date}</span>}
                  {o.status === 'open' && (st.late ? <span className="pl-badge is-out">At risk — ready about {st.lastReady}</span>
                    : st.anyLeft && st.lastReady && !st.unknown ? <span className="pl-badge">On track — ready about {st.lastReady}</span>
                    : st.anyLeft && st.unknown ? <span className="pl-badge is-plain">No mold count for some products</span>
                    : !st.anyLeft ? <span className="pl-badge is-plain">All cast — waiting for quality release</span> : null)}
                  {o.status !== 'open' && <span className="pl-badge is-plain">{STATUS_LABEL[o.status]}{o.close_note ? ` — ${o.close_note}` : ''}</span>}
                  {canPlan && (
                    <span className="po-actions">
                      {o.status === 'open' && <button type="button" className="btn btn-ghost btn-sm" onClick={() => editOrder(o)}><Pencil size={13} /> Edit</button>}
                      {o.status === 'open' && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setStatus(o, 'completed')}>Mark done</button>}
                      {o.status === 'open' && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setStatus(o, 'cancelled')}>Cancel</button>}
                      {o.status !== 'open' && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setStatus(o, 'open')}>Reopen</button>}
                    </span>
                  )}
                </div>
                <div className="table-container">
                  <table className="po-table">
                    <thead><tr><th>Product</th><th className="num">Planned</th><th className="num">Cast</th><th className="num">Curing</th><th className="num">Passed</th><th className="num">Rejected</th><th className="num">To cast</th><th /></tr></thead>
                    <tbody>
                      {st.lines.map(l => (
                        <tr key={l.id}>
                          <td>
                            {nameOf(l.product_id, l.color_id)}
                            <div className="po-bar" title={`${l.pct}% passed`}><i className="po-cure" style={{ width: `${l.curingPct}%` }} /><i style={{ width: `${l.pct}%` }} /></div>
                          </td>
                          <td className="num">{qtyText(l.pieces)}{l.sqm != null && <div className="pl-help">{qtyText(l.sqm)} m²</div>}</td>
                          <td className="num">{qtyText(l.cast_pieces)}</td>
                          <td className="num">{qtyText(l.curing)}</td>
                          <td className="num"><strong>{qtyText(l.passed)}</strong></td>
                          <td className="num">{l.rejected ? qtyText(l.rejected) : '—'}</td>
                          <td className="num">{l.toCast ? <strong>{qtyText(l.toCast)}</strong> : '—'}</td>
                          <td className="num">
                            {o.status === 'open' && l.toCast > 0 && (
                              <button type="button" className="btn btn-ghost btn-sm" title="Load what is left into the simulator"
                                onClick={() => { setSim({ productId: l.product_id, colorId: l.color_id ?? '', target: String(l.toCast), unit: 'pcs' }); document.querySelector('.sim')?.scrollIntoView({ behavior: 'smooth' }); }}>Plan rest</button>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
                {o.notes && <p className="pl-help">{o.notes}</p>}
              </div>
            );
          })}
      </section>

      {/* ---- the order being written ---- */}
      {draft && (
        <section className="pl-card po-draft">
          <div className="pl-subhead">
            <h3 className="pl-title">{draft.id ? `Edit order ${draft.order_no}` : 'New order'}</h3>
            <span className="pl-help">Add products with the simulator below.</span>
          </div>
          <div className="po-fields">
            <label className="po-field"><span className="pl-label">Customer / reference</span>
              <input className="form-input" value={draft.reference} placeholder="e.g. Mr Juma — house in Area D" onChange={e => setDraft(d => ({ ...d, reference: e.target.value }))} /></label>
            <label className="po-field"><span className="pl-label">Due date</span>
              <input type="date" className="form-input" value={draft.due_date} min={today} onChange={e => setDraft(d => ({ ...d, due_date: e.target.value }))} /></label>
          </div>
          {draft.lines.length === 0 ? <div className="pl-empty">No products yet — choose one in the simulator, set the target, then "Add to order".</div> : (
            <div className="po-lines">
              {draft.lines.map((l, i) => {
                const per = perSqm[l.productId];
                return (
                  <div key={`${l.productId}|${l.colorId}`} className="po-line">
                    <span className="po-line-name">{nameOf(l.productId, l.colorId)}</span>
                    <NumberInput step="1" min="0" className="form-input po-pcs" aria-label={`${nameOf(l.productId, l.colorId)} pieces`} value={l.pieces}
                      onChange={e => setLine(i, { pieces: e.target.value, sqm: '' })} />
                    <span className="pl-help">pcs{per > 0 && num(l.pieces) > 0 ? ` · ${qtyText(round(num(l.pieces) / per))} m²` : ''}</span>
                    <button type="button" className="icon-btn" aria-label="Remove" onClick={() => setDraft(d => ({ ...d, lines: d.lines.filter((_, j) => j !== i) }))}><Trash2 size={14} /></button>
                  </div>
                );
              })}
            </div>
          )}
          <textarea className="form-input" rows={2} placeholder="Notes (optional)" value={draft.notes} onChange={e => setDraft(d => ({ ...d, notes: e.target.value }))} />
          <div className="flex gap-8">
            <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !draft.lines.length} onClick={saveOrder}>{draft.id ? 'Save changes' : 'Save order'}</button>
            <button type="button" className="btn btn-ghost" onClick={() => { setDraft(null); setError(''); }}>Cancel</button>
          </div>
        </section>
      )}

      {/* ---- simulator ---- */}
      <section className="pl-card sim">
        <div className="sim-head">
          <Gauge size={20} className="sim-icon" />
          <div><h3 className="sim-title">Production capacity &amp; mix simulator</h3>
            <p className="pl-help">Order size → casting days, curing and raw materials needed.</p></div>
        </div>
        <div className="sim-inputs">
          <div className="sim-field">
            <span className="pl-label">1. Finished product</span>
            <div className="sim-pick">
              <button type="button" className="btn btn-outline sim-product" onClick={() => setSimPicking(true)}>
                {simItem ? <>{simItem.name} <span className="pl-help">({simItem.category}{simCap?.molds ? ` · ${qtyText(simCap.molds)} molds` : ''})</span></> : 'Choose product…'}
              </button>
              {simItem?.colorIds?.length > 0 && (
                <select className="form-input sim-colour" aria-label="Colour" value={sim.colorId} onChange={e => setSim(x => ({ ...x, colorId: e.target.value }))}>
                  <option value="">Colour…</option>
                  {simItem.colorIds.map(c => <option key={c} value={c}>{refs.colorById[c]?.name}</option>)}
                </select>
              )}
            </div>
          </div>
          <div className="sim-field">
            <span className="pl-label">2. Target output</span>
            <div className="sim-pick">
              <NumberInput step="any" min="0" className="form-input sim-target" placeholder="0" aria-label="Target output" value={sim.target} onChange={e => setSim(x => ({ ...x, target: e.target.value }))} />
              {simPerSqm > 0 ? (
                <select className="form-input sim-colour" aria-label="Unit" value={inSqm ? 'sqm' : 'pcs'}
                  onChange={e => setSim(x => {
                    const v = num(x.target);
                    if (v == null) return { ...x, unit: e.target.value };
                    // keep the same amount: m² ↔ pieces at the product's pieces per m²
                    return { ...x, unit: e.target.value, target: String(e.target.value === 'sqm' ? round(v / simPerSqm) : Math.ceil(v * simPerSqm - 1e-9)) };
                  })}>
                  <option value="sqm">m²</option>
                  <option value="pcs">pcs</option>
                </select>
              ) : <span className="sim-unit">pcs</span>}
            </div>
            {simPerSqm > 0 && typed > 0 && (
              <span className="pl-help">{inSqm ? `= ${qtyText(target)} pcs` : `= ${qtyText(round(typed / simPerSqm))} m²`} · {+simPerSqm} pcs/m²</span>
            )}
          </div>
        </div>
        <div className="sim-presets">
          <span className="pl-help">Quick:</span>
          {(inSqm ? [10, 25, 50, 100] : [100, 200, 500, 1000]).map(n => (
            <button key={n} type="button" className={`filter-chip${typed === n ? ' is-on' : ''}`} onClick={() => setSim(x => ({ ...x, target: String(n) }))}>{qtyText(n)} {inSqm ? 'm²' : 'pcs'}</button>
          ))}
          {perDayMax && <button type="button" className={`filter-chip${!inSqm && typed === perDayMax ? ' is-on' : ''}`} onClick={() => setSim(x => ({ ...x, unit: 'pcs', target: String(perDayMax) }))}>One day max ({qtyText(perDayMax)} pcs)</button>}
        </div>

        {simItem && (
          <div className="sim-result">
            <div className="sim-cap">
              <span><span className="pl-help">Capacity: </span><strong>{capLine ?? 'No daily limit'}</strong></span>
              {days != null && target > 0 && <span className="pl-badge is-plain">{days} casting day{days === 1 ? '' : 's'}</span>}
            </div>
            {target > 0 && perDayMax != null && target > perDayMax && (
              <div className="alert alert-warning sim-warn"><AlertTriangle size={14} /> {qtyText(target)} pcs is more than one day's capacity ({qtyText(perDayMax)} pcs) — {days} days of casting.</div>
            )}
            {target > 0 && (readyBy
              ? <p className="pl-help">Ready to sell about <strong>{readyBy}</strong> (casting + {curingDays} days curing).</p>
              : <p className="pl-help">Ready to sell {curingDays} days after casting.</p>)}
            {simW == null && bands[sim.productId] !== undefined && <p className="pl-help text-warning">No wastani for {simItem.name} — set it to work out cement and materials.</p>}
            {simItem.colorIds?.length > 0 && !sim.colorId && <p className="pl-help">Choose the colour to see its materials.</p>}

            {target > 0 && simMaterials.length > 0 && (
              <>
                <span className="pl-label">Raw materials for {qtyText(target)} pcs{inSqm ? ` (${qtyText(typed)} m²)` : ''}</span>
                <div className="sim-mats">
                  {simMaterials.map(m => (
                    <div key={m.item.name + m.unit} className={`sim-mat${m.short ? ' is-short' : ''}`}>
                      <span className="pl-label">{m.item.name}</span>
                      <span><strong>{qtyText(round(m.qty))}</strong> <span className="pl-unit">{m.unit}</span></span>
                      {m.short && <span className="pl-stock text-error">Short {qtyText(round(m.shortBy))} {m.unit}</span>}
                    </div>
                  ))}
                </div>
                {simW > 0 && <p className="pl-help">Cement: {qtyText(target)} pcs ÷ {+simW} pcs/bag = {qtyText(round(simBags))} bags</p>}
              </>
            )}

            <div className="flex gap-8" style={{ flexWrap: 'wrap' }}>
              {canPlan && orders !== false && (
                <button type="button" className="btn btn-primary" disabled={!simReady} onClick={addToOrder}>
                  <Plus size={15} /> {draft ? `Add to ${draft.id ? `order ${draft.order_no}` : 'the new order'}` : 'Add to a new order'}
                </button>
              )}
              {onOpenForm && (
                <button type="button" className="btn btn-outline" onClick={() => onOpenForm({ productId: sim.productId, colorId: sim.colorId })}>
                  <Factory size={15} /> Open production form for {simItem.name}{sim.colorId ? ` ${refs.colorById[sim.colorId]?.name}` : ''}
                </button>
              )}
            </div>
          </div>
        )}
      </section>
    </div>
  );
}
