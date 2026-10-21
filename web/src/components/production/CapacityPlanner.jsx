import { useEffect, useMemo, useState } from 'react';
import { Plus, Trash2, AlertTriangle, Gauge, Factory } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import { qtyText, byMaterialOrder } from '../../lib/inventory';
import { categoryTools, productOrder } from '../../lib/categories';
import NumberInput from '../NumberInput';
import ProductPicker from './ProductPicker';

const num = v => (String(v ?? '').trim() === '' ? null : Number(v));
const round = (n, d = 2) => Math.round(n * 10 ** d) / 10 ** d;

/**
 * Capacity planner (045): pick products and pieces for a day and see, for
 * each, the branch's capacity (molds for vibro — the day's ceiling; bags a
 * day for press — a usual range; none = not defined), the cement it takes
 * (pieces ÷ wastani) and, for the whole day, the materials needed against
 * what the store holds. A calculator by default; in "plan & compare" mode
 * the day's plan is saved and set against what was actually cast.
 */
export default function CapacityPlanner({ refs, recipes, branchId, branchName, today, batches = [], usage = {}, onOpenForm }) {
  const { organization, canAt } = useAuth();
  const [mode, setMode] = useState('calculator');
  const [date, setDate] = useState(today);
  const [rows, setRows] = useState([]);           // { productId, colorId, pieces }
  const [capacity, setCapacity] = useState({});   // product id → { molds, bags_per_day_min, bags_per_day_max }
  const [bands, setBands] = useState({});
  const [stock, setStock] = useState({});
  const [sizes, setSizes] = useState({});
  const [wastani, setWastani] = useState({});
  const [picking, setPicking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState('');
  const [error, setError] = useState('');
  // the simulator: one product and a target
  const [sim, setSim] = useState({ productId: '', colorId: '', target: '' });
  const [simPicking, setSimPicking] = useState(false);
  const [curingDays, setCuringDays] = useState(14);
  const rawStore = refs.warehouses.find(w => w.status === 'active' && w.branch_id === branchId && w.type === 'raw_materials');
  const canSave = canAt('production.create', branchId, null);

  useEffect(() => {
    let live = true;
    Promise.all([
      supabase.from('organizations').select('*').eq('id', organization.id).maybeSingle(),
      supabase.from('branch_product_capacity').select('product_id, molds, bags_per_day_min, bags_per_day_max').eq('branch_id', branchId),
      rawStore ? supabase.from('stock_balances').select('material_id, quantity').eq('warehouse_id', rawStore.id).not('material_id', 'is', null) : Promise.resolve({ data: [] }),
      supabase.from('product_specs').select('product_id, spec_id, average_yield_per_bag'),
      supabase.from('product_size_specs').select('id, size_cm'),
    ]).then(([o, c, st, ps, ss]) => {
      if (!live) return;
      setMode(o.data?.planner_mode ?? 'calculator');
      if (o.data?.curing_days != null) setCuringDays(o.data.curing_days);
      setCapacity(Object.fromEntries((c.data || []).map(x => [x.product_id, x])));
      setStock(Object.fromEntries((st.data || []).map(x => [x.material_id, Number(x.quantity)])));
      const sizeOf = Object.fromEntries((ss.data || []).map(x => [x.id, x.size_cm]));
      setWastani(Object.fromEntries((ps.data || []).map(x => [x.product_id, x.average_yield_per_bag])));
      setSizes(Object.fromEntries((ps.data || []).filter(x => sizeOf[x.spec_id]).map(x => [x.product_id, sizeOf[x.spec_id]])));
    });
    return () => { live = false; };
  }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  // Plan & compare: the saved plan for the day
  useEffect(() => {
    if (mode !== 'plan_compare') return;
    let live = true;
    supabase.from('production_plans').select('id, notes, lines:production_plan_lines(product_id, color_id, pieces)')
      .eq('branch_id', branchId).eq('plan_date', date).maybeSingle()
      .then(({ data }) => { if (live) setRows((data?.lines || []).map(l => ({ productId: l.product_id, colorId: l.color_id ?? '', pieces: String(l.pieces) }))); });
    return () => { live = false; };
  }, [mode, date, branchId]);

  // each product's yield band at this branch (the branch's own wastani wins)
  useEffect(() => {
    [...rows, ...(sim.productId ? [{ productId: sim.productId }] : [])].forEach(async r => {
      if (bands[r.productId] !== undefined) return;
      const { data } = await supabase.rpc('product_yield_band', { p_product_id: r.productId, p_branch_id: branchId });
      setBands(b => ({ ...b, [r.productId]: data?.[0] ?? null }));
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

  // Each row worked out
  const lines = rows.map(r => {
    const item = refs.items[`p:${r.productId}`];
    const w = bands[r.productId]?.average_yield_per_bag;
    const pcs = num(r.pieces) ?? 0;
    const bags = w > 0 ? pcs / w : null;
    const cap = capacity[r.productId];
    let max = null, capText = 'Capacity not defined', over = false;
    if (cap?.molds) { max = cap.molds; capText = `${qtyText(cap.molds)} molds · max ${qtyText(cap.molds)} pcs/day`; over = pcs > cap.molds; }
    else if (cap?.bags_per_day_max || cap?.bags_per_day_min) {
      const lo = cap.bags_per_day_min, hi = cap.bags_per_day_max ?? cap.bags_per_day_min;
      max = w > 0 ? Math.floor(hi * w) : null;
      capText = `${qtyText(lo ?? hi)}–${qtyText(hi)} bags/day${w > 0 ? ` · ${qtyText(Math.round((lo ?? hi) * w))}–${qtyText(Math.round(hi * w))} pcs` : ''}`;
      over = bags != null && bags > hi + 1e-9;
    }
    const recipe = item && (!item.colorIds?.length || r.colorId) ? recipeFor(item, r.colorId) : null;
    const cast = batches.filter(b => b.batch_date === date && b.status !== 'void')
      .flatMap(b => b.outputs || []).filter(o => o.product_id === r.productId && (o.color_id ?? '') === (r.colorId || ''))
      .reduce((s, o) => s + o.pieces_cast, 0);
    return { ...r, item, w, pcs, bags, max, capText, over, recipe, cast, needsColour: !!item?.colorIds?.length && !r.colorId };
  });

  // The day's materials: each row's recipe × its bags, in the recipe's units, against the store
  const materials = useMemo(() => {
    const m = {};
    for (const l of lines) {
      if (!l.recipe || l.bags == null) continue;
      for (const it of l.recipe.items) {
        if (refs.items[`m:${it.material_id}`]?.inRecipes === false) continue;
        const k = `${it.material_id}|${it.unit_id}`;
        m[k] ??= { materialId: it.material_id, unitId: it.unit_id, qty: 0 };
        m[k].qty += Number(it.quantity) * l.bags;
      }
    }
    return Object.values(m).map(x => {
      const f = factorOf(x.materialId, x.unitId);
      const have = f ? (stock[x.materialId] ?? 0) / f : null;
      return { ...x, item: refs.items[`m:${x.materialId}`] ?? { name: '—' }, unit: refs.unitById[x.unitId]?.symbol ?? '', have, short: have != null && x.qty > have + 1e-9 };
    }).sort((a, b) => byMaterialOrder(a.item, b.item));
  }, [lines, stock]); // eslint-disable-line react-hooks/exhaustive-deps

  const totalBags = lines.reduce((s, l) => s + (l.bags ?? 0), 0);

  // ---- simulator: target pieces → casting days, curing, materials
  const simItem = refs.items[`p:${sim.productId}`];
  const simW = bands[sim.productId]?.average_yield_per_bag;
  const simCap = capacity[sim.productId];
  const target = num(sim.target) ?? 0;
  const simBags = simW > 0 ? target / simW : null;
  const perDayMax = simCap?.molds ?? (simCap?.bags_per_day_max && simW > 0 ? Math.floor(simCap.bags_per_day_max * simW) : null);
  const perDayMin = simCap?.molds ?? (simCap?.bags_per_day_min && simW > 0 ? Math.floor(simCap.bags_per_day_min * simW) : perDayMax);
  const daysFast = perDayMax ? Math.ceil(target / perDayMax) : null;
  const daysSlow = perDayMin ? Math.ceil(target / perDayMin) : null;
  const addDays = (iso, n) => new Date(new Date(`${iso}T00:00:00Z`).getTime() + n * 864e5).toISOString().slice(0, 10);
  const readyBy = daysSlow ? addDays(today, daysSlow - 1 + curingDays) : null;
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
    : simCap?.bags_per_day_max || simCap?.bags_per_day_min ? `${qtyText(simCap.bags_per_day_min ?? simCap.bags_per_day_max)}–${qtyText(simCap.bags_per_day_max ?? simCap.bags_per_day_min)} bags a day${perDayMax ? ` — ${qtyText(perDayMin)}–${qtyText(perDayMax)} pcs a day` : ''}`
    : null;
  const set = (i, patch) => setRows(rs => rs.map((r, j) => (j === i ? { ...r, ...patch } : r)));

  async function savePlan() {
    setError(''); setNote('');
    setBusy(true);
    const { error: err } = await supabase.rpc('save_production_plan', { p: { branch_id: branchId, plan_date: date,
      lines: rows.filter(r => num(r.pieces) > 0).map(r => ({ product_id: r.productId, color_id: r.colorId || null, pieces: num(r.pieces) })) } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't save the plan. Please try again.")); return; }
    setNote(`Plan for ${date} saved.`);
  }

  return (
    <div className="pl">
      {picking && (
        <ProductPicker title="Add a product to plan" items={carried.filter(i => !rows.some(r => r.productId === i.id && !i.colorIds?.length))} cats={cats} usage={usage} wastani={wastani}
          onClose={() => setPicking(false)} onPick={id => { setPicking(false); setRows(rs => [...rs, { productId: id, colorId: '', pieces: '' }]); }} />
      )}
      {simPicking && (
        <ProductPicker title="Select finished product" items={carried} cats={cats} usage={usage} wastani={wastani}
          onClose={() => setSimPicking(false)} onPick={id => { setSimPicking(false); setSim(x => ({ ...x, productId: id, colorId: '' })); }} />
      )}

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
            <span className="pl-label">2. Target output (pcs)</span>
            <NumberInput step="1" min="0" className="form-input sim-target" placeholder="0" value={sim.target} onChange={e => setSim(x => ({ ...x, target: e.target.value }))} />
          </div>
        </div>
        <div className="sim-presets">
          <span className="pl-help">Quick:</span>
          {[100, 200, 500, 1000].map(n => (
            <button key={n} type="button" className={`filter-chip${target === n ? ' is-on' : ''}`} onClick={() => setSim(x => ({ ...x, target: String(n) }))}>{qtyText(n)} pcs</button>
          ))}
          {perDayMax && <button type="button" className={`filter-chip${target === perDayMax ? ' is-on' : ''}`} onClick={() => setSim(x => ({ ...x, target: String(perDayMax) }))}>One day max ({qtyText(perDayMax)} pcs)</button>}
        </div>

        {simItem && (
          <div className="sim-result">
            <div className="sim-cap">
              <span><span className="pl-help">Capacity: </span><strong>{capLine ?? 'Not defined for this product'}</strong></span>
              {daysFast != null && target > 0 && (
                <span className="pl-badge is-plain">{daysFast === daysSlow ? `${daysFast} casting day${daysFast === 1 ? '' : 's'}` : `${daysFast}–${daysSlow} casting days`}</span>
              )}
            </div>
            {target > 0 && perDayMax != null && target > perDayMax && (
              <div className="alert alert-warning sim-warn"><AlertTriangle size={14} /> {qtyText(target)} pcs is more than one day's capacity ({qtyText(perDayMax)} pcs) — {daysFast === daysSlow ? daysFast : `${daysFast}–${daysSlow}`} days of casting.</div>
            )}
            {target > 0 && readyBy && <p className="pl-help">Ready to sell about <strong>{readyBy}</strong> (casting + {curingDays} days curing).</p>}
            {simW == null && bands[sim.productId] !== undefined && <p className="pl-help text-warning">No wastani for {simItem.name} — set it to work out cement and materials.</p>}
            {simItem.colorIds?.length > 0 && !sim.colorId && <p className="pl-help">Choose the colour to see its materials.</p>}

            {target > 0 && simMaterials.length > 0 && (
              <>
                <span className="pl-label">Raw materials for {qtyText(target)} pcs</span>
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

            {onOpenForm && (
              <button type="button" className="btn btn-primary pl-wide" onClick={() => onOpenForm({ productId: sim.productId, colorId: sim.colorId })}>
                <Factory size={15} /> Open production form for {simItem.name}{sim.colorId ? ` ${refs.colorById[sim.colorId]?.name}` : ''}
              </button>
            )}
          </div>
        )}
      </section>

      {mode === 'plan_compare' && (<>
      <div className="pl-toolbar">
        <span className="pl-badge is-plain">Plan & compare</span>
        <label className="pl-inline">Day
          <input type="date" className="form-input" value={date} onChange={e => setDate(e.target.value)} />
        </label>
      </div>

      <section className="pl-card">
        <div className="pl-subhead">
          <h3 className="pl-title">Products for {date} at {branchName}</h3>
          <button type="button" className="btn btn-outline btn-sm" onClick={() => setPicking(true)}><Plus size={13} /> Add product</button>
        </div>
        {lines.length === 0 ? <div className="pl-empty">Add the products to make — capacity, cement and materials are worked out here.</div> : (
          <div className="table-container">
            <table className="cp-table">
              <thead><tr>
                <th>Product</th><th>Pieces</th><th>Capacity</th><th style={{ textAlign: 'right' }}>Cement</th>
                {mode === 'plan_compare' && <th style={{ textAlign: 'right' }}>Cast</th>}<th />
              </tr></thead>
              <tbody>
                {lines.map((l, i) => (
                  <tr key={i} className={l.over ? 'cp-over' : ''}>
                    <td>
                      <strong>{l.item?.name ?? '—'}</strong> <span className="pl-tag">{l.item?.category}</span>
                      {l.item?.colorIds?.length > 0 && (
                        <select className="form-input cp-colour" aria-label="Colour" value={l.colorId} onChange={e => set(i, { colorId: e.target.value })}>
                          <option value="">Colour…</option>
                          {l.item.colorIds.map(c => <option key={c} value={c}>{refs.colorById[c]?.name}</option>)}
                        </select>
                      )}
                    </td>
                    <td>
                      <span className="flex items-center gap-4">
                        <NumberInput step="1" min="0" className="form-input cp-pcs" aria-label={`${l.item?.name} pieces`} placeholder="0" value={l.pieces} onChange={e => set(i, { pieces: e.target.value })} />
                        {l.max != null && <button type="button" className="btn btn-ghost btn-sm" title="Fill to capacity" onClick={() => set(i, { pieces: String(l.max) })}>Max</button>}
                      </span>
                    </td>
                    <td className="text-sm">{l.capText}{l.over && <div className="text-xs text-warning">Above capacity</div>}</td>
                    <td style={{ textAlign: 'right' }}>{l.bags != null ? <><strong>{qtyText(round(l.bags))}</strong> bags</> : <span className="text-xs text-warning">No wastani</span>}
                      {l.w > 0 && <div className="text-xs text-muted">÷ {+l.w}/bag</div>}</td>
                    {mode === 'plan_compare' && <td style={{ textAlign: 'right' }}>{qtyText(l.cast)} <span className="text-xs text-muted">/ {qtyText(l.pcs)}</span></td>}
                    <td style={{ textAlign: 'right' }}><button type="button" className="icon-btn" aria-label="Remove" onClick={() => setRows(rs => rs.filter((_, j) => j !== i))}><Trash2 size={14} /></button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {lines.length > 0 && (
        <section className="pl-card">
          <div className="pl-subhead">
            <h3 className="pl-title">Materials needed</h3>
            <span className="pl-badge is-plain">Cement {qtyText(round(totalBags))} bags</span>
          </div>
          {lines.some(l => l.needsColour) && <p className="pl-help text-warning">Choose the colour for each coloured product to count its materials.</p>}
          <div className="cp-mats">
            {materials.map(m => (
              <div key={`${m.materialId}|${m.unitId}`} className={`cp-mat${m.short ? ' is-short' : ''}`}>
                <span className="pl-label">{m.item.name}</span>
                <span><strong>{qtyText(round(m.qty))}</strong> <span className="pl-unit">{m.unit}</span></span>
                {m.short && <span className="pl-stock text-error">Short {qtyText(round(m.qty - m.have))} {m.unit}</span>}
              </div>
            ))}
          </div>
          {materials.some(m => m.short) && (
            <div className="alert alert-error flex items-center gap-8" role="alert"><AlertTriangle size={15} /> Not enough in store for this plan — buy or check the stock first.</div>
          )}
        </section>
      )}

      {mode === 'plan_compare' && canSave && (
        <>
          {error && <p className="text-sm text-error" role="alert">{error}</p>}
          {note && <p className="text-sm text-success" role="status">{note}</p>}
          <button type="button" className={`btn btn-primary pl-wide pl-save${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={savePlan}>Save plan for {date}</button>
        </>
      )}
      </>)}
    </div>
  );
}
