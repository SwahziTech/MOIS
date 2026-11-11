import { useEffect, useMemo, useState } from 'react';
import { Printer, Truck } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { dbErrorMessage } from '../../lib/masterData';
import EmptyState from '../EmptyState';
import Modal from '../Modal';
import { tableDate, tableDateTime } from '../../lib/format';
import { qtyText } from '../../lib/inventory';

const STATUS = { on_the_way: 'On the way', delivered: 'Delivered' };
const localNow = () => { const d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 16); };

/*
 * Deliveries (PRD 4.14, migration 096, 2026-10-30): every delivery and
 * collection at the branch, newest first. A delivery leaves "on the way" with
 * its driver and vehicle and is confirmed delivered with proof — who received
 * the goods, when, a note. A collection is delivered on the spot.
 */
export default function DeliveriesPanel({ branchId, inBranch, canAct, today, search }) {
  const [rows, setRows] = useState(null);
  const [error, setError] = useState('');
  // two lists (2026-11-11, the user): Collected — the goods have left the store (a delivery not yet confirmed
  // arrived, or a customer's own collection); Delivered — a delivery confirmed arrived
  const [filter, setFilter] = useState('collected');
  const [confirming, setConfirming] = useState(null);
  async function load() {
    setError('');
    const { data, error: err } = await supabase.from('sale_deliveries')
      .select('*, sale:sales!inner(id, sale_no, branch_id, customer_id, walk_in_name, site, customer:customers(name)), lines:sale_delivery_lines(quantity, line:sale_lines(line_no, item_name, product:products(canonical_name, unit:units(symbol)), color:color_palette(name)))')
      .order('created_at', { ascending: false }).limit(500);
    if (err) { console.error(err); setError("We couldn't load deliveries."); setRows([]); return; }
    setRows(data || []);
  }
  useEffect(() => { load(); }, []);
  const tracked = (rows || []).some(r => r.status);   // 096 applied
  const here = useMemo(() => (rows || []).filter(r => inBranch(r.sale.branch_id)), [rows, inBranch]);
  const who = r => r.sale.customer?.name ?? r.sale.walk_in_name ?? 'Walk-in';
  // what left on the note: each product on its own line, its quantity beside it
  const items = r => [...(r.lines || [])].sort((x, y) => (x.line?.line_no ?? 0) - (y.line?.line_no ?? 0)).map(x => ({
    name: x.line?.product ? `${x.line.product.canonical_name}${x.line.color?.name ? ` ${x.line.color.name}` : ''}` : x.line?.item_name ?? '',
    qty: Number(x.quantity), unit: (x.line?.product?.unit?.symbol ?? '').toUpperCase() === 'SQM' ? 'm²' : 'pcs' }));
  const stateOf = r => (r.kind === 'delivery' && (r.status ?? 'delivered') === 'delivered' ? 'delivered' : 'collected');
  const q = (search || '').trim().toLowerCase();
  const shown = here.filter(r => (filter === 'all' || stateOf(r) === filter)
    && (!q || `${who(r)} ${r.sale.site ?? ''} ${r.driver ?? ''} ${r.vehicle ?? ''} ${r.sale.sale_no} DN-${r.delivery_no}`.toLowerCase().includes(q)));
  // the delivery notes by the day the goods left the store, newest day first
  const days = [];
  for (const r of [...shown].sort((x, y) => (y.delivered_on || '').localeCompare(x.delivered_on || '') || (y.created_at || '').localeCompare(x.created_at || ''))) {
    const last = days[days.length - 1];
    if (last && last.day === r.delivered_on) last.rows.push(r); else days.push({ day: r.delivered_on, rows: [r] });
  }
  const toConfirm = here.filter(r => r.status === 'on_the_way');
  const leftToday = here.filter(r => r.delivered_on === today);
  const month = today.slice(0, 7);
  const count = k => here.filter(r => stateOf(r) === k).length;

  return (
    <>
      {rows !== null && (
        <div className="mm-stats">
          <div className="mm-stat"><span className="pl-label">To confirm delivered</span><strong className={toConfirm.length ? 'text-warning' : ''}>{toConfirm.length}</strong><span className="pl-help">{toConfirm.length ? 'collected, not yet confirmed' : 'none waiting'}</span></div>
          <div className="mm-stat"><span className="pl-label">Left the store today</span><strong>{leftToday.length}</strong><span className="pl-help">delivery note{leftToday.length === 1 ? '' : 's'}</span></div>
          <div className="mm-stat"><span className="pl-label">This month</span><strong>{here.filter(r => (r.delivered_on || '').startsWith(month)).length}</strong><span className="pl-help">delivery notes</span></div>
        </div>
      )}
      <div className="flex items-center gap-8" style={{ margin: '12px 0', flexWrap: 'wrap' }}>
        {[['collected', `Collected (${count('collected')})`], ['delivered', `Delivered (${count('delivered')})`], ['all', 'All']].map(([k, l]) => (
          <button key={k} type="button" className={`btn btn-sm ${filter === k ? 'btn-primary' : 'btn-ghost'}`} onClick={() => setFilter(k)}>{l}</button>
        ))}
      </div>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      {!tracked && rows?.length > 0 && <div className="alert alert-warning">Delivery tracking isn't set up on this system yet.</div>}
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>Date</th><th>Delivery note</th><th>Customer</th><th>Product</th><th style={{ textAlign: 'right' }}>Qty</th><th>Driver · truck</th><th>Site</th><th>Status</th><th /></tr></thead>
          <tbody>
            {rows === null ? <tr><td colSpan={9}><span className="skeleton" /></td></tr>
            : shown.length === 0 ? <tr><td colSpan={9}><EmptyState icon={Truck} title="Nothing here" description={filter === 'collected' ? 'No goods collected.' : filter === 'delivered' ? 'No deliveries confirmed.' : 'No delivery notes.'} /></td></tr>
            : days.map(d => [
              ...d.rows.map((r, i) => (
                <tr key={r.id} className={i === 0 ? 'dl-first' : ''}>
                  <td>{i === 0 ? <>{tableDate(d.day)}<div className="pl-help">{d.rows.length} note{d.rows.length === 1 ? '' : 's'}</div></> : ''}</td>
                  <td>DN-{r.delivery_no}<div className="pl-help">sale #{r.sale.sale_no}{r.dispatched_at ? ` · ${new Date(r.dispatched_at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}` : ''}</div></td>
                  <td>{who(r)}</td>
                  <td>{items(r).map((x, k) => <div key={k}>{x.name}</div>)}</td>
                  <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>{items(r).map((x, k) => <div key={k}>{qtyText(x.qty)} <span className="pl-help">{x.unit}</span></div>)}</td>
                  <td>{r.kind === 'collection' ? <>{r.vehicle || <span className="pl-help">the customer's own</span>}</> : [r.driver, r.vehicle].filter(Boolean).join(' · ') || <span className="pl-help">—</span>}</td>
                  <td>{r.sale.site || ''}</td>
                  <td>{(() => {
                    const got = r.pod_received_by || r.received_by;
                    const when = r.kind === 'delivery' && r.delivered_at ? ` · ${tableDateTime(r.delivered_at)}` : '';
                    return stateOf(r) === 'delivered'
                      ? <span className="badge badge-success" title={`Received by ${got || '—'}${when}${r.pod_note ? ` · ${r.pod_note}` : ''}`}>Delivered</span>
                      : <span className={`badge ${r.status === 'on_the_way' ? 'badge-warning' : 'badge-neutral'}`} title={r.status === 'on_the_way' ? 'Left with our driver: confirm Delivered when it arrives' : `Collected by ${got || 'the customer'}`}>Collected</span>;
                  })()}</td>
                  <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                    {canAct && r.status === 'on_the_way' && <button type="button" className="btn btn-primary btn-sm" onClick={() => setConfirming(r)}>Delivered…</button>}
                    <button type="button" className="icon-btn" aria-label="Print the delivery note" title="Print the delivery note" onClick={() => window.open(`/print/sale/${r.sale.id}?doc=delivery&delivery=${r.id}`, '_blank', 'noopener')}><Printer size={15} /></button>
                  </td>
                </tr>
              )),
            ])}
          </tbody>
        </table>
      </div></div>
      {confirming && <ConfirmDelivery delivery={confirming} who={who(confirming)} onClose={() => setConfirming(null)} onDone={async () => { setConfirming(null); await load(); }} />}
    </>
  );
}

/* Proof of delivery: who received the goods, when, a note */
export function ConfirmDelivery({ delivery, who, onClose, onDone }) {
  const [f, setF] = useState({ received_by: delivery.received_by ?? '', at: localNow(), note: '' });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function save() {
    setError(''); setBusy(true);
    const { error: err } = await supabase.rpc('confirm_delivery', { p_delivery: delivery.id, p: { received_by: f.received_by, delivered_at: new Date(f.at).toISOString(), note: f.note } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onDone();
  }
  return (
    <Modal title={`Delivered — DN-${delivery.delivery_no}`} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !f.received_by.trim()} onClick={save}>Confirm delivered</button></>}>
      <div className="modal-form">
        <p className="pl-help">For {who}{delivery.driver ? ` · driver ${delivery.driver}` : ''}</p>
        <div className="form-row">
          <label className="pe-field" style={{ flex: 2 }}><span>Received by (at the site)</span><input className="form-input" autoFocus value={f.received_by} onChange={e => setF({ ...f, received_by: e.target.value })} /></label>
          <label className="pe-field"><span>When</span><input type="datetime-local" className="form-input" value={f.at} onChange={e => setF({ ...f, at: e.target.value })} /></label>
        </div>
        <label className="pe-field"><span>Note (optional)</span><input className="form-input" placeholder="e.g. 3 pieces broken, left at the gate" value={f.note} onChange={e => setF({ ...f, note: e.target.value })} /></label>
      </div>
    </Modal>
  );
}
