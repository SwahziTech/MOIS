import { useEffect, useMemo, useState } from 'react';
import { Boxes, Plus, Minus, Layers, Package } from 'lucide-react';
import { Link, useNavigate } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { MOVEMENT_TYPES, loadInventoryRefs, warehouseLabel, itemKey, stockKey, qtyText, orgToday, mainUnitOf } from '../lib/inventory';
import PageShell from '../components/PageShell';
import { ListToolbar, ChipRow, ActionMenu, categoryChipItems } from '../components/ListControls';
import { categoryTools, productOrder } from '../lib/categories';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import MovementModal from '../components/inventory/MovementModal';
import { DoubleEntryAlert } from '../components/inventory/DoubleEntry';

const LOAD_ERROR = "We couldn't load stock. Please try again.";
const ACTIONS = ['receipt', 'issue', 'transfer', 'adjustment', 'count', 'opening_balance'];
const SORT_LABEL = { size: 'Structural size (smallest → largest)', name: 'Name (A → Z)', qty_desc: 'Quantity (highest → lowest)', qty_asc: 'Quantity (lowest → highest)', recent: 'Last movement (newest first)' };
const round = (n, d = 2) => Math.round(n * 10 ** d) / 10 ** d;

/*
 * Stock on hand = the sum of the inventory ledger (stock_balances view,
 * migration 022). Nothing here edits a number: every change is a posted
 * movement. Layout (SwahziTech, 2026-10-23): Raw materials / Finished goods,
 * one card per item with its total and, for coloured products, a box per
 * colour; m² products show pieces too. Curing stock is counted apart —
 * not sellable until its quality release.
 */
