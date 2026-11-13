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
import BatchNotes, { useProductionLists, teamLabel, peopleOf, labourNorm } from './BatchNotes';
import { dateText, dateTimeText } from '../../lib/format';

const num = v => (String(v ?? '').trim() === '' ? null : Number(v));
const round = (n, d = 4) => Math.round(n * 10 ** d) / 10 ** d;
const draftKey = (org, branch) => `mois.production.day.${org}.${branch}`;
const emptyForm = () => ({ productId: '', colorId: '', bags: '', pieces: '', leftovers: [], edits: {}, allowOther: false, notes: '', orderPick: {},
  teamId: '', workerIds: null, machineId: '' });   // production tracking (056)
// a new batch keeps who made it and on what — the same crew usually casts the next one
// the next batch keeps the machine; the team is chosen afresh for every batch (user rule, 2026-10-30)
const nextForm = f => ({ ...emptyForm(), machineId: f.machineId ?? '' });

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
  // A refresh opens on today; unsaved batches keep their day, since they all save under this one date
  const [date,   setDate]   = useState(saved?.staged?.length ? saved?.date ?? today : today);
  const defaultRaw = () => rawStores.find(w => w.type === 'raw_materials')?.id ?? rawStores[0]?.id ?? '';
  const [rawId,  setRawId]  = useState(() => (rawStores.some(w => w.id === saved?.rawId) ? saved.rawId : defaultRaw()));
  // a blank or unknown store (saved while the branch's stores weren't loaded yet) falls back to the raw materials store (2026-11-05)
  useEffect(() => { if (rawStores.length && !rawStores.some(w => w.id === rawId)) setRawId(defaultRaw()); }, [rawStores.length, rawId]); // eslint-disable-line react-hooks/exhaustive-deps
  const [form,   setForm]   = useState(saved?.form ? { ...saved.form, teamId: '', workerIds: null } : emptyForm());
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
  const [pickingResidual, setPickingResidual] = useState(null);   // a residual row's index, or 'new'
  const tilesRef = useRef(null);
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  const [addError, setAddError] = useState('');
  const [lists, reloadLists] = useProductionLists(branchId);   // teams and machines (056)
  const [sentNote, setSentNote] = useState('');
  const [editingId, setEditingId] = useState(null);   // a staged batch loaded back into the form
  const [previewing, setPreviewing] = useState(null); // a staged batch shown in full
  const [confirming, setConfirming] = useState(false);
  const [already, setAlready] = useState([]);      // staged batches that look already saved (or waiting for approval) for this date
  // An uploaded report's batches (Daily report › Upload a report), each loaded into the form in turn
  const uploadKey = `mois.upload.queue.${organization?.id}.${branchId}`;
  const [upload, setUpload] = useState(null);   // { date, forms, next, done }
  const [uploadClash, setUploadClash] = useState(false);
  // read once the company and branch are known (the form can open a moment before); the place
  // reached is kept on this tab until the last batch, so a refresh carries on from it
  const keepUpload = q => { try { if (q) sessionStorage.setItem(uploadKey, JSON.stringify(q)); else sessionStorage.removeItem(uploadKey); } catch { /* ignore */ } };
  useEffect(() => {
    if (!organization?.id || !branchId) return;
    let q = null;
    try { q = JSON.parse(sessionStorage.getItem(uploadKey) || 'null'); } catch { /* ignore */ }
    if (!q?.forms?.length) return;
    // the listed batches all save under one date: a different day waits until they are saved or cleared
    if (staged.length && date !== q.date) { setUpload(q); setUploadClash(true); return; }
    const at = Math.min(q.at ?? 0, q.forms.length - 1);
    setUploadClash(false);
    setDate(q.date);
    setEditingId(null);
    setForm({ ...emptyForm(), ...q.forms[at] });
    setUpload({ ...q, next: at + 1 });
  }, [uploadKey]); // eslint-disable-line react-hooks/exhaustive-deps
  function nextFromUpload(form0) {
    if (upload?.next != null && upload.next < upload.forms.length) {
      setForm({ ...emptyForm(), ...upload.forms[upload.next] });
      keepUpload({ date: upload.date, forms: upload.forms, at: upload.next });
      setUpload(u => ({ ...u, next: u.next + 1 }));
      return true;
    }
    if (upload?.next != null) { keepUpload(null); setUpload(u => ({ ...u, done: true })); }
    if (form0) setForm(nextForm(form0));
    return false;
  }

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
  // the other stores' materials too: a shortage in one can point to the store that has them (2026-11-05)
  const [otherStock, setOtherStock] = useState({});   // warehouse id → material id → quantity
  async function loadStock() {
    if (!rawId) return;
    const ids = rawStores.map(w => w.id);
    const { data } = await supabase.from('stock_balances').select('warehouse_id, material_id, quantity').in('warehouse_id', ids.length ? ids : [rawId]).not('material_id', 'is', null);
    const by = {};
    for (const r of data || []) (by[r.warehouse_id] ||= {})[r.material_id] = Number(r.quantity);
    setOtherStock(by);
    setStock(by[rawId] || {});
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
  // another store at the branch that holds everything this batch is short of
  const betterStore = shortLines.length ? rawStores.find(w => w.id !== rawId && shortLines.every(l => (otherStock[w.id]?.[l.material_id] ?? 0) + 1e-9 >= (l.need ?? Infinity))) : null;

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
  // the check counts only products with pieces entered (2026-11-13, the user: adding a residual hid it);
  // one with pieces but no wastani can't be checked — its cement share is unknown — and says so
  const counted = outputs.filter(o => o.pieces > 0);
  const unbanded = counted.filter(o => !(bands[o.productId]?.average_yield_per_bag > 0));
  const allBanded = counted.length > 0 && unbanded.length === 0;
  const theoretical = allBanded ? counted.reduce((s, o) => s + o.pieces / bands[o.productId].average_yield_per_bag, 0) : null;
  const bagsMin = allBanded ? counted.reduce((s, o) => s + o.pieces / bands[o.productId].yield_max, 0) : null;
  const bagsMax = allBanded && counted.every(o => bands[o.productId].yield_min > 0)
    ? counted.reduce((s, o) => s + o.pieces / bands[o.productId].yield_min, 0) : null;
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
    const tracked = !!lists?.ready;
    if (tracked && !form.teamId) { setAddError('Choose the team that made this batch (or + New team).'); return; }
    if (tracked && !form.machineId) { setAddError('Choose the machine it was made on (or + New machine).'); return; }
    if (tracked && !form.workerIds?.length) { setAddError('Tick who worked on this batch (the people chip).'); return; }
    const payload = {
      batch_date: date, raw_warehouse_id: rawId, curing_warehouse_id: curingStore.id, color_id: form.colorId || null,
      recipe_version_id: recipe.id, cement_bags: bags, notes: form.notes.trim() || null, allow_other_products: form.allowOther,
      ...(tracked ? { team_id: form.teamId, machine_id: form.machineId, ...(form.workerIds ? { worker_ids: form.workerIds } : {}) } : {}),
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
      factor: theoretical != null ? theoretical / bags : null, theoretical, outOfBand, expected, notes: form.notes.trim(),
      team: tracked ? teamLabel(lists, form.teamId, form.workerIds) : null, machine: tracked ? lists.machines.find(m => m.id === form.machineId)?.name : null };
    setStaged(st => (editingId ? st.map(x => (x.id === editingId ? item : x)) : [...st, item]));
    setEditingId(null);
    // the next batch from an uploaded report, else a fresh form ("allow other products" back to the default; the machine stays, the team doesn't)
    if (editingId) setForm(nextForm(form)); else nextFromUpload(form);
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
    // people (056/057): each person once a day, whichever batches they worked on; the norm from the bags and machines
    // (from each batch's team as sent, so batches listed earlier count too)
    const peopleIn = b => (lists?.ready && b.payload?.team_id ? peopleOf(lists.teams, b.payload.team_id, b.payload.worker_ids) : null);
    const known = staged.map(peopleIn).filter(Boolean);
    const people = known.length ? new Set(known.flat()).size : null;
    const norm = known.length ? labourNorm(lists, staged.map(b => ({ machineId: b.payload?.machine_id, bags: b.bags,
      productId: (b.payload?.outputs || []).find(o => o.primary)?.product_id }))) : null;
    const curingUntil = new Date(new Date(`${date}T00:00:00Z`).getTime() + curingDays * 864e5).toISOString().slice(0, 10);
    return {
      date, branchName, curingUntil, curingDays, people, norm,
      batches: staged.map((b, i) => ({ n: i + 1, bags: b.bags, factor: b.factor, outOfBand: b.outOfBand, team: b.team, machine: b.machine, people: peopleIn(b)?.length ?? null,
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
          p_summary: `Production of ${dateText(date)} at ${branchName}: ${staged.length} batch${staged.length === 1 ? '' : 'es'}, ${qtyText(bagsTotal)} bags — ${made}` })
      : await supabase.rpc('record_production_batches', { p: { batches } });
    setBusy(false);
    setConfirming(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't save these batches. Please try again.")); loadStock(); return; }
    setStaged([]);
    try { localStorage.removeItem(key); } catch { /* ignore */ }
    loadStock();
    if (viaApproval) {
      window.dispatchEvent(new Event('mois:approvals-changed'));
      setSentNote(`Sent for approval — ${dateText(date)}'s batches are recorded once an admin approves (Approvals).`);
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
  // the bag's average counts every product (2026-11-13, the user): each in the main product's pieces by the
  // products' own yield a bag — same size (equal wastani) simply adds up, (65 + 10) ÷ bags; a smaller residual
  // counts for the share of the bag it used (30 pcs of a 150-a-bag product = 15 of a 75-a-bag main)
  const mainYield = bands[form.productId]?.average_yield_per_bag;
  const mixPieces = mainPieces == null ? null : outputs.reduce((t, o) => {
    if (!(o.pieces > 0)) return t;
    const y = bands[o.productId]?.average_yield_per_bag;
    return t + (mainYield > 0 && y > 0 ? o.pieces * (mainYield / y) : o.pieces);
  }, 0);
  const hasResidual = outputs.some(o => !o.primary && o.pieces > 0);
  const avgHelp = hasResidual ? outputs.filter(o => o.pieces > 0).map(o => {
    const y = bands[o.productId]?.average_yield_per_bag; const nm = refs.items[`p:${o.productId}`]?.name ?? '';
    return mainYield > 0 && y > 0 && Math.abs(y - mainYield) > 1e-9 ? `${nm} ${o.pieces} pcs = ${round(o.pieces * mainYield / y, 1)} of the main (${+y} a bag)` : `${nm} ${o.pieces} pcs`;
  }).join(' + ') + (bags > 0 ? ` ÷ ${qtyText(bags)} bags` : '') : undefined;
  const stagedBags = round(staged.reduce((s, b) => s + b.bags, 0));
  const ColourChip = ({ id }) => (id ? <span className="pl-chip"><i style={{ background: refs.colorById[id]?.name?.toLowerCase() }} />{refs.colorById[id]?.name}</span> : null);

  return (
    <div className="pl">
      {pickingResidual !== null && (
        <ProductPicker title="Select residual product" keepOnClose usage={usage} wastani={wastani} cats={cats} onClose={() => setPickingResidual(null)}
          items={leftoverChoices.filter(c => !form.leftovers.some((x, j) => x.productId === c.id && j !== pickingResidual))}
          onPick={id => {
            const at = pickingResidual;
            setPickingResidual(null);
            // a new residual goes on top, its pieces box ready to type in (2026-11-05)
            set({ leftovers: at === 'new' ? [{ productId: id, pieces: '' }, ...form.leftovers] : form.leftovers.map((x, j) => (j === at ? { ...x, productId: id } : x)) });
            setTimeout(() => document.querySelectorAll('.pl-res input[aria-label="Residual pieces"]')[at === 'new' ? 0 : at]?.focus(), 50);
          }} />
      )}
      {picking && (
        <ProductPicker items={carried} cats={cats} usage={usage} wastani={wastani} onClose={() => setPicking(false)}
          onPick={id => { setPicking(false); set({ productId: id, colorId: '', leftovers: [], edits: {}, allowOther: false }); }} />
      )}
      {uploadClash && (
        <div className="alert alert-warning" role="note">An uploaded report for {dateText(upload.date)} is waiting. Save or clear the {staged.length} batch{staged.length === 1 ? '' : 'es'} listed for {dateText(date)} first, then open it again from Daily report.</div>
      )}
      {upload?.next != null && !upload.done && (
        <div className="alert alert-info" role="note">From the uploaded report: batch {upload.next} of {upload.forms.length}. Check the materials, then Add to list.
          {' '}<button type="button" className="btn btn-outline btn-sm" onClick={() => nextFromUpload(form)}>Skip this batch</button></div>
      )}
      {upload?.done && staged.length > 0 && (
        <div className="alert alert-info" role="note">Uploaded batches are on the list.</div>
      )}
      {restored && staged.length > 0 && (
        <div className="alert alert-info" role="note">Your unsaved list from earlier is back: {staged.length} batch{staged.length === 1 ? '' : 'es'} not saved yet, dated {dateText(date)}.</div>
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
          <input type="date" className="form-input" max={today} value={date} title={canBackdate ? '' : 'An earlier date goes to Approvals'} onChange={e => setDate(e.target.value)} />
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
            <span>Not enough {shortLines.map(l => refs.items[`m:${l.material_id}`]?.name).join(', ')} in {refs.warehouses.find(w => w.id === rawId)?.name ?? 'this store'}.
              {betterStore ? '' : ' The branch manager should check the stock.'}</span>
            {betterStore && <button type="button" className="btn btn-outline btn-sm" style={{ marginLeft: 'auto' }} onClick={() => setRawId(betterStore.id)}>Use {betterStore.name}</button>}
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
                <div className="pl-mid" title={avgHelp}>{mixPieces != null && bags > 0 ? `${qtyText(round(mixPieces / bags, 1))} pcs/bag` : '—'}
                  {hasResidual && mainPieces != null && bags > 0 && <span className="pl-sub-num"> (main only {qtyText(round(mainPieces / bags, 1))})</span>}</div>
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
            <button type="button" className="btn btn-outline btn-sm" disabled={!main} onClick={() => setPickingResidual('new')}><Plus size={13} /> Add residual product</button>
          </div>
          {/* only the box toggles it, and residuals already entered stay (2026-11-05): unticking drops only those outside the main product's category */}
          {isManager && main && (
            <span className="pl-allow"><input type="checkbox" id="pl-allow-other" aria-label="Allow other products for this batch" checked={form.allowOther}
              onChange={e => set({ allowOther: e.target.checked, leftovers: e.target.checked ? form.leftovers : form.leftovers.filter(l => !l.productId || refs.items[`p:${l.productId}`]?.categoryId === main?.categoryId) })} />
              <span>Allow other products for this batch</span></span>
          )}
          {form.leftovers.map((l, i) => {
            const b = bands[l.productId];
            const it = refs.items[`p:${l.productId}`];
            return (
              <div key={i} className="pl-res">
                <div className="pl-res-name">
                  <button type="button" className="form-input pl-res-pick" aria-label="Residual product" onClick={() => setPickingResidual(i)}>
                    {it ? it.name : 'Choose residual product…'}
                  </button>
                  {it && b?.average_yield_per_bag > 0 && <span className="pl-accent-text">Wastani: {+b.average_yield_per_bag} pcs/bag</span>}
                  {it && b !== undefined && !(b?.average_yield_per_bag > 0) && <WastaniMissing productId={it.id} name={it.name} branchId={branchId} />}
                  {it && orderPick(it.id, residualColour(it))}
                </div>
                <ColourChip id={residualColour(it)} />
                <NumberInput step="1" min="0" className="pl-num" style={{ width: 90 }} placeholder="Pcs" aria-label="Residual pieces" value={l.pieces}
                  onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); setPickingResidual('new'); } }}   /* Enter: the next residual (2026-11-05) */
                  onChange={e => set({ leftovers: form.leftovers.map((x, j) => (j === i ? { ...x, pieces: e.target.value } : x)) })} />
                <button type="button" className="icon-btn" aria-label="Remove residual" onClick={() => set({ leftovers: form.leftovers.filter((_, j) => j !== i) })}><Trash2 size={14} /></button>
              </div>
            );
          })}
        </div>

        {/* the yield factor alone (2026-11-13, the user): products, pieces and the cement implied in its tooltip */}
        {((theoretical != null && bags > 0 && totalPieces > 0) || unbanded.length > 0) && (
          <div className="pl-calib-min">
            {unbanded.length > 0 && <span className="pl-help text-warning">No yield check until {unbanded.map(o => refs.items[`p:${o.productId}`]?.name).join(', ')} {unbanded.length === 1 ? 'has' : 'have'} a wastani</span>}
            {outOfBand && <span className="pl-help text-warning">Outside the band — flagged for review</span>}
            {theoretical != null && bags > 0 && totalPieces > 0 && (
              <span className={`pl-badge${outOfBand ? ' is-out' : ''}`}
                title={`${counted.map(o => `${refs.items[`p:${o.productId}`]?.name ?? ''} ${qtyText(o.pieces)} pcs`).join(' + ')} → cement implied ${qtyText(round(theoretical, 2))} of ${qtyText(bags)} bags`}>
                Yield factor: {Math.round((theoretical / bags) * 1000) / 10}%</span>
            )}
          </div>
        )}
        {/* team, who worked, machine and note belong to the batch: inside its card (2026-11-13, the user) */}
        <div className="pl-batch-notes">
          <BatchNotes branchId={branchId} organizationId={organization?.id} productId={form.productId} date={date} lists={lists} reload={reloadLists}
            value={{ teamId: form.teamId ?? '', workerIds: form.workerIds ?? null, machineId: form.machineId ?? '', notes: form.notes }}
            onChange={v => set(v)} />
        </div>
      </section>
      <div className="pl-actions">
        <button type="button" className="btn btn-primary pl-wide" disabled={shortLines.length > 0} onClick={addToList}>
          {editingId ? <><Pencil size={15} /> Update batch {staged.findIndex(x => x.id === editingId) + 1}</> : <><Plus size={15} /> Add batch to daily productions</>}
        </button>
        <button type="button" className="btn btn-outline" onClick={() => { setForm(nextForm(form)); setEditingId(null); }}>{editingId ? 'Cancel edit' : 'Reset'}</button>
      </div>
      {addError && <p className="text-sm text-error">{addError}</p>}

      {/* 3 · the day's list — the same look as Sales' (2026-11-13, the user): a coloured edge sets it apart from the form */}
      <section className="pl-card day-list">
        <div className="day-list-head">
          <h3 className="card-title" style={{ margin: 0 }}>Daily Production Ledger</h3>
          <span className="day-list-chip">{staged.length} batch{staged.length === 1 ? '' : 'es'} · {qtyText(stagedBags)} bag{stagedBags === 1 ? '' : 's'}</span>
        </div>
        {staged.length === 0 ? (
          <div className="pl-empty">No batches staged yet.</div>
        ) : (
          // a table like the sales one (2026-11-13, the user): each product a row; bags, yield, team and machine per batch
          <table className="rd-table sl-day-table">
            <thead><tr><th style={{ width: 36 }}>No.</th><th>Products</th><th style={{ textAlign: 'right' }}>Qty</th><th style={{ textAlign: 'right' }}>Bags</th><th className="dl-avg" title="Pieces a cement bag — residuals counted in the main product's pieces by each one's wastani">Avg <span className="th-unit">(pcs/bag)</span></th><th className="dl-split">Team</th><th>Machine</th><th>Yield</th><th aria-label="Actions" /></tr></thead>
            <tbody>
              {/* newest on top (2026-11-13, the user); numbered in the order added, saved in that order */}
              {staged.map((st, i) => [st, i]).reverse().map(([st, i]) => {
                const outs = st.outputs?.length ? st.outputs : [{ name: '—', pieces: null }];
                const span = outs.length;
                // the batch's average a bag, as in the form: each product in the main product's pieces by its wastani
                const mainOut = outs.find(o => !o.residual);
                const mainY = Number(mainOut?.wastani) || null;
                const mix = outs.reduce((t, o) => t + (Number(o.pieces) > 0 ? Number(o.pieces) * (mainY && Number(o.wastani) > 0 ? mainY / Number(o.wastani) : 1) : 0), 0);
                const avg = st.bags > 0 && mix > 0 ? Math.round((mix / st.bags) * 10) / 10 : null;
                return outs.map((o, k) => (
                  <tr key={`${st.id}-${k}`} className={`clickable-row${k === 0 ? ' sl-day-first' : ''}${editingId === st.id ? ' is-editing' : ''}`} onClick={() => setPreviewing(st)} title="Look at it">
                    {k === 0 && <td rowSpan={span}><span className="pl-staged-n">{i + 1}</span></td>}
                    <td className={o.residual ? 'pl-staged-res' : ''}>{o.residual ? '+ ' : ''}{o.name}{o.order ? <span className="pl-help"> · order {o.order}</span> : ''}</td>
                    <td style={{ textAlign: 'right' }}>{o.pieces != null ? <>{qtyText(o.pieces)} <span className="pl-help">pcs</span></> : '—'}</td>
                    {k === 0 && <td rowSpan={span} style={{ textAlign: 'right' }}>{qtyText(st.bags)}</td>}
                    {k === 0 && <td rowSpan={span} className="dl-avg">{avg != null ? <>{qtyText(avg)} <span className="td-unit">pcs</span></> : '—'}</td>}
                    {k === 0 && <td rowSpan={span} className="text-sm dl-split">{st.team || <span className="pl-help">—</span>}</td>}
                    {k === 0 && <td rowSpan={span} className="text-sm">{st.machine || <span className="pl-help">—</span>}</td>}
                    {k === 0 && <td rowSpan={span}>{st.factor == null ? <span className="pl-help">no check</span> : <span className={`pl-badge${st.outOfBand ? ' is-out' : ''}`}>{Math.round(st.factor * 1000) / 10}%</span>}</td>}
                    {k === 0 && <td rowSpan={span} className="sl-day-acts" onClick={e => e.stopPropagation()}>
                      <button type="button" className="icon-btn" aria-label="Look at the batch" title="Look at it" onClick={() => setPreviewing(st)}><Eye size={14} /></button>
                      <button type="button" className="icon-btn" aria-label="Edit batch" title="Edit it in the form" disabled={!st.form} onClick={() => editStaged(st)}><Pencil size={14} /></button>
                      <button type="button" className="icon-btn" aria-label="Remove batch" title="Remove from the list" onClick={() => { setStaged(x => x.filter(y => y.id !== st.id)); if (editingId === st.id) { setEditingId(null); setForm(emptyForm()); } }}><Trash2 size={14} /></button>
                    </td>}
                  </tr>
                ));
              })}
              <tr className="sl-day-total"><td colSpan={3}><strong>Total</strong> <span className="pl-help">{staged.length} batch{staged.length === 1 ? '' : 'es'}</span></td>
                <td style={{ textAlign: 'right' }}><strong>{qtyText(stagedBags)}</strong></td><td /><td className="dl-split" colSpan={4} /></tr>
            </tbody>
          </table>
        )}
        <div className="day-list-foot">
          <span className="day-list-totals" />
          {error && <span className="text-sm text-error" role="alert">{error}</span>}
          {sentNote && <span className="text-sm text-success" role="status">{sentNote}</span>}
          {viaApproval && staged.length > 0 && <span className="pl-help">An earlier date needs an admin's approval.</span>}
          {editingId && <span className="pl-help">Finish or cancel the edit to save.</span>}
          <button type="button" className="btn btn-primary" disabled={busy || staged.length === 0 || !!editingId} onClick={openConfirm}>
            {viaApproval ? 'Submit for approval' : 'Save all'} · {staged.length} batch{staged.length === 1 ? '' : 'es'}
          </button>
        </div>
      </section>

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
              <strong>{dateText(date)} may already be recorded.</strong> These look like batches already {already.every(a => a.how === 'saved') ? 'saved' : 'saved or waiting for approval'} for this date — saving again counts them twice:
              <ul style={{ margin: '6px 0 0 18px' }}>
                {already.map((a, i) => <li key={i}>{a.label} · {qtyText(a.bags)} bags — {a.how} {dateTimeText(a.at)}</li>)}
              </ul>
              <span className="pl-help">Save only if these are extra batches.</span>
            </div>
          )}
          <DaySummary day={daySummary()} currency={organization?.currency_code} />
        </Modal>
      )}
      {previewing && (
        <Modal size="xl" title={`Batch ${staged.findIndex(x => x.id === previewing.id) + 1} — ${previewing.label}`} onClose={() => setPreviewing(null)}
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
      <ProductionBreakdown dayTotal={false} currency={currency} batches={[{ n: 1, bags: b.bags, team: b.team, machine: b.machine,
        ...(est ? { cost: est.cost, costComplete: est.complete, estimate: true } : {}),
        outputs: b.outputs.map((o, j) => ({ ...o, perBag: o.wastani, ...(est?.outputs[j] ?? {}) })),
        materials: breakdownMaterials((b.payload?.materials || []).map(m => ({ material_id: m.material_id, quantity: m.quantity, unit_id: m.unit_id })), refs) }]} />
      {b.notes && <p className="text-sm"><span className="pl-label">Note</span> {b.notes}</p>}
    </div>
  );
}
