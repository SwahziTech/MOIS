import { Fragment, useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { qtyText, warehouseLabel } from '../../lib/inventory';
import Modal from '../Modal';

/**
 * One approval request in full, so the admin sees exactly what will be
 * applied before approving: a production day's batches, a purchase's lines,
 * a stock correction's lines — names, not ids. Other kinds show their fields.
 */
export default function RequestDetail({ request: r, kindLabel, branchName, askedBy, refs, canDecide, mine, busy, error, note, onNote, onDecide, onWithdraw, onClose }) {
  const pending = r.status === 'pending';
  return (
    <Modal title={kindLabel} onClose={onClose} size="xl"
      footer={<>
        {pending && canDecide && (
          <>
            <input className="form-input" style={{ maxWidth: 280 }} placeholder="Note (optional)" aria-label="Note" value={note} onChange={e => onNote(e.target.value)} />
            <button type="button" className="btn btn-outline" disabled={busy} onClick={() => onDecide(false)}>Reject</button>
            <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={() => onDecide(true)}>Approve</button>
          </>
        )}
        {pending && !canDecide && mine && <button type="button" className="btn btn-outline" disabled={busy} onClick={onWithdraw}>Withdraw</button>}
        {!(pending && canDecide) && <button type="button" className="btn btn-primary" onClick={onClose}>Close</button>}
      </>}>
      <div className="rd">
        <p className="rd-meta">{r.summary}</p>
        <p className="pl-help">{branchName ?? '—'} · asked by {askedBy ?? '—'} · {new Date(r.requested_at).toLocaleString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })} · <strong>{r.status}</strong></p>
        {r.status === 'pending' && r.last_error && <div className="alert alert-error">Last approval couldn't be applied: {r.last_error}</div>}
        {r.decision_note && <p className="pl-help">Note: {r.decision_note}</p>}
        {error && <div className="alert alert-error">{error}</div>}
        {!refs ? <span className="skeleton" /> : <Body r={r} refs={refs} />}
      </div>
    </Modal>
  );
}

function Body({ r, refs }) {
  const p = r.payload || {};
  if (r.kind === 'production_day') return <ProductionDay p={p} refs={refs} />;
  if (r.kind === 'purchase') return <Purchase p={p} refs={refs} />;
  if (r.kind === 'stock_movement') return <Movement p={p} refs={refs} />;
  if (r.kind === 'stock_reversal') return <Reversal p={p} refs={refs} />;
  return <Fields value={p} refs={refs} />;
}

const money = n => (n == null ? '—' : new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(Number(n)));
const itemName = (refs, x) => refs.items[x.product_id ? `p:${x.product_id}` : `m:${x.material_id}`]?.name ?? '—';
const colour = (refs, id) => (id ? refs.colorById[id]?.name ?? '—' : '');
const unit = (refs, id) => refs.unitById[id]?.symbol ?? '';
const store = (refs, id) => { const w = refs.warehouses.find(x => x.id === id); return w ? warehouseLabel(w) : '—'; };

