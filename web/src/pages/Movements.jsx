import { useEffect, useMemo, useState } from 'react';
import { ArrowLeftRight } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatMoney, dateText, dateTimeText, tableDate } from '../lib/format';
import { dbErrorMessage } from '../lib/masterData';
import { MOVEMENT_TYPES, loadInventoryRefs, warehouseLabel, itemKey, qtyText } from '../lib/inventory';

/** Date (YYYY-MM-DD) a timestamp falls on in the organization's time zone */
const dateIn = (ts, tz) => { try { return new Intl.DateTimeFormat('en-CA', { timeZone: tz || 'UTC' }).format(new Date(ts)); } catch { return String(ts).slice(0, 10); } };
import PageShell from '../components/PageShell';
import { PageTabs } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import { SkeletonRow } from '../components/LoadingSpinner';

const LOAD_ERROR = "We couldn't load movements. Please try again.";
const PAGE = 500;
// every kind of movement has a plain name (2026-11-21, the user: all movements show here)
const NOUN = { production_use: 'Production use', production_output: 'Production', curing_release: 'Quality release', waste: 'Waste / broken',
  sale_delivery: 'Goods leaving', reclassification: 'Reclassification' };
const nounOf = t => MOVEMENT_TYPES[t]?.noun ?? NOUN[t] ?? t;
// the other side of a one-store movement, by its kind (Allocation: from → to)
const SOURCE = { receipt: 'Supplier', production_output: 'Production', opening_balance: 'Opening stock', adjustment: 'Adjustment', count: 'Stock count', reversal: 'Reversed (undone)', reclassification: 'Reclassified' };
const DEST = { sale_delivery: 'Customer', production_use: 'Production', issue: 'Issued out', waste: 'Waste', adjustment: 'Adjustment', count: 'Stock count', reversal: 'Reversed (undone)', reclassification: 'Reclassified' };

/*
 * The inventory ledger as documents (migration 022). Read-only: a mistake
 * is corrected by reversing the movement, which posts its exact opposite
 * and keeps both on record.
 */
