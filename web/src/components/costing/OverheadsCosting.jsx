import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Wrench } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { formatMoney, formatMoneyShort, formatAmount } from '../../lib/format';
import { PageTabs } from '../ListControls';
import EmptyState from '../EmptyState';
import ErrorState from '../ErrorState';

const monthName = m => new Date(`${m}T00:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });

/*
 * Overheads on Costing (1e, migration 076): the expenses of categories ticked
 * as production costs (Purchases ⚙), pulled from Purchases › Expenses and
 * shared over each month's batches by cement bags — over a machine's batches
 * when the expense names one, else over all the branch's. Monthly for now.
 */
export default function OverheadsCosting({ branchId, currency }) {
  const money = v => formatMoney(v, currency);
  const [view, setView] = useState('months');
  const [data, setData] = useState(null);
  const [error, setError] = useState('');

  async function load() {
    setError('');
    const [m, e, x] = await Promise.all([
      supabase.from('production_overhead_months').select('*').eq('branch_id', branchId).order('month', { ascending: false }),
      supabase.from('production_overhead_expenses').select('*').eq('branch_id', branchId).order('expense_date', { ascending: false }).limit(500),
      supabase.from('machines').select('id, name').eq('branch_id', branchId),
    ]);
    if (m.error || e.error) { console.error(m.error || e.error); setError("We couldn't load overheads."); return; }
    setData({ months: m.data || [], expenses: e.data || [], machine: Object.fromEntries((x.data || []).map(r => [r.id, r.name])) });
  }
  useEffect(() => { setData(null); load(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  if (error) return <div className="card"><ErrorState message={error} onRetry={load} /></div>;
  if (data === null) return <div className="card"><span className="skeleton" /></div>;
  const thisMonth = new Date().toISOString().slice(0, 8) + '01';
  const now = data.months.filter(r => r.month === thisMonth);
  const total = now.reduce((t, r) => t + Number(r.overheads), 0);
  const branchWide = now.find(r => !r.machine_id);
  const unshared = data.months.filter(r => !(Number(r.bags) > 0)).reduce((t, r) => t + Number(r.overheads), 0);

  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Overheads this month</span><strong>{money(total)}</strong><span className="pl-help">{now.reduce((t, r) => t + Number(r.expenses), 0)} expenses into products</span></div>
        <div className="mm-stat"><span className="pl-label">A cement bag</span><strong>{branchWide?.per_bag != null ? money(Number(branchWide.per_bag)) : '—'}</strong><span className="pl-help">branch-wide, this month</span></div>
        <div className="mm-stat"><span className="pl-label">Not shared</span><strong className={unshared > 0 ? 'text-warning' : ''}>{formatMoneyShort(unshared, currency)}</strong><span className="pl-help">no batches on that machine or month</span></div>
      </div>
      <div className="flex items-center gap-8" style={{ marginBottom: 8, flexWrap: 'wrap' }}>
        <PageTabs nested tabs={[['months', 'By month'], ['expenses', 'Expenses counted']]} value={view} onChange={setView} />
        <Link to="/purchases?tab=expenses" className="btn btn-ghost btn-sm" style={{ marginLeft: 'auto' }}>Expenses ›</Link>
      </div>
      {data.months.length === 0 ? (
        <div className="card"><EmptyState icon={Wrench} title="No production overheads yet" description="Tick the expense categories that are production costs under Purchases ⚙, then record those expenses — naming the machine when it is for one." /></div>
      ) : (
        <div className="card"><div className="table-container">
          {view === 'months' ? (
            <table>
              <thead><tr><th>Month</th><th>For</th><th className="num">Expenses</th><th className="num">Overheads (TZS)</th><th className="num">Batches</th><th className="num">Cement bags</th><th className="num">A bag (TZS)</th></tr></thead>
              <tbody>
                {data.months.map(r => (
                  <tr key={`${r.month}|${r.machine_id ?? ''}`}>
                    <td>{monthName(r.month)}</td>
                    <td>{r.machine_id ? data.machine[r.machine_id] ?? '—' : <span className="pl-help">the whole branch</span>}</td>
                    <td className="num">{r.expenses}</td>
                    <td className="num"><strong>{formatAmount(Number(r.overheads))}</strong></td>
                    <td className="num">{Number(r.batches) || ''}</td>
                    <td className="num">{Number(r.bags) || ''}</td>
                    <td className="num">{r.per_bag != null ? formatAmount(Number(r.per_bag)) : <span className="text-warning">not shared</span>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <table>
              <thead><tr><th>Date</th><th>Category</th><th>What</th><th>For</th><th className="num">Amount (TZS)</th></tr></thead>
              <tbody>
                {data.expenses.map(e => (
                  <tr key={e.id}>
                    <td>{e.expense_date}</td><td>{e.category}</td><td>{e.description}</td>
                    <td>{e.machine_id ? data.machine[e.machine_id] ?? '—' : <span className="pl-help">the whole branch</span>}</td>
                    <td className="num">{formatAmount(Number(e.amount))}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot><tr><td colSpan={4}><strong>Total</strong></td><td className="num"><strong>{money(data.expenses.reduce((t, e) => t + Number(e.amount), 0))}</strong></td></tr></tfoot>
            </table>
          )}
        </div></div>
      )}
      <p className="pl-help" style={{ marginTop: 8 }}>From Purchases › Expenses (categories ticked as production costs under Purchases ⚙). A month's overheads are shared over that month's batches by cement bags — on the expense's machine when it names one — and go into each product's production cost. Electricity is costed from the meters; labour comes with HR.</p>
    </>
  );
}