function ProductionDay({ p, refs }) {
  const batches = p.batches || [];
  return batches.map((b, i) => {
    const main = (b.outputs || []).find(o => o.primary);
    return (
      <section key={i} className="rd-sec">
        <h4 className="rd-title">
          Batch {i + 1} · {b.batch_date} · {main ? itemName(refs, main) : '—'}{b.color_id ? ` ${colour(refs, b.color_id)}` : ''} · <strong>{qtyText(b.cement_bags)} bags</strong>
          {b.allow_other_products && <span className="pl-tag">other products allowed</span>}
        </h4>
        <div className="rd-cols">
          <table className="rd-table">
            <thead><tr><th>Cast</th><th>Colour</th><th className="num">Pieces</th></tr></thead>
            <tbody>
              {(b.outputs || []).map((o, k) => (
                <tr key={k}><td>{o.primary ? '' : '+ '}{itemName(refs, o)}{!o.primary && <span className="pl-help"> (residual)</span>}</td>
                  <td>{colour(refs, o.primary ? b.color_id : (o.color_id ?? (refs.items[`p:${o.product_id}`]?.colorIds?.length ? b.color_id : null))) || '—'}</td>
                  <td className="num">{qtyText(o.pieces)}</td></tr>
              ))}
            </tbody>
          </table>
          <table className="rd-table">
            <thead><tr><th>Material used</th><th className="num">Quantity</th></tr></thead>
            <tbody>
              {(b.materials || []).map((m, k) => (
                <tr key={k}><td>{itemName(refs, m)}{m.source === 'counted' && <span className="pl-help"> (counted)</span>}</td>
                  <td className="num">{qtyText(m.quantity)} {unit(refs, m.unit_id)}</td></tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="pl-help">From {store(refs, b.raw_warehouse_id)} → cures in {store(refs, b.curing_warehouse_id)}{b.notes ? ` · ${b.notes}` : ''}</p>
      </section>
    );
  });
}

function Purchase({ p, refs }) {
  const rc = p.receipt || {};
  const price = Object.fromEntries((p.lines || []).map(l => [l.material_id, l.unit_price]));
  const sup = refs.suppliers.find(s => s.id === p.supplier_id)?.name ?? p.new_supplier_name ?? '—';
  let total = 0;
  return (
    <section className="rd-sec">
      <p className="pl-help">Received {rc.movement_date ?? '—'} into {store(refs, rc.warehouse_id)} · supplier <strong>{sup}</strong>{p.invoice_reference ? ` · invoice ${p.invoice_reference}` : ''}</p>
      <table className="rd-table">
        <thead><tr><th>Material</th><th className="num">Quantity</th><th className="num">Unit price</th><th className="num">Amount</th></tr></thead>
        <tbody>
          {(rc.lines || []).map((l, k) => {
            const amt = price[l.material_id] != null ? Number(price[l.material_id]) * Number(l.quantity) : null;
            if (amt != null) total += amt;
            return (
              <tr key={k}><td>{itemName(refs, l)}</td><td className="num">{qtyText(l.quantity)} {unit(refs, l.unit_id)}</td>
                <td className="num">{money(price[l.material_id])}</td><td className="num">{money(amt)}</td></tr>
            );
          })}
        </tbody>
      </table>
      <dl className="rd-dl">
        <dt>Lines total</dt><dd>{money(total)}{p.prices_include_vat ? ' (VAT included)' : ''}</dd>
        {Number(p.transport_charge) > 0 && <><dt>Transport</dt><dd>{money(p.transport_charge)}</dd></>}
        {p.vat_amount != null && <><dt>VAT</dt><dd>{money(p.vat_amount)}</dd></>}
        <dt>Paid</dt><dd>{money(p.amount_paid)}{p.paid_on ? ` on ${p.paid_on}` : ''}{p.payment_method ? ` · ${p.payment_method}` : ''}</dd>
        {p.notes && <><dt>Notes</dt><dd>{p.notes}</dd></>}
      </dl>
    </section>
  );
}

const MOVE_LABEL = { opening_balance: 'Opening balance', receipt: 'Receipt', issue: 'Issue', transfer: 'Transfer', adjustment: 'Adjustment', count: 'Count' };
function Movement({ p, refs }) {
  return (
    <section className="rd-sec">
      <p className="pl-help">{MOVE_LABEL[p.type] ?? p.type} · {p.movement_date ?? '—'} · {store(refs, p.warehouse_id)}{p.to_warehouse_id ? ` → ${store(refs, p.to_warehouse_id)}` : ''}{p.reason ? ` · ${p.reason}` : ''}</p>
      <Lines lines={p.lines || []} refs={refs} />
      {p.notes && <p className="pl-help">Notes: {p.notes}</p>}
    </section>
  );
}

function Lines({ lines, refs }) {
  return (
    <table className="rd-table">
      <thead><tr><th>Item</th><th>Colour</th><th className="num">Quantity</th></tr></thead>
      <tbody>
        {lines.map((l, k) => (
          <tr key={k}><td>{itemName(refs, l)}</td><td>{colour(refs, l.color_id) || '—'}</td>
            <td className="num">{qtyText(l.quantity)} {unit(refs, l.unit_id ?? l.stock_unit_id)}</td></tr>
        ))}
      </tbody>
    </table>
  );
}

// A reversal: the movement it undoes, as recorded
function Reversal({ p, refs }) {
  const [mv, setMv] = useState(null);
  useEffect(() => {
    if (!p.movement_id) return;
    supabase.from('inventory_movements').select('movement_type, movement_date, warehouse_id, reason, lines:inventory_transactions(product_id, material_id, color_id, quantity, stock_unit_id)')
      .eq('id', p.movement_id).maybeSingle().then(({ data }) => setMv(data ?? false));
  }, [p.movement_id]);
  return (
    <section className="rd-sec">
      <p className="pl-help">Reason: {p.reason ?? '—'}</p>
      {mv === null ? <span className="skeleton" /> : !mv ? <p className="pl-help">The movement isn't available.</p> : (
        <>
          <p className="pl-help">Undoes: {MOVE_LABEL[mv.movement_type] ?? mv.movement_type} · {mv.movement_date} · {store(refs, mv.warehouse_id)}{mv.reason ? ` · ${mv.reason}` : ''}</p>
          <Lines lines={mv.lines || []} refs={refs} />
        </>
      )}
    </section>
  );
}

// Anything else: its fields, with ids shown as names
const ID_NAME = {
  product_id: (refs, v) => refs.items[`p:${v}`]?.name, material_id: (refs, v) => refs.items[`m:${v}`]?.name,
  color_id: (refs, v) => refs.colorById[v]?.name, base_color_id: (refs, v) => refs.colorById[v]?.name,
  unit_id: (refs, v) => refs.unitById[v]?.symbol, warehouse_id: (refs, v) => store(refs, v),
  supplier_id: (refs, v) => refs.suppliers.find(s => s.id === v)?.name,
  category_id: (refs, v) => refs.categoryRows.find(c => c.id === v)?.name,
};
const keyLabel = k => k.replace(/_id$/, '').replace(/_/g, ' ').replace(/^./, c => c.toUpperCase());
const show = (refs, k, v) => (v == null || v === '' ? '—' : ID_NAME[k] ? ID_NAME[k](refs, v) ?? '—' : typeof v === 'boolean' ? (v ? 'Yes' : 'No') : typeof v === 'number' ? money(v) : String(v));

function Fields({ value, refs }) {
  const entries = Object.entries(value || {}).filter(([k]) => k !== 'draft_id');
  return (
    <section className="rd-sec">
      <dl className="rd-dl">
        {entries.filter(([, v]) => !Array.isArray(v) && (v === null || typeof v !== 'object')).map(([k, v]) => (
          <Fragment key={k}><dt>{keyLabel(k)}</dt><dd>{show(refs, k, v)}</dd></Fragment>
        ))}
      </dl>
      {entries.filter(([, v]) => Array.isArray(v) && v.length && typeof v[0] === 'object').map(([k, rows]) => {
        const cols = [...new Set(rows.flatMap(x => Object.keys(x)))];
        return (
          <table key={k} className="rd-table">
            <thead><tr>{cols.map(c => <th key={c}>{keyLabel(c)}</th>)}</tr></thead>
            <tbody>{rows.map((x, i) => <tr key={i}>{cols.map(c => <td key={c}>{show(refs, c, x[c])}</td>)}</tr>)}</tbody>
          </table>
        );
      })}
      {entries.filter(([, v]) => v && typeof v === 'object' && !Array.isArray(v)).map(([k, v]) => (
        <div key={k}><h4 className="rd-title">{keyLabel(k)}</h4><Fields value={v} refs={refs} /></div>
      ))}
    </section>
  );
}
