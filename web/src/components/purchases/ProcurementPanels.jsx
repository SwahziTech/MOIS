import { useEffect, useMemo, useState } from 'react';
import { Plus, Trash2, Printer } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { formatMoney, formatAmount, dateText } from '../../lib/format';
import { dbErrorMessage } from '../../lib/masterData';
import { qtyText, orgToday } from '../../lib/inventory';
import Modal from '../Modal';
import NumberInput from '../NumberInput';

const num = v => (v === '' || v === null || v === undefined || Number.isNaN(Number(v)) ? null : Number(v));
const r2 = n => Math.round(n * 100) / 100;
const REQ = { waiting: ['Waiting', 'badge-warning'], approved: ['Approved', 'badge-info'], rejected: ['Turned down', 'badge-error'], ordered: ['Ordered', 'badge-success'], done: ['Bought', 'badge-success'], cancelled: ['Cancelled', 'badge-neutral'] };
const PO = { open: ['Open', 'badge-info'], closed: ['Closed', 'badge-neutral'], cancelled: ['Cancelled', 'badge-neutral'] };

/*
 * Procurement (1c's "Not yet" items, migration 077): purchase requests asked
 * by the storekeeper or secretary and approved by the branch manager;
 * purchase orders to suppliers (from a request or on their own), kept in
 * MOIS and printable for the supplier; payments to suppliers per purchase.
 */

/* Material lines for a request or an order: material, quantity, unit (its own units), price (orders) */
function MaterialLines({ refs, branchId, lines, setLines, withPrice }) {
  const mats = useMemo(() => Object.values(refs?.items || {}).filter(i => i.kind === 'material' && i.status === 'active' && (!i.branchId || i.branchId === branchId))
    .sort((a, b) => a.rank - b.rank || a.name.localeCompare(b.name)), [refs, branchId]);
  const set = (i, patch) => setLines(ls => ls.map((l, j) => (j === i ? { ...l, ...patch } : l)));
  return (
    <table className="rd-table">
      <thead><tr><th>Material</th><th className="num">Quantity</th><th>Unit</th>{withPrice && <th className="num">Price a unit (TZS)</th>}<th /></tr></thead>
      <tbody>
        {lines.map((l, i) => {
          const it = refs?.items[`m:${l.materialId}`];
          return (
            <tr key={i}>
              <td><select className="form-input" value={l.materialId} onChange={e => { const m = refs.items[`m:${e.target.value}`]; set(i, { materialId: e.target.value, unitId: m?.mainUnitId || m?.stockUnitId || '' }); }}>
                <option value="">Choose…</option>{mats.map(m => <option key={m.id} value={m.id}>{m.materialCategory ? `${m.materialCategory} · ` : ''}{m.name}</option>)}</select></td>
              <td className="num"><NumberInput step="any" min="0" className="form-input" style={{ width: 100 }} value={l.quantity} onChange={e => set(i, { quantity: e.target.value })} /></td>
              <td><select className="form-input" value={l.unitId} onChange={e => set(i, { unitId: e.target.value })} disabled={!it}>
                {(it?.units || []).map(u => <option key={u.id} value={u.id}>{refs.unitById[u.id]?.symbol ?? '—'}</option>)}</select></td>
              {withPrice && <td className="num"><NumberInput step="any" min="0" className="form-input" style={{ width: 120 }} placeholder="optional" value={l.price ?? ''} onChange={e => set(i, { price: e.target.value })} /></td>}
              <td>{lines.length > 1 && <button type="button" className="btn btn-ghost btn-sm" aria-label="Remove line" onClick={() => setLines(ls => ls.filter((_, j) => j !== i))}><Trash2 size={13} /></button>}</td>
            </tr>
          );
        })}
      </tbody>
      <tfoot><tr><td colSpan={withPrice ? 5 : 4}><button type="button" className="btn btn-ghost btn-sm" onClick={() => setLines(ls => [...ls, { materialId: '', quantity: '', unitId: '', price: '' }])}><Plus size={13} /> Add a material</button></td></tr></tfoot>
    </table>
  );
}

const lineText = (refs, l, cats = [], money = v => v) => (l.kind === 'expense'
  ? `${cats.find(c => c.id === l.category_id)?.name ?? 'Expense'}: ${l.description}${l.quantity != null ? ` · ${qtyText(Number(l.quantity))} ${l.unit_text ?? ''}` : ''}${l.amount != null ? ` · ${money(Number(l.amount))}` : ''}`
  : `${qtyText(Number(l.quantity))} ${refs?.unitById[l.unit_id]?.symbol ?? ''} ${refs?.items[`m:${l.material_id}`]?.name ?? '—'}`);

