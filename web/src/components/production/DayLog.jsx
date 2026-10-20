import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Plus, Trash2, AlertTriangle } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import { qtyText, warehouseLabel, byMaterialOrder } from '../../lib/inventory';
import NumberInput from '../NumberInput';
import ProductPicker from './ProductPicker';
import { categoryTools, productOrder } from '../../lib/categories';

const num = v => (String(v ?? '').trim() === '' ? null : Number(v));
const round = (n, d = 4) => Math.round(n * 10 ** d) / 10 ** d;
const draftKey = (org, branch) => `mois.production.day.${org}.${branch}`;
const emptyForm = () => ({ productId: '', colorId: '', bags: '', pieces: '', leftovers: [], edits: {}, allowOther: false, notes: '' });

/**
 * Log a day's batches (migration 043), the way the factory works: each mix
 * is one batch — main product, colour, bags of cement — scaled from the
 * branch's recipe and checked against the store straight away; its pieces
 * (plus leftovers cast from the same mix) give the weighted yield check.
 * Batches are added to today's list and saved together. The unsaved list
 * stays on this device and comes back when the page is opened again.
 */
export default function DayLog({ refs, recipes, branchId, branchName, today, curingDays, usage = {}, onSaved }) {
  const { organization, canAt, canManage } = useAuth();
  const stores = refs.warehouses.filter(w => w.status === 'active' && w.branch_id === branchId);
  const rawStores = stores.filter(w => w.type === 'raw_materials' || w.type === 'general');
  const curingStore = stores.find(w => w.type === 'wip');
  const canBackdate = canAt('inventory.adjust', branchId, null);
  const isManager = canAt('products.manage', branchId, null);   // may allow other products for one batch
  const key = draftKey(organization?.id, branchId);

  // Restore the unsaved list (and the batch being typed) from this device
  const saved = useMemo(() => { try { return JSON.parse(localStorage.getItem(key) || 'null'); } catch { return null; } }, [key]);
  const [date,   setDate]   = useState(saved?.date ?? today);
  const [rawId,  setRawId]  = useState(saved?.rawId ?? rawStores.find(w => w.type === 'raw_materials')?.id ?? rawStores[0]?.id ?? '');
  const [form,   setForm]   = useState(saved?.form ?? emptyForm());
  const [staged, setStaged] = useState(saved?.staged ?? []);
  const [restored] = useState(!!saved?.staged?.length);
  const [stock,  setStock]  = useState({});    // material id → quantity in the chosen store
  const [bands,  setBands]  = useState({});    // product id → yield band at this branch
  const [specs,  setSpecs]  = useState({});    // product id → pieces per m²
  const [wastani, setWastani] = useState({});   // product id → shared yield per bag (picker cards)
  const [sizes,   setSizes]   = useState({});   // product id → size (from its size spec)
  const [picking, setPicking] = useState(false);
  const tilesRef = useRef(null);
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  const [addError, setAddError] = useState('');
  const [sentNote, setSentNote] = useState('');

  useEffect(() => {
    try { localStorage.setItem(key, JSON.stringify({ date, rawId, form, staged, at: new Date().toISOString() })); } catch { /* per-device convenience only */ }
  }, [key, date, rawId, form, staged]);
  // Closing the page with batches not yet saved: warn
  useEffect(() => {
    if (!staged.length) return undefined;
    const warn = e => { e.preventDefault(); e.returnValue = ''; };
    window.addEventListener('beforeunload', warn);
    return () => window.removeEventListener('beforeunload', warn);
  }, [staged.length]);

  // What the store holds now (the server re-checks at save)
  async function loadStock() {
    if (!rawId) return;
    const { data } = await supabase.from('stock_balances').select('material_id, quantity').eq('warehouse_id', rawId).not('material_id', 'is', null);
    setStock(Object.fromEntries((data || []).map(r => [r.material_id, Number(r.quantity)])));
  }
  useEffect(() => { loadStock(); }, [rawId]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    Promise.all([
      supabase.from('product_specs').select('product_id, spec_id, pcs_per_sqm, average_yield_per_bag'),
      supabase.from('product_size_specs').select('id, size_cm'),
    ]).then(([ps, ss]) => {
      const sizeOf = Object.fromEntries((ss.data || []).map(x => [x.id, x.size_cm]));
      setSpecs(Object.fromEntries((ps.data || []).map(s => [s.product_id, s.pcs_per_sqm])));
      setWastani(Object.fromEntries((ps.data || []).map(s => [s.product_id, s.average_yield_per_bag])));
      setSizes(Object.fromEntries((ps.data || []).filter(s => sizeOf[s.spec_id]).map(s => [s.product_id, sizeOf[s.spec_id]])));
    });
  }, []);
  async function band(productId) {
    if (!productId || bands[productId] !== undefined) return;
    const { data } = await supabase.rpc('product_yield_band', { p_product_id: productId, p_branch_id: branchId });
    setBands(b => ({ ...b, [productId]: data?.[0] ?? null }));
  }

  const cats = useMemo(() => categoryTools(refs.categoryRows), [refs]);
  const carried = useMemo(() => Object.values(refs.items)
    .filter(i => i.kind === 'product' && i.status === 'active' && refs.carriedByBranch?.[branchId]?.has(i.id))
    .map(i => ({ ...i, size: i.size || sizes[i.id] }))
    .sort(productOrder(cats)), [refs, branchId, cats, sizes]);
  const main = refs.items[`p:${form.productId}`];
  const colours = main?.colorIds || [];
  const bags = num(form.bags);
  const set = patch => { setAddError(''); setForm(f => ({ ...f, ...patch })); };

  // The branch's active recipe for the main product's category + colour (the server picks the same)
  const recipe = useMemo(() => {
    if (!main || (colours.length && !form.colorId)) return null;
    const c = recipes.filter(r => r.branch_id === branchId && r.category_id === main.categoryId && (r.color_id ?? '') === (form.colorId || ''));
    return c.sort((a, b) => (b.products.some(x => x.product_id === main.id) - a.products.some(x => x.product_id === main.id))
      || String(b.effective_date ?? '').localeCompare(String(a.effective_date ?? '')) || b.version_number - a.version_number)[0] ?? null;
  }, [main, form.colorId, recipes, branchId, colours.length]);

  // Materials: recipe × bags (cement = the bags), each editable; checked against the store minus today's list
  const factorOf = (materialId, unitId) => {
    const it = refs.items[`m:${materialId}`];
    return it?.units.find(u => u.id === unitId)?.factor ?? (unitId === it?.stockUnitId ? 1 : null);
  };
  const usedToday = useMemo(() => {
    const u = {};
    for (const s of staged.filter(x => x.payload.raw_warehouse_id === rawId)) {
      for (const m of s.payload.materials) u[m.material_id] = (u[m.material_id] || 0) + m.quantity * (factorOf(m.material_id, m.unit_id) ?? 0);
    }
    return u;
  }, [staged, rawId]); // eslint-disable-line react-hooks/exhaustive-deps
  const recipeItems = [...(recipe?.items || [])].filter(it => refs.items[`m:${it.material_id}`]?.inRecipes !== false).sort((a, b) => byMaterialOrder(refs.items[`m:${a.material_id}`] ?? {}, refs.items[`m:${b.material_id}`] ?? {}));
  const isSteel = materialId => /steel|chuma/i.test(refs.items[`m:${materialId}`]?.materialCategory ?? '');
  const lines = recipeItems.map(it => {
    const isBag = refs.unitById[it.unit_id]?.symbol?.toLowerCase() === 'bag' && Number(it.quantity) === 1;
    const edited = form.edits[it.material_id];
    const quantity = edited !== undefined ? num(edited) : bags != null ? round(Number(it.quantity) * bags) : null;
    const f = factorOf(it.material_id, it.unit_id);
    const need = quantity != null && f != null ? quantity * f : null;
    const available = (stock[it.material_id] ?? 0) - (usedToday[it.material_id] ?? 0);
    return { ...it, perBag: Number(it.quantity), isBag, edited: edited !== undefined, quantity, need, available, short: need != null && need > available + 1e-9,
      source: isBag || edited !== undefined ? 'counted' : 'recipe' };
  });
  const shortLines = lines.filter(l => l.short);

  // Products cast: main + leftovers (same family + colour unless allowed for this batch)
  const leftoverChoices = carried.filter(i => i.id !== form.productId && (form.allowOther
    ? (!colours.length || !i.colorIds?.length || i.colorIds.includes(form.colorId))
    : i.categoryId === main?.categoryId));
  const outputs = [
    ...(main ? [{ productId: main.id, pieces: num(form.pieces), primary: true }] : []),
    ...form.leftovers.filter(l => l.productId).map(l => ({ productId: l.productId, pieces: num(l.pieces), primary: false })),
  ];
  useEffect(() => { outputs.forEach(o => band(o.productId)); }); // eslint-disable-line react-hooks/exhaustive-deps

  const totalPieces = outputs.reduce((s, o) => s + (o.pieces ?? 0), 0);
  const allBanded = outputs.length > 0 && outputs.every(o => bands[o.productId]?.average_yield_per_bag > 0);
  const theoretical = allBanded ? outputs.reduce((s, o) => s + (o.pieces ?? 0) / bands[o.productId].average_yield_per_bag, 0) : null;
  const bagsMin = allBanded ? outputs.reduce((s, o) => s + (o.pieces ?? 0) / bands[o.productId].yield_max, 0) : null;
  const bagsMax = allBanded && outputs.every(o => bands[o.productId].yield_min > 0)
    ? outputs.reduce((s, o) => s + (o.pieces ?? 0) / bands[o.productId].yield_min, 0) : null;
  const outOfBand = theoretical != null && bags > 0 && totalPieces > 0 && (bags < bagsMin - 1e-9 || (bagsMax != null && bags > bagsMax + 1e-9));
  const sqmOf = (productId, pcs) => {
    const it = refs.items[`p:${productId}`];
    const sqm = refs.unitById[it?.stockUnitId]?.symbol?.toUpperCase() === 'SQM';
    return sqm && specs[productId] > 0 && pcs != null ? pcs / specs[productId] : null;
  };
  const mainBand = bands[form.productId];
  const expected = mainBand?.average_yield_per_bag > 0 && bags > 0 ? Math.round(bags * mainBand.average_yield_per_bag) : null;

  // Products in the mix without a wastani (yield per bag): quality control needs it
  const noWastani = outputs.filter(o => bands[o.productId] !== undefined && !(bands[o.productId]?.average_yield_per_bag > 0));

  function addToList() {
    setAddError('');
    if (!main) { setAddError('Choose the product.'); return; }
    if (colours.length && !form.colorId) { setAddError('Choose the colour.'); return; }
    if (!recipe) { setAddError('No active recipe for this product and colour at this branch — add one under Recipes.'); return; }
    if (!(bags > 0)) { setAddError('Enter the bags of cement used.'); return; }
    if (outputs.some(o => o.pieces == null || o.pieces < 0 || !Number.isInteger(o.pieces))) { setAddError('Enter the pieces cast for each product (whole numbers).'); return; }
    if (totalPieces === 0) { setAddError('Enter the pieces cast.'); return; }
    if (shortLines.length) { setAddError('Not enough stock — the branch manager should check the stock first.'); return; }
    if (noWastani.length) { setAddError(`Set the wastani for ${noWastani.map(o => refs.items[`p:${o.productId}`]?.name).join(', ')} first.`); return; }
    if (form.leftovers.some(l => !l.productId)) { setAddError('Choose each leftover product, or remove the empty row.'); return; }
    const payload = {
      batch_date: date, raw_warehouse_id: rawId, curing_warehouse_id: curingStore.id, color_id: form.colorId || null,
      recipe_version_id: recipe.id, cement_bags: bags, notes: form.notes.trim() || null, allow_other_products: form.allowOther,
      outputs: outputs.map(o => ({ product_id: o.productId, pieces: o.pieces, primary: o.primary })),
      materials: lines.map(l => ({ material_id: l.material_id, unit_id: l.unit_id, quantity: l.quantity ?? 0, source: l.source })),
    };
    setStaged(s => [...s, { id: crypto.randomUUID?.() ?? String(Date.now()), payload, label: `${main.name}${form.colorId ? ` ${refs.colorById[form.colorId]?.name}` : ''}`,
      leftovers: outputs.filter(o => !o.primary).map(o => `${o.pieces} ${refs.items[`p:${o.productId}`]?.name}`),
      bags, pieces: totalPieces, factor: theoretical != null ? theoretical / bags : null, outOfBand }]);
    setForm(emptyForm());   // "allow other products" goes back to the default too
  }

  // An earlier date is a stock correction: someone who isn't an org admin sends the day for approval (044)
  const viaApproval = date < today && !canManage('inventory.adjust');

  async function saveDay() {
    setError('');
    setSentNote('');
    setBusy(true);
    const batches = staged.map(s => ({ ...s.payload, batch_date: date }));
    const pcs = staged.reduce((n, s) => n + s.pieces, 0);
    const bagsTotal = round(staged.reduce((n, s) => n + s.bags, 0));
    const { error: err } = viaApproval
      ? await supabase.rpc('request_change', { p_kind: 'production_day', p_branch_id: null, p_payload: { batches },
          p_summary: `Production of ${date} at ${branchName}: ${staged.length} batch${staged.length === 1 ? '' : 'es'} — ${staged.map(s => s.label).join(', ')} · ${qtyText(pcs)} pcs, ${qtyText(bagsTotal)} bags` })
      : await supabase.rpc('record_production_batches', { p: { batches } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't save these batches. Please try again.")); loadStock(); return; }
    setStaged([]);
    try { localStorage.removeItem(key); } catch { /* ignore */ }
    loadStock();
    if (viaApproval) {
      window.dispatchEvent(new Event('mois:approvals-changed'));
      setSentNote(`Sent for approval — ${date}'s batches are recorded once an admin approves (Approvals).`);
      return;
    }
    onSaved();
  }

  const symOf = id => refs.unitById[id]?.symbol ?? '';
  const shortName = materialId => {
    const m = refs.items[`m:${materialId}`];
    if (m?.code) return m.code.charAt(0) + m.code.slice(1).toLowerCase();
    return (m?.name ?? '').split(/[\s/(]+/)[0];
  };
  const stockSym = materialId => symOf(refs.items[`m:${materialId}`]?.stockUnitId);

  // A unit that no longer fits beside its number drops below it, at the bottom right
  useLayoutEffect(() => {
    const box = tilesRef.current;
    if (!box) return undefined;
    const mark = () => box.querySelectorAll('.pl-tile').forEach(t => {
      const n = t.querySelector('.pl-fit'), u = t.querySelector('.pl-unit');
      if (!n || !u) return;
      t.classList.remove('unit-below');   // measure where it falls on its own
      t.classList.toggle('unit-below', u.getBoundingClientRect().top >= n.getBoundingClientRect().bottom - 2);
    });
    mark();
    const ro = new ResizeObserver(mark);
    ro.observe(box);
    return () => ro.disconnect();
  });

  if (!curingStore) return <div className="card"><div className="card-body"><p className="text-sm">{branchName} has no curing store yet.</p></div></div>;

  const colourName = form.colorId ? refs.colorById[form.colorId]?.name : '';
  const resPieces = outputs.filter(o => !o.primary).reduce((s, o) => s + (o.pieces ?? 0), 0);
  const mainPieces = num(form.pieces);
  const stagedPieces = staged.reduce((s, b) => s + b.pieces, 0);
  const stagedBags = round(staged.reduce((s, b) => s + b.bags, 0));
  const ColourChip = ({ id }) => (id ? <span className="pl-chip"><i style={{ background: refs.colorById[id]?.name?.toLowerCase() }} />{refs.colorById[id]?.name}</span> : null);

  return (
    <div className="pl">
      {picking && (
        <ProductPicker items={carried} cats={cats} usage={usage} wastani={wastani} onClose={() => setPicking(false)}
          onPick={id => { setPicking(false); set({ productId: id, colorId: '', leftovers: [], edits: {}, allowOther: false }); }} />
      )}
      {restored && staged.length > 0 && (
        <div className="alert alert-info" role="note">Your unsaved list from earlier is back: {staged.length} batch{staged.length === 1 ? '' : 'es'} not saved yet.</div>
      )}
      <div className="pl-toolbar">
        {rawStores.length > 1 && (
          <label className="pl-inline">From
            <select className="form-input" value={rawId} disabled={staged.length > 0} onChange={e => setRawId(e.target.value)}>
              {rawStores.map(w => <option key={w.id} value={w.id}>{w.name}</option>)}
            </select>
          </label>
        )}
        <label className="pl-inline">Date
          <input type="date" className="form-input" max={today} value={date} disabled={!canBackdate} title={canBackdate ? '' : 'An earlier date needs an admin'} onChange={e => setDate(e.target.value)} />
        </label>
      </div>

      {/* 1 · Batch mix recipe scaling */}
      <section className="pl-card">
        <h3 className="pl-title">Batch mix recipe scaling</h3>
        <div className="pl-mix">
          <div className="pl-box pl-primary">
            <span className="pl-label">Primary product</span>
            {main ? (
              <>
                <div className="pl-name-row">
                  <span className="pl-big">{main.name}</span>
                  <ColourChip id={form.colorId} />
                  <span className="pl-tag">{main.category}</span>
                  {mainBand?.average_yield_per_bag > 0 && <span className="pl-tag">Wastani: {+mainBand.average_yield_per_bag} pcs/bag</span>}
                </div>
                {mainBand !== undefined && !(mainBand?.average_yield_per_bag > 0) && <WastaniMissing productId={main.id} name={main.name} branchId={branchId} />}
              </>
            ) : <div className="pl-big pl-muted">Choose a product</div>}
            <div className="pl-row">
              <button type="button" className="btn btn-outline" onClick={() => setPicking(true)}>{main ? 'Change' : 'Choose product…'}</button>
              {colours.length > 0 && (
                <select className="form-input" aria-label="Colour" value={form.colorId} onChange={e => set({ colorId: e.target.value, leftovers: [], edits: {} })}>
                  <option value="">Colour…</option>
                  {colours.map(c => <option key={c} value={c}>{refs.colorById[c]?.name}</option>)}
                </select>
              )}
            </div>
          </div>

          <div className="pl-box pl-recipe">
            {recipe ? (
              <>
                <div className="pl-baseline">Baseline: {recipeItems.filter(it => !isSteel(it.material_id)).map(it => `${qtyText(it.quantity)}${symOf(it.unit_id).length <= 3 ? ` ${symOf(it.unit_id)}` : ''} ${shortName(it.material_id)}`).join(' : ')}</div>
                <div className="pl-tiles" ref={tilesRef}>
                  {lines.filter(l => !isSteel(l.material_id)).map(l => (
                    <div key={l.material_id} className={`pl-tile${l.short ? ' is-short' : ''}${l.edited ? ' is-edited' : ''}`}>
                      <span className="pl-label" title={refs.items[`m:${l.material_id}`]?.name}>{shortName(l.material_id)}</span>
                      <span className="pl-tile-in">
                        <NumberInput step="any" min="0" className="pl-num pl-fit" size={1} aria-label={`${refs.items[`m:${l.material_id}`]?.name} used`}
                          style={{ '--len': Math.max(1, qtyText(l.quantity ?? 0).length) }}
                          value={l.quantity == null ? '' : String(l.quantity)}
                          onChange={e => set({ edits: { ...form.edits, [l.material_id]: e.target.value } })} />
                        <span className="pl-unit">{symOf(l.unit_id)}</span>
                      </span>
                      {(l.short || l.edited) && (
                        <span className={`pl-stock${l.short ? ' text-error' : ''}`}>
                          {l.short && `Short ${qtyText(round(l.need - l.available))} ${stockSym(l.material_id)}`}
                          {l.edited && <button type="button" className="pl-reset" title="Back to the recipe" onClick={() => { const { [l.material_id]: _, ...rest } = form.edits; set({ edits: rest }); }}>↺ recipe</button>}
                        </span>
                      )}
                    </div>
                  ))}
                </div>
                {lines.some(l => isSteel(l.material_id)) && (
                  <div className="pl-steel">
                    <span className="pl-label">Steel</span>
                    {lines.filter(l => isSteel(l.material_id)).map(l => (
                      <span key={l.material_id} className={`pl-steel-item${l.short ? ' is-short' : ''}`}>
                        <span className="pl-steel-name">{refs.items[`m:${l.material_id}`]?.name}</span>
                        <NumberInput step="any" min="0" className="pl-num" aria-label={`${refs.items[`m:${l.material_id}`]?.name} used`}
                          value={l.quantity == null ? '' : String(l.quantity)}
                          onChange={e => set({ edits: { ...form.edits, [l.material_id]: e.target.value } })} />
                        <span className="pl-unit">{symOf(l.unit_id)}</span>
                        {l.short && <span className="pl-stock text-error">Short {qtyText(round(l.need - l.available))} {stockSym(l.material_id)}</span>}
                      </span>
                    ))}
                  </div>
                )}
              </>
            ) : <div className="pl-muted text-sm">{main && (!colours.length || form.colorId) ? `No active recipe for ${main.name} ${colourName} — add one under Recipes.` : 'Choose the product and colour.'}</div>}
          </div>
        </div>
        {shortLines.length > 0 && (
          <div className="alert alert-error flex items-center gap-8" role="alert">
            <AlertTriangle size={15} />
            <span>Not enough {shortLines.map(l => refs.items[`m:${l.material_id}`]?.name).join(', ')} in stock — the branch manager should check the stock first.</span>
          </div>
        )}
      </section>

      {/* 2 · Main batch output */}
      <section className="pl-card">
        <h3 className="pl-title">Main batch output</h3>

        <div className="pl-sub">
          <h4 className="pl-subtitle">Primary product output</h4>
          <div className="pl-out">
            <div className="pl-box">
              <span className="pl-label">Mold</span>
              <div className="pl-mid">{main ? main.name : '—'} <ColourChip id={form.colorId} /></div>
              <span className="pl-label">Expected (bags × wastani)</span>
              <div className="pl-big">{expected != null ? `${qtyText(expected)} pcs` : '—'}
                {expected != null && sqmOf(main.id, expected) != null && <span className="pl-sub-num"> ({qtyText(round(sqmOf(main.id, expected), 2))} m²)</span>}
              </div>
            </div>
            <div className="pl-inputs">
              <label className="pl-field">
                <span className="pl-label">Cement bags</span>
                <NumberInput step="any" min="0" className="pl-num pl-num-lg" placeholder="0" value={form.bags} onChange={e => set({ bags: e.target.value })} />
              </label>
              <label className="pl-field is-key">
                <span className="pl-label">Counted pcs</span>
                <NumberInput step="1" min="0" className="pl-num pl-num-lg" placeholder="0" value={form.pieces} onChange={e => set({ pieces: e.target.value })} />
              </label>
              <div className="pl-field">
                <span className="pl-label">Average</span>
                <div className="pl-mid">{mainPieces != null && bags > 0 ? `${qtyText(round(mainPieces / bags, 1))} pcs/bag` : '—'}</div>
              </div>
              <div className="pl-field">
                <span className="pl-label">Actual yield</span>
                <div className="pl-mid">{main && mainPieces != null && sqmOf(main.id, mainPieces) != null ? `${qtyText(round(sqmOf(main.id, mainPieces), 2))} m²` : mainPieces != null ? `${qtyText(mainPieces)} pcs` : '—'}
                  {main && mainPieces != null && sqmOf(main.id, mainPieces) != null && <span className="pl-sub-num"> ({qtyText(mainPieces)} pcs)</span>}</div>
              </div>
            </div>
          </div>
        </div>

        <div className="pl-sub">
          <div className="pl-subhead">
            <h4 className="pl-subtitle">Residuals (secondary products)</h4>
            <button type="button" className="btn btn-outline btn-sm" disabled={!main} onClick={() => set({ leftovers: [...form.leftovers, { productId: '', pieces: '' }] })}><Plus size={13} /> Add residual product</button>
          </div>
          {isManager && main && (
            <label className="pl-allow"><input type="checkbox" checked={form.allowOther} onChange={e => set({ allowOther: e.target.checked, leftovers: [] })} /> Allow other products for this batch</label>
          )}
          {form.leftovers.map((l, i) => {
            const b = bands[l.productId];
            const it = refs.items[`p:${l.productId}`];
            return (
              <div key={i} className="pl-res">
                <div className="pl-res-name">
                  <select className="form-input" aria-label="Residual product" value={l.productId}
                    onChange={e => set({ leftovers: form.leftovers.map((x, j) => (j === i ? { ...x, productId: e.target.value } : x)) })}>
                    <option value="">Residual product…</option>
                    {leftoverChoices.filter(c => c.id === l.productId || !form.leftovers.some(x => x.productId === c.id)).map(c => <option key={c.id} value={c.id}>{c.name} · {c.category}</option>)}
                  </select>
                  {it && b?.average_yield_per_bag > 0 && <span className="pl-accent-text">Wastani: {+b.average_yield_per_bag} pcs/bag</span>}
                  {it && b !== undefined && !(b?.average_yield_per_bag > 0) && <WastaniMissing productId={it.id} name={it.name} branchId={branchId} />}
                </div>
                <ColourChip id={it?.colorIds?.length ? form.colorId : ''} />
                <NumberInput step="1" min="0" className="pl-num" style={{ width: 90 }} placeholder="Pcs" aria-label="Residual pieces" value={l.pieces}
                  onChange={e => set({ leftovers: form.leftovers.map((x, j) => (j === i ? { ...x, pieces: e.target.value } : x)) })} />
                <button type="button" className="icon-btn" aria-label="Remove residual" onClick={() => set({ leftovers: form.leftovers.filter((_, j) => j !== i) })}><Trash2 size={14} /></button>
              </div>
            );
          })}
        </div>

        <div className="pl-sub">
          <div className="pl-subhead">
            <h4 className="pl-subtitle">Weighted batch yield calibration</h4>
            {theoretical != null && bags > 0 && totalPieces > 0 && (
              <span className={`pl-badge${outOfBand ? ' is-out' : ''}`}>Yield factor: {Math.round((theoretical / bags) * 1000) / 10}%</span>
            )}
          </div>
          {outOfBand && <p className="pl-help text-warning">Outside the band — this batch will be flagged for review.</p>}
          <div className="pl-two">
            <div className="pl-box">
              <span className="pl-label">Total pieces in batch</span>
              <div className="pl-mid">{qtyText(mainPieces ?? 0)} pcs{resPieces > 0 && <span className="pl-sub-num"> (+{qtyText(resPieces)} res)</span>}</div>
            </div>
            <div className="pl-box">
              <span className="pl-label">Theoretical cement needed</span>
              <div className="pl-mid pl-accent-text">{theoretical != null && totalPieces > 0 ? `${qtyText(round(theoretical, 2))} bags` : '—'}</div>
            </div>
          </div>
        </div>
      </section>

      <input className="form-input" placeholder="Batch note (optional)" aria-label="Batch note" value={form.notes} onChange={e => set({ notes: e.target.value })} />
      <div className="pl-actions">
        <button type="button" className="btn btn-primary pl-wide" disabled={shortLines.length > 0} onClick={addToList}><Plus size={15} /> Add batch to daily productions</button>
        <button type="button" className="btn btn-outline" onClick={() => setForm(emptyForm())}>Reset</button>
      </div>
      {addError && <p className="text-sm text-error">{addError}</p>}

      {/* 3 · Daily ledger verification preview */}
      <section className="pl-card">
        <div className="pl-subhead">
          <h3 className="pl-title">Daily ledger verification preview</h3>
          <span className="pl-badge is-plain">{staged.length} batch{staged.length === 1 ? '' : 'es'} staged</span>
        </div>
        {staged.length === 0 ? (
          <div className="pl-empty">No batches staged yet.</div>
        ) : (
          <div className="pl-staged">
            {staged.map((s, i) => (
              <div key={s.id} className="pl-staged-row">
                <span className="pl-staged-n">{i + 1}</span>
                <span className="pl-staged-name"><strong>{s.label}</strong>{s.leftovers.length > 0 && <span className="pl-help"> + {s.leftovers.join(', ')}</span>}</span>
                <span>{qtyText(s.bags)} bags</span>
                <span>{qtyText(s.pieces)} pcs</span>
                {s.factor == null ? <span className="pl-help">no check</span> : <span className={`pl-badge${s.outOfBand ? ' is-out' : ''}`}>{Math.round(s.factor * 1000) / 10}%</span>}
                <button type="button" className="icon-btn" aria-label="Remove batch" onClick={() => setStaged(st => st.filter(x => x.id !== s.id))}><Trash2 size={14} /></button>
              </div>
            ))}
          </div>
        )}
        <div className="pl-totals"><span>Total staged output: <strong>{qtyText(stagedPieces)} pcs</strong></span><span>Total cement: <strong>{qtyText(stagedBags)} bags</strong></span></div>
      </section>

      {error && <p className="text-sm text-error" role="alert">{error}</p>}
      {sentNote && <p className="text-sm text-success" role="status">{sentNote}</p>}
      {viaApproval && staged.length > 0 && <p className="pl-help">An earlier date needs an admin's approval.</p>}
      <button type="button" className={`btn btn-primary pl-wide pl-save${busy ? ' btn-loading' : ''}`} disabled={busy || staged.length === 0} onClick={saveDay}>
        {viaApproval ? 'Submit for approval' : 'Save daily productions'} ({staged.length} batch{staged.length === 1 ? '' : 'es'} · {qtyText(stagedPieces)} pcs)
      </button>
    </div>
  );
}

/**
 * A product without a wastani (yield per bag): quality control needs it, so
 * the batch waits. Someone who can set it is offered the way there (the
 * unsaved list stays on this device); others are told who sets it.
 */
function WastaniMissing({ productId, name, branchId }) {
  const navigate = useNavigate();
  const { canAt } = useAuth();
  const canSet = canAt('products.manage', branchId, null);   // org admins, or the branch manager (the branch's own figure)
  return (
    <span className="pl-missing">
      <span className="pl-missing-text">No wastani for {name}</span>
      {canSet
        ? <button type="button" className="btn btn-ghost btn-sm" onClick={() => navigate(`/products?edit=${productId}`)}>Set it now</button>
        : <span> Ask the branch manager to set it.</span>}
    </span>
  );
}
