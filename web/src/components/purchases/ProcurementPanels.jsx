import { useEffect, useMemo, useState } from 'react';
import { Plus, Trash2, Printer } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { formatMoney, formatAmount } from '../../lib/format';
import { dbErrorMessage } from '../../lib/masterData';
import { qtyText, orgToday } from '../../lib/inventory';
import Modal from '../Modal';
import NumberInput from '../NumberInput';

const num = v => (v === '' || v === null || v === undefined || Number.isNaN(Number(v)) ? null : Number(v));
const r2 = n => Math.round(n * 100) / 100;
const REQ = { waiting: ['Waiting', 'badge-warning'], approved: ['Approved', 'badge-info'], rejected: ['Turned down', 'badge-error'], ordered: ['Ordered', 'badge-success'], cancelled: ['Cancelled', 'badge-neutral'] };
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

const lineText = (refs, l) => `${qtyText(Number(l.quantity))} ${refs?.unitById[l.unit_id]?.symbol ?? ''} ${refs?.items[`m:${l.material_id}`]?.name ?? '—'}`;

/* ---------- Requests ---------- */
export function RequestsPanel({ refs, branchId, inBranch, people, onOrder }) {
  const { canAt } = useAuth();
  const [rows, setRows] = useState(null);
  const [error, setError] = useState('');
  const [asking, setAsking] = useState(false);
  const [deciding, setDeciding] = useState(null);   // { r, decision }
  async function load() {
    const { data, error: err } = await supabase.from('purchase_requests').select('*, lines:purchase_request_lines(*)').order('requested_on', { ascending: false }).order('request_no', { ascending: false });
    if (err) { console.error(err); setError("We couldn't load purchase requests."); return; }
    setRows(data || []);
  }
  useEffect(() => { load(); }, []);
  const here = (rows || []).filter(r => inBranch(r.branch_id));
  const canAsk = !!branchId && canAt('procurement.request', branchId);
  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Waiting</span><strong className={here.some(r => r.status === 'waiting') ? 'text-warning' : ''}>{here.filter(r => r.status === 'waiting').length}</strong><span className="pl-help">for the branch manager</span></div>
        <div className="mm-stat"><span className="pl-label">Approved</span><strong>{here.filter(r => r.status === 'approved').length}</strong><span className="pl-help">to order</span></div>
        <div className="mm-stat"><span className="pl-label">Ordered</span><strong>{here.filter(r => r.status === 'ordered').length}</strong><span className="pl-help">a purchase order made</span></div>
      </div>
      <div className="flex items-center gap-8" style={{ marginBottom: 8 }}>
        {canAsk && <button type="button" className="btn btn-primary btn-sm" onClick={() => setAsking(true)}><Plus size={14} /> Ask for materials</button>}
        <span className="pl-help">Asked by the storekeeper or secretary; the branch manager approves; then a purchase order is made.</span>
      </div>
      {error && <div className="alert alert-error">{error}</div>}
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>No.</th><th>Asked</th><th>By</th><th>Needed by</th><th>Materials</th><th>Status</th><th /></tr></thead>
          <tbody>
            {rows === null ? <tr><td colSpan={7}><span className="skeleton" /></td></tr>
            : here.length === 0 ? <tr><td colSpan={7} className="text-muted">No purchase requests yet.</td></tr>
            : here.map(r => {
              const canDecide = r.status === 'waiting' && canAt('procurement.approve', r.branch_id);
              return (
                <tr key={r.id}>
                  <td>#{r.request_no}</td>
                  <td>{r.requested_on}</td>
                  <td>{people[r.requested_by] ?? ''}</td>
                  <td>{r.needed_by ?? ''}</td>
                  <td>{[...(r.lines || [])].sort((a, b) => a.line_no - b.line_no).map(l => <div key={l.id}>{lineText(refs, l)}</div>)}{r.notes && <div className="pl-help">{r.notes}</div>}</td>
                  <td><span className={`badge ${REQ[r.status][1]}`}>{REQ[r.status][0]}</span>{r.decision_note && <div className="pl-help">{r.decision_note}</div>}</td>
                  <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                    {canDecide && <>
                      <button type="button" className="btn btn-primary btn-sm" onClick={() => setDeciding({ r, decision: 'approved' })}>Approve</button>{' '}
                      <button type="button" className="btn btn-ghost btn-sm" onClick={() => setDeciding({ r, decision: 'rejected' })}>Turn down…</button>
                    </>}
                    {r.status === 'approved' && canAt('procurement.order', r.branch_id) && <button type="button" className="btn btn-primary btn-sm" onClick={() => onOrder(r)}>Make order</button>}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div></div>
      {asking && <AskModal refs={refs} branchId={branchId} onClose={() => setAsking(false)} onSaved={async () => { setAsking(false); await load(); }} />}
      {deciding && <DecideModal {...deciding} onClose={() => setDeciding(null)} onDone={async () => { setDeciding(null); await load(); }} />}
    </>
  );
}

function AskModal({ refs, branchId, onClose, onSaved }) {
  const [lines, setLines] = useState([{ materialId: '', quantity: '', unitId: '' }]);
  const [neededBy, setNeededBy] = useState('');
  const [notes, setNotes] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function save() {
    setError('');
    if (lines.some(l => !l.materialId || !(num(l.quantity) > 0) || !l.unitId)) { setError('Each line needs a material, a quantity above zero and a unit.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('submit_purchase_request', { p: { branch_id: branchId, needed_by: neededBy || null, notes,
      lines: lines.map(l => ({ material_id: l.materialId, quantity: num(l.quantity), unit_id: l.unitId })) } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  return (
    <Modal title="Ask for materials" onClose={onClose} size="lg"
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Send for approval</button></>}>
      <div className="modal-form">
        <MaterialLines refs={refs} branchId={branchId} lines={lines} setLines={setLines} />
        <div className="form-row">
          <label className="pe-field"><span>Needed by (optional)</span><input type="date" className="form-input" value={neededBy} onChange={e => setNeededBy(e.target.value)} /></label>
          <label className="pe-field" style={{ flex: 2 }}><span>Why / notes (optional)</span><input className="form-input" value={notes} onChange={e => setNotes(e.target.value)} /></label>
        </div>
      </div>
    </Modal>
  );
}

function DecideModal({ r, decision, onClose, onDone }) {
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function go() {
    setError(''); setBusy(true);
    const { error: err } = await supabase.rpc('decide_purchase_request', { p_id: r.id, p_decision: decision, p_note: note || null });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onDone();
  }
  return (
    <Modal title={`${decision === 'approved' ? 'Approve' : 'Turn down'} request #${r.request_no}`} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={decision === 'approved' ? 'btn btn-primary' : 'btn btn-danger'} disabled={busy || (decision === 'rejected' && !note.trim())} onClick={go}>{decision === 'approved' ? 'Approve' : 'Turn down'}</button></>}>
      <label className="pe-field"><span>{decision === 'approved' ? 'Note (optional)' : 'Why?'}</span><input className="form-input" autoFocus value={note} onChange={e => setNote(e.target.value)} /></label>
    </Modal>
  );
}

/* ---------- Orders ---------- */
export function OrdersPanel({ refs, branchId, inBranch, fromRequest, onUsedRequest, money }) {
  const { canAt } = useAuth();
  const [rows, setRows] = useState(null);
  const [got, setGot] = useState({});           // order line id → received (stock unit)
  const [error, setError] = useState('');
  const [making, setMaking] = useState(null);   // {} or { request }
  const [closing, setClosing] = useState(null); // { po, cancel }
  async function load() {
    const [o, rc] = await Promise.all([
      supabase.from('purchase_orders').select('*, lines:purchase_order_lines(*)').order('order_date', { ascending: false }).order('po_no', { ascending: false }),
      supabase.from('purchase_order_receipts').select('order_line_id, received'),
    ]);
    if (o.error) { console.error(o.error); setError("We couldn't load purchase orders."); return; }
    setRows(o.data || []);
    setGot(Object.fromEntries((rc.data || []).map(x => [x.order_line_id, Number(x.received)])));
  }
  useEffect(() => { load(); }, []);
  useEffect(() => { if (fromRequest) { setMaking({ request: fromRequest }); onUsedRequest(); } }, [fromRequest]); // eslint-disable-line react-hooks/exhaustive-deps
  const here = (rows || []).filter(r => inBranch(r.branch_id));
  const supplierName = id => refs?.suppliers.find(s => s.id === id)?.name ?? '—';
  const fullyIn = po => (po.lines || []).every(l => (got[l.id] ?? 0) >= Number(l.stock_quantity) - 1e-9);
  const stateOf = po => (po.status !== 'open' ? po.status : fullyIn(po) ? 'received' : (po.lines || []).some(l => (got[l.id] ?? 0) > 0) ? 'part' : 'open');
  const canMake = !!branchId && canAt('procurement.order', branchId);
  const valueOf = po => (po.lines || []).reduce((t, l) => t + (l.unit_price != null ? Number(l.unit_price) * Number(l.quantity) : 0), 0);
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
          <thead><tr><th>PO</th><th>Date</th><th>Supplier</th><th>Materials · received / ordered</th><th className="num">Value (TZS)</th><th>Status</th><th /></tr></thead>
          <tbody>
            {rows === null ? <tr><td colSpan={7}><span className="skeleton" /></td></tr>
            : here.length === 0 ? <tr><td colSpan={7} className="text-muted">No purchase orders yet.</td></tr>
            : here.map(po => {
              const st = stateOf(po);
              return (
                <tr key={po.id}>
                  <td>#{po.po_no}{po.sent_to_supplier && <div className="pl-help">sent</div>}</td>
                  <td>{po.order_date}{po.expected_on && <div className="pl-help">expected {po.expected_on}</div>}</td>
                  <td>{supplierName(po.supplier_id)}</td>
                  <td>{[...(po.lines || [])].sort((a, b) => a.line_no - b.line_no).map(l => {
                    const it = refs?.items[`m:${l.material_id}`]; const f = Number(l.stock_quantity) / Number(l.quantity);
                    return <div key={l.id}>{it?.name ?? '—'} <span className="pl-help">{qtyText(r2((got[l.id] ?? 0) / f))} / {qtyText(Number(l.quantity))} {refs?.unitById[l.unit_id]?.symbol ?? ''}</span></div>;
                  })}</td>
                  <td className="num">{valueOf(po) ? formatAmount(valueOf(po)) : ''}</td>
                  <td><span className={`badge ${st === 'received' ? 'badge-success' : st === 'part' ? 'badge-warning' : PO[po.status]?.[1] ?? 'badge-info'}`}>{st === 'received' ? 'Received' : st === 'part' ? 'Part received' : PO[po.status][0]}</span>
                    {po.close_reason && <div className="pl-help">{po.close_reason}</div>}</td>
                  <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
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
    </>
  );
}

function OrderModal({ refs, branchId, request, onClose, onSaved }) {
  const [supplierId, setSupplierId] = useState('');
  const [lines, setLines] = useState(() => (request?.lines?.length
    ? [...request.lines].sort((a, b) => a.line_no - b.line_no).map(l => ({ materialId: l.material_id, quantity: String(Number(l.quantity)), unitId: l.unit_id, price: '' }))
    : [{ materialId: '', quantity: '', unitId: '', price: '' }]));
  const [expected, setExpected] = useState('');
  const [notes, setNotes] = useState('');
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function save() {
    setError('');
    if (!supplierId) { setError('Choose the supplier.'); return; }
    if (lines.some(l => !l.materialId || !(num(l.quantity) > 0) || !l.unitId)) { setError('Each line needs a material, a quantity above zero and a unit.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('create_purchase_order', { p: { branch_id: branchId, supplier_id: supplierId, request_id: request?.id ?? null,
      expected_on: expected || null, notes, sent_to_supplier: sent,
      lines: lines.map(l => ({ material_id: l.materialId, quantity: num(l.quantity), unit_id: l.unitId, unit_price: num(l.price) })) } });
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
          <label className="pe-field"><span>Supplier</span>
            <select className="form-input" value={supplierId} onChange={e => setSupplierId(e.target.value)}>
              <option value="">Choose…</option>{(refs?.suppliers || []).filter(s => s.status === 'active').map(s => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select></label>
          <label className="pe-field"><span>Expected (optional)</span><input type="date" className="form-input" value={expected} onChange={e => setExpected(e.target.value)} /></label>
        </div>
        <MaterialLines refs={refs} branchId={branchId} lines={lines} setLines={setLines} withPrice />
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
    <Modal title={`Pay ${supplierName} — purchase of ${purchase.purchase_date}`} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || owed <= 0} onClick={save}>Record payment</button></>}>
      <div className="modal-form">
        <p className="text-sm">Total <strong>{money(Number(total))}</strong> · paid {money(paid)} · <strong className={owed > 0 ? 'text-warning' : ''}>{money(owed)} owed</strong></p>
        {payments.length > 0 && <div className="pl-help">{payments.map(p => `${p.paid_on}: ${money(Number(p.amount))}${p.kind === 'at_purchase' ? ' (with the purchase)' : ''}`).join(' · ')}</div>}
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