export default function Movements() {
  const { organization } = useAuth();
  const { branchId, inBranch } = useBranch();
  const [refs,      setRefs]      = useState(null);
  const [movements, setMovements] = useState([]);
  const [people,    setPeople]    = useState({});
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [type,        setType]        = useState('');
  const [warehouseId, setWarehouseId] = useState('');
  const [viewing,     setViewing]     = useState(null);
  const [kind,        setKind]        = useState('products');   // products | materials (2026-11-21, the user)

  async function load() {
    setError('');
    try {
      // With a branch picked, only its movements are fetched (incl. transfers
      // into it) — so the row limit never hides them behind other branches'
      let scope = q => q;
      if (branchId) {
        const { data: whs, error: whErr } = await supabase.from('warehouses').select('id').eq('branch_id', branchId);
        if (whErr) throw whErr;
        const ids = (whs || []).map(w => w.id);
        scope = q => q.or(ids.length ? `branch_id.eq.${branchId},to_warehouse_id.in.(${ids.join(',')})` : `branch_id.eq.${branchId}`);
      }
      const [r, mv] = await Promise.all([
        loadInventoryRefs(),
        scope(supabase.from('inventory_movements')
          .select(`id, movement_type, movement_date, created_at, created_by, branch_id, warehouse_id, to_warehouse_id,
                   reference, reason, notes, reverses_movement_id, supplier:suppliers(name),
                   sale:sales(id, sale_no, walk_in_name, customer:customers(name)),
                   lines:inventory_transactions(id, transaction_type, warehouse_id, material_id, product_id, color_id, quantity, stock_unit_id,
                                                entered_quantity, entered_unit_id, counted_quantity, unit_cost)`)
          // the day it happened, newest first; the same day in the order recorded, latest first (2026-11-21, the user)
          .order('movement_date', { ascending: false }).order('created_at', { ascending: false }))
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

  useEffect(() => { setWarehouseId(''); setLoading(true); load(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  const whById = useMemo(() => Object.fromEntries((refs?.warehouses || []).map(w => [w.id, w])), [refs]);
  const reversedBy = useMemo(() => Object.fromEntries(movements.filter(m => m.reverses_movement_id).map(m => [m.reverses_movement_id, m])), [movements]);
  const ofKind = m => m.lines.some(l => (kind === 'products' ? l.product_id : l.material_id));
  const types = [...new Set(movements.filter(ofKind).map(m => m.movement_type))].sort((a, b) => nounOf(a).localeCompare(nounOf(b)));
  const shown = movements.filter(m => ofKind(m) && (!type || m.movement_type === type)
    && (inBranch(whById[m.warehouse_id]?.branch_id) || inBranch(whById[m.to_warehouse_id]?.branch_id))
    && (!warehouseId || m.warehouse_id === warehouseId || m.to_warehouse_id === warehouseId));

  // One row an item (2026-11-21, the user): Date · Type · Item · Qty · Allocation (from → to) · Reference.
  // A movement's legs for the same item give its from and to (a transfer, a quality release, broken → Rejects);
  // a single leg's other side is named by the kind of movement (production, the customer, the supplier…).
  const storeName = id => whById[id]?.name ?? '—';
  const rowsOf = m => {
    const g = {};
    for (const l of m.lines) {
      if (kind === 'products' ? !l.product_id : !l.material_id) continue;
      const k = itemKey(l) + '|' + (l.color_id ?? '');
      (g[k] ||= { line: l, out: [], in: [] })[Number(l.quantity) < 0 ? 'out' : 'in'].push(l);
    }
    return Object.values(g).map(({ line, out, in: inn }) => {
      const sum = ls => ls.reduce((t, l) => t + Math.abs(Number(l.quantity)), 0);
      const qty = out.length ? sum(out) : sum(inn);
      const from = out.length ? [...new Set(out.map(l => storeName(l.warehouse_id)))].join(', ')
        : (m.movement_type === 'receipt' && m.supplier?.name) || SOURCE[m.movement_type] || '—';
      const to = inn.length ? [...new Set(inn.map(l => storeName(l.warehouse_id)))].join(', ')
        : m.movement_type === 'transfer' ? storeName(m.to_warehouse_id) : DEST[m.movement_type] || '—';
      const it = refs?.items[itemKey(line)];
      return { key: `${m.id}|${itemKey(line)}|${line.color_id ?? ''}`, m, name: `${it?.name ?? '—'}${line.color_id ? ` ${refs?.colorById[line.color_id]?.name ?? ''}` : ''}`,
        qty, unit: refs?.unitById[line.stock_unit_id]?.symbol ?? '', from, to };
    });
  };
  const tableRows = shown.flatMap(rowsOf);

  return (
    <PageShell title="Movements" subtitle="Inventory">
      <PageTabs tabs={[['products', 'Products'], ['materials', 'Materials']]} value={kind} onChange={k => { setKind(k); setType(''); }} />
      <div className="flex items-center gap-8 mb-16" style={{ flexWrap: 'wrap' }}>
        <select className="form-input" style={{ width: 'auto' }} aria-label="Type" value={type} onChange={e => setType(e.target.value)}>
          <option value="">All types</option>
          {types.map(k => <option key={k} value={k}>{nounOf(k)}</option>)}
        </select>
        <select className="form-input" style={{ width: 'auto' }} aria-label="Store" value={warehouseId} onChange={e => setWarehouseId(e.target.value)}>
          <option value="">All stores</option>
          {(refs?.warehouses || []).filter(w => inBranch(w.branch_id)).map(w => <option key={w.id} value={w.id}>{warehouseLabel(w)}</option>)}
        </select>
      </div>

      <div className="card">
        {error ? <ErrorState message={error} onRetry={load} /> : (
          <div className="table-container">
            <table className="mv-table">
              <thead><tr><th>Date</th><th>Type</th><th>Item</th><th className="num">Qty</th><th>Allocation</th><th>Reference</th><th aria-label="Actions" /></tr></thead>
              <tbody>
                {loading ? Array.from({ length: 5 }).map((_, i) => <SkeletonRow key={i} cols={7} />)
                : tableRows.length === 0 ? (
                  <tr><td colSpan={7}><EmptyState icon={ArrowLeftRight} title="No movements yet" description="Receipts, issues, transfers, adjustments and counts appear here once posted." /></td></tr>
                ) : tableRows.map(({ key, m, name, qty, unit, from, to }) => (
                  <tr key={key} title={people[m.created_by] ? `By ${people[m.created_by]}` : undefined}>
                    <td className="text-muted">{tableDate(m.movement_date)}</td>
                    <td>
                      <span className="badge badge-neutral">{nounOf(m.movement_type)}</span>
                      {reversedBy[m.id] && <span className="badge badge-warning" style={{ marginLeft: 4 }}>reversed</span>}
                      {dateIn(m.created_at, organization?.timezone) > m.movement_date && (
                        <div className="pl-help" title={`Recorded ${tableDate(m.created_at, organization?.timezone)}`}>entered {tableDate(m.created_at, organization?.timezone)}</div>
                      )}
                    </td>
                    <td className="text-sm"><strong>{name}</strong></td>
                    <td className="num">{qtyText(Math.round(qty * 1000) / 1000)} <span className="pl-help">{unit}</span></td>
                    <td className="text-sm">{from} <span className="pl-help">→</span> {to}</td>
                    <td className="text-sm text-muted">{m.reference || m.supplier?.name || '—'}{m.sale && <div className="pl-help">{m.sale.customer?.name || m.sale.walk_in_name || 'Walk-in'}</div>}</td>
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
  const navigate = useNavigate();
  const { canAt, canManage, organization } = useAuth();
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
  // A reversal is a correction: non-admins send it for approval (migration 033)
  const reverseNeedsApproval = !canManage('inventory.adjust');
  const [requested, setRequested] = useState(false);
  const unit = id => refs.unitById[id]?.symbol ?? '';
  // one line an item (2026-11-21, the user): its two sides as an allocation, from → to, each store's balance after
  const nameOf = id => whById[id]?.name ?? '—';
  const groups = Object.values(m.lines.reduce((g, l) => {
    const k = itemKey(l) + '|' + (l.color_id ?? '');
    (g[k] ||= { k, line: l, out: [], in: [] })[Number(l.quantity) < 0 ? 'out' : 'in'].push(l);
    return g;
  }, {})).map(g => ({ ...g,
    from: g.out.length ? [...new Set(g.out.map(l => nameOf(l.warehouse_id)))].join(', ') : (m.movement_type === 'receipt' && m.supplier?.name) || SOURCE[m.movement_type] || '—',
    to: g.in.length ? [...new Set(g.in.map(l => nameOf(l.warehouse_id)))].join(', ') : m.movement_type === 'transfer' ? nameOf(m.to_warehouse_id) : DEST[m.movement_type] || '—',
    main: g.out[0] ?? g.in[0] }));

  async function reverse() {
    setError('');
    if (!reason.trim()) { setError('Give a reason for the reversal.'); return; }
    setBusy(true);
    if (reverseNeedsApproval) {
      const { error: err } = await supabase.rpc('request_change', {
        p_kind: 'stock_reversal', p_branch_id: null, p_payload: { movement_id: m.id, reason: reason.trim() },
        p_summary: `Reverse the ${nounOf(m.movement_type).toLowerCase()} of ${dateText(m.movement_date)} at ${warehouseLabel(whById[m.warehouse_id])} — ${reason.trim()}`,
      });
      setBusy(false);
      if (err) { setError(dbErrorMessage(err, "We couldn't send this for approval. Please try again.")); return; }
      setRequested(true);
      return;
    }
    const { error: err } = await supabase.rpc('reverse_inventory_movement', { p_movement_id: m.id, p_reason: reason.trim() });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't reverse this movement. Please try again.")); return; }
    onReversed();
  }

  return (
    <Modal title={`${nounOf(m.movement_type)} · ${dateText(m.movement_date)}`} onClose={onClose} size="lg"
      footer={<button type="button" className="btn btn-outline" onClick={onClose}>Close</button>}>
      <div className="modal-form">
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        <dl className="detail-list text-sm">
          <dt>Allocation</dt><dd>{[...new Set(groups.map(g => `${g.from} → ${g.to}`))].join(' · ')}</dd>
          {m.supplier && <><dt>Supplier</dt><dd>{m.supplier.name}</dd></>}
          {m.reason && <><dt>Reason</dt><dd>{m.reason}</dd></>}
          {m.reference && <><dt>Reference</dt><dd>{m.reference}</dd></>}
          {/* the sale's buyer, and the sale itself in Sales (2026-11-21, the user) */}
          {m.sale && <><dt>Customer</dt><dd>{m.sale.customer?.name || m.sale.walk_in_name || 'Walk-in'}
            <div><a className="link-btn" href={`/sales?sale=${m.sale.id}`} onClick={e => { e.preventDefault(); onClose(); navigate(`/sales?sale=${m.sale.id}`); }}>Open sale #{m.sale.sale_no} in Sales</a></div></dd></>}
          {m.notes && <><dt>Notes</dt><dd>{m.notes}</dd></>}
          <dt>Dated</dt><dd>{dateText(m.movement_date)}</dd>
          <dt>Recorded</dt><dd>{dateTimeText(m.created_at, organization?.timezone)} by {people[m.created_by] || 'a user'}</dd>
          {original && <><dt>Reverses</dt><dd>{nounOf(original.movement_type)} of {dateText(original.movement_date)}</dd></>}
          {reversal && <><dt>Reversed</dt><dd>{dateText(reversal.movement_date)} — {reversal.reason}</dd></>}
        </dl>
        <div className="table-container">
          <table>
            <thead><tr><th>Item</th><th>Allocation</th><th style={{ textAlign: 'right' }}>Qty</th><th style={{ textAlign: 'right' }} title="Stock in each store right after this movement, in date order">Balance after</th></tr></thead>
            <tbody>
              {groups.map(g => { const l = g.main; return (
                <tr key={g.k}>
                  <td>{refs.items[itemKey(l)]?.name ?? '—'}{l.color_id && <span className="text-muted"> · {refs.colorById[l.color_id]?.name}</span>}</td>
                  <td className="text-sm">{g.from} <span className="pl-help">→</span> {g.to}</td>
                  <td style={{ textAlign: 'right' }} className="text-sm">
                    {l.transaction_type === 'count'
                      ? <>found {qtyText(l.entered_quantity)} {unit(l.entered_unit_id)}</>
                      : <strong>{qtyText(Math.abs(l.entered_quantity))} {unit(l.entered_unit_id)}</strong>}
                    {l.unit_cost != null && <div className="text-muted">{formatMoney(l.unit_cost, organization?.currency_code)} each</div>}
                  </td>
                  <td style={{ textAlign: 'right' }} className="text-sm text-muted">{[...g.out, ...g.in].map(x => (after[x.id] != null ? <div key={x.id}>{nameOf(x.warehouse_id)} {qtyText(after[x.id])} {unit(x.stock_unit_id)}</div> : null))}</td>
                </tr>
              ); })}
            </tbody>
          </table>
        </div>
        {canReverse && (
          requested ? (
            <div className="alert alert-info" role="status">Reversal sent for approval.</div>
          ) : confirm ? (
            <div className="confirm-box">
              <p className="text-sm">Reversing posts the exact opposite of this movement. Both stay on record.{reverseNeedsApproval ? " A reversal needs an admin's approval: it is sent to the Approvals queue." : ''}</p>
              <input className="form-input" placeholder="Reason, e.g. entered twice" aria-label="Reason for reversal" value={reason} onChange={e => setReason(e.target.value)} />
              <div className="flex gap-8">
                <button type="button" className="btn btn-outline btn-sm" disabled={busy} onClick={reverse}>{reverseNeedsApproval ? 'Submit reversal for approval' : 'Reverse movement'}</button>
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
