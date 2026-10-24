import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Plus, Trash2, AlertTriangle, Pencil, Eye } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import { qtyText, warehouseLabel, byMaterialOrder, materialShortName, breakdownMaterials, estimateBatchCosts } from '../../lib/inventory';
import NumberInput from '../NumberInput';
import ProductPicker from './ProductPicker';
import ProductionBreakdown from './ProductionBreakdown';
import { categoryTools, productOrder } from '../../lib/categories';
import Modal from '../Modal';
import DaySummary from './DaySummary';

const num = v => (String(v ?? '').trim() === '' ? null : Number(v));
const round = (n, d = 4) => Math.round(n * 10 ** d) / 10 ** d;
const draftKey = (org, branch) => `mois.production.day.${org}.${branch}`;
const emptyForm = () => ({ productId: '', colorId: '', bags: '', pieces: '', leftovers: [], edits: {}, allowOther: false, notes: '', orderPick: {} });

/**
 * Log a day's batches (migration 043), the way the factory works: each mix
 * is one batch — main product, colour, bags of cement — scaled from the
 * branch's recipe and checked against the store straight away; its pieces
 * (plus leftovers cast from the same mix) give the weighted yield check.
 * Batches are added to today's list and saved together. The unsaved list
 * stays on this device and comes back when the page is opened again.
 */
