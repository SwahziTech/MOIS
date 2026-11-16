import { useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { formatAmount, dateText } from '../../lib/format';
import { qtyText } from '../../lib/inventory';
import Modal from '../Modal';

/*
 * What the branch has of each material now (2026-11-16, the user): shown beside what is asked or
 * ordered, so whoever approves or pays sees the stock first. Summed over the branch's stores, in the
 * material's stock unit.
 */
export function useStockNow(branchId) {
  const [stock, setStock] = useState(null);   // material id → { qty, unit }
  useEffect(() => {
    if (!branchId) { setStock({}); return; }
    Promise.all([
      supabase.from('stock_balances').select('material_id, quantity').eq('branch_id', branchId).not('material_id', 'is', null),
      supabase.from('materials').select('id, stock_unit_id'),
      supabase.from('units').select('id, symbol'),
    ]).then(([b, m, u]) => {
      const sym = Object.fromEntries((u.data || []).map(x => [x.id, x.symbol]));
      const unitOf = Object.fromEntries((m.data || []).map(x => [x.id, sym[x.stock_unit_id] ?? '']));
      const out = {};
      for (const x of b.data || []) { const s = out[x.material_id] ||= { qty: 0, unit: unitOf[x.material_id] ?? '' }; s.qty += Number(x.quantity); }
      for (const id of Object.keys(unitOf)) out[id] ||= { qty: 0, unit: unitOf[id] };
      setStock(out);
    });
  }, [branchId]);
  return stock;
}

export const stockText = s => (s ? `${qtyText(Math.round(s.qty * 100) / 100)} ${s.unit}` : '…');

/** An order to pay, opened from the director's Needs you now: supplier, each material, stock now */
export default function OrderDetail({ order, branchName, money, canPay, onPay, onClose }) {
  const stock = useStockNow(order.branch_id);
  const [names, setNames] = useState({ mat: {}, unit: {} });
  useEffect(() => {
    Promise.all([supabase.from('materials').select('id, name'), supabase.from('units').select('id, symbol')])
      .then(([m, u]) => setNames({ mat: Object.fromEntries((m.data || []).map(x => [x.id, x.name])), unit: Object.fromEntries((u.data || []).map(x => [x.id, x.symbol])) }));
  }, []);
  const lines = order.lines || [];
  return (
    <Modal title={`Order #${order.po_no} · ${order.supplier?.name ?? 'Supplier'}`} onClose={onClose} size="lg"
      footer={<>
        <button type="button" className="btn btn-outline" onClick={onClose}>Close</button>
        {canPay && order.priced && <button type="button" className="btn btn-primary" onClick={onPay}>Pay</button>}
      </>}>
      <div className="modal-form">
        <div className="pd-grid">
          <span className="pl-help">Supplier</span><strong>{order.supplier?.name ?? '—'}</strong>
          <span className="pl-help">Branch</span><strong>{branchName}</strong>
          <span className="pl-help">Ordered</span><strong>{dateText(order.order_date)}</strong>
        </div>
        <table className="pd-lines">
          <thead><tr><th>Material</th><th className="num">Qty</th><th className="num">Price (TZS)</th><th className="num">Amount (TZS)</th><th className="num" title="What the branch has now, all its stores">In stock</th></tr></thead>
          <tbody>{lines.map((l, i) => (
            <tr key={i}>
              <td>{names.mat[l.material_id] ?? '—'}</td>
              <td className="num">{qtyText(Number(l.quantity))} <span className="pl-help">{names.unit[l.unit_id] ?? ''}</span></td>
              <td className="num">{l.unit_price != null ? formatAmount(Number(l.unit_price)) : '—'}</td>
              <td className="num">{l.unit_price != null ? formatAmount(Math.round(Number(l.quantity) * Number(l.unit_price) * 100) / 100) : '—'}</td>
              <td className="num">{stock ? stockText(stock[l.material_id]) : '…'}</td>
            </tr>
          ))}</tbody>
          <tfoot><tr><td colSpan={3}><strong>Total</strong></td><td className="num"><strong>{money(order.amount)}</strong></td><td /></tr></tfoot>
        </table>
        {!order.priced && <p className="text-sm text-warning">A price is missing — the branch manager adds it on the order before it can be paid.</p>}
      </div>
    </Modal>
  );
}
