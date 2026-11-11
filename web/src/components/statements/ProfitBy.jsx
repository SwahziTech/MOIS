import { useEffect, useMemo, useState } from 'react';
import { PieChart } from 'lucide-react';
import PeriodBar from '../PeriodBar';
import EmptyState from '../EmptyState';
import ErrorState from '../ErrorState';
import { PageTabs } from '../ListControls';
import { supabase } from '../../lib/supabase';
import { useSessionPeriod } from '../../lib/sessionPeriod';
import { periodRange } from '../../lib/periods';
import { formatAmount, formatMoney } from '../../lib/format';
import { loadInventoryRefs, qtyText } from '../../lib/inventory';
import { loadOutputs, totals, keyOf } from '../../lib/costingCalc';

/*
 * Profit by product, customer and branch (2026-11-11, advanced costing; SwahziTech chose rejects &
 * waste to come off). For a period:
 *   sales delivered without VAT − the full cost of what was delivered (materials, labour, electricity,
 *   overheads — as Profit & loss) = gross margin;
 *   by product and branch, less the rejects made in the period at their full cost = profit.
 * Rejects belong to production, not to a customer, so the customer view stops at the gross margin.
 * The totals match Profit & loss's sales, cost and gross margin for the same days.
 */
const amt = v => formatAmount(Math.round(Number(v || 0)));
const pct = (a, b) => (b > 0 ? `${Math.round((a / b) * 100)}%` : '—');

