import { useEffect, useMemo, useState } from 'react';
import { Printer, Truck } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { dbErrorMessage } from '../../lib/masterData';
import EmptyState from '../EmptyState';
import Modal from '../Modal';

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
  const [filter, setFilter] = useState('on_the_way');
  const [confirming, setConfirming] = useState(null);
  async function load() {
    setError('');
    const { data, error: err } = await supabase.from('sale_deliveries')
      .select('*, sale:sales!inner(id, sale_no, branch_id, customer_id, walk_in_name, site, customer:customers(name))')
      .order('created_at', { ascending: false }).limit(500);
    if (err) { console.error(err); setError("We couldn't load deliveries."); setRows([]); return; }
    setRows(data || []);
  }
  useEffect(() => { load(); }, []);
  const tracked = (rows || []).some(r => r.status);   // 096 applied
  const here = useMemo(() => (rows || []).filter(r => inBranch(r.sale.branch_id)), [rows, inBranch]);
  const who = r => r.sale.customer?.name ?? r.sale.walk_in_name ?? 'Walk-in';
  const q = (search || '').trim().toLowerCase();
  const shown = here.filter(r => (filter === 'all' || (filter === 'collection' ? r.kind === 'collection' : r.kind === 'delivery' && (r.status ?? 'delivered') === filter))
    && (!q || `${who(r)} ${r.sale.site ?? ''} ${r.driver ?? ''} ${r.vehicle ?? ''} ${r.sale.sale_no}`.toLowerCase().includes(q)));
  const onWay = here.filter(r => r.status === 'on_the_way');
  const month = today.slice(0, 7);

  return (
    <>
      {rows !== null && (
        <div className="mm-stats">
          <div className="mm-stat"><span className="pl-label">On the way</span><strong className={onWay.length ? 'text-warning' : ''}>{onWay.length}</strong><span className="pl-help">{onWay.length ? 'waiting for proof of delivery' : 'none out'}</span></div>
          <div className="mm-stat"><span className="pl-label">Delivered today</span><strong>{here.filter(r => r.kind === 'delivery' && (r.delivered_at || '').slice(0, 10) === today).length}</strong><span className="pl-help">{here.filter(r => r.kind === 'collection' && r.delivered_on === today).length} collected</span></div>
          <div className="mm-stat"><span className="pl-label">This month</span><strong>{here.filter(r => (r.delivered_on || '').startsWith(month)).length}</strong><span className="pl-help">deliveries & collections</span></div>
        </div>
      )}
      <div className="flex items-center gap-8" style={{ margin: '12px 0', flexWrap: 'wrap' }}>
        {[['on_the_way', `On the way (${onWay.length})`], ['delivered', 'Delivered'], ['collection', 'Collected'], ['all', 'All']].map(([k, l]) => (
          <button key={k} type="button" className={`btn btn-sm ${filter === k ? 'btn-primary' : 'btn-ghost'}`} onClick={() => setFilter(k)}>{l}</button>
        ))}
      </div>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      {!tracked && rows?.length > 0 && <div className="alert alert-warning">Delivery tracking isn't set up on this system yet.</div>}
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>Left</th><th>No.</th><th>Customer</th><th>Site</th><th>Driver · vehicle</th><th>Status</th><th>Proof of delivery</th><th /></tr></thead>
          <tbody>
            {rows === null ? <tr><td colSpan={8}><span className="skeleton" /></td></tr>
            : shown.length === 0 ? <tr><td colSpan={8}><EmptyState icon={Truck} title="Nothing here" description={filter === 'on_the_way' ? 'No deliveries on the way.' : 'No deliveries in this list.'} /></td></tr>
            : shown.map(r => (
              <tr key={r.id}>
                <td>{r.delivered_on}{r.dispatched_at ? <div className="pl-help">{new Date(r.dispatched_at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}</div> : null}</td>
                <td>DN-{r.delivery_no}<div className="pl-help">#{r.sale.sale_no}</div></td>
                <td>{who(r)}</td>
                <td>{r.sale.site || ''}</td>
                <td>{r.kind === 'collection' ? <span className="pl-help">collected by the customer</span> : [r.driver, r.vehicle].filter(Boolean).join(' · ') || <span className="pl-help">—</span>}</td>
                <td>{r.kind === 'collection' ? <span className="badge badge-neutral">Collected</span>
                  : <span className={`badge ${r.status === 'on_the_way' ? 'badge-warning' : 'badge-success'}`}>{STATUS[r.status ?? 'delivered']}</span>}</td>
                <td>{r.status === 'delivered' || r.kind === 'collection'
                  ? <>{r.pod_received_by || r.received_by || '—'}{r.delivered_at ? <div className="pl-help">{new Date(r.delivered_at).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}{r.pod_note ? ` · ${r.pod_note}` : ''}</div> : null}</>
                  : ''}</td>
                <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                  {canAct && r.status === 'on_the_way' && <button type="button" className="btn btn-primary btn-sm" onClick={() => setConfirming(r)}>Delivered…</button>}
                  <button type="button" className="btn btn-ghost btn-sm" onClick={() => window.open(`/print/sale/${r.sale.id}?doc=delivery&delivery=${r.id}`, '_blank', 'noopener')}><Printer size={13} /> Note</button>
                </td>
              </tr>
            ))}
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
        <p className="pl-help">For {who}{delivery.driver ? ` · driver ${delivery.driver}` : ''}. Check the signed delivery note before confirming.</p>
        <div className="form-row">
          <label className="pe-field" style={{ flex: 2 }}><span>Received by (at the site)</span><input className="form-input" autoFocus value={f.received_by} onChange={e => setF({ ...f, received_by: e.target.value })} /></label>
          <label className="pe-field"><span>When</span><input type="datetime-local" className="form-input" value={f.at} onChange={e => setF({ ...f, at: e.target.value })} /></label>
        </div>
        <label className="pe-field"><span>Note (optional)</span><input className="form-input" placeholder="e.g. 3 pieces broken, left at the gate" value={f.note} onChange={e => setF({ ...f, note: e.target.value })} /></label>
      </div>
    </Modal>
  );
}
