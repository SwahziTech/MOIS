import { useEffect, useState } from 'react';
import { Factory } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { qtyText } from '../../lib/inventory';
import { dbErrorMessage } from '../../lib/masterData';
import Modal from '../Modal';
import NumberInput from '../NumberInput';

/*
 * Customer orders (141, 2026-11-22, the user): on a sale — what it waits for, and the production made for it.
 *   Waiting for: Stock · Cash · Transport · Customer (any of them)
 *   Make in production: the shortfall (ordered − delivered − in the store − already being made) becomes a
 *   Planner production order linked to the sale; under the advance (40%) only a warning.
 *   Progress a product: to make · cast · curing · ready (passed) — pieces made join the general stock.
 */
export const WAITING = [['stock', 'Stock'], ['cash', 'Cash'], ['transport', 'Transport'], ['customer', 'Customer']];
export const ADVANCE = 0.4;   // the advance before production — a warning only (the user, 2026-11-22)

/** The production made for these sales: sale id → [{ order, line, progress }] */
export async function loadSaleProduction(saleIds) {
  if (!saleIds.length) return {};
  const { data: orders, error } = await supabase.from('production_orders')
    .select('id, order_no, status, due_date, sale_id, lines:production_order_lines(id, sale_line_id, product_id, color_id, pieces)')
    .in('sale_id', saleIds);
  if (error || !orders?.length) return {};
  const lineIds = orders.flatMap(o => (o.lines || []).map(l => l.id));
  const { data: prog } = lineIds.length ? await supabase.from('production_order_line_progress').select('*').in('line_id', lineIds) : { data: [] };
  const byLine = Object.fromEntries((prog || []).map(p => [p.line_id, p]));
  const out = {};
  for (const o of orders) for (const l of o.lines || []) (out[o.sale_id] ||= []).push({ order: o, line: l, progress: byLine[l.id] ?? null });
  return out;
}

/** "made 400 / 1,200" across a sale's production */
export function productionSummary(rows) {
  if (!rows?.length) return null;
  const planned = rows.reduce((t, r) => t + Number(r.line.pieces), 0);
  const ready = rows.reduce((t, r) => t + Number(r.progress?.passed ?? 0), 0);
  const cast = rows.reduce((t, r) => t + Number(r.progress?.cast_pieces ?? 0), 0);
  return { planned, cast, ready };
}

