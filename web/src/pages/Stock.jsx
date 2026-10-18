import { useEffect, useMemo, useState } from 'react';
import { Boxes, Search, Plus } from 'lucide-react';
import { Link, useNavigate } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { MOVEMENT_TYPES, loadInventoryRefs, warehouseLabel, itemKey, stockKey, qtyText, orgToday } from '../lib/inventory';
import PageShell from '../components/PageShell';
import { ListToolbar, ChipRow, ActionMenu, categoryChipItems } from '../components/ListControls';
import { categoryTools } from '../lib/categories';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import { SkeletonRow } from '../components/LoadingSpinner';
import MovementModal from '../components/inventory/MovementModal';
import { DoubleEntryAlert } from '../components/inventory/DoubleEntry';

const LOAD_ERROR = "We couldn't load stock. Please try again.";
const ACTIONS = ['receipt', 'issue', 'transfer', 'adjustment', 'count', 'opening_balance'];

/*
 * Stock on hand = the sum of the inventory ledger (stock_balances view,
 * migration 022). Nothing here edits a number: every change is a posted
 * movement.
 */
export default function Stock() {
  const { canAt, organization } = useAuth();
  const navigate = useNavigate();
  const today = orgToday(organization?.timezone);
  const [asOfDate, setAsOfDate] = useState('');   // '' = now
  const [refs,     setRefs]     = useState(null);
  const [balances, setBalances] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [search,  setSearch]  = useState('');
  const { branchId, setBranchId, branches, allowAll } = useBranch();
  const [warehouseId, setWarehouseId] = useState('');
  const [kind,        setKind]        = useState('');
  const [showZero,    setShowZero]    = useState(false);
  const [chip,        setChip]        = useState('');          // '' | 'materials' | a product category (or group)
  const [sortBy,      setSortBy]      = useState('name');      // name | qty_desc | qty_asc | recent
  const [posting,     setPosting]     = useState(null);   // movement type

  async function load(date = asOfDate) {
    setError('');
    try {
      const [r, bal] = await Promise.all([
        loadInventoryRefs(),
        date && date < today
          ? supabase.rpc('stock_balances_as_of', { p_date: date })
          : supabase.from('stock_balances').select('warehouse_id, material_id, product_id, color_id, stock_unit_id, quantity, last_movement_date'),
      ]);
      if (bal.error) throw bal.error;
      setRefs(r);
      setBalances(bal.data || []);
    } catch (err) {
      console.error(err);
      setError(LOAD_ERROR);
    }
    setLoading(false);
  }

  useEffect(() => { load(); }, []);
  useEffect(() => { setWarehouseId(''); }, [branchId]);

  const whById = useMemo(() => Object.fromEntries((refs?.warehouses || []).map(w => [w.id, w])), [refs]);
  const balanceMap = useMemo(() => Object.fromEntries(balances.map(b => [`${b.warehouse_id}|${stockKey(b)}`, b.quantity])), [balances]);

  const activeWarehouses = (refs?.warehouses || []).filter(w => w.status === 'active');
  const allowedActions = ACTIONS.filter(t => activeWarehouses.some(w => canAt(MOVEMENT_TYPES[t].perm, w.branch_id, w.id)));

  const q = search.trim().toLowerCase();
  const cats = useMemo(() => categoryTools(refs?.categoryRows || []), [refs]);
  // Chips: materials, or a product category (a group stands for its categories)
  const inChip = item => !chip || (chip === 'materials' ? item.kind === 'material'
    : item.kind === 'product' && (item.categoryId === chip || cats.byId[item.categoryId]?.parent_category_id === chip));
  const byName = (a, b) => a.item.name.localeCompare(b.item.name) || warehouseLabel(a.wh).localeCompare(warehouseLabel(b.wh))
    || (refs.colorById[a.color_id]?.display_order ?? 0) - (refs.colorById[b.color_id]?.display_order ?? 0);
  const rows = balances
    .map(b => ({ ...b, item: refs?.items[itemKey(b)], wh: whById[b.warehouse_id] }))
    .filter(b => b.item && b.wh
      && (showZero || Number(b.quantity) !== 0)
      && (!branchId || b.wh.branch_id === branchId)
      && (!warehouseId || b.warehouse_id === warehouseId)
      && (!kind || b.item.kind === kind)
      && inChip(b.item)
      && (!q || b.item.name.toLowerCase().includes(q)))
    .sort((a, b) => sortBy === 'qty_desc' ? Number(b.quantity) - Number(a.quantity) || byName(a, b)
      : sortBy === 'qty_asc' ? Number(a.quantity) - Number(b.quantity) || byName(a, b)
      : sortBy === 'recent' ? String(b.last_movement_date).localeCompare(String(a.last_movement_date)) || byName(a, b)
      : byName(a, b));

  return (
    <PageShell
      title="Stock"
      subtitle="Inventory"
      description="What's on hand in each store, worked out from every recorded movement."
      actions={
        <label className="text-sm flex items-center gap-8" style={{ whiteSpace: 'nowrap' }}>
          Stock as of
          <input type="date" className="form-input" style={{ width: 'auto' }} max={today} value={asOfDate || today}
            onChange={e => { const d = e.target.value === today ? '' : e.target.value; setAsOfDate(d); setLoading(true); load(d); }} />
        </label>
      }
    >

      <ListToolbar id="stock-search" search={search} onSearch={setSearch} placeholder="Search items…"
        sort={{ value: sortBy, onChange: setSortBy, options: [
          { value: 'name',     label: 'Name: A → Z (default)' },
          { value: 'qty_desc', label: 'Quantity: highest → lowest' },
          { value: 'qty_asc',  label: 'Quantity: lowest → highest' },
          { value: 'recent',   label: 'Last movement: newest first' },
        ] }}
        filters={[
          { key: 'store', label: 'Store', value: warehouseId, onChange: setWarehouseId,
            options: [{ value: '', label: 'All stores' }, ...activeWarehouses.filter(w => !branchId || w.branch_id === branchId).map(w => ({ value: w.id, label: warehouseLabel(w) }))] },
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
          items={[{ id: 'materials', label: 'Materials' }, ...categoryChipItems(cats, c => c.status === 'active')]} />
      )}

      <div className="card">
        {error ? <ErrorState message={error} onRetry={load} /> : (
          <div className="table-container">
            <table>
              <thead><tr><th>Item</th><th>Store</th><th style={{ textAlign: 'right' }}>On hand</th><th>Last movement</th></tr></thead>
              <tbody>
                {loading ? Array.from({ length: 5 }).map((_, i) => <SkeletonRow key={i} cols={4} />)
                : rows.length === 0 ? (
                  <tr><td colSpan={4}>
                    <EmptyState icon={Boxes}
                      title={balances.length ? 'Nothing in this view' : 'No stock recorded yet'}
                      description={balances.length ? 'Change the filters to see more.' : 'Start by posting opening balances for what is on hand, then receive and issue as stock moves.'} />
                  </td></tr>
                ) : rows.map(b => (
                  <tr key={`${b.warehouse_id}|${stockKey(b)}`}>
                    <td>
                      <div style={{ fontWeight: 500 }}>{b.item.name}{b.color_id && <span className="badge badge-neutral" style={{ marginLeft: 6 }}>{refs.colorById[b.color_id]?.name}</span>}</div>
                      <div className="text-xs text-muted">{b.item.kind === 'material' ? 'Material' : `Product · ${b.item.category ?? ''}`}</div>
                    </td>
                    <td className="text-muted">{warehouseLabel(b.wh)}{b.wh.type === 'wip' && <div><span className="badge badge-accent">Curing — not sellable</span></div>}</td>
                    <td style={{ textAlign: 'right', fontWeight: 600 }} className={Number(b.quantity) < 0 ? 'text-error' : ''}>
                      {qtyText(b.quantity)} <span className="text-muted" style={{ fontWeight: 400 }}>{refs.unitById[b.stock_unit_id]?.symbol}</span>
                    </td>
                    <td className="text-muted">{b.last_movement_date}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {!loading && rows.length > 0 && (
              <div className="table-footer-note">
                {asOfDate ? `Stock at the end of ${asOfDate}, from movements dated up to then. ` : ''}Calculated from posted movements — see <Link to="/movements">Movements</Link> for the full history.
              </div>
            )}
          </div>
        )}
      </div>

      {posting && refs && (
        <MovementModal type={posting} refs={refs} balances={balanceMap} defaultWarehouseId={warehouseId}
          onClose={() => setPosting(null)} onPosted={async () => { setPosting(null); await load(); }} />
      )}
    </PageShell>
  );
}
