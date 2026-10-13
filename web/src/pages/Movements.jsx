import { useEffect, useMemo, useState } from 'react';
import { ArrowLeftRight } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { formatMoney } from '../lib/format';
import { dbErrorMessage } from '../lib/masterData';
import { MOVEMENT_TYPES, loadInventoryRefs, warehouseLabel, itemKey, qtyText } from '../lib/inventory';

/** Date (YYYY-MM-DD) a timestamp falls on in the organization's time zone */
const dateIn = (ts, tz) => { try { return new Intl.DateTimeFormat('en-CA', { timeZone: tz || 'UTC' }).format(new Date(ts)); } catch { return String(ts).slice(0, 10); } };
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import { SkeletonRow } from '../components/LoadingSpinner';

const LOAD_ERROR = "We couldn't load movements. Please try again.";
const PAGE = 200;

/*
 * The inventory ledger as documents (migration 022). Read-only: a mistake
 * is corrected by reversing the movement, which posts its exact opposite
 * and keeps both on record.
 */
export default function Movements() {
  const { organization } = useAuth();
  const [refs,      setRefs]      = useState(null);
  const [movements, setMovements] = useState([]);
  const [people,    setPeople]    = useState({});
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [type,        setType]        = useState('');
  const [warehouseId, setWarehouseId] = useState('');
  const [viewing,     setViewing]     = useState(null);

  async function load() {
    setError('');
    try {
      const [r, mv] = await Promise.all([
        loadInventoryRefs(),
        supabase.from('inventory_movements')
          .select(`id, movement_type, movement_date, created_at, created_by, branch_id, warehouse_id, to_warehouse_id,
                   reference, reason, notes, reverses_movement_id, supplier:suppliers(name),
                   lines:inventory_transactions(id, transaction_type, warehouse_id, material_id, product_id, color_id, quantity, stock_unit_id,
                                                entered_quantity, entered_unit_id, counted_quantity, unit_cost)`)
          .order('movement_date', { ascending: false }).order('created_at', { ascending: false })
          .limit(PAGE),
      ]);
      if (mv.error) throw mv.error;
      const ids = [...new Set((mv.data || []).map(m => m.created_by))];
      if (ids.length) {
        const { data: ppl } = await supabase.from('profiles').select('id, first_name, last_name, email').in('id', ids);
        setPeople(Object.fromEntries((ppl || []).map(p => [p.id, [p.first_name, p.last_name].filter(Boolean).join(' ') || p.email])));
      }
      setRefs(r);
      setMovements(mv.data || []);
    } catch (err) {
      console.error(err);
      setError(LOAD_ERROR);
    }
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  const whById = useMemo(() => Object.fromEntries((refs?.warehouses || []).map(w => [w.id, w])), [refs]);
  const reversedBy = useMemo(() => Object.fromEntries(movements.filter(m => m.reverses_movement_id).map(m => [m.reverses_movement_id, m])), [movements]);
  const shown = movements.filter(m => (!type || m.movement_type === type)
    && (!warehouseId || m.warehouse_id === warehouseId || m.to_warehouse_id === warehouseId));

  const where = m => m.movement_type === 'transfer'
    ? `${warehouseLabel(whById[m.warehouse_id])} → ${warehouseLabel(whById[m.to_warehouse_id])}`
    : warehouseLabel(whById[m.warehouse_id]);
  const summary = m => {
    const lines = m.lines.filter(l => l.transaction_type !== 'transfer_in');
    const first = lines[0] && refs?.items[itemKey(lines[0])]?.name;
    return lines.length > 1 ? `${first} and ${lines.length - 1} more` : first ?? '—';
  };

  return (
    <PageShell title="Movements" subtitle="Inventory">
      <div className="flex items-center gap-8 mb-16" style={{ flexWrap: 'wrap' }}>
        <select className="form-input" style={{ width: 'auto' }} aria-label="Type" value={type} onChange={e => setType(e.target.value)}>
          <option value="">All types</option>
          {Object.entries(MOVEMENT_TYPES).map(([k, d]) => <option key={k} value={k}>{d.noun}</option>)}
        </select>
        <select className="form-input" style={{ width: 'auto' }} aria-label="Store" value={warehouseId} onChange={e => setWarehouseId(e.target.value)}>
          <option value="">All stores</option>
          {(refs?.warehouses || []).map(w => <option key={w.id} value={w.id}>{warehouseLabel(w)}</option>)}
        </select>
      </div>

      <div className="card">
        {error ? <ErrorState message={error} onRetry={load} /> : (
          <div className="table-container">
            <table>
              <thead><tr><th>Date</th><th>Type</th><th>Store</th><th>Items</th><th>Reference</th><th>By</th><th aria-label="Actions" /></tr></thead>
              <tbody>
                {loading ? Array.from({ length: 5 }).map((_, i) => <SkeletonRow key={i} cols={7} />)
                : shown.length === 0 ? (
                  <tr><td colSpan={7}><EmptyState icon={ArrowLeftRight} title="No movements yet" description="Receipts, issues, transfers, adjustments and counts appear here once posted." /></td></tr>
                ) : shown.map(m => (
                  <tr key={m.id}>
                    <td className="text-muted">{m.movement_date}</td>
                    <td>
                      <span className="badge badge-neutral">{MOVEMENT_TYPES[m.movement_type]?.noun ?? m.movement_type}</span>
                      {reversedBy[m.id] && <span className="badge badge-warning" style={{ marginLeft: 4 }}>reversed</span>}
                      {dateIn(m.created_at, organization?.timezone) > m.movement_date && (
                        <span className="badge badge-neutral" style={{ marginLeft: 4 }} title={`Recorded ${dateIn(m.created_at, organization?.timezone)}`}>entered later</span>
                      )}
                    </td>
                    <td className="text-sm">{where(m)}</td>
                    <td className="text-sm">{summary(m)}</td>
                    <td className="text-sm text-muted">{m.reference || m.supplier?.name || '—'}</td>
                    <td className="text-sm text-muted">{people[m.created_by] || '—'}</td>
                    <td style={{ textAlign: 'right' }}><button type="button" className="btn btn-outline btn-sm" onClick={() => setViewing(m)}>View</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
            {!loading && movements.length === PAGE && <div className="table-footer-note">Showing the latest {PAGE} movements.</div>}
          </div>
        )}
      </div>

      {viewing && refs && (
        <MovementDetail movement={viewing} refs={refs} whById={whById} people={people}
          original={movements.find(m => m.id === viewing.reverses_movement_id)}
          reversal={reversedBy[viewing.id]}
          onClose={() => setViewing(null)} onReversed={async () => { setViewing(null); await load(); }} />
      )}
    </PageShell>
  );
}

function MovementDetail({ movement: m, refs, whById, people, original, reversal, onClose, onReversed }) {
  const { canAt, organization } = useAuth();
  const [reason, setReason] = useState('');
  const [confirm, setConfirm] = useState(false);
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  const [after, setAfter] = useState({});   // line id → store balance after it (date order)
  useEffect(() => {
    supabase.from('inventory_ledger_running').select('id, running_balance').eq('movement_id', m.id)
      .then(({ data }) => setAfter(Object.fromEntries((data || []).map(r => [r.id, r.running_balance]))));
  }, [m.id]);
  const canReverse = m.movement_type !== 'reversal' && !reversal && canAt('inventory.adjust', m.branch_id, m.warehouse_id);
  const unit = id => refs.unitById[id]?.symbol ?? '';

  async function reverse() {
    setError('');
    if (!reason.trim()) { setError('Give a reason for the reversal.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('reverse_inventory_movement', { p_movement_id: m.id, p_reason: reason.trim() });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't reverse this movement. Please try again.")); return; }
    onReversed();
  }

  return (
    <Modal title={`${MOVEMENT_TYPES[m.movement_type]?.noun ?? m.movement_type} · ${m.movement_date}`} onClose={onClose} size="lg"
      footer={<button type="button" className="btn btn-outline" onClick={onClose}>Close</button>}>
      <div className="modal-form">
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        <dl className="detail-list text-sm">
          <dt>Store</dt><dd>{m.movement_type === 'transfer' ? `${warehouseLabel(whById[m.warehouse_id])} → ${warehouseLabel(whById[m.to_warehouse_id])}` : warehouseLabel(whById[m.warehouse_id])}</dd>
          {m.supplier && <><dt>Supplier</dt><dd>{m.supplier.name}</dd></>}
          {m.reason && <><dt>Reason</dt><dd>{m.reason}</dd></>}
          {m.reference && <><dt>Reference</dt><dd>{m.reference}</dd></>}
          {m.notes && <><dt>Notes</dt><dd>{m.notes}</dd></>}
          <dt>Dated</dt><dd>{m.movement_date}</dd>
          <dt>Recorded</dt><dd>{new Date(m.created_at).toLocaleString('en-GB', { timeZone: organization?.timezone || undefined })} by {people[m.created_by] || 'a user'}</dd>
          {original && <><dt>Reverses</dt><dd>{MOVEMENT_TYPES[original.movement_type]?.noun} of {original.movement_date}</dd></>}
          {reversal && <><dt>Reversed</dt><dd>{reversal.movement_date} — {reversal.reason}</dd></>}
        </dl>
        <div className="table-container">
          <table>
            <thead><tr><th>Item</th><th>Store</th><th>As entered</th><th style={{ textAlign: 'right' }}>Stock change</th><th style={{ textAlign: 'right' }} title="Stock in that store right after this line, in date order">Balance after</th></tr></thead>
            <tbody>
              {m.lines.map(l => (
                <tr key={l.id}>
                  <td>{refs.items[itemKey(l)]?.name ?? '—'}{l.color_id && <span className="text-muted"> · {refs.colorById[l.color_id]?.name}</span>}</td>
                  <td className="text-sm text-muted">{warehouseLabel(whById[l.warehouse_id])}</td>
                  <td className="text-sm">
                    {l.transaction_type === 'count'
                      ? `found ${qtyText(l.entered_quantity)} ${unit(l.entered_unit_id)}`
                      : `${qtyText(Math.abs(l.entered_quantity))} ${unit(l.entered_unit_id)}`}
                    {l.unit_cost != null && <span className="text-muted"> · {formatMoney(l.unit_cost, organization?.currency_code)} each</span>}
                  </td>
                  <td style={{ textAlign: 'right', fontWeight: 600 }} className={Number(l.quantity) < 0 ? 'text-error' : ''}>
                    {Number(l.quantity) > 0 ? '+' : ''}{qtyText(l.quantity)} {unit(l.stock_unit_id)}
                  </td>
                  <td style={{ textAlign: 'right' }} className="text-muted">{after[l.id] != null ? `${qtyText(after[l.id])} ${unit(l.stock_unit_id)}` : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {canReverse && (
          confirm ? (
            <div className="confirm-box">
              <p className="text-sm">Reversing posts the exact opposite of this movement today. Both stay on record.</p>
              <input className="form-input" placeholder="Reason, e.g. entered twice" aria-label="Reason for reversal" value={reason} onChange={e => setReason(e.target.value)} />
              <div className="flex gap-8">
                <button type="button" className="btn btn-outline btn-sm" disabled={busy} onClick={reverse}>Reverse movement</button>
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => setConfirm(false)}>Keep it</button>
              </div>
            </div>
          ) : (
            <button type="button" className="btn btn-ghost btn-sm" style={{ alignSelf: 'flex-start' }} onClick={() => setConfirm(true)}>Reverse this movement…</button>
          )
        )}
      </div>
    </Modal>
  );
}