export default function SaleProduction({ sale, refs, rows = [], paid, canSell, canPlan, onChanged }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [making, setMaking] = useState(false);
  const live = sale.stage !== 'cancelled';
  const waiting = sale.waiting_for || [];
  const nameOf = (productId, colorId) => `${refs.items[`p:${productId}`]?.name ?? '—'}${colorId ? ` ${refs.colorById[colorId]?.name ?? ''}` : ''}`;

  async function toggle(k) {
    setError(''); setBusy(true);
    const next = waiting.includes(k) ? waiting.filter(x => x !== k) : [...waiting, k];
    const { error: err } = await supabase.rpc('set_sale_waiting', { p_sale: sale.id, p_for: next });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onChanged();
  }

  return (
    <section className="so">
      {live && (
        <div className="so-wait">
          <span className="pl-label">Waiting for</span>
          {WAITING.map(([k, l]) => (
            <button key={k} type="button" className={`filter-chip${waiting.includes(k) ? ' is-on' : ''}`} disabled={!canSell || busy} onClick={() => toggle(k)}>{l}</button>
          ))}
          {['order', 'invoice'].includes(sale.stage) && canPlan && (
            <button type="button" className="btn btn-outline btn-sm" style={{ marginLeft: 'auto' }} onClick={() => setMaking(true)}><Factory size={14} /> Make in production</button>
          )}
        </div>
      )}
      {error && <p className="text-xs text-error">{error}</p>}
      {rows.length > 0 && (
        <table className="rd-table so-prog">
          <thead><tr><th>Made for this order</th><th className="num">To make</th><th className="num">Cast</th><th className="num">Curing</th><th className="num">Ready</th><th>Production order</th></tr></thead>
          <tbody>
            {rows.map(({ order, line, progress }) => (
              <tr key={line.id}>
                <td><strong>{nameOf(line.product_id, line.color_id)}</strong></td>
                <td className="num">{qtyText(line.pieces)}</td>
                <td className="num">{qtyText(progress?.cast_pieces ?? 0)}</td>
                <td className="num">{qtyText(progress?.curing ?? 0)}</td>
                <td className="num"><strong className={(progress?.passed ?? 0) >= line.pieces ? 'text-success' : ''}>{qtyText(progress?.passed ?? 0)}</strong></td>
                <td className="text-sm">#{order.order_no} · {order.status}{order.due_date ? <span className="pl-help"> · due {order.due_date}</span> : ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {making && <MakeModal sale={sale} refs={refs} rows={rows} paid={paid} nameOf={nameOf} onClose={() => setMaking(false)} onSaved={() => { setMaking(false); onChanged(); }} />}
    </section>
  );
}

function MakeModal({ sale, refs, rows, paid, nameOf, onClose, onSaved }) {
  const lines = (sale.lines || []).filter(l => l.product_id);
  const [inStore, setInStore] = useState(null);
  const [perSqm, setPerSqm] = useState({});
  const [pcs, setPcs] = useState({});
  const [due, setDue] = useState(sale.due_date ?? '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const isSqm = id => (refs.unitById[refs.items[`p:${id}`]?.stockUnitId]?.symbol ?? '').toUpperCase() === 'SQM';
  const done = l => (sale.deliveries || []).reduce((t, d) => t + (d.lines || []).filter(x => x.sale_line_id === l.id).reduce((u, x) => u + Number(x.quantity), 0), 0);
  // already being made for this line (still to pass), in pieces
  const making = l => rows.filter(r => r.line.sale_line_id === l.id && r.order.status === 'open').reduce((t, r) => t + Math.max(Number(r.line.pieces) - Number(r.progress?.passed ?? 0), 0), 0);
  const toPcs = (l, q) => (isSqm(l.product_id) ? (perSqm[l.product_id] ? Math.ceil(q * perSqm[l.product_id]) : null) : Math.ceil(q));

  useEffect(() => {
    supabase.rpc('sales_availability', { p_branch_id: sale.branch_id, ...(sale.warehouse_id ? { p_warehouse_id: sale.warehouse_id } : {}) })
      .then(({ data }) => setInStore(Object.fromEntries((data || []).map(x => [`${x.product_id}|${x.color_id ?? ''}`, Number(x.on_hand)]))));
    supabase.from('product_specs').select('product_id, pcs_per_sqm').in('product_id', lines.map(l => l.product_id))
      .then(({ data }) => setPerSqm(Object.fromEntries((data || []).filter(x => Number(x.pcs_per_sqm) > 0).map(x => [x.product_id, Number(x.pcs_per_sqm)]))));
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // the shortfall a line, in pieces: what is left to deliver less the store and what is already being made
  const shortOf = l => {
    if (!inStore) return null;
    const left = Math.max(Number(l.quantity) - done(l), 0);
    const store = Math.max(inStore[`${l.product_id}|${l.color_id ?? ''}`] ?? 0, 0);
    const p = toPcs(l, Math.max(left - store, 0));
    return p == null ? null : Math.max(p - making(l), 0);
  };
  useEffect(() => { if (inStore) setPcs(Object.fromEntries(lines.map(l => [l.id, String(shortOf(l) ?? '')]))); }, [inStore, perSqm]); // eslint-disable-line react-hooks/exhaustive-deps

  const advance = Number(sale.total) > 0 ? paid / Number(sale.total) : 1;
  async function save() {
    setError('');
    const out = lines.map(l => ({ sale_line_id: l.id, pieces: Math.round(Number(pcs[l.id]) || 0) })).filter(x => x.pieces > 0);
    if (!out.length) { setError('Enter the pieces to make.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('make_production_for_sale', { p_sale: sale.id, p: { due_date: due || null, lines: out } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't start production. Please try again.")); return; }
    onSaved();
  }

  return (
    <Modal title={`Make in production · order #${sale.sale_no}`} onClose={onClose} size="lg"
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Send to the Planner</button></>}>
      <div className="modal-form">
        {advance < ADVANCE - 1e-9 && (
          <div className="alert alert-warning" role="note">Paid {Math.round(advance * 100)}% — production usually starts after a {Math.round(ADVANCE * 100)}% advance.</div>
        )}
        <table className="rd-table">
          <thead><tr><th>Product</th><th className="num">Left to deliver</th><th className="num">In store</th><th className="num">Being made</th><th className="num">Make (pcs)</th></tr></thead>
          <tbody>
            {lines.map(l => {
              const u = isSqm(l.product_id) ? 'm²' : 'pcs';
              return (
                <tr key={l.id}>
                  <td><strong>{nameOf(l.product_id, l.color_id)}</strong></td>
                  <td className="num">{qtyText(Math.max(Number(l.quantity) - done(l), 0))} {u}</td>
                  <td className="num">{inStore ? `${qtyText(Math.max(inStore[`${l.product_id}|${l.color_id ?? ''}`] ?? 0, 0))} ${u}` : '…'}</td>
                  <td className="num">{making(l) ? `${qtyText(making(l))} pcs` : '—'}</td>
                  <td className="num"><NumberInput step="1" min="0" className="form-input" style={{ width: 100, marginLeft: 'auto' }} value={pcs[l.id] ?? ''} onChange={e => setPcs({ ...pcs, [l.id]: e.target.value })} /></td>
                </tr>
              );
            })}
          </tbody>
        </table>
        <label className="pe-field" style={{ maxWidth: 220 }}><span>Needed by</span><input type="date" className="form-input" value={due} onChange={e => setDue(e.target.value)} /></label>
        <p className="pl-help">It becomes a production order in the Planner, named for this order; batches cast against it show here. Pieces made join the general stock.</p>
      </div>
    </Modal>
  );
}