export default function ProfitBy({ today, inBranch, branchIds, cur, branches = [] }) {
  const money = v => formatMoney(Math.round(Number(v || 0)), cur);
  const [period, setPeriod] = useSessionPeriod('statements-profit-by');
  const [from, to] = periodRange(period, today);
  const [by, setBy] = useState('product');
  const [data, setData] = useState(null);
  const [error, setError] = useState('');

  async function load() {
    setError(''); setData(null);
    try {
      const [refs, d, ...outs] = await Promise.all([
        loadInventoryRefs(),
        supabase.from('sale_delivery_lines')
          .select('quantity, value, cost, estimated_cost, line:sale_lines!inner(product_id, color_id, item_name, amount, total), delivery:sale_deliveries!inner(delivered_on, sale:sales!inner(branch_id, customer_id, walk_in_name, customer:customers(name)))')
          .gte('delivery.delivered_on', from).lte('delivery.delivered_on', to),
        // rejects need costing_outputs (118); without it, profit still shows (no rejects)
        ...branchIds.map(b => loadOutputs(b, from, to < today ? to : today).then(rs => rs.map(r => ({ ...r, branch_id: b }))).catch(() => [])),
      ]);
      if (d.error) throw d.error;
      setData({ refs, lines: (d.data || []).filter(x => inBranch(x.delivery.sale.branch_id)), outputs: outs.flat() });
    } catch (e) { console.error(e); setError("We couldn't work out the profit."); }
  }
  useEffect(() => { load(); }, [from, to, branchIds.join(',')]); // eslint-disable-line react-hooks/exhaustive-deps

  const view = useMemo(() => {
    if (!data) return null;
    const { refs, lines, outputs } = data;
    const exVat = x => (Number(x.line.total) ? Number(x.value) * Number(x.line.amount) / Number(x.line.total) : Number(x.value));
    const nameOf = (pid, cid, item) => (pid ? `${refs.items[`p:${pid}`]?.name ?? ''}${cid ? ` ${refs.colorById[cid]?.name ?? ''}` : ''}` : (item || 'Other items'));
    const unitOf = pid => ((refs.unitById[refs.items[`p:${pid}`]?.stockUnitId]?.symbol ?? '').toUpperCase() === 'SQM' ? 'm²' : 'pcs');
    const branchName = id => branches.find(b => b.id === id)?.name ?? 'Branch';
    const groupKey = x => (by === 'product' ? (x.line.product_id ? keyOf(x.line) : `other|${x.line.item_name ?? ''}`)
      : by === 'customer' ? (x.delivery.sale.customer_id || `walk|${(x.delivery.sale.walk_in_name || 'Walk-in').trim().toLowerCase()}`)
      : x.delivery.sale.branch_id);
    const rows = {};
    for (const x of lines) {
      const k = groupKey(x);
      const r = (rows[k] ||= {
        key: k, sales: 0, cost: 0, est: 0, noCost: 0, qty: 0, rejects: 0, rejectQty: 0,
        name: by === 'product' ? nameOf(x.line.product_id, x.line.color_id, x.line.item_name)
          : by === 'customer' ? (x.delivery.sale.customer?.name ?? x.delivery.sale.walk_in_name ?? 'Walk-in') : branchName(x.delivery.sale.branch_id),
        unit: by === 'product' && x.line.product_id ? unitOf(x.line.product_id) : '',
      });
      r.sales += exVat(x);
      if (x.cost == null) r.noCost += 1; else r.cost += Number(x.cost);
      r.est += Number(x.estimated_cost || 0);
      r.qty += Number(x.quantity || 0);
    }
    // rejects made in the period at their full cost — by product, or by branch
    if (by !== 'customer') {
      const g = {};
      for (const o of outputs) (g[by === 'product' ? keyOf(o) : o.branch_id] ||= []).push(o);
      for (const [k, os] of Object.entries(g)) {
        const t = totals(os);
        const rq = Math.max(t.qtyReleased - t.qtyPassed, 0);
        if (!(rq > 0) || !(t.qtyCast > 0)) continue;
        const r = (rows[k] ||= { key: k, sales: 0, cost: 0, est: 0, noCost: 0, qty: 0, rejects: 0, rejectQty: 0,
          name: by === 'product' ? nameOf(os[0].product_id, os[0].color_id) : branchName(k), unit: by === 'product' ? unitOf(os[0].product_id) : '' });
        r.rejects += rq * (t.total / t.qtyCast);
        r.rejectQty += rq;
      }
    }
    const list = Object.values(rows).map(r => ({ ...r, margin: r.sales - r.cost, profit: r.sales - r.cost - r.rejects }))
      .sort((a, b) => b.profit - a.profit);
    const sum = list.reduce((s, r) => ({ sales: s.sales + r.sales, cost: s.cost + r.cost, rejects: s.rejects + r.rejects, est: s.est + r.est, noCost: s.noCost + r.noCost }),
      { sales: 0, cost: 0, rejects: 0, est: 0, noCost: 0 });
    return { list, sum };
  }, [data, by]);

  const withRejects = by !== 'customer';
  return (
    <>
      <PeriodBar value={period} onChange={setPeriod} today={today} />
      <div style={{ margin: '4px 0 8px' }}>
        <PageTabs nested tabs={[['product', 'By product'], ['customer', 'By customer'], ['branch', 'By branch']]} value={by} onChange={setBy} />
      </div>
      {error ? <div className="card"><ErrorState message={error} onRetry={load} /></div>
      : !view ? <div className="card"><span className="skeleton" /></div>
      : <>
        <div className="mm-stats">
          <div className="mm-stat"><span className="pl-label">Gross margin</span><strong className="mm-money">{money(view.sum.sales - view.sum.cost)}</strong>
            <span className="pl-help">{pct(view.sum.sales - view.sum.cost, view.sum.sales)} of {money(view.sum.sales)} sales</span></div>
          <div className="mm-stat"><span className="pl-label">Rejects</span><strong className={view.sum.rejects > 0.5 ? 'text-error' : ''}>{money(view.sum.rejects)}</strong>
            <span className="pl-help">at full cost</span></div>
          <div className="mm-stat"><span className="pl-label">After rejects</span><strong className="mm-money">{money(view.sum.sales - view.sum.cost - view.sum.rejects)}</strong>
            <span className="pl-help">before running costs (Profit &amp; loss)</span></div>
        </div>
        {view.list.length === 0 ? <div className="card"><EmptyState icon={PieChart} title="Nothing delivered in this period" description="Profit is counted on the goods delivered." /></div> : (
          <div className="card"><div className="table-container">
            <table className="rd-table pb-table">
              <thead><tr>
                <th>{by === 'product' ? 'Product' : by === 'customer' ? 'Customer' : 'Branch'}</th>
                {by === 'product' && <th className="num">Delivered</th>}
                <th className="num">Sales (TZS)</th><th className="num" title="The full production cost of what was delivered: materials, labour, electricity, overheads">Cost (TZS)</th>
                <th className="num">Gross margin (TZS)</th><th className="num">%</th>
                {withRejects && <><th className="num" title="Pieces that failed quality in the period, at their full cost">Rejects (TZS)</th><th className="num">Profit (TZS)</th></>}
              </tr></thead>
              <tbody>
                {view.list.map(r => (
                  <tr key={r.key}>
                    <td><strong>{r.name}</strong>{r.noCost > 0 && <div className="pl-help" title="Delivered from stock with no production cost recorded">{r.noCost} line{r.noCost === 1 ? '' : 's'} without a cost</div>}</td>
                    {by === 'product' && <td className="num">{r.qty ? <>{qtyText(Math.round(r.qty * 100) / 100)} <span className="pl-help">{r.unit}</span></> : '—'}</td>}
                    <td className="num">{amt(r.sales)}</td>
                    <td className="num">{amt(r.cost)}{r.est > 0.5 && <div className="pl-help co-est-txt" title="Part of the cost estimated at the price (stock with no production cost)">{amt(r.est)} est.</div>}</td>
                    <td className={`num ${r.margin < 0 ? 'text-error' : ''}`}><strong>{amt(r.margin)}</strong></td>
                    <td className="num pl-help">{pct(r.margin, r.sales)}</td>
                    {withRejects && <>
                      <td className={`num ${r.rejects > 0.5 ? 'text-error' : 'text-muted'}`}>{r.rejects > 0.5 ? <>{amt(r.rejects)}{by === 'product' && <div className="pl-help">{qtyText(Math.round(r.rejectQty * 100) / 100)} {r.unit}</div>}</> : '—'}</td>
                      <td className={`num ${r.profit < 0 ? 'text-error' : ''}`}><strong>{amt(r.profit)}</strong></td>
                    </>}
                  </tr>
                ))}
              </tbody>
              <tfoot><tr>
                <td><strong>Total</strong></td>{by === 'product' && <td />}
                <td className="num"><strong>{money(view.sum.sales)}</strong></td><td className="num"><strong>{money(view.sum.cost)}</strong></td>
                <td className="num"><strong>{money(view.sum.sales - view.sum.cost)}</strong></td><td className="num pl-help">{pct(view.sum.sales - view.sum.cost, view.sum.sales)}</td>
                {withRejects && <><td className="num"><strong>{money(view.sum.rejects)}</strong></td><td className="num"><strong>{money(view.sum.sales - view.sum.cost - view.sum.rejects)}</strong></td></>}
              </tr></tfoot>
            </table>
          </div></div>
        )}
      </>}
    </>
  );
}
