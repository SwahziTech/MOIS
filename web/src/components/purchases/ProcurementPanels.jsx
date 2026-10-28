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
export function RequestsPanel({ refs, branchId, inBranch, people, onOrder, onRecordExpense, money = v => v }) {
  const { canAt } = useAuth();
  const [rows, setRows] = useState(null);
  const [error, setError] = useState('');
  const [asking, setAsking] = useState(false);
  const [deciding, setDeciding] = useState(null);   // { r, decision }
  const [cats, setCats] = useState([]);
  const [done, setDone] = useState({});      // expense request line → recorded amount
  async function load() {
    const [q, c, e] = await Promise.all([
      supabase.from('purchase_requests').select('*, lines:purchase_request_lines(*)').order('requested_on', { ascending: false }).order('request_no', { ascending: false }),
      supabase.from('expense_categories').select('id, name, status').order('display_order').order('name'),
      supabase.from('expenses').select('request_line_id, amount').not('request_line_id', 'is', null).eq('status', 'recorded'),
    ]);
    if (q.error) { console.error(q.error); setError("We couldn't load purchase requests."); return; }
    setRows(q.data || []);
    setCats(c.data || []);
    setDone((e.data || []).reduce((m, x) => ({ ...m, [x.request_line_id]: (m[x.request_line_id] || 0) + Number(x.amount) }), {}));
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
        {canAsk && <button type="button" className="btn btn-primary btn-sm" onClick={() => setAsking(true)}><Plus size={14} /> Ask for materials or expenses</button>}
        <span className="pl-help">Materials or expenses (LUKU, tools, transport…). Asked by the storekeeper or secretary; the branch manager approves; then materials go on a purchase order and expenses are recorded when bought.</span>
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
                  <td>{[...(r.lines || [])].sort((a, b) => a.line_no - b.line_no).map(l => (
                    <div key={l.id}>{lineText(refs, l, cats, money)}
                      {l.kind === 'expense' && done[l.id] != null && <span className="pl-help"> · recorded {money(done[l.id])}</span>}
                      {l.kind === 'expense' && !l.meter_id && done[l.id] == null && r.status === 'approved' && onRecordExpense && (
                        <button type="button" className="btn btn-ghost btn-sm" onClick={() => onRecordExpense(l)}>Record expense</button>)}
                    </div>))}{r.notes && <div className="pl-help">{r.notes}</div>}</td>
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
      {asking && <AskModal refs={refs} branchId={branchId} cats={cats} onClose={() => setAsking(false)} onSaved={async () => { setAsking(false); await load(); }} />}
      {deciding && <DecideModal {...deciding} onClose={() => setDeciding(null)} onDone={async () => { setDeciding(null); await load(); }} />}
    </>
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
                  <td>{po.order_date}{po.expected_on && <div className="pl-help">expected {po.expected_on}</div>}</td>
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
        <p className="text-sm">Ordered {po.order_date}{po.expected_on ? ` · expected ${po.expected_on}` : ''} · {po.sent_to_supplier ? 'sent to the supplier' : 'kept in MOIS'} · <strong>{state === 'received' ? 'received in full' : state === 'part' ? 'part received' : po.status === 'open' ? 'nothing received yet' : po.status}</strong></p>
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
          : <p className="text-sm">{purchases.map(p => `${p.purchase_date}${p.invoice_reference ? ` (${p.invoice_reference})` : ''}`).join(' · ')}</p>}
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
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function save() {
    setError('');
    if (!supplierId || (supplierId === '__new' && !newSupplier.trim())) { setError('Choose the supplier, or name a new one.'); return; }
    if (lines.some(l => !l.materialId || !(num(l.quantity) > 0) || !l.unitId)) { setError('Each material line needs a material, a quantity above zero and a unit.'); return; }
    if (!lines.length && !expenseLines.length) { setError('Add what is ordered.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('create_purchase_order', { p: { branch_id: branchId, ...(supplierId === '__new' ? { new_supplier_name: newSupplier.trim() } : { supplier_id: supplierId }),
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
          <label className="pe-field"><span>Supplier</span>
            <select className="form-input" value={supplierId} onChange={e => setSupplierId(e.target.value)}>
              <option value="">Choose…</option>{(refs?.suppliers || []).filter(s => s.status === 'active').map(s => <option key={s.id} value={s.id}>{s.name}</option>)}
              <option value="__new">New supplier…</option>
            </select>
            {supplierId === '__new' && <input className="form-input mt-4" placeholder="e.g. the LUKU seller" value={newSupplier} onChange={e => setNewSupplier(e.target.value)} />}</label>
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
