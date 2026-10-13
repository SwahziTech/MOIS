import { useEffect, useMemo, useState } from 'react';
import { Boxes, Search } from 'lucide-react';
import { Link } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { MOVEMENT_TYPES, loadInventoryRefs, warehouseLabel, itemKey, qtyText, orgToday } from '../lib/inventory';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import { SkeletonRow } from '../components/LoadingSpinner';
import MovementModal from '../components/inventory/MovementModal';

const LOAD_ERROR = "We couldn't load stock. Please try again.";
const ACTIONS = ['receipt', 'issue', 'transfer', 'adjustment', 'count', 'opening_balance'];

/*
 * Stock on hand = the sum of the inventory ledger (stock_balances view,
 * migration 022). Nothing here edits a number: every change is a posted
 * movement.
 */
export default function Stock() {
  const { canAt, organization } = useAuth();
  const today = orgToday(organization?.timezone);
  const [asOfDate, setAsOfDate] = useState('');   // '' = now
  const [refs,     setRefs]     = useState(null);
  const [balances, setBalances] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [search,  setSearch]  = useState('');
  const [branchId,    setBranchId]    = useState('');
  const [warehouseId, setWarehouseId] = useState('');
  const [kind,        setKind]        = useState('');
  const [showZero,    setShowZero]    = useState(false);
  const [posting,     setPosting]     = useState(null);   // movement type

  async function load(date = asOfDate) {
    setError('');
    try {
      const [r, bal] = await Promise.all([
        loadInventoryRefs(),
        date && date < today
          ? supabase.rpc('stock_balances_as_of', { p_date: date })
          : supabase.from('stock_balances').select('warehouse_id, material_id, product_id, stock_unit_id, quantity, last_movement_date'),
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

  const whById = useMemo(() => Object.fromEntries((refs?.warehouses || []).map(w => [w.id, w])), [refs]);
  const balanceMap = useMemo(() => Object.fromEntries(balances.map(b => [`${b.warehouse_id}|${itemKey(b)}`, b.quantity])), [balances]);
  const branches = useMemo(() => {
    const m = {};
    for (const w of refs?.warehouses || []) if (w.branch) m[w.branch.id] = w.branch.name;
    return Object.entries(m).sort((a, b) => a[1].localeCompare(b[1]));
  }, [refs]);

  const activeWarehouses = (refs?.warehouses || []).filter(w => w.status === 'active');
  const allowedActions = ACTIONS.filter(t => activeWarehouses.some(w => canAt(MOVEMENT_TYPES[t].perm, w.branch_id, w.id)));

  const q = search.trim().toLowerCase();
  const rows = balances
    .map(b => ({ ...b, item: refs?.items[itemKey(b)], wh: whById[b.warehouse_id] }))
    .filter(b => b.item && b.wh
      && (showZero || Number(b.quantity) !== 0)
      && (!branchId || b.wh.branch_id === branchId)
      && (!warehouseId || b.warehouse_id === warehouseId)
      && (!kind || b.item.kind === kind)
      && (!q || b.item.name.toLowerCase().includes(q)))
    .sort((a, b) => a.item.name.localeCompare(b.item.name) || warehouseLabel(a.wh).localeCompare(warehouseLabel(b.wh)));

  return (
    <PageShell
      title="Stock"
      subtitle="Inventory"
      actions={
        <div className="search-wrapper">
          <Search size={14} className="search-icon" />
          <input id="stock-search" type="search" className="search-input" placeholder="Search items…" value={search} onChange={e => setSearch(e.target.value)} />
        </div>
      }
    >
      {allowedActions.length > 0 && (
        <div className="flex gap-8 mb-16" style={{ flexWrap: 'wrap' }}>
          {allowedActions.map(t => (
            <button key={t} type="button" className={`btn ${t === 'receipt' ? 'btn-primary' : 'btn-outline'}`} disabled={!refs} onClick={() => setPosting(t)}>
              {MOVEMENT_TYPES[t].label}
            </button>
          ))}
        </div>
      )}

      <div className="flex items-center gap-8 mb-16" style={{ flexWrap: 'wrap' }}>
        <select className="form-input" style={{ width: 'auto' }} aria-label="Branch" value={branchId} onChange={e => { setBranchId(e.target.value); setWarehouseId(''); }}>
          <option value="">All branches</option>
          {branches.map(([id, name]) => <option key={id} value={id}>{name}</option>)}
        </select>
        <select className="form-input" style={{ width: 'auto' }} aria-label="Store" value={warehouseId} onChange={e => setWarehouseId(e.target.value)}>
          <option value="">All stores</option>
          {activeWarehouses.filter(w => !branchId || w.branch_id === branchId).map(w => <option key={w.id} value={w.id}>{warehouseLabel(w)}</option>)}
        </select>
        <select className="form-input" style={{ width: 'auto' }} aria-label="Item type" value={kind} onChange={e => setKind(e.target.value)}>
          <option value="">Materials and products</option>
          <option value="material">Materials</option>
          <option value="product">Products</option>
        </select>
        <label className="text-sm flex items-center gap-4">
          As of
          <input type="date" className="form-input" style={{ width: 'auto' }} max={today} value={asOfDate || today}
            onChange={e => { const d = e.target.value === today ? '' : e.target.value; setAsOfDate(d); setLoading(true); load(d); }} />
        </label>
        <label className="text-sm flex items-center gap-4">
          <input type="checkbox" checked={showZero} onChange={e => setShowZero(e.target.checked)} /> Show zero stock
        </label>
      </div>

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
                  <tr key={`${b.warehouse_id}|${itemKey(b)}`}>
                    <td>
                      <div style={{ fontWeight: 500 }}>{b.item.name}</div>
                      <div className="text-xs text-muted">{b.item.kind === 'material' ? 'Material' : `Product · ${b.item.category ?? ''}`}</div>
                    </td>
                    <td className="text-muted">{warehouseLabel(b.wh)}</td>
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
