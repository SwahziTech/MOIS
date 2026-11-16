import { useEffect, useMemo, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { formatAmount, tableDate } from '../../lib/format';
import PeriodSelect from '../PeriodSelect';
import { ChipRow } from '../ListControls';

/*
 * All money out, by date (2026-11-16, the user: "include all money out under All — purchases, expenses,
 * wages, electricity, etc."). One list, newest first: payments to suppliers and every expense paid —
 * salaries and wages (pay sheets post as expenses), electricity tokens, tools, transport… — with where
 * the money came from (the weekly cash or the directors · bank) and the total.
 */
const TYPES = [['', 'All'], ['purchase', 'Purchases'], ['expense', 'Expenses'], ['pay', 'Salaries & wages'], ['power', 'Electricity']];

export default function MoneyOutPanel({ branchId, inBranch, period, today, expenses, expCats, suppliers, money }) {
  const [pays, setPays] = useState(null);
  const [type, setType] = useState('');
  useEffect(() => {
    let q = supabase.from('purchase_payments').select('*, purchase:purchases!inner(id, branch_id, status, invoice_reference, supplier_id)').eq('purchase.status', 'recorded');
    if (branchId) q = q.eq('purchase.branch_id', branchId);
    q.order('paid_on', { ascending: false }).limit(1000).then(({ data }) => setPays(data || []));
  }, [branchId]);
  const cat = id => expCats.find(c => c.id === id)?.name ?? '';
  const kindOf = name => (/^(salaries|wages|statutory)/i.test(name) ? 'pay' : /^electricity/i.test(name) ? 'power' : 'expense');
  const rows = useMemo(() => [
    ...(pays || []).filter(p => inBranch(p.purchase.branch_id)).map(p => ({
      key: `p${p.id}`, day: p.paid_on, what: `${suppliers.find(s => s.id === p.purchase.supplier_id)?.name ?? 'Supplier'}${p.purchase.invoice_reference ? ` · ${p.purchase.invoice_reference}` : ''}`,
      type: 'Purchase', kind: 'purchase', weekly: p.from_weekly_cash, amount: Number(p.amount) })),
    ...expenses.filter(e => inBranch(e.branch_id) && e.status === 'recorded' && Number(e.amount_paid) > 0).map(e => ({
      key: `e${e.id}`, day: e.paid_on || e.expense_date, what: e.description, type: cat(e.category_id) || 'Expense', kind: kindOf(cat(e.category_id)),
      weekly: e.from_weekly_cash, amount: Number(e.amount_paid) })),
  ].filter(r => r.day && period.has(r.day) && (!type || r.kind === type))
   .sort((a, b) => (a.day < b.day ? 1 : a.day > b.day ? -1 : 0)), [pays, expenses, type, period, inBranch]); // eslint-disable-line react-hooks/exhaustive-deps
  const total = rows.reduce((t, r) => t + r.amount, 0);
  return (
    <div className="card">
      <div className="card-body" style={{ paddingBottom: 0 }}><PeriodSelect period={period} today={today} extra={[['all', 'All time']]} /></div>
      <div className="card-body" style={{ paddingBottom: 0 }}><ChipRow value={type} onChange={setType} items={TYPES.slice(1).map(([id, label]) => ({ id, label }))} /></div>
      <div className="table-container">
        <table>
          <thead><tr><th>Date</th><th>What</th><th>Type</th><th>From</th><th className="num">Amount (TZS)</th></tr></thead>
          <tbody>
            {pays === null ? <tr><td colSpan={5}><span className="skeleton" /></td></tr>
            : rows.length === 0 ? <tr><td colSpan={5} className="text-muted">No money out in this period.</td></tr>
            : rows.map(r => (
              <tr key={r.key}>
                <td>{tableDate(r.day)}</td>
                <td>{r.what}</td>
                <td>{r.type}</td>
                <td className="text-sm">{r.weekly ? 'Weekly cash' : r.weekly === false ? 'Directors · bank' : '—'}</td>
                <td className="num">{formatAmount(r.amount)}</td>
              </tr>
            ))}
          </tbody>
          {rows.length > 0 && <tfoot><tr><td colSpan={4}><strong>Total</strong></td><td className="num"><strong>{money(total)}</strong></td></tr></tfoot>}
        </table>
      </div>
    </div>
  );
}