export default function DayLog({ refs, recipes, branchId, branchName, today, curingDays, usage = {}, preset = null, onSaved }) {
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
  // lists saved before 2026-10-21 lack the per-product detail: rebuild it from what was sent
  const [staged, setStaged] = useState(() => (saved?.staged ?? []).map(x => (x.outputs ? x : {
    ...x,
    outputs: (x.payload?.outputs || []).map(o => ({ productId: o.product_id, name: refs.items[`p:${o.product_id}`]?.name ?? '—', pieces: o.pieces, sqm: null, residual: !o.primary, wastani: null })),
    materials: (x.payload?.materials || []).map(m => ({ materialId: m.material_id, name: refs.items[`m:${m.material_id}`]?.name ?? '—', quantity: m.quantity, unit: refs.unitById[m.unit_id]?.symbol ?? '', counted: m.source === 'counted' })),
  })));
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
  const [editingId, setEditingId] = useState(null);   // a staged batch loaded back into the form
  const [previewing, setPreviewing] = useState(null); // a staged batch shown in full
  const [confirming, setConfirming] = useState(false);
  const [already, setAlready] = useState([]);      // staged batches that look already saved (or waiting for approval) for this date

  // Before saving: the same product, colour and bags already recorded (or sent for approval) on this date
  // at this branch? Shown in the confirm window — saving is still allowed, e.g. a genuine second batch.
  const [estimates, setEstimates] = useState(null);   // ≈ material cost of the staged batches (055's way)
  const costInput = b => ({ materials: b.payload?.materials || [], outputs: b.outputs.map(o => ({ pieces: o.pieces, perBag: o.wastani, sqm: o.sqm })) });
  async function openConfirm() {
    setError('');
    setAlready([]);
    setEstimates(null);
    setConfirming(true);
    estimateBatchCosts(refs, branchId, staged.map(costInput)).then(setEstimates).catch(() => setEstimates(null));
    const [bt, pc] = await Promise.all([
      supabase.from('production_batches').select('product_id, color_id, cement_bags, created_at').eq('branch_id', branchId).eq('batch_date', date).neq('status', 'void'),
      supabase.from('pending_changes').select('payload, requested_at').eq('kind', 'production_day').eq('status', 'pending'),
    ]);
    const seen = [
      ...(bt.data || []).map(b => ({ product: b.product_id, color: b.color_id ?? '', bags: Number(b.cement_bags), how: 'saved', at: b.created_at })),
      ...(pc.data || []).flatMap(x => (x.payload?.batches || []).filter(b => b.batch_date === date).map(b => ({
        product: (b.outputs || []).find(o => o.primary)?.product_id, color: b.color_id ?? '', bags: Number(b.cement_bags), how: 'waiting for approval', at: x.requested_at }))),
    ];
    const hits = staged.map(st => {
      const main = (st.payload.outputs || []).find(o => o.primary)?.product_id;
      const m = seen.find(x => x.product === main && x.color === (st.payload.color_id ?? '') && x.bags === Number(st.payload.cement_bags));
      return m ? { label: st.label, bags: st.bags, how: m.how, at: m.at } : null;
    }).filter(Boolean);
    setAlready(hits);
  }
  const [openLines, setOpenLines] = useState([]);    // open production orders' lines at this branch (048)

  // Open production orders: each product cast can count towards one (048; none before it)
  async function loadOrders() {
    const { data, error: err } = await supabase.from('production_order_lines')
      .select('id, product_id, color_id, pieces, order:production_orders!inner(id, order_no, reference, due_date, status, branch_id)')
      .eq('order.branch_id', branchId).eq('order.status', 'open');
    if (err || !data?.length) { setOpenLines([]); return; }
    const { data: g } = await supabase.from('production_order_line_progress').select('line_id, passed, curing').in('line_id', data.map(l => l.id));
    const done = Object.fromEntries((g || []).map(x => [x.line_id, x.passed + x.curing]));
    setOpenLines(data.map(l => ({ ...l, left: Math.max(0, l.pieces - (done[l.id] ?? 0)) }))
      .sort((a, b) => (a.order.due_date ?? '9999') .localeCompare(b.order.due_date ?? '9999') || a.order.order_no - b.order.order_no));
  }
  useEffect(() => { loadOrders(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

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
    const quantity = edited !== undefined ? num(edited) : bags != null ? round(Number(it.quantity) * bags) : 0;
    const f = factorOf(it.material_id, it.unit_id);
    const need = quantity != null && f != null ? quantity * f : null;
    const available = (stock[it.material_id] ?? 0) - (usedToday[it.material_id] ?? 0);
    return { ...it, perBag: Number(it.quantity), factor: f, isBag, edited: edited !== undefined, quantity, need, available, short: need != null && need > available + 1e-9,
      source: isBag || edited !== undefined ? 'counted' : 'recipe' };
  });
  const shortLines = lines.filter(l => l.short);

  // A residual's colour is the main product's: the same colour by name (Red
  // with Red, Grey with Grey); a plain main product's residuals are White.
  // Never chosen separately (047 stores it per product).
  const residualColour = item => {
    if (!item?.colorIds?.length) return '';
    if (form.colorId && item.colorIds.includes(form.colorId)) return form.colorId;
    const want = (form.colorId ? refs.colorById[form.colorId]?.name : 'White')?.toLowerCase();
    return item.colorIds.find(id => refs.colorById[id]?.name?.toLowerCase() === want) ?? '';
  };
  // Products cast: main + leftovers (same family unless allowed for this batch),
  // and only those that come in the main product's colour
  const leftoverChoices = carried.filter(i => i.id !== form.productId
    && (form.allowOther || i.categoryId === main?.categoryId)
    && (!i.colorIds?.length || residualColour(i)));
  const orderLinesFor = (productId, colorId) => openLines.filter(l => l.product_id === productId && (l.color_id ?? '') === (colorId || ''));
  const orderLineOf = (productId, colorId) => {
    const c = orderLinesFor(productId, colorId);
    const pick = form.orderPick?.[productId];
    if (pick === 'none') return '';
    if (pick && c.some(l => l.id === pick)) return pick;
    return (c.find(l => l.left > 0) ?? c[0])?.id ?? '';
  };
  // called as a function, not a component, so the select keeps focus across renders
  const orderPick = (productId, colorId) => {
    const c = orderLinesFor(productId, colorId);
    if (!c.length) return null;
    return (
      <label className="pl-order">For order
        <select className="form-input" value={orderLineOf(productId, colorId) || 'none'} onChange={e => set({ orderPick: { ...form.orderPick, [productId]: e.target.value } })}>
          {c.map(l => <option key={l.id} value={l.id}>Order {l.order.order_no}{l.order.reference ? ` · ${l.order.reference}` : ''} · {qtyText(l.left)} to go</option>)}
          <option value="none">No order</option>
        </select>
      </label>
    );
  };
  const outputs = [
    ...(main ? [{ productId: main.id, colorId: form.colorId || '', pieces: num(form.pieces), primary: true }] : []),
    ...form.leftovers.filter(l => l.productId).map(l => ({ productId: l.productId, colorId: residualColour(refs.items[`p:${l.productId}`]), pieces: num(l.pieces), primary: false })),
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

  // A product sent from the capacity simulator starts a new batch form
  useEffect(() => {
    if (!preset?.productId) return;
    setEditingId(null);
    setForm({ ...emptyForm(), productId: preset.productId, colorId: preset.colorId || '' });
  }, [preset?.at]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (recipe && !form.bags) document.getElementById('pl-bags')?.focus();
  }, [recipe?.id]); // eslint-disable-line react-hooks/exhaustive-deps

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
    const noColour = outputs.find(o => !o.primary && refs.items[`p:${o.productId}`]?.colorIds?.length && !o.colorId);
    if (noColour) { setAddError(`Choose the colour for ${refs.items[`p:${noColour.productId}`]?.name}.`); return; }
    const payload = {
      batch_date: date, raw_warehouse_id: rawId, curing_warehouse_id: curingStore.id, color_id: form.colorId || null,
      recipe_version_id: recipe.id, cement_bags: bags, notes: form.notes.trim() || null, allow_other_products: form.allowOther,
      outputs: outputs.map(o => ({ product_id: o.productId, pieces: o.pieces, primary: o.primary, ...(o.primary ? {} : { color_id: o.colorId || null }),
        ...(orderLineOf(o.productId, o.colorId) ? { order_line_id: orderLineOf(o.productId, o.colorId) } : {}) })),
      materials: lines.map(l => ({ material_id: l.material_id, unit_id: l.unit_id, quantity: l.quantity ?? 0, source: l.source })),
    };
    const colourTxt = form.colorId ? ` ${refs.colorById[form.colorId]?.name}` : '';
    const item = { id: editingId ?? (crypto.randomUUID?.() ?? String(Date.now())), payload, form: { ...form },
      label: `${main.name}${colourTxt}`, category: main.category, bags,
      // each product on its own — main and residuals are different stock items
      outputs: outputs.map(o => ({ productId: o.productId, name: `${refs.items[`p:${o.productId}`]?.name}${o.colorId ? ` ${refs.colorById[o.colorId]?.name}` : ''}`,
        order: openLines.find(l => l.id === orderLineOf(o.productId, o.colorId))?.order.order_no ?? null,
        pieces: o.pieces, sqm: sqmOf(o.productId, o.pieces), residual: !o.primary, wastani: bands[o.productId]?.average_yield_per_bag ?? null })),
      materials: lines.map(l => ({ materialId: l.material_id, name: refs.items[`m:${l.material_id}`]?.name, quantity: l.quantity ?? 0, unit: symOf(l.unit_id),
        stockQty: (l.quantity ?? 0) * (l.factor ?? 0), counted: l.source === 'counted' })),
      factor: theoretical != null ? theoretical / bags : null, theoretical, outOfBand, expected, notes: form.notes.trim() };
    setStaged(st => (editingId ? st.map(x => (x.id === editingId ? item : x)) : [...st, item]));
    setEditingId(null);
    setForm(emptyForm());   // "allow other products" goes back to the default too
  }
  function editStaged(item) {
    setForm(item.form);
    setEditingId(item.id);
    setAddError('');
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  // The day at a glance, for the confirmation before saving
  function daySummary() {
    const products = {};
    const mats = {};
    staged.forEach(b => {
      b.outputs.forEach(o => {
        const k = o.productId + (o.name || '');
        products[k] ??= { name: o.name, pieces: 0, sqm: o.sqm != null ? 0 : null };
        products[k].pieces += o.pieces ?? 0;
        if (products[k].sqm != null && o.sqm != null) products[k].sqm += o.sqm;
      });
      b.materials.forEach(m => {
        mats[m.materialId] ??= { name: m.name, used: 0, unit: m.unit, rank: refs.items[`m:${m.materialId}`]?.rank ?? 999 };
        mats[m.materialId].used += m.quantity;
      });
    });
    const curingUntil = new Date(new Date(`${date}T00:00:00Z`).getTime() + curingDays * 864e5).toISOString().slice(0, 10);
    return {
      date, branchName, curingUntil, curingDays,
      batches: staged.map((b, i) => ({ n: i + 1, bags: b.bags, factor: b.factor, outOfBand: b.outOfBand,
        ...(estimates?.[i] ? { cost: estimates[i].cost, costComplete: estimates[i].complete, estimate: true } : {}),
        outputs: b.outputs.map((o, j) => ({ ...o, perBag: o.wastani, ...(estimates?.[i]?.outputs[j] ?? {}) })),
        materials: breakdownMaterials((b.payload?.materials || []).map(m => ({ material_id: m.material_id, quantity: m.quantity, unit_id: m.unit_id })), refs) })),
      products: Object.values(products),
      materials: Object.entries(mats).sort((a, b) => a[1].rank - b[1].rank || a[1].name.localeCompare(b[1].name)).map(([id, m]) => ({
        ...m, label: shortName(id), left: (stock[id] ?? 0) - (usedToday[id] ?? 0), leftUnit: stockSym(id), short: (stock[id] ?? 0) - (usedToday[id] ?? 0) < -1e-9,
      })),
    };
  }

  // An earlier date is a stock correction: someone who isn't an org admin sends the day for approval (044)
  const viaApproval = date < today && !canManage('inventory.adjust');

  async function saveDay() {
    setError('');
    setSentNote('');
    setBusy(true);
    const batches = staged.map(s => ({ ...s.payload, batch_date: date }));
    const bagsTotal = round(staged.reduce((n, s) => n + s.bags, 0));
    const made = staged.flatMap(s => s.outputs.map(o => `${o.pieces} ${o.name}`)).join(', ');
    const { error: err } = viaApproval
      ? await supabase.rpc('request_change', { p_kind: 'production_day', p_branch_id: null, p_payload: { batches },
          p_summary: `Production of ${date} at ${branchName}: ${staged.length} batch${staged.length === 1 ? '' : 'es'}, ${qtyText(bagsTotal)} bags — ${made}` })
      : await supabase.rpc('record_production_batches', { p: { batches } });
    setBusy(false);
    setConfirming(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't save these batches. Please try again.")); loadStock(); return; }
    setStaged([]);
    try { localStorage.removeItem(key); } catch { /* ignore */ }
    loadStock();
    if (viaApproval) {
      window.dispatchEvent(new Event('mois:approvals-changed'));
      setSentNote(`Sent for approval — ${date}'s batches are recorded once an admin approves (Approvals).`);
      return;
    }
    loadOrders();
    onSaved();
  }

  const symOf = id => refs.unitById[id]?.symbol ?? '';
  const shortName = materialId => materialShortName(refs.items[`m:${materialId}`]);
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
  const mainPieces = num(form.pieces);
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
                          {l.short && `Short ${qtyText(round(l.factor ? (l.need - l.available) / l.factor : l.need - l.available, 2))} ${l.factor ? symOf(l.unit_id) : stockSym(l.material_id)}`}
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
                        {l.short && <span className="pl-stock text-error">Short {qtyText(round(l.factor ? (l.need - l.available) / l.factor : l.need - l.available, 2))} {l.factor ? symOf(l.unit_id) : stockSym(l.material_id)}</span>}
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
              <span className="pl-label">Mold : {main ? main.category : '—'}</span>
              <div className="pl-big pl-mold">{main ? main.name : '—'} <ColourChip id={form.colorId} /></div>
              {main && orderPick(main.id, form.colorId)}
              <span className="pl-label">Expected output ({bags > 0 ? qtyText(bags) : '—'} bags × {mainBand?.average_yield_per_bag > 0 ? +mainBand.average_yield_per_bag : 'wastani'})</span>
              <div className="pl-big">{expected != null ? `${qtyText(expected)} pcs` : '—'}
                {expected != null && sqmOf(main.id, expected) != null && <span className="pl-sub-num"> ({qtyText(round(sqmOf(main.id, expected), 2))} m²)</span>}
              </div>
            </div>
            <div className="pl-inputs">
              <label className="pl-field">
                <span className="pl-label">Cement bags</span>
                <NumberInput id="pl-bags" step="any" min="0" className="pl-num pl-num-lg" placeholder="0" value={form.bags} onChange={e => set({ bags: e.target.value })} />
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
                  {it && orderPick(it.id, residualColour(it))}
                </div>
                <ColourChip id={residualColour(it)} />
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
              <span className="pl-label">Pieces in batch</span>
              <div className="pl-mid">{qtyText(mainPieces ?? 0)} {main?.name ?? 'pcs'}{form.leftovers.filter(l => l.productId && num(l.pieces)).map(l => (
                <span key={l.productId} className="pl-sub-num"> + {qtyText(num(l.pieces))} {refs.items[`p:${l.productId}`]?.name}</span>))}</div>
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
        <button type="button" className="btn btn-primary pl-wide" disabled={shortLines.length > 0} onClick={addToList}>
          {editingId ? <><Pencil size={15} /> Update batch {staged.findIndex(x => x.id === editingId) + 1}</> : <><Plus size={15} /> Add batch to daily productions</>}
        </button>
        <button type="button" className="btn btn-outline" onClick={() => { setForm(emptyForm()); setEditingId(null); }}>{editingId ? 'Cancel edit' : 'Reset'}</button>
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
              <div key={s.id} className={`pl-staged-row${editingId === s.id ? ' is-editing' : ''}`}>
                <span className="pl-staged-n">{i + 1}</span>
                <span className="pl-staged-name">
                  {(s.outputs || []).map((o, k) => (
                    <span key={k} className={o.residual ? 'pl-staged-res' : 'pl-staged-main'}>{o.residual ? '+ ' : ''}{o.name} <strong>{qtyText(o.pieces)}</strong> pcs{o.order ? ` · order ${o.order}` : ''}</span>
                  ))}
                </span>
                <span>{qtyText(s.bags)} bags</span>
                {s.factor == null ? <span className="pl-help">no check</span> : <span className={`pl-badge${s.outOfBand ? ' is-out' : ''}`}>{Math.round(s.factor * 1000) / 10}%</span>}
                <span className="pl-staged-actions">
                  <button type="button" className="icon-btn" aria-label="Preview batch" title="Preview" onClick={() => setPreviewing(s)}><Eye size={14} /></button>
                  <button type="button" className="icon-btn" aria-label="Edit batch" title="Edit" disabled={!s.form} onClick={() => editStaged(s)}><Pencil size={14} /></button>
                  <button type="button" className="icon-btn" aria-label="Remove batch" title="Remove" onClick={() => { setStaged(st => st.filter(x => x.id !== s.id)); if (editingId === s.id) { setEditingId(null); setForm(emptyForm()); } }}><Trash2 size={14} /></button>
                </span>
              </div>
            ))}
          </div>
        )}
        <div className="pl-totals"><span>Batches: <strong>{staged.length}</strong></span><span>Total cement: <strong>{qtyText(stagedBags)} bags</strong></span></div>
      </section>

      {error && <p className="text-sm text-error" role="alert">{error}</p>}
      {sentNote && <p className="text-sm text-success" role="status">{sentNote}</p>}
      {viaApproval && staged.length > 0 && <p className="pl-help">An earlier date needs an admin's approval.</p>}
      <button type="button" className="btn btn-primary pl-wide pl-save" disabled={busy || staged.length === 0 || !!editingId} onClick={openConfirm}>
        {viaApproval ? 'Submit for approval' : 'Save daily productions'} ({staged.length} batch{staged.length === 1 ? '' : 'es'})
      </button>
      {editingId && <p className="pl-help">Finish or cancel the edit to save.</p>}

      {confirming && (
        <Modal title={viaApproval ? 'Submit this production for approval?' : 'Confirm daily production'} onClose={() => setConfirming(false)} size="xl"
          footer={<>
            {error && <span className="modal-footer-error" role="alert">{error}</span>}
            <button type="button" className="btn btn-outline" onClick={() => setConfirming(false)}>Back to edit</button>
            <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={saveDay}>
              {already.length ? (viaApproval ? 'Submit anyway' : 'Save anyway') : viaApproval ? 'Submit for approval' : 'Confirm & save'}
            </button>
          </>}>
          {already.length > 0 && (
            <div className="alert alert-warning" role="alert" style={{ marginBottom: 12 }}>
              <strong>{date} may already be recorded.</strong> These look like batches already {already.every(a => a.how === 'saved') ? 'saved' : 'saved or waiting for approval'} for this date — saving again counts them twice:
              <ul style={{ margin: '6px 0 0 18px' }}>
                {already.map((a, i) => <li key={i}>{a.label} · {qtyText(a.bags)} bags — {a.how} {new Date(a.at).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</li>)}
              </ul>
              <span className="pl-help">Check Production › Curing or Approvals first. Save anyway only if these are genuinely extra batches.</span>
            </div>
          )}
          <DaySummary day={daySummary()} currency={organization?.currency_code} />
        </Modal>
      )}
      {previewing && (
        <Modal title={`Batch ${staged.findIndex(x => x.id === previewing.id) + 1} — ${previewing.label}`} onClose={() => setPreviewing(null)}
          footer={<>
            <button type="button" className="btn btn-outline" onClick={() => setPreviewing(null)}>Close</button>
            {previewing.form && <button type="button" className="btn btn-primary" onClick={() => { const it = previewing; setPreviewing(null); editStaged(it); }}><Pencil size={14} /> Edit</button>}
          </>}>
          <BatchPreview b={previewing} refs={refs} branchId={branchId} currency={organization?.currency_code} costInput={costInput} />
        </Modal>
      )}
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

/** One staged batch in full: products, cement and materials (recipe units), yield */
function BatchPreview({ b, refs, branchId, currency, costInput }) {
  const [est, setEst] = useState(null);
  useEffect(() => { estimateBatchCosts(refs, branchId, [costInput(b)]).then(x => setEst(x[0])).catch(() => setEst(null)); }, [b]); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <div className="bp">
      <div className="bp-row"><span className="pl-label">Mold : {b.category}</span><strong className="bp-big">{b.label}</strong></div>
      <div className="bp-grid">
        <div className="bp-box"><span className="pl-label">Cement</span><strong>{qtyText(b.bags)} bags</strong></div>
        <div className="bp-box"><span className="pl-label">Expected</span><strong>{b.expected != null ? `${qtyText(b.expected)} pcs` : '—'}</strong></div>
        <div className="bp-box"><span className="pl-label">Cement implied</span><strong>{b.theoretical != null ? `${qtyText(Math.round(b.theoretical * 100) / 100)} bags` : '—'}</strong></div>
        <div className="bp-box"><span className="pl-label">Yield factor</span><strong className={b.outOfBand ? 'text-warning' : 'text-success'}>{b.factor != null ? `${Math.round(b.factor * 1000) / 10}%` : 'no check'}</strong></div>
      </div>
      <ProductionBreakdown dayTotal={false} currency={currency} batches={[{ n: 1, bags: b.bags,
        ...(est ? { cost: est.cost, costComplete: est.complete, estimate: true } : {}),
        outputs: b.outputs.map((o, j) => ({ ...o, perBag: o.wastani, ...(est?.outputs[j] ?? {}) })),
        materials: breakdownMaterials((b.payload?.materials || []).map(m => ({ material_id: m.material_id, quantity: m.quantity, unit_id: m.unit_id })), refs) }]} />
      {b.notes && <p className="text-sm"><span className="pl-label">Note</span> {b.notes}</p>}
    </div>
  );
}
