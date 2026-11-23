import { formatAmount, tableDate } from '../../lib/format';
import EmptyState from '../EmptyState';
import { ShoppingCart } from 'lucide-react';

/*
 * One table for all of procurement (2026-11-16, the user): purchases and expenses alike —
 * Date · Item · Qty · Price · Amount · Source · Status. No buttons on the rows: a click opens the
 * record with its whole story (payment, delivery, slips) and what can be done next.
 *
 * row: { key, date, ref?, items: [{ name, qty, unit, price }], amount, source, status, sub?, muted?, onOpen }
 *
 * The status, one word or two, for where the record stands:
 */
export const STATUS = {
  approval:   ['Waiting approval',     'badge-warning', 'Sent for approval; nothing is recorded until it is approved'],
  ordered:    ['Ordered',              'badge-neutral', 'Bought, nothing paid or delivered yet'],
  paid_wait:  ['Paid · not delivered', 'badge-info',    'Paid; the goods are still coming'],
  part_deliv: ['Part delivered',       'badge-info',    'Some of the goods have come'],
  deliv_due:  ['Delivered · not paid', 'badge-warning', 'The goods are in; the supplier is still to be paid'],
  part_paid:  ['Part paid',            'badge-warning', 'Part of the amount is paid'],
  not_paid:   ['Not paid',             'badge-neutral', 'Recorded, nothing paid yet'],
  done:       ['Done',                 'badge-success', 'Paid and delivered — nothing left to do'],
  void:       ['Void',                 'badge-neutral', 'Entered wrongly and cancelled; kept on record'],
};
export const STATUS_OPTIONS = [{ value: '', label: 'All' }, ...Object.entries(STATUS).map(([value, [label]]) => ({ value, label }))];

export default function ProcTable({ rows, loading, money, empty = 'Nothing recorded in this period.' }) {
  const total = rows.filter(r => r.status !== 'void' && r.status !== 'approval').reduce((t, r) => t + (Number(r.amount) || 0), 0);
  return (
    <table className="proc-table pc">
      <thead><tr><th>Date</th><th>Item</th><th className="num">Qty</th><th className="num">Price (TZS)</th><th className="num">Amount (TZS)</th><th>Source</th><th>Status</th></tr></thead>
      <tbody>
        {loading ? <tr><td colSpan={7}><span className="skeleton" /></td></tr>
        : rows.length === 0 ? <tr><td colSpan={7}><EmptyState icon={ShoppingCart} title={empty} description="" /></td></tr>
        : rows.map(r => {
          const [label, cls, help] = STATUS[r.status] ?? ['—', 'badge-neutral', ''];
          return (
            <tr key={r.key} className={`clickable-row${r.muted ? ' text-muted' : ''}`} onClick={r.onOpen} title="Open it — its payments, delivery and what to do next">
              <td>{tableDate(r.date)}{r.ref && <div className="text-xs text-muted">{r.ref}</div>}</td>
              <td>{r.items.map((x, i) => <div key={i} style={{ fontWeight: 500 }}>{x.name}</div>)}{r.kindLabel && <div className="text-xs text-muted">{r.kindLabel}</div>}</td>
              <td className="num">{r.items.map((x, i) => <div key={i}>{x.qty != null && x.qty !== '' ? <>{typeof x.qty === 'number' ? formatAmount(x.qty) : x.qty} <span className="text-xs text-muted">{x.unit}</span></> : '—'}</div>)}</td>
              <td className="num">{r.items.map((x, i) => <div key={i}>{x.price != null ? formatAmount(Number(x.price)) : '—'}</div>)}</td>
              <td className="num">{r.amount != null ? formatAmount(Number(r.amount)) : '—'}</td>
              <td>{r.source || '—'}</td>
              <td><span className={`badge ${cls}`} title={help}>{label}</span>{r.sub && <div className="text-xs text-muted">{r.sub}</div>}</td>
            </tr>
          );
        })}
      </tbody>
      {!loading && rows.length > 0 && <tfoot><tr><td colSpan={4}><strong>Total</strong></td><td className="num"><strong>{money(total)}</strong></td><td colSpan={2} /></tr></tfoot>}
    </table>
  );
}