export default function Stock() {
  const { canAt, organization } = useAuth();
  const navigate = useNavigate();
  const today = orgToday(organization?.timezone);
  const [asOfDate, setAsOfDate] = useState('');   // '' = now
  const [refs,     setRefs]     = useState(null);
  const [balances, setBalances] = useState([]);
  const [perSqm,   setPerSqm]   = useState({});   // product id → pieces per m²
  const [reorder,  setReorder]  = useState({});   // branch id → product id → reorder level (049)
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [search,  setSearch]  = useState('');
  const { branchId } = useBranch();
  const [view,        setView]        = useState('products');  // materials | products
  const [warehouseId, setWarehouseId] = useState('');
  const [showZero,    setShowZero]    = useState(false);
  const [chip,        setChip]        = useState('');
  const [sortBy,      setSortBy]      = useState('size');
  const [posting,     setPosting]     = useState(null);   // movement type

  async function load(date = asOfDate) {
    setError('');
    try {
      const [r, bal, ps] = await Promise.all([
        loadInventoryRefs(),
        date && date < today
          ? supabase.rpc('stock_balances_as_of', { p_date: date })
          : supabase.from('stock_balances').select('warehouse_id, material_id, product_id, color_id, stock_unit_id, quantity, last_movement_date'),
        supabase.from('product_specs').select('product_id, pcs_per_sqm'),
      ]);
      if (bal.error) throw bal.error;
      setRefs(r);
      setBalances(bal.data || []);
      setPerSqm(Object.fromEntries((ps.data || []).filter(x => Number(x.pcs_per_sqm) > 0).map(x => [x.product_id, Number(x.pcs_per_sqm)])));
      // reorder levels (049) — on their own, so Stock works without them
      const rl = await supabase.from('branch_products').select('branch_id, product_id, reorder_level').not('reorder_level', 'is', null);
      const m = {};
      for (const x of rl.error ? [] : rl.data || []) (m[x.branch_id] ||= {})[x.product_id] = Number(x.reorder_level);
      setReorder(m);
    } catch (err) {
      console.error(err);
      setError(LOAD_ERROR);
    }
    setLoading(false);
  }

  useEffect(() => { load(); }, []);
  useEffect(() => { setWarehouseId(''); }, [branchId]);
  useEffect(() => { setChip(''); setWarehouseId(''); }, [view]);

  const whById = useMemo(() => Object.fromEntries((refs?.warehouses || []).map(w => [w.id, w])), [refs]);
  const balanceMap = useMemo(() => Object.fromEntries(balances.map(b => [`${b.warehouse_id}|${stockKey(b)}`, b.quantity])), [balances]);
  const activeWarehouses = (refs?.warehouses || []).filter(w => w.status === 'active');
  const allowedActions = ACTIONS.filter(t => activeWarehouses.some(w => canAt(MOVEMENT_TYPES[t].perm, w.branch_id, w.id)));
  const cats = useMemo(() => categoryTools(refs?.categoryRows || []), [refs]);
  const order = useMemo(() => productOrder(cats), [cats]);
  const isProducts = view === 'products';
  const stores = activeWarehouses.filter(w => (!branchId || w.branch_id === branchId) && w.type !== 'wip'
    && (isProducts ? w.type !== 'raw_materials' : w.type === 'raw_materials' || w.type === 'general'));

  // One card per item: its total in the stores in view, per colour, and (products) what is still curing
  const cards = useMemo(() => {
    if (!refs) return [];
    const m = {};
    for (const b of balances) {
      const item = refs.items[itemKey(b)];
      const wh = whById[b.warehouse_id];
      if (!item || !wh || (isProducts ? item.kind !== 'product' : item.kind !== 'material')) continue;
      if (branchId && wh.branch_id !== branchId) continue;
      if (warehouseId && b.warehouse_id !== warehouseId
        && !(wh.type === 'wip' && whById[warehouseId]?.type === 'finished_goods' && whById[warehouseId]?.branch_id === wh.branch_id)) continue;
      const c = (m[item.key] ??= { item, total: 0, curing: 0, byColour: {}, unitId: b.stock_unit_id, last: null });
      const q = Number(b.quantity);
      if (wh.type === 'wip') c.curing += q;
      else { c.total += q; if (b.color_id) c.byColour[b.color_id] = (c.byColour[b.color_id] ?? 0) + q; }
      if (!c.last || String(b.last_movement_date) > c.last) c.last = String(b.last_movement_date);
    }
    // carried products with nothing on hand still appear when zero stock is shown
    if (showZero && isProducts) {
      for (const i of Object.values(refs.items)) {
        if (i.kind !== 'product' || i.status !== 'active' || m[i.key]) continue;
        if (branchId && !refs.carriedByBranch?.[branchId]?.has(i.id)) continue;
        m[i.key] = { item: i, total: 0, curing: 0, byColour: {}, unitId: i.stockUnitId, last: null };
      }
    }
    return Object.values(m);
  }, [refs, balances, whById, branchId, warehouseId, isProducts, showZero]);

  // Chips: product categories (a group stands for its categories), or material categories
  const materialChips = useMemo(() => [...new Map(cards.filter(c => c.item.materialCategory).sort((a, b) => (a.item.rank ?? 999) - (b.item.rank ?? 999))
    .map(c => [c.item.materialCategory, { id: c.item.materialCategory, label: c.item.materialCategory }])).values()], [cards]);
  const inChip = item => !chip || (isProducts
    ? item.categoryId === chip || cats.byId[item.categoryId]?.parent_category_id === chip
    : item.materialCategory === chip);
  const q = search.trim().toLowerCase();
  const byName = (a, b) => a.item.name.localeCompare(b.item.name, undefined, { numeric: true });
  const shown = cards
    .filter(c => (showZero || c.total !== 0 || c.curing !== 0) && inChip(c.item)
      && (!q || `${c.item.name} ${c.item.category ?? c.item.materialCategory ?? ''}`.toLowerCase().includes(q)))
    .sort((a, b) => sortBy === 'qty_desc' ? b.total - a.total || byName(a, b)
      : sortBy === 'qty_asc' ? a.total - b.total || byName(a, b)
      : sortBy === 'recent' ? String(b.last ?? '').localeCompare(String(a.last ?? '')) || byName(a, b)
      : sortBy === 'name' ? byName(a, b)
      : isProducts ? order(a.item, b.item) : (a.item.rank ?? 999) - (b.item.rank ?? 999) || byName(a, b));

  const unit = id => refs?.unitById[id]?.symbol ?? '';
  const isSqm = c => /^(sqm|m²)$/i.test(unit(c.unitId));
  const pcsOf = (c, qty) => (isSqm(c) && perSqm[c.item.id] ? Math.round(qty * perSqm[c.item.id]) : null);
  // a material's other unit, e.g. bags for kg or metres for rollers
  const altOf = (c, qty) => {
    const u = (c.item.units || []).find(x => x.id !== c.unitId && x.factor > 0 && x.factor !== 1);
    return u ? `${qtyText(round(qty / u.factor))} ${unit(u.id)}` : null;
  };

  return (
    <PageShell
      title="Stock"
      subtitle="Inventory"
      description="What's on hand, worked out from every recorded movement."
      actions={
        <label className="text-sm flex items-center gap-8" style={{ whiteSpace: 'nowrap' }}>
          Stock as of
          <input type="date" className="form-input" style={{ width: 'auto' }} max={today} value={asOfDate || today}
            onChange={e => { const d = e.target.value === today ? '' : e.target.value; setAsOfDate(d); setLoading(true); load(d); }} />
        </label>
      }
    >
      <div className="sk-tabs" role="tablist">
        <button type="button" role="tab" aria-selected={!isProducts} className={`sk-tab${!isProducts ? ' is-on' : ''}`} onClick={() => setView('materials')}><Layers size={16} /> Raw materials</button>
        <button type="button" role="tab" aria-selected={isProducts} className={`sk-tab${isProducts ? ' is-on' : ''}`} onClick={() => setView('products')}><Package size={16} /> Finished goods</button>
      </div>

      <ListToolbar id="stock-search" search={search} onSearch={setSearch} placeholder={isProducts ? 'Search product (e.g. Chuchu, Buibui, 600R)…' : 'Search material (e.g. Huaxin, Rangi)…'}
        sort={{ value: sortBy, onChange: setSortBy, options: Object.entries(SORT_LABEL).map(([value, label]) => ({ value, label: isProducts || value !== 'size' ? label : 'Material order (cement → steel)' })) }}
        filters={[
          { key: 'store', label: 'Store', value: warehouseId, onChange: setWarehouseId,
            options: [{ value: '', label: 'All stores' }, ...stores.map(w => ({ value: w.id, label: warehouseLabel(w) }))] },
          { key: 'zero', label: 'Zero stock', value: showZero ? 'show' : '', onChange: v => setShowZero(v === 'show'),
            options: [{ value: '', label: 'Hide' }, { value: 'show', label: 'Show' }] },
        ]}>
        {allowedActions.length > 0 && (
          <ActionMenu label="Stock actions" icon={Plus}
            items={[
              ...allowedActions.map(t => ({ key: t, label: MOVEMENT_TYPES[t].label, disabled: !refs, onClick: () => setPosting(t) })),
              ...(allowedActions.includes('opening_balance')
                ? [{ key: 'div', divider: true }, { key: 'import', label: 'Import stock sheet', onClick: () => navigate('/stock/import') }]
                : []),
            ]} />
        )}
      </ListToolbar>
      {refs && <DoubleEntryAlert refs={refs} reloadKey={balances} onFixed={() => load()} />}
      {refs && (
        <ChipRow value={chip} onChange={setChip}
          items={isProducts ? categoryChipItems(cats, c => c.status === 'active') : materialChips} />
      )}

      {error ? <div className="card"><ErrorState message={error} onRetry={load} /></div> : (
        <section className="sk">
          <div className="sk-head">
            <span>{isProducts ? 'Finished goods' : 'Raw materials'} ({shown.length})</span>
            <span className="pl-help">{isProducts || sortBy !== 'size' ? SORT_LABEL[sortBy] : 'Material order (cement → steel)'}</span>
          </div>
          {loading ? Array.from({ length: 5 }).map((_, i) => <div key={i} className="sk-card"><span className="skeleton" /></div>)
          : shown.length === 0 ? (
            <div className="card"><EmptyState icon={Boxes}
              title={balances.length ? 'Nothing in this view' : 'No stock recorded yet'}
              description={balances.length ? 'Change the search, chips or filters to see more.' : 'Start by posting opening balances for what is on hand, then receive and issue as stock moves.'} /></div>
          ) : shown.map(c => {
            const colours = c.item.colorIds || [];
            const pcs = pcsOf(c, c.total);
            return (
              <div key={c.item.key} className="sk-card">
                <div className="sk-name">
                  <span className="sk-tags">
                    <span className="pl-tag">{isProducts ? c.item.category : c.item.materialCategory ?? 'Material'}</span>
                    {c.total <= 0 && c.curing <= 0 && <span className="sk-out">OUT</span>}
                    {c.total > 0 && branchId && reorder[branchId]?.[c.item.id] != null && c.total < reorder[branchId][c.item.id] && (
                      <span className="sk-out" title={`Below the reorder level of ${qtyText(reorder[branchId][c.item.id])} ${unit(c.unitId)}`}>LOW</span>
                    )}
                    {c.total < 0 && <span className="sk-out">BELOW ZERO</span>}
                  </span>
                  <strong>{c.item.name}</strong>
                </div>
                <div className="sk-total">
                  {!isProducts && mainUnitOf(c.item) ? (<>
                    <span><strong className={c.total < 0 ? 'text-error' : ''}>{qtyText(round(c.total / mainUnitOf(c.item).factor))}</strong> <span className="sk-unit">{unit(mainUnitOf(c.item).id)}</span></span>
                    <span className="sk-sub">({qtyText(round(c.total))} {unit(c.unitId)})</span>
                  </>) : (<>
                    <span><strong className={c.total < 0 ? 'text-error' : ''}>{qtyText(round(c.total))}</strong> <span className="sk-unit">{unit(c.unitId)}</span></span>
                    {pcs != null && <span className="sk-sub">({qtyText(pcs)} pcs)</span>}
                    {!isProducts && altOf(c, c.total) && <span className="sk-sub">({altOf(c, c.total)})</span>}
                  </>)}
                  {c.curing > 0 && <span className="sk-cure" title="In the curing store — not sellable until its quality release">+ {qtyText(round(c.curing))} {unit(c.unitId)}{pcsOf(c, c.curing) != null ? ` (${qtyText(pcsOf(c, c.curing))} pcs)` : ''} curing</span>}
                </div>
                <div className="sk-colours">
                  {colours.length > 0 ? colours.map(id => {
                    const v = c.byColour[id] ?? 0;
                    const vp = pcsOf(c, v);
                    return (
                      <div key={id} className={`sk-colour${v ? '' : ' is-zero'}`}>
                        <span className="sk-colour-name"><i style={{ background: refs.colorById[id]?.name?.toLowerCase() }} />{refs.colorById[id]?.name}</span>
                        <span><strong>{qtyText(round(v))}</strong> <span className="sk-unit">{unit(c.unitId)}</span></span>
                        {vp != null && <span className="sk-sub">({qtyText(vp)})</span>}
                      </div>
                    );
                  }) : isProducts && <span className="pl-help">Single colour{pcs != null ? ` · ${qtyText(pcs)} pcs` : ''}</span>}
                </div>
                <div className="sk-actions">
                  {isProducts ? (
                    canAt('production.create', branchId || null, null) &&
                      <button type="button" className="btn btn-outline btn-sm" onClick={() => navigate(`/production?produce=${c.item.id}`)}><Plus size={13} /> Produce</button>
                  ) : (<>
                    {allowedActions.includes('receipt') && <button type="button" className="btn btn-outline btn-sm" onClick={() => setPosting('receipt')}><Plus size={13} /> Receive</button>}
                    {allowedActions.includes('issue') && <button type="button" className="btn btn-outline btn-sm" onClick={() => setPosting('issue')}><Minus size={13} /> Issue</button>}
                  </>)}
                </div>
              </div>
            );
          })}
          {!loading && shown.length > 0 && (
            <p className="pl-help">
              {asOfDate ? `Stock at the end of ${asOfDate}, from movements dated up to then. ` : ''}Calculated from posted movements — see <Link to="/movements">Movements</Link> for the full history.
            </p>
          )}
        </section>
      )}

      {posting && refs && (
        <MovementModal type={posting} refs={refs} balances={balanceMap} defaultWarehouseId={warehouseId}
          onClose={() => setPosting(null)} onPosted={async () => { setPosting(null); await load(); }} />
      )}
    </PageShell>
  );
}
