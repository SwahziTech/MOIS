import { useEffect, useRef, useState } from 'react';
import { CalendarClock } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../../lib/supabase';
import { qtyText } from '../../lib/inventory';
import { dbErrorMessage } from '../../lib/masterData';
import Modal from '../Modal';
import NumberInput from '../NumberInput';
import DropDetails from '../DropDetails';

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

/** A production line belongs to a sale line: by its link, or — after the sale was edited and its lines replaced — by product and colour */
export const belongsTo = (r, l, sale) => r.line.sale_line_id === l.id
  || (!(sale.lines || []).some(y => y.id === r.line.sale_line_id) && r.line.product_id === l.product_id && (r.line.color_id ?? null) === (l.color_id ?? null));

/** "made 400 / 1,200" across a sale's production */
export function productionSummary(rows) {
  if (!rows?.length) return null;
  const planned = rows.reduce((t, r) => t + Number(r.line.pieces), 0);
  const ready = rows.reduce((t, r) => t + Number(r.progress?.passed ?? 0), 0);
  const cast = rows.reduce((t, r) => t + Number(r.progress?.cast_pieces ?? 0), 0);
  return { planned, cast, ready };
}

// makeTick: the sale window's step button asks for the Make in production window (2026-11-22, step by step)
// needOf(line): how much of a line the free stock can't cover (stock unit) — the sale window works it out
export default function SaleProduction({ sale, refs, rows = [], paid, canSell, canPlan = false, needOf = () => 0, makeTick = 0, onChanged }) {
  const navigate = useNavigate();
  const [sent, setSent] = useState(null);   // a production order just made: go to the Planner or stay
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [making, setMaking] = useState(false);
  useEffect(() => { if (makeTick > 0) setMaking(true); }, [makeTick]);
  const live = sale.stage !== 'cancelled';
  const waiting = sale.waiting_for || [];
  const nameOf = (productId, colorId) => `${refs.items[`p:${productId}`]?.name ?? '—'}${colorId ? ` ${refs.colorById[colorId]?.name ?? ''}` : ''}`;
  const toPlanner = () => navigate('/production?tab=planner');

  // the order changed since production was planned (2026-11-22, the user): more, less, a product added, a new date
  const [perSqm, setPerSqm] = useState({});
  useEffect(() => {
    const ids = [...new Set((sale.lines || []).map(l => l.product_id).filter(Boolean))];
    if (!ids.length || !rows.length) return;
    supabase.from('product_specs').select('product_id, pcs_per_sqm').in('product_id', ids)
      .then(({ data }) => setPerSqm(Object.fromEntries((data || []).filter(x => Number(x.pcs_per_sqm) > 0).map(x => [x.product_id, Number(x.pcs_per_sqm)]))));
  }, [sale.id, rows.length]); // eslint-disable-line react-hooks/exhaustive-deps
  const isSqm = id => (refs.unitById[refs.items[`p:${id}`]?.stockUnitId]?.symbol ?? '').toUpperCase() === 'SQM';
  const pcsOf = (l, q) => (isSqm(l.product_id) ? (perSqm[l.product_id] ? Math.ceil(q * perSqm[l.product_id]) : null) : Math.ceil(q));
  const open = rows.filter(r => r.order.status === 'open');
  const openOrder = open[0]?.order ?? null;
  const changes = [];
  // only an edit of the order is a change (2026-11-22, the user): production moving on, or stock coming and going, is not.
  // Saving an edited order replaces its lines, so a production line no longer linked to one of them means the order was edited.
  const saleLineIds = new Set((sale.lines || []).map(l => l.id));
  const productLines = (sale.lines || []).filter(x => x.product_id);
  const edited = open.some(r => !saleLineIds.has(r.line.sale_line_id) && productLines.some(l => belongsTo(r, l, sale)));
  const gone = open.filter(r => !productLines.some(l => belongsTo(r, l, sale)));
  if (live && openOrder && canPlan && edited) {
    for (const l of productLines) {
      const r = open.find(x => belongsTo(x, l, sale));
      const need = pcsOf(l, needOf(l));
      if (need == null) continue;
      const left = r ? Math.max(Number(r.line.pieces) - Number(r.progress?.passed ?? 0), 0) : 0;   // still to come out of production
      const cast = r ? Number(r.progress?.cast_pieces ?? 0) : 0;
      if (r && need > left) changes.push({ key: l.id, l, kind: 'more', text: `${nameOf(l.product_id, l.color_id)}: the order needs ${qtyText(need - left)} pcs more than production #${r.order.order_no} makes`, order: r.order, pieces: Number(r.line.pieces) + (need - left), extra: need - left });
      else if (r && left > need) {
        const to = Math.max(Number(r.line.pieces) - (left - need), cast, 1);
        if (to < Number(r.line.pieces)) changes.push({ key: l.id, l, kind: 'less', text: `${nameOf(l.product_id, l.color_id)}: production #${r.order.order_no} makes ${qtyText(left - need)} pcs more than the order now needs${cast > to - 1 && cast > 0 ? ` (${qtyText(cast)} already cast)` : ''}`, order: r.order, pieces: to });
      } else if (!r && need > 0) changes.push({ key: l.id, l, kind: 'new', text: `${nameOf(l.product_id, l.color_id)}: ${qtyText(need)} pcs short and not in production`, order: openOrder, pieces: need });
    }
  }
  if (live && openOrder && canPlan) {
    for (const r of gone) changes.push({ key: `gone:${r.line.id}`, kind: 'gone', text: `${nameOf(r.line.product_id, r.line.color_id)} is no longer in the order; production #${r.order.order_no} still makes ${qtyText(Math.max(Number(r.line.pieces) - Number(r.progress?.cast_pieces ?? 0), 0))} pcs of it`, order: r.order });
    if (sale.due_date && openOrder.due_date && sale.due_date !== openOrder.due_date)
      changes.push({ key: 'due', kind: 'due', text: `The order is due ${sale.due_date}; production #${openOrder.order_no} is due ${openOrder.due_date}`, order: openOrder });
  }
  // edited but nothing to change: link production to the new lines quietly, so it isn't asked again
  const lineChanges = changes.filter(c => ['more', 'less', 'new'].includes(c.kind)).length;
  const relinked = useRef('');
  useEffect(() => {
    if (!edited || lineChanges > 0 || !openOrder || !canPlan || relinked.current === openOrder.id + [...saleLineIds].join()) return;
    relinked.current = openOrder.id + [...saleLineIds].join();
    supabase.rpc('update_production_for_sale', { p_sale: sale.id, p: { order_id: openOrder.id, lines: [] } }).then(({ error: err }) => { if (!err) onChanged(); });
  }, [edited, lineChanges, openOrder?.id]); // eslint-disable-line react-hooks/exhaustive-deps
  async function applyChange(c, how) {
    setError(''); setBusy(true);
    const { data, error: err } = how === 'separate'
      ? await supabase.rpc('make_production_for_sale', { p_sale: sale.id, p: { lines: [{ sale_line_id: c.l.id, pieces: c.kind === 'more' ? c.extra : c.pieces }] } })
      : await supabase.rpc('update_production_for_sale', { p_sale: sale.id, p: { order_id: c.order.id, ...(c.kind === 'due' ? { due_date: sale.due_date, lines: [] } : { lines: [{ sale_line_id: c.l.id, pieces: c.pieces }] }) } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't change production. Please try again.")); return; }
    if (how === 'separate' && data) setSent({ id: data });
    onChanged();
  }

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
          {/* a dropdown (2026-11-22, the user): tick what it waits for */}
          <DropDetails summary={waiting.length ? WAITING.filter(([k]) => waiting.includes(k)).map(([, l]) => l).join(', ') : 'Nothing'}>
            {WAITING.map(([k, l]) => (
              <label key={k} className="so-opt"><input type="checkbox" checked={waiting.includes(k)} disabled={!canSell || busy} onChange={() => toggle(k)} /> {l}</label>
            ))}
          </DropDetails>
          {/* Make in production: now a step of the sale window (2026-11-22) */}
        </div>
      )}
      {error && <p className="text-xs text-error">{error}</p>}
      {changes.length > 0 && (
        <div className="alert alert-warning so-changes" role="note">
          <strong>The order changed since production was planned</strong>
          {changes.map(c => (
            <div key={c.key} className="so-change">
              <span>{c.text}.</span>
              <span className="so-change-acts">
                {c.kind === 'more' && <><button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={() => applyChange(c, 'update')}>Update #{c.order.order_no} to {qtyText(c.pieces)}</button>
                  <button type="button" className="btn btn-outline btn-sm" disabled={busy} onClick={() => applyChange(c, 'separate')} title="A production order of its own for the extra pieces">New order for {qtyText(c.extra)}</button></>}
                {c.kind === 'less' && <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={() => applyChange(c, 'update')}>Reduce #{c.order.order_no} to {qtyText(c.pieces)}</button>}
                {c.kind === 'new' && <><button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={() => applyChange(c, 'update')} title="Merge it into the production order already made for this order">Add to #{c.order.order_no}</button>
                  <button type="button" className="btn btn-outline btn-sm" disabled={busy} onClick={() => applyChange(c, 'separate')}>New production order</button></>}
                {c.kind === 'gone' && <button type="button" className="btn btn-outline btn-sm" onClick={toPlanner}><CalendarClock size={15} /> Change it in the Planner</button>}
                {c.kind === 'due' && <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={() => applyChange(c, 'update')}>Move #{c.order.order_no} to {sale.due_date}</button>}
              </span>
            </div>
          ))}
          <span className="pl-help">Or leave it as it is — change it later here or in the Planner.</span>
        </div>
      )}
      {rows.length > 0 && (
        <table className="rd-table so-prog">
          <thead><tr><th>Made for this order</th><th className="num">Planned</th><th className="num">Made</th><th className="num">Curing</th><th className="num">Ready</th><th className="num">Left to make</th><th>Production order</th></tr></thead>
          <tbody>
            {rows.map(({ order, line, progress }) => (
              <tr key={line.id}>
                <td><strong>{nameOf(line.product_id, line.color_id)}</strong></td>
                <td className="num">{qtyText(line.pieces)}</td>
                <td className="num">{qtyText(progress?.cast_pieces ?? 0)}</td>
                <td className="num">{qtyText(progress?.curing ?? 0)}</td>
                <td className="num"><strong className={(progress?.passed ?? 0) >= line.pieces ? 'text-success' : ''}>{qtyText(progress?.passed ?? 0)}</strong></td>
                <td className="num">{qtyText(Math.max(Number(line.pieces) - Number(progress?.cast_pieces ?? 0), 0))}</td>
                <td className="text-sm">#{order.order_no} · {order.status}{order.due_date ? <span className="pl-help"> · due {order.due_date}</span> : ''}
                  <button type="button" className="icon-btn" style={{ marginLeft: 6, verticalAlign: 'middle' }} aria-label="Open the Planner" title="Open the Planner" onClick={toPlanner}><CalendarClock size={15} /></button></td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {making && <MakeModal sale={sale} refs={refs} rows={rows} paid={paid} nameOf={nameOf} needOf={needOf} onClose={() => setMaking(false)} onSaved={id => { setMaking(false); setSent({ id }); onChanged(); }} />}
      {/* sent (2026-11-22, the user): go to the Planner, or stay on the order */}
      {sent && (
        <Modal title="Sent to the Planner" onClose={() => setSent(null)}
          footer={<><button type="button" className="btn btn-outline" onClick={() => setSent(null)}>Stay here</button>
            <button type="button" className="btn btn-primary" onClick={() => { setSent(null); toPlanner(); }}><CalendarClock size={15} /> Go to the Planner</button></>}>
          <p className="text-sm">A production order was made for this order. Its progress shows here as batches are cast against it.</p>
        </Modal>
      )}
    </section>
  );
}

function MakeModal({ sale, refs, rows, paid, nameOf, needOf, onClose, onSaved }) {
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
  const making = l => rows.filter(r => belongsTo(r, l, sale) && r.order.status === 'open').reduce((t, r) => t + Math.max(Number(r.line.pieces) - Number(r.progress?.passed ?? 0), 0), 0);
  const toPcs = (l, q) => (isSqm(l.product_id) ? (perSqm[l.product_id] ? Math.ceil(q * perSqm[l.product_id]) : null) : Math.ceil(q));

  useEffect(() => {
    supabase.rpc('sales_availability', { p_branch_id: sale.branch_id, ...(sale.warehouse_id ? { p_warehouse_id: sale.warehouse_id } : {}) })
      .then(({ data }) => setInStore(Object.fromEntries((data || []).map(x => [`${x.product_id}|${x.color_id ?? ''}`, Number(x.on_hand)]))));
    supabase.from('product_specs').select('product_id, pcs_per_sqm').in('product_id', lines.map(l => l.product_id))
      .then(({ data }) => setPerSqm(Object.fromEntries((data || []).filter(x => Number(x.pcs_per_sqm) > 0).map(x => [x.product_id, Number(x.pcs_per_sqm)]))));
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // the shortfall a line, in pieces: what is left to deliver less the store and what is already being made
  // the same shortage the sale shows (free stock — others' holds taken off), in pieces, less what is already being made
  const shortOf = l => {
    if (!inStore) return null;
    const p = toPcs(l, needOf(l));
    return p == null ? null : Math.max(p - making(l), 0);
  };
  useEffect(() => { if (inStore) setPcs(Object.fromEntries(lines.map(l => [l.id, String(shortOf(l) ?? '')]))); }, [inStore, perSqm]); // eslint-disable-line react-hooks/exhaustive-deps

  const advance = Number(sale.total) > 0 ? paid / Number(sale.total) : 1;
  async function save() {
    setError('');
    const out = lines.map(l => ({ sale_line_id: l.id, pieces: Math.round(Number(pcs[l.id]) || 0) })).filter(x => x.pieces > 0);
    if (!out.length) { setError('Enter the pieces to make.'); return; }
    setBusy(true);
    const { data, error: err } = await supabase.rpc('make_production_for_sale', { p_sale: sale.id, p: { due_date: due || null, lines: out } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't start production. Please try again.")); return; }
    onSaved(data);
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