/* A request's lines: each a material (quantity in its units) or an expense of a kind (description, quantity, about how much) */
function RequestLines({ refs, branchId, cats, lines, setLines }) {
  const mats = useMemo(() => Object.values(refs?.items || {}).filter(i => i.kind === 'material' && i.status === 'active' && (!i.branchId || i.branchId === branchId))
    .sort((a, b) => a.rank - b.rank || a.name.localeCompare(b.name)), [refs, branchId]);
  const set = (i, patch) => setLines(ls => ls.map((l, j) => (j === i ? { ...l, ...patch } : l)));
  return (
    <table className="rd-table">
      <thead><tr><th>Kind</th><th>What</th><th className="num">Quantity</th><th>Unit</th><th className="num">About (TZS)</th><th /></tr></thead>
      <tbody>
        {lines.map((l, i) => {
          const it = refs?.items[`m:${l.materialId}`];
          return (
            <tr key={i}>
              <td><select className="form-input" value={l.kind} onChange={e => set(i, { kind: e.target.value })}>
                <option value="material">Material</option><option value="expense">Expense</option></select></td>
              <td>{l.kind === 'material'
                ? <select className="form-input" value={l.materialId} onChange={e => { const m = refs.items[`m:${e.target.value}`]; set(i, { materialId: e.target.value, unitId: m?.mainUnitId || m?.stockUnitId || '' }); }}>
                    <option value="">Choose the material…</option>{mats.map(m => <option key={m.id} value={m.id}>{m.materialCategory ? `${m.materialCategory} · ` : ''}{m.name}</option>)}</select>
                : <div className="flex items-center gap-8">
                    <select className="form-input" style={{ maxWidth: 190 }} value={l.categoryId} onChange={e => set(i, { categoryId: e.target.value })}>
                      <option value="">What kind…</option>{cats.filter(c => c.status === 'active').map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select>
                    <input className="form-input" placeholder="e.g. LUKU for Makina" value={l.description} onChange={e => set(i, { description: e.target.value })} />
                  </div>}</td>
              <td className="num"><NumberInput step="any" min="0" className="form-input" style={{ width: 90 }} placeholder={l.kind === 'expense' ? 'optional' : ''} value={l.quantity} onChange={e => set(i, { quantity: e.target.value })} /></td>
              <td>{l.kind === 'material'
                ? <select className="form-input" value={l.unitId} onChange={e => set(i, { unitId: e.target.value })} disabled={!it}>
                    {(it?.units || []).map(u => <option key={u.id} value={u.id}>{refs.unitById[u.id]?.symbol ?? '—'}</option>)}</select>
                : <input className="form-input" style={{ width: 80 }} placeholder="units" value={l.unitText} onChange={e => set(i, { unitText: e.target.value })} />}</td>
              <td className="num">{l.kind === 'expense' && <NumberInput step="any" min="0" className="form-input" style={{ width: 110 }} placeholder="optional" value={l.amount} onChange={e => set(i, { amount: e.target.value })} />}</td>
              <td>{lines.length > 1 && <button type="button" className="btn btn-ghost btn-sm" aria-label="Remove line" onClick={() => setLines(ls => ls.filter((_, j) => j !== i))}><Trash2 size={13} /></button>}</td>
            </tr>
          );
        })}
      </tbody>
      <tfoot><tr><td colSpan={6}><button type="button" className="btn btn-ghost btn-sm" onClick={() => setLines(ls => [...ls, { ...EMPTY_LINE, kind: ls[ls.length - 1]?.kind ?? 'material' }])}><Plus size={13} /> Add a line</button></td></tr></tfoot>
    </table>
  );
}
const EMPTY_LINE = { kind: 'material', materialId: '', quantity: '', unitId: '', categoryId: '', description: '', unitText: '', amount: '' };

/* ---------- Requests ---------- */
/** An order's material lines still to come, in their own units, ready for the purchase form */
const goodsLeftOf = (po, got) => [...(po.lines || [])].filter(l => l.kind !== 'expense' && (got[l.id] ?? 0) < Number(l.stock_quantity) - 1e-9)
  .sort((a, b) => a.line_no - b.line_no).map(l => {
    const f = Number(l.stock_quantity) / Number(l.quantity);
    return { materialId: l.material_id, unitId: l.unit_id, quantity: String(r2(Math.max(Number(l.stock_quantity) - (got[l.id] ?? 0), 0) / f)), price: l.unit_price != null ? String(Number(l.unit_price)) : '' };
  });
const purchaseFromOrder = (po, got) => ({ orderId: po.id, supplierId: po.supplier_id, branchId: po.branch_id, lines: goodsLeftOf(po, got) });

/*
 * One flow for every request (2026-10-28, migration 084), from its row:
 * waiting → the branch manager approves → approved → an order is made →
 * ordered → open it again to edit the order or confirm what was bought
 * (goods received, expenses or LUKU tokens recorded) → done. An ordered
 * request with goods to come also has Record purchase right on its row: the
 * form opens filled from the order.
 */
export function RequestsPanel({ refs, branchId, inBranch, people, money = v => v, onReceive, onRecordExpense, onRecordToken, openFirst, onOpened }) {
  const { canAt } = useAuth();
  const [rows, setRows] = useState(null);
  const [error, setError] = useState('');
  const [asking, setAsking] = useState(false);
  const [cats, setCats] = useState([]);
  const [orders, setOrders] = useState({});   // request id → its open order
  const [gotAll, setGotAll] = useState({});   // order line id → received
  const [openId, setOpenId] = useState(openFirst ?? null);   // a request opened from elsewhere (Electricity › Top-ups)
  useEffect(() => { if (openFirst) onOpened?.(); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  async function load() {
    const [q, c, po, rc] = await Promise.all([
      supabase.from('purchase_requests').select('*, lines:purchase_request_lines(*)').order('requested_on', { ascending: false }).order('request_no', { ascending: false }),
      supabase.from('expense_categories').select('id, name, status').order('display_order').order('name'),
      supabase.from('purchase_orders').select('*, lines:purchase_order_lines(*)').eq('status', 'open').not('request_id', 'is', null),
      supabase.from('purchase_order_receipts').select('order_line_id, received'),
    ]);
    if (q.error) { console.error(q.error); setError("We couldn't load purchase requests."); return; }
    setRows(q.data || []);
    setCats(c.data || []);
    setOrders(Object.fromEntries((po.data || []).map(o => [o.request_id, o])));
    setGotAll(Object.fromEntries((rc.data || []).map(x => [x.order_line_id, Number(x.received)])));
  }
  useEffect(() => { load(); }, []);
  const canBuy = b => canAt('procurement.receive', b) || canAt('cash.approve', b);
  const here = (rows || []).filter(r => inBranch(r.branch_id));
  const canAsk = !!branchId && canAt('procurement.request', branchId);
  const open = here.find(r => r.id === openId);
  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Waiting</span><strong className={here.some(r => r.status === 'waiting') ? 'text-warning' : ''}>{here.filter(r => r.status === 'waiting').length}</strong><span className="pl-help">for the branch manager</span></div>
        <div className="mm-stat"><span className="pl-label">Approved</span><strong>{here.filter(r => r.status === 'approved').length}</strong><span className="pl-help">to order</span></div>
        <div className="mm-stat"><span className="pl-label">Ordered</span><strong>{here.filter(r => r.status === 'ordered').length}</strong><span className="pl-help">to confirm when bought</span></div>
      </div>
      <div className="flex items-center gap-8" style={{ marginBottom: 8 }}>
        {canAsk && <button type="button" className="btn btn-primary btn-sm" onClick={() => setAsking(true)}><Plus size={14} /> Ask for materials or expenses</button>}
        <span className="pl-help">Open a request to approve it, order it, then confirm what was bought.</span>
      </div>
      {error && <div className="alert alert-error">{error}</div>}
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>No.</th><th>Asked</th><th>By</th><th>Needed by</th><th>What</th><th>Status</th><th aria-label="Actions" /></tr></thead>
          <tbody>
            {rows === null ? <tr><td colSpan={7}><span className="skeleton" /></td></tr>
            : here.length === 0 ? <tr><td colSpan={7} className="text-muted">No purchase requests yet.</td></tr>
            : here.map(r => (
              <tr key={r.id} className="clickable-row" onClick={() => setOpenId(r.id)} title="Open the request">
                <td>#{r.request_no}</td>
                <td>{dateText(r.requested_on)}</td>
                <td>{people[r.requested_by] ?? ''}</td>
                <td>{dateText(r.needed_by) ?? ''}</td>
                <td>{[...(r.lines || [])].sort((x, y) => x.line_no - y.line_no).map(l => <div key={l.id}>{lineText(refs, l, cats, money)}</div>)}</td>
                <td><span className={`badge ${REQ[r.status][1]}`}>{REQ[r.status][0]}</span>{r.decision_note && <div className="pl-help">{r.decision_note}</div>}</td>
                <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }} onClick={e => e.stopPropagation()}>
                  {orders[r.id] && canBuy(r.branch_id) && goodsLeftOf(orders[r.id], gotAll).length > 0 && (
                    <button type="button" className="btn btn-primary btn-sm" onClick={() => onReceive?.(purchaseFromOrder(orders[r.id], gotAll))}>Record purchase</button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div></div>
      {asking && <AskModal refs={refs} branchId={branchId} cats={cats} onClose={() => setAsking(false)} onSaved={async () => { setAsking(false); await load(); }} />}
      {open && <RequestView r={open} refs={refs} cats={cats} people={people} money={money} onChanged={load} onClose={() => setOpenId(null)}
        onReceive={x => { setOpenId(null); onReceive?.(x); }} onRecordExpense={x => { setOpenId(null); onRecordExpense?.(x); }} onRecordToken={x => { setOpenId(null); onRecordToken?.(x); }} />}
    </>
  );
}

/* A request, start to end: decide; order; edit the order or confirm what was bought */
function RequestView({ r, refs, cats, people, money, onChanged, onClose, onReceive, onRecordExpense, onRecordToken }) {
  const { canAt } = useAuth();
  const [po, setPo] = useState(null);           // the request's order (latest, not cancelled)
  const [got, setGot] = useState({});
  const [paidFor, setPaidFor] = useState({});
  const [mode, setMode] = useState(null);       // 'order' | 'edit' | 'close'
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function loadOrder() {
    const { data } = await supabase.from('purchase_orders').select('*, lines:purchase_order_lines(*)').eq('request_id', r.id).neq('status', 'cancelled').order('created_at', { ascending: false }).limit(1);
    const o = data?.[0] ?? null;
    setPo(o);
    if (o) {
      const [rc, ex] = await Promise.all([
        supabase.from('purchase_order_receipts').select('order_line_id, received').eq('order_id', o.id),
        supabase.from('expenses').select('order_line_id, amount').in('order_line_id', o.lines.map(l => l.id)).eq('status', 'recorded'),
      ]);
      setGot(Object.fromEntries((rc.data || []).map(x => [x.order_line_id, Number(x.received)])));
      setPaidFor((ex.data || []).reduce((m, x) => ({ ...m, [x.order_line_id]: (m[x.order_line_id] || 0) + Number(x.amount) }), {}));
    }
  }
  useEffect(() => { loadOrder(); }, [r.id, r.status]); // eslint-disable-line react-hooks/exhaustive-deps
  const supplierName = id => refs?.suppliers.find(x => x.id === id)?.name ?? '—';
  const decide = async decision => {
    setError(''); setBusy(true);
    const { error: err } = await supabase.rpc('decide_purchase_request', { p_id: r.id, p_decision: decision, p_note: note || null });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    setNote(''); onChanged();
  };
  const lineDone = l => (l.kind === 'expense' ? paidFor[l.id] != null : (got[l.id] ?? 0) >= Number(l.stock_quantity) - 1e-9);
  const lines = [...(po?.lines || [])].sort((a, b) => a.line_no - b.line_no);
  const goodsLeft = po ? goodsLeftOf(po, got) : [];
  const nothingYet = po && !lines.some(l => (l.kind === 'expense' ? paidFor[l.id] != null : (got[l.id] ?? 0) > 0));
  const canConfirm = po && po.status === 'open' && (canAt('procurement.receive', r.branch_id) || canAt('cash.approve', r.branch_id));
  return (
    <Modal title={`Request #${r.request_no}`} onClose={onClose} size="lg"
      footer={<>
        {error && <span className="modal-footer-error" role="alert">{error}</span>}
        {['waiting', 'approved'].includes(r.status) && (r.requested_by === undefined || canAt('procurement.request', r.branch_id)) && <button type="button" className="btn btn-ghost" disabled={busy} onClick={() => decide('cancelled')}>Cancel request</button>}
        {r.status === 'waiting' && canAt('procurement.approve', r.branch_id) && <>
          <button type="button" className="btn btn-outline" disabled={busy || !note.trim()} onClick={() => decide('rejected')}>Turn down</button>
          <button type="button" className="btn btn-primary" disabled={busy} onClick={() => decide('approved')}>Approve</button>
        </>}
        {r.status === 'approved' && canAt('procurement.order', r.branch_id) && <button type="button" className="btn btn-primary" onClick={() => setMode('order')}>Make order</button>}
        {r.status === 'ordered' && po?.status === 'open' && <>
          <button type="button" className="btn btn-ghost" onClick={() => window.open(`/print/po/${po.id}`, '_blank', 'noopener')}><Printer size={14} /> Print order</button>
          {canAt('procurement.order', r.branch_id) && nothingYet && <button type="button" className="btn btn-outline" onClick={() => setMode('edit')}>Edit order</button>}
          {canAt('procurement.order', r.branch_id) && <button type="button" className="btn btn-outline" onClick={() => setMode('close')}>{nothingYet ? 'Cancel order…' : 'Close order…'}</button>}
        </>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Close</button>
      </>}>
      <div className="modal-form">
        <p className="text-sm"><span className={`badge ${REQ[r.status][1]}`}>{REQ[r.status][0]}</span> · asked {dateText(r.requested_on)}{people[r.requested_by] ? ` by ${people[r.requested_by]}` : ''}{r.needed_by ? ` · needed by ${dateText(r.needed_by)}` : ''}{r.decision_note ? ` · ${r.decision_note}` : ''}</p>
        {r.notes && <p className="pl-help">{r.notes}</p>}
        {!po && (
          <table className="rd-table">
            <thead><tr><th>Asked for</th></tr></thead>
            <tbody>{[...(r.lines || [])].sort((x, y) => x.line_no - y.line_no).map(l => <tr key={l.id}><td>{lineText(refs, l, cats, money)}</td></tr>)}</tbody>
          </table>
        )}
        {r.status === 'waiting' && canAt('procurement.approve', r.branch_id) && (
          <label className="pe-field"><span>Note (needed to turn down)</span><input className="form-input" value={note} onChange={e => setNote(e.target.value)} /></label>
        )}
        {po && <>
          <h3 className="modal-section-title">Order #{po.po_no} — {supplierName(po.supplier_id)}{po.expected_on ? ` · expected ${dateText(po.expected_on)}` : ''}{po.status !== 'open' ? ` · ${po.status}` : ''}</h3>
          <table className="rd-table">
            <thead><tr><th>What</th><th className="num">Ordered</th><th className="num">Price (TZS)</th><th>Bought</th></tr></thead>
            <tbody>{lines.map(l => {
              const isExp = l.kind === 'expense'; const u = isExp ? l.unit_text ?? '' : refs?.unitById[l.unit_id]?.symbol ?? '';
              const f = isExp ? 1 : Number(l.stock_quantity) / Number(l.quantity);
              return (
                <tr key={l.id}>
                  <td><strong>{isExp ? l.description : refs?.items[`m:${l.material_id}`]?.name ?? '—'}</strong></td>
                  <td className="num">{l.quantity != null ? `${qtyText(Number(l.quantity))} ${u}` : ''}</td>
                  <td className="num">{isExp ? (l.amount != null ? formatAmount(Number(l.amount)) : '') : l.unit_price != null ? formatAmount(Number(l.unit_price)) : ''}</td>
                  <td>{lineDone(l)
                    ? <span className="badge badge-success">{isExp ? `Recorded ${money(paidFor[l.id])}` : 'Received'}</span>
                    : isExp
                      ? canConfirm && <button type="button" className="btn btn-primary btn-sm" onClick={() => (l.meter_id
                          ? onRecordToken({ id: r.id, requested_on: r.requested_on, meterName: (l.description || '').replace(/^LUKU top-up — /, ''), lines: [{ meter_id: l.meter_id, quantity: l.quantity, amount: l.amount }] })
                          : onRecordExpense({ category_id: l.category_id, description: l.description, quantity: l.quantity, amount: l.amount, order_line_id: l.id, request_line_id: l.request_line_id }))}>{l.meter_id ? 'Record token bought' : 'Record expense'}</button>
                      : <span className="pl-help">{qtyText(r2((got[l.id] ?? 0) / f))} of {qtyText(Number(l.quantity))} {u}</span>}</td>
                </tr>
              );
            })}</tbody>
          </table>
          {canConfirm && goodsLeft.length > 0 && <button type="button" className="btn btn-primary btn-sm" onClick={() => onReceive(purchaseFromOrder(po, got))}>Record purchase</button>}
        </>}
      </div>
      {mode === 'order' && <OrderModal refs={refs} branchId={r.branch_id} request={r} onClose={() => setMode(null)} onSaved={async () => { setMode(null); onChanged(); }} />}
      {mode === 'edit' && po && <EditOrderModal po={po} refs={refs} onClose={() => setMode(null)} onSaved={async () => { setMode(null); await loadOrder(); }} />}
      {mode === 'close' && po && <CloseModal po={po} cancel={nothingYet} onClose={() => setMode(null)} onDone={async () => { setMode(null); onChanged(); await loadOrder(); }} />}
    </Modal>
  );
}

/* Change an order before anything comes: expected date, notes, quantities, prices */
function EditOrderModal({ po, refs, onClose, onSaved }) {
  const [expected, setExpected] = useState(po.expected_on ?? '');
  const [notes, setNotes] = useState(po.notes ?? '');
  const [ls, setLs] = useState(() => [...po.lines].sort((a, b) => a.line_no - b.line_no).map(l => ({ id: l.id, kind: l.kind, name: l.kind === 'expense' ? l.description : refs?.items[`m:${l.material_id}`]?.name ?? '—',
    unit: l.kind === 'expense' ? l.unit_text ?? '' : refs?.unitById[l.unit_id]?.symbol ?? '', quantity: l.quantity != null ? String(Number(l.quantity)) : '',
    price: l.kind === 'expense' ? (l.amount != null ? String(Number(l.amount)) : '') : l.unit_price != null ? String(Number(l.unit_price)) : '' })));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function save() {
    setError(''); setBusy(true);
    const { error: err } = await supabase.rpc('update_purchase_order', { p_id: po.id, p: { expected_on: expected || null, notes,
      lines: ls.map(l => ({ id: l.id, quantity: num(l.quantity), ...(l.kind === 'expense' ? { amount: num(l.price) } : { unit_price: num(l.price) }) })) } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  return (
    <Modal title={`Edit order #${po.po_no}`} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Save</button></>}>
      <div className="modal-form">
        <table className="rd-table">
          <thead><tr><th>What</th><th className="num">Quantity</th><th className="num">Price / amount (TZS)</th></tr></thead>
          <tbody>{ls.map((l, i) => (
            <tr key={l.id}><td><strong>{l.name}</strong></td>
              <td className="num"><NumberInput step="any" min="0" className="form-input" style={{ width: 90 }} value={l.quantity} onChange={e => setLs(x => x.map((y, j) => (j === i ? { ...y, quantity: e.target.value } : y)))} /> {l.unit}</td>
              <td className="num"><NumberInput step="any" min="0" className="form-input" style={{ width: 120 }} value={l.price} onChange={e => setLs(x => x.map((y, j) => (j === i ? { ...y, price: e.target.value } : y)))} /></td></tr>))}
          </tbody>
        </table>
        <div className="form-row">
          <label className="pe-field"><span>Expected</span><input type="date" className="form-input" value={expected} onChange={e => setExpected(e.target.value)} /></label>
          <label className="pe-field" style={{ flex: 2 }}><span>Notes</span><input className="form-input" value={notes} onChange={e => setNotes(e.target.value)} /></label>
        </div>
      </div>
    </Modal>
  );
}

function AskModal({ refs, branchId, cats, onClose, onSaved }) {
  const [lines, setLines] = useState([{ ...EMPTY_LINE }]);
  const [neededBy, setNeededBy] = useState('');
  const [notes, setNotes] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function save() {
    setError('');
    if (lines.some(l => l.kind === 'material' && (!l.materialId || !(num(l.quantity) > 0) || !l.unitId))) { setError('Each material line needs the material, a quantity above zero and a unit.'); return; }
    if (lines.some(l => l.kind === 'expense' && (!l.categoryId || !l.description.trim()))) { setError('Each expense line needs its kind and what it is.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('submit_purchase_request', { p: { branch_id: branchId, needed_by: neededBy || null, notes,
      lines: lines.map(l => (l.kind === 'expense'
        ? { kind: 'expense', category_id: l.categoryId, description: l.description, quantity: num(l.quantity), unit_text: l.unitText, amount: num(l.amount) }
        : { kind: 'material', material_id: l.materialId, quantity: num(l.quantity), unit_id: l.unitId })) } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  return (
    <Modal title="Ask for materials or expenses" onClose={onClose} size="xl"
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Send for approval</button></>}>
      <div className="modal-form">
        <RequestLines refs={refs} branchId={branchId} cats={cats} lines={lines} setLines={setLines} />
        <div className="form-row">
          <label className="pe-field"><span>Needed by (optional)</span><input type="date" className="form-input" value={neededBy} onChange={e => setNeededBy(e.target.value)} /></label>
          <label className="pe-field" style={{ flex: 2 }}><span>Why / notes (optional)</span><input className="form-input" value={notes} onChange={e => setNotes(e.target.value)} /></label>
        </div>
      </div>
    </Modal>
  );
}


/* ---------- Orders ---------- */
export function OrdersPanel({ refs, branchId, inBranch, fromRequest, onUsedRequest, money, canReceive = () => false, onReceive, onRecordExpense, onRecordToken }) {
  const { canAt } = useAuth();
  const [rows, setRows] = useState(null);
  const [got, setGot] = useState({});           // order line id → received (stock unit)
  const [paidFor, setPaidFor] = useState({});   // expense order line id → recorded amount (082)
  const [error, setError] = useState('');
  const [making, setMaking] = useState(null);   // {} or { request }
  const [closing, setClosing] = useState(null); // { po, cancel }
  const [viewing, setViewing] = useState(null); // an order opened for review
  // what is still to come on an order, in its own units, ready for the purchase form
  const remainingOf = po => [...(po.lines || [])].filter(l => l.kind !== 'expense').sort((a, b) => a.line_no - b.line_no).map(l => {
    const f = Number(l.stock_quantity) / Number(l.quantity);
    return { materialId: l.material_id, unitId: l.unit_id, quantity: String(r2(Math.max(Number(l.stock_quantity) - (got[l.id] ?? 0), 0) / f)), price: l.unit_price != null ? String(Number(l.unit_price)) : '' };
  }).filter(l => Number(l.quantity) > 0);
  const receive = po => { setViewing(null); onReceive?.({ orderId: po.id, supplierId: po.supplier_id, lines: remainingOf(po) }); };
  async function load() {
    const [o, rc, ex] = await Promise.all([
      supabase.from('purchase_orders').select('*, lines:purchase_order_lines(*)').order('order_date', { ascending: false }).order('po_no', { ascending: false }),
      supabase.from('purchase_order_receipts').select('order_line_id, received'),
      supabase.from('expenses').select('order_line_id, amount').not('order_line_id', 'is', null).eq('status', 'recorded'),
    ]);
    if (o.error) { console.error(o.error); setError("We couldn't load purchase orders."); return; }
    setRows(o.data || []);
    setGot(Object.fromEntries((rc.data || []).map(x => [x.order_line_id, Number(x.received)])));
    setPaidFor((ex.data || []).reduce((m, x) => ({ ...m, [x.order_line_id]: (m[x.order_line_id] || 0) + Number(x.amount) }), {}));
  }
  useEffect(() => { load(); }, []);
  useEffect(() => { if (fromRequest) { setMaking({ request: fromRequest }); onUsedRequest(); } }, [fromRequest]); // eslint-disable-line react-hooks/exhaustive-deps
  const here = (rows || []).filter(r => inBranch(r.branch_id));
  const supplierName = id => refs?.suppliers.find(s => s.id === id)?.name ?? '—';
  const lineIn = l => (l.kind === 'expense' ? paidFor[l.id] != null : (got[l.id] ?? 0) >= Number(l.stock_quantity) - 1e-9);
  const fullyIn = po => (po.lines || []).every(lineIn);
  const stateOf = po => (po.status !== 'open' ? po.status : fullyIn(po) ? 'received' : (po.lines || []).some(l => (l.kind === 'expense' ? paidFor[l.id] != null : (got[l.id] ?? 0) > 0)) ? 'part' : 'open');
  const hasGoodsToCome = po => (po.lines || []).some(l => l.kind !== 'expense' && !lineIn(l));
  const canMake = !!branchId && canAt('procurement.order', branchId);
  const valueOf = po => (po.lines || []).reduce((t, l) => t + (l.kind === 'expense' ? Number(l.amount || 0) : l.unit_price != null ? Number(l.unit_price) * Number(l.quantity) : 0), 0);
  const open = here.filter(p => p.status === 'open');
  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Open orders</span><strong>{open.length}</strong><span className="pl-help">{open.filter(p => stateOf(p) === 'part').length} partly received</span></div>
        <div className="mm-stat"><span className="pl-label">Waiting to arrive</span><strong>{open.filter(p => stateOf(p) === 'open').length}</strong><span className="pl-help">nothing received yet</span></div>
        <div className="mm-stat"><span className="pl-label">Open order value</span><strong>{money(r2(open.reduce((t, p) => t + valueOf(p), 0)))}</strong><span className="pl-help">at agreed prices</span></div>
      </div>
      <div className="flex items-center gap-8" style={{ marginBottom: 8 }}>
        {canMake && <button type="button" className="btn btn-primary btn-sm" onClick={() => setMaking({})}><Plus size={14} /> New purchase order</button>}
        <span className="pl-help">Goods arrive as purchases: choose the order when recording them. Print the order for the supplier, or keep it in MOIS.</span>
      </div>
      {error && <div className="alert alert-error">{error}</div>}
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>PO</th><th>Date</th><th>Supplier</th><th>What · received / ordered</th><th className="num">Value (TZS)</th><th>Status</th><th /></tr></thead>
          <tbody>
            {rows === null ? <tr><td colSpan={7}><span className="skeleton" /></td></tr>
            : here.length === 0 ? <tr><td colSpan={7} className="text-muted">No purchase orders yet.</td></tr>
            : here.map(po => {
              const st = stateOf(po);
              return (
                <tr key={po.id} className="clickable-row" onClick={() => setViewing(po)} title="Open the order">
                  <td>#{po.po_no}{po.sent_to_supplier && <div className="pl-help">sent</div>}</td>
                  <td>{dateText(po.order_date)}{po.expected_on && <div className="pl-help">expected {dateText(po.expected_on)}</div>}</td>
                  <td>{supplierName(po.supplier_id)}</td>
                  <td onClick={e => { if (e.target.closest('button')) e.stopPropagation(); }}>{[...(po.lines || [])].sort((a, b) => a.line_no - b.line_no).map(l => {
                    if (l.kind === 'expense') return (
                      <div key={l.id}>{l.description}{l.amount != null && <span className="pl-help"> · {money(Number(l.amount))}</span>}
                        {paidFor[l.id] != null ? <span className="pl-help text-success"> · recorded {money(paidFor[l.id])}</span>
                          : po.status === 'open' && canReceive(po.branch_id) && <button type="button" className="btn btn-ghost btn-sm" onClick={() => (l.meter_id ? onRecordToken?.(po, l) : onRecordExpense?.(l))}>{l.meter_id ? 'Bought — record token' : 'Record expense'}</button>}
                      </div>);
                    const it = refs?.items[`m:${l.material_id}`]; const f = Number(l.stock_quantity) / Number(l.quantity);
                    return <div key={l.id}>{it?.name ?? '—'} <span className="pl-help">{qtyText(r2((got[l.id] ?? 0) / f))} / {qtyText(Number(l.quantity))} {refs?.unitById[l.unit_id]?.symbol ?? ''}</span></div>;
                  })}</td>
                  <td className="num">{valueOf(po) ? formatAmount(valueOf(po)) : ''}</td>
                  <td><span className={`badge ${st === 'received' ? 'badge-success' : st === 'part' ? 'badge-warning' : PO[po.status]?.[1] ?? 'badge-info'}`}>{st === 'received' ? 'Received' : st === 'part' ? 'Part received' : PO[po.status][0]}</span>
                    {po.close_reason && <div className="pl-help">{po.close_reason}</div>}</td>
                  <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }} onClick={e => e.stopPropagation()}>
                    {po.status === 'open' && hasGoodsToCome(po) && canReceive(po.branch_id) && <button type="button" className="btn btn-primary btn-sm" onClick={() => receive(po)}>Receive goods</button>}
                    <button type="button" className="btn btn-ghost btn-sm" onClick={() => window.open(`/print/po/${po.id}`, '_blank', 'noopener')}><Printer size={13} /> Print</button>
                    {po.status === 'open' && canAt('procurement.order', po.branch_id) && <>
                      {!po.sent_to_supplier && <button type="button" className="btn btn-ghost btn-sm" onClick={async () => { const { error: err } = await supabase.rpc('mark_purchase_order_sent', { p_id: po.id }); if (err) setError(dbErrorMessage(err)); else load(); }}>Mark sent</button>}
                      <button type="button" className="btn btn-ghost btn-sm" onClick={() => setClosing({ po, cancel: st === 'open' })}>{st === 'open' ? 'Cancel…' : 'Close…'}</button>
                    </>}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div></div>
      {making && <OrderModal refs={refs} branchId={making.request?.branch_id ?? branchId} request={making.request} onClose={() => setMaking(null)} onSaved={async () => { setMaking(null); await load(); }} />}
      {closing && <CloseModal {...closing} onClose={() => setClosing(null)} onDone={async () => { setClosing(null); await load(); }} />}
      {viewing && <OrderView po={viewing} refs={refs} got={got} money={money} supplierName={supplierName(viewing.supplier_id)} state={stateOf(viewing)}
        canReceive={viewing.status === 'open' && hasGoodsToCome(viewing) && canReceive(viewing.branch_id)} onReceive={() => receive(viewing)} onClose={() => setViewing(null)} />}
    </>
  );
}

/* An order opened for review: what was ordered and what has come, the purchases received against it */
function OrderView({ po, refs, got, money, supplierName, state, canReceive, onReceive, onClose }) {
  const [purchases, setPurchases] = useState([]);
  useEffect(() => {
    supabase.from('purchases').select('id, purchase_date, invoice_reference, amount_paid, status').eq('purchase_order_id', po.id).eq('status', 'recorded').order('purchase_date')
      .then(({ data }) => setPurchases(data || []));
  }, [po.id]);
  const lines = [...(po.lines || [])].sort((a, b) => a.line_no - b.line_no);
  const total = lines.reduce((t, l) => t + (l.kind === 'expense' ? Number(l.amount || 0) : l.unit_price != null ? Number(l.unit_price) * Number(l.quantity) : 0), 0);
  return (
    <Modal title={`Purchase order #${po.po_no} — ${supplierName}`} onClose={onClose} size="lg"
      footer={<>
        <button type="button" className="btn btn-ghost" onClick={() => window.open(`/print/po/${po.id}`, '_blank', 'noopener')}><Printer size={14} /> Print</button>
        <button type="button" className="btn btn-outline" onClick={onClose}>Close</button>
        {canReceive && <button type="button" className="btn btn-primary" onClick={onReceive}>Receive goods</button>}
      </>}>
      <div className="modal-form">
        <p className="text-sm">Ordered {dateText(po.order_date)}{po.expected_on ? ` · expected ${dateText(po.expected_on)}` : ''} · {po.sent_to_supplier ? 'sent to the supplier' : 'kept in MOIS'} · <strong>{state === 'received' ? 'received in full' : state === 'part' ? 'part received' : po.status === 'open' ? 'nothing received yet' : po.status}</strong></p>
        <table className="rd-table">
          <thead><tr><th>Material</th><th className="num">Ordered</th><th className="num">Received</th><th className="num">To come</th><th className="num">Price (TZS)</th></tr></thead>
          <tbody>
            {lines.map(l => {
              if (l.kind === 'expense') return (
                <tr key={l.id}><td><strong>{l.description}</strong></td><td className="num">{l.quantity != null ? `${qtyText(Number(l.quantity))} ${l.unit_text ?? ''}` : ''}</td>
                  <td className="num" colSpan={2} /><td className="num">{l.amount != null ? formatAmount(Number(l.amount)) : ''}</td></tr>);
              const f = Number(l.stock_quantity) / Number(l.quantity); const u = refs?.unitById[l.unit_id]?.symbol ?? '';
              const rec = (got[l.id] ?? 0) / f;
              return (
                <tr key={l.id}>
                  <td><span className="pl-help">{refs?.items[`m:${l.material_id}`]?.materialCategory ?? ''}</span><div><strong>{refs?.items[`m:${l.material_id}`]?.name ?? '—'}</strong></div></td>
                  <td className="num">{qtyText(Number(l.quantity))} {u}</td>
                  <td className="num">{qtyText(r2(rec))} {u}</td>
                  <td className="num"><strong>{qtyText(r2(Math.max(Number(l.quantity) - rec, 0)))}</strong> {u}</td>
                  <td className="num">{l.unit_price != null ? formatAmount(Number(l.unit_price)) : ''}</td>
                </tr>
              );
            })}
          </tbody>
          {total > 0 && <tfoot><tr><td colSpan={4}><strong>Order value</strong></td><td className="num"><strong>{money(total)}</strong></td></tr></tfoot>}
        </table>
        {po.notes && <p className="pl-help">{po.notes}</p>}
        <h3 className="modal-section-title">Received against it</h3>
        {purchases.length === 0 ? <p className="pl-help">Nothing yet — use Receive goods when they arrive.</p>
          : <p className="text-sm">{purchases.map(p => `${dateText(p.purchase_date)}${p.invoice_reference ? ` (${p.invoice_reference})` : ''}`).join(' · ')}</p>}
      </div>
    </Modal>
  );
}

function OrderModal({ refs, branchId, request, onClose, onSaved }) {
  const [supplierId, setSupplierId] = useState('');
  const [newSupplier, setNewSupplier] = useState('');
  const reqMaterials = [...(request?.lines || [])].filter(l => l.kind !== 'expense').sort((a, b) => a.line_no - b.line_no);
  const [lines, setLines] = useState(() => (reqMaterials.length
    ? reqMaterials.map(l => ({ materialId: l.material_id, quantity: String(Number(l.quantity)), unitId: l.unit_id, price: '' }))
    : request ? [] : [{ materialId: '', quantity: '', unitId: '', price: '' }]));
  // the request's expense lines (LUKU top-up, tools…): what it is and about how much
  const [expenseLines, setExpenseLines] = useState(() => [...(request?.lines || [])].filter(l => l.kind === 'expense').sort((a, b) => a.line_no - b.line_no)
    .map(l => ({ requestLineId: l.id, categoryId: l.category_id, meterId: l.meter_id, description: l.description, quantity: l.quantity != null ? String(Number(l.quantity)) : '', unitText: l.unit_text ?? '', amount: l.amount != null ? String(Number(l.amount)) : '' })));
  const [expected, setExpected] = useState('');
  const [notes, setNotes] = useState('');
  const [sent, setSent] = useState(false);
  // LUKU is bought from TANESCO only (083)
  const isLuku = expenseLines.some(l => l.meterId);
  const tanesco = (refs?.suppliers || []).find(x => /tanesco/i.test(x.name));
  // who supplied these before: materials (purchases) and expense kinds (expenses) — offered first, preselected when one stands out
  const [past, setPast] = useState({ byMaterial: {}, byCategory: {} });
  useEffect(() => {
    if (isLuku) return;
    Promise.all([
      supabase.from('purchases').select('supplier_id, purchase_date, lines:purchase_lines(tx:inventory_transactions(material_id))').eq('status', 'recorded').eq('branch_id', branchId),
      supabase.from('expenses').select('supplier_id, category_id, expense_date').eq('status', 'recorded').not('supplier_id', 'is', null).eq('branch_id', branchId),
    ]).then(([p, e]) => {
      const byMaterial = {}; const byCategory = {};
      for (const x of p.data || []) for (const l of x.lines || []) if (l.tx?.material_id) (byMaterial[l.tx.material_id] ||= []).push({ s: x.supplier_id, d: x.purchase_date });
      for (const x of e.data || []) (byCategory[x.category_id] ||= []).push({ s: x.supplier_id, d: x.expense_date });
      setPast({ byMaterial, byCategory });
    });
  }, [branchId, isLuku]);
  const score = {};
  for (const l of lines) for (const h of past.byMaterial[l.materialId] || []) { const x = score[h.s] ||= { n: 0, d: '' }; x.n += 1; if (h.d > x.d) x.d = h.d; }
  for (const l of expenseLines) for (const h of past.byCategory[l.categoryId] || []) { const x = score[h.s] ||= { n: 0, d: '' }; x.n += 1; if (h.d > x.d) x.d = h.d; }
  const suggested = Object.entries(score).sort((a, b) => b[1].n - a[1].n || (a[1].d < b[1].d ? 1 : -1)).map(([id]) => id);
  const active = (refs?.suppliers || []).filter(x => x.status === 'active');
  useEffect(() => { if (!supplierId && suggested.length) setSupplierId(suggested[0]); }, [suggested.join(',')]); // eslint-disable-line react-hooks/exhaustive-deps
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function save() {
    setError('');
    if (!isLuku && (!supplierId || (supplierId === '__new' && !newSupplier.trim()))) { setError('Choose the supplier, or name a new one.'); return; }
    if (lines.some(l => !l.materialId || !(num(l.quantity) > 0) || !l.unitId)) { setError('Each material line needs a material, a quantity above zero and a unit.'); return; }
    if (!lines.length && !expenseLines.length) { setError('Add what is ordered.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('create_purchase_order', { p: { branch_id: branchId, ...(isLuku ? (tanesco ? { supplier_id: tanesco.id } : { new_supplier_name: 'TANESCO' }) : supplierId === '__new' ? { new_supplier_name: newSupplier.trim() } : { supplier_id: supplierId }),
      request_id: request?.id ?? null, expected_on: expected || null, notes, sent_to_supplier: sent,
      lines: [...lines.map(l => ({ material_id: l.materialId, quantity: num(l.quantity), unit_id: l.unitId, unit_price: num(l.price) })),
        ...expenseLines.map(l => ({ kind: 'expense', category_id: l.categoryId, meter_id: l.meterId, description: l.description, quantity: num(l.quantity), unit_text: l.unitText, amount: num(l.amount), request_line_id: l.requestLineId }))] } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  return (
    <Modal title={request ? `Purchase order for request #${request.request_no}` : 'New purchase order'} onClose={onClose} size="lg"
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Make order</button></>}>
      <div className="modal-form">
        <div className="form-row">
          {isLuku ? (
            <div className="pe-field"><span>Supplier</span><strong className="text-sm" style={{ padding: '8px 0' }}>{tanesco?.name ?? 'TANESCO'}</strong><span className="pl-help">LUKU is bought from TANESCO only.</span></div>
          ) : (
          <label className="pe-field"><span>Supplier</span>
            <select className="form-input" value={supplierId} onChange={e => setSupplierId(e.target.value)}>
              <option value="">Choose…</option>
              {suggested.length > 0 && <optgroup label="Supplied these before">{suggested.map(id => active.find(x => x.id === id)).filter(Boolean).map(x => <option key={x.id} value={x.id}>{x.name}</option>)}</optgroup>}
              <optgroup label={suggested.length ? 'Other suppliers' : 'Suppliers'}>{active.filter(x => !suggested.includes(x.id)).map(x => <option key={x.id} value={x.id}>{x.name}</option>)}</optgroup>
              <option value="__new">New supplier…</option>
            </select>
            {supplierId === '__new' && <input className="form-input mt-4" placeholder="The supplier's name" value={newSupplier} onChange={e => setNewSupplier(e.target.value)} />}</label>
          )}
          <label className="pe-field"><span>Expected (optional)</span><input type="date" className="form-input" value={expected} onChange={e => setExpected(e.target.value)} /></label>
        </div>
        {(lines.length > 0 || !request) && <MaterialLines refs={refs} branchId={branchId} lines={lines} setLines={setLines} withPrice />}
        {expenseLines.length > 0 && (
          <table className="rd-table">
            <thead><tr><th>Expense</th><th className="num">Quantity</th><th className="num">Amount (TZS)</th></tr></thead>
            <tbody>{expenseLines.map((l, i) => (
              <tr key={i}>
                <td><strong>{l.description}</strong></td>
                <td className="num">{l.quantity ? `${l.quantity} ${l.unitText}` : ''}</td>
                <td className="num"><NumberInput step="any" min="0" className="form-input" style={{ width: 120 }} value={l.amount} onChange={e => setExpenseLines(ls => ls.map((x, j) => (j === i ? { ...x, amount: e.target.value } : x)))} /></td>
              </tr>))}</tbody>
          </table>
        )}
        <label className="pe-field"><span>Notes (optional — printed on the order)</span><input className="form-input" value={notes} onChange={e => setNotes(e.target.value)} /></label>
        <label className="text-sm flex items-center gap-8"><input type="checkbox" checked={sent} onChange={e => setSent(e.target.checked)} /> Sent to the supplier (print it from the list); leave unticked to keep it in MOIS only</label>
      </div>
    </Modal>
  );
}

function CloseModal({ po, cancel, onClose, onDone }) {
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function go() {
    setError(''); setBusy(true);
    const { error: err } = await supabase.rpc('close_purchase_order', { p_id: po.id, p_cancel: cancel, p_reason: reason });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onDone();
  }
  return (
    <Modal title={`${cancel ? 'Cancel' : 'Close'} order #${po.po_no}`} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Back</button>
        <button type="button" className="btn btn-danger" disabled={busy || (cancel && !reason.trim())} onClick={go}>{cancel ? 'Cancel order' : 'Close order'}</button></>}>
      <label className="pe-field"><span>{cancel ? 'Why is it cancelled?' : 'Note (optional) — e.g. the rest is not coming'}</span><input className="form-input" autoFocus value={reason} onChange={e => setReason(e.target.value)} /></label>
    </Modal>
  );
}

/* ---------- Paying a purchase ---------- */
export function PayPurchaseModal({ purchase, total, supplierName, accounts, currency, onClose, onSaved }) {
  const { organization } = useAuth();
  const today = orgToday(organization?.timezone);
  const money = v => formatMoney(v, currency);
  const [payments, setPayments] = useState([]);
  const [f, setF] = useState({ amount: '', paid_on: today, account_id: '', method: 'cash', reference: '' });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => {
    supabase.from('purchase_payments').select('*').eq('purchase_id', purchase.id).order('paid_on').then(({ data }) => setPayments(data || []));
  }, [purchase.id]);
  const paid = Number(purchase.amount_paid);
  const owed = r2(Number(total) - paid);
  async function save() {
    setError('');
    if (!(num(f.amount) > 0)) { setError('Enter the amount paid.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('record_purchase_payment', { p_purchase: purchase.id, p: { amount: num(f.amount), paid_on: f.paid_on, account_id: f.account_id || null, method: f.account_id ? null : f.method, reference: f.reference } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  return (
    <Modal title={`Pay ${supplierName} — purchase of ${dateText(purchase.purchase_date)}`} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || owed <= 0} onClick={save}>Record payment</button></>}>
      <div className="modal-form">
        <p className="text-sm">Total <strong>{money(Number(total))}</strong> · paid {money(paid)} · <strong className={owed > 0 ? 'text-warning' : ''}>{money(owed)} owed</strong></p>
        {payments.length > 0 && <div className="pl-help">{payments.map(p => `${dateText(p.paid_on)}: ${money(Number(p.amount))}${p.kind === 'at_purchase' ? ' (with the purchase)' : ''}`).join(' · ')}</div>}
        <div className="form-row">
          <label className="pe-field"><span>Amount</span><NumberInput step="any" min="0" className="form-input" autoFocus value={f.amount} onChange={e => setF({ ...f, amount: e.target.value })} /></label>
          <label className="pe-field"><span>Paid on</span><input type="date" className="form-input" max={today} value={f.paid_on} onChange={e => setF({ ...f, paid_on: e.target.value })} /></label>
        </div>
        <div className="form-row">
          <label className="pe-field"><span>Paid from</span>
            <select className="form-input" value={f.account_id} onChange={e => setF({ ...f, account_id: e.target.value })}>
              <option value="">— a method —</option>{accounts.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
            </select></label>
          {!f.account_id && <label className="pe-field"><span>Method</span>
            <select className="form-input" value={f.method} onChange={e => setF({ ...f, method: e.target.value })}>
              <option value="cash">Cash</option><option value="bank">Bank</option><option value="mobile_money">Mobile money</option>
            </select></label>}
          <label className="pe-field"><span>Reference (optional)</span><input className="form-input" value={f.reference} onChange={e => setF({ ...f, reference: e.target.value })} /></label>
        </div>
      </div>
    </Modal>
  );
}
