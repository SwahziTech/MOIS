import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { Download } from 'lucide-react';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatAmount, formatMoney, formatMoneyShort, dateText } from '../lib/format';
import { orgToday, loadInventoryRefs } from '../lib/inventory';
import { loadProduction, loadSales, loadSpending, loadMaterialUse, loadProfit, loadBranches, exportTable } from '../lib/reports';
import PageShell from '../components/PageShell';
import { PageTabs } from '../components/ListControls';
import ErrorState from '../components/ErrorState';

const addDays = (d, n) => { const x = new Date(`${d}T00:00:00Z`); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
const monthEnd = d => { const x = new Date(`${d.slice(0, 7)}-01T00:00:00Z`); x.setUTCMonth(x.getUTCMonth() + 1); x.setUTCDate(0); return x.toISOString().slice(0, 10); };
const prevMonthStart = d => { const x = new Date(`${d.slice(0, 7)}-01T00:00:00Z`); x.setUTCMonth(x.getUTCMonth() - 1); return x.toISOString().slice(0, 10); };
const mondayOf = d => { const w = new Date(`${d}T00:00:00Z`).getUTCDay(); return addDays(d, -((w + 6) % 7)); };
const n1 = v => (v == null ? '' : new Intl.NumberFormat('en-US', { maximumFractionDigits: 1 }).format(v));
const n2 = v => (v == null ? '' : new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(v));
const amt = v => formatAmount(Math.round(Number(v || 0)));

const TABS = [['production', 'Production'], ['sales', 'Sales'], ['spending', 'Purchases & expenses'], ['materials', 'Materials used'], ['profit', 'Profit'], ['branches', 'Branches']];

/*
 * Reports (1f, PRD 4.15, 2026-10-29): one page, a tab a report, for a date
 * range at the chosen branch (or every branch the viewer sees). Each tab:
 * three summary cards, the range, its table, Excel. Stock, movements and
 * customer/supplier balances already have their own pages — linked here.
 */
export default function Reports() {
  const { organization } = useAuth();
  const { branchId, branchName, inBranch, branches } = useBranch();
  const today = orgToday(organization?.timezone);
  const cur = organization?.currency_code;
  const money = v => formatMoney(Math.round(Number(v || 0)), cur);
  const short = v => formatMoneyShort(v, cur);
  const [tab, setTab] = useState('production');
  const [nested, setNested] = useState('a');
  const [range, setRange] = useState(() => [`${today.slice(0, 7)}-01`, today]);
  const [from, to] = range;
  const [refs, setRefs] = useState(null);
  const [loaded, setLoaded] = useState(null);   // { tab, value }: a tab's data, never shown under another tab
  const [error, setError] = useState('');

  useEffect(() => { loadInventoryRefs().then(setRefs).catch(() => setError("We couldn't load the report.")); }, []);
  async function load() {
    if (!refs) return;
    setError(''); setLoaded(null);
    const args = { from, to, inBranch, refs, branches };
    const forTab = tab; const req = ++reqRef.current;   // only the latest request lands (tab or range changed meanwhile)
    try {
      const fn = { production: loadProduction, sales: loadSales, spending: loadSpending, materials: loadMaterialUse, profit: loadProfit, branches: loadBranches }[forTab];
      const value = await fn(args);
      if (req === reqRef.current) setLoaded({ tab: forTab, value });
    } catch (e) { console.error(e); setError("We couldn't load the report."); }
  }
  const reqRef = useRef(0);
  useEffect(() => { load(); }, [tab, from, to, refs, branchId]); // eslint-disable-line react-hooks/exhaustive-deps
  const data = loaded?.tab === tab ? loaded.value : null;
  useEffect(() => { setNested('a'); }, [tab]);

  const where = branchId ? branchName : 'all branches';
  const title = `${TABS.find(t => t[0] === tab)[1]} — ${where}, ${from} to ${to}`;
  const presets = [
    ['This month', [`${today.slice(0, 7)}-01`, today]],
    ['Last month', [prevMonthStart(today), monthEnd(prevMonthStart(today))]],
    ['This week', [mondayOf(today), today]],
    ['Last 7 days', [addDays(today, -6), today]],
    ['This year', [`${today.slice(0, 4)}-01-01`, today]],
  ];
  const card = (label, figure, note, title2) => (
    <div className="mm-stat"><span className="pl-label">{label}</span><strong>{figure}</strong><span className="pl-help" title={title2}>{note}</span></div>
  );

  // each tab: cards, table head, rows, total row, and the same for Excel
  let cards = null; let head = []; let rows = []; let total = null; let xl = null; let nestedTabs = null; let note = null;
  if (data) {
    if (tab === 'production') {
      const r = data.rows;
      const pcs = r.reduce((t, x) => t + x.pieces, 0); const bags = r.reduce((t, x) => t + x.bags, 0);
      const rel = r.reduce((t, x) => t + x.released, 0); const rej = r.reduce((t, x) => t + x.rejected, 0);
      const cost = r.reduce((t, x) => t + x.cost, 0);
      cards = <>{card('Pieces cast', formatAmount(pcs), `${data.batches} batches · ${r.length} products`)}
        {card('Cement', `${n2(bags)} bags`, `wastani ${bags ? n1((pcs + r.reduce((t, x) => t + x.leftovers, 0)) / bags) : '—'} a bag`)}
        {card('Rejected', formatAmount(rej), rel ? `${n1((rej / rel) * 100)}% of released` : 'nothing released yet', 'Rejected at release, of the pieces released in the range')}</>;
      head = ['Product', 'Batches', 'Cement bags', 'Pieces cast', 'Leftovers', 'Wastani', 'Curing', 'Passed', 'Rejected', 'Reject %', 'Material cost (TZS)', 'A piece (TZS)'];
      rows = r.map(x => [x.name, x.batches, n2(x.bags), formatAmount(x.pieces), x.leftovers ? formatAmount(x.leftovers) : '', n1(x.wastani), x.curing ? formatAmount(x.curing) : '', x.passed ? formatAmount(x.passed) : '', x.rejected ? formatAmount(x.rejected) : '', n1(x.rejectPct), amt(x.cost), n2(x.perPiece)]);
      total = ['Total', data.batches, n2(bags), formatAmount(pcs), '', '', '', formatAmount(r.reduce((t, x) => t + x.passed, 0)), formatAmount(rej), rel ? n1((rej / rel) * 100) : '', money(cost), ''];
      xl = () => exportTable(`Production ${from} to ${to}`, title, head, r.map(x => [x.name, x.batches, x.bags, x.pieces, x.leftovers, x.wastani, x.curing, x.passed, x.rejected, x.rejectPct, Math.round(x.cost), x.perPiece]), ['Total', data.batches, bags, pcs, '', '', '', '', rej, '', Math.round(cost), '']);
      note = 'Material cost only (materials as they left the store); full cost per product is in Costing.';
    } else if (tab === 'sales') {
      cards = <>{card('Sales', short(data.total), `${data.docs} orders & invoices · VAT ${short(data.vat)}`)}
        {card('Received', short(data.received), 'payments in the range')}
        {card('Owed now', short(data.owed), 'all orders & invoices', 'What customers owe today, whatever the date — see Customers › Who owes')}</>;
      nestedTabs = [['a', 'By product'], ['b', 'By customer']];
      if (nested === 'a') {
        head = ['Product', 'Quantity', 'Without VAT (TZS)', 'VAT (TZS)', 'Total (TZS)'];
        rows = data.products.map(x => [x.name, `${n2(x.quantity)} ${x.unit}`, amt(x.amount), amt(x.vat), amt(x.total)]);
        xl = () => exportTable(`Sales by product ${from} to ${to}`, title, head, data.products.map(x => [x.name, x.quantity, Math.round(x.amount), Math.round(x.vat), Math.round(x.total)]), ['Total', '', Math.round(data.amount), Math.round(data.vat), Math.round(data.total)]);
      } else {
        head = ['Customer', 'Orders & invoices', 'Without VAT (TZS)', 'VAT (TZS)', 'Total (TZS)'];
        rows = data.customers.map(x => [x.name, x.docs, amt(x.amount), amt(x.vat), amt(x.total)]);
        xl = () => exportTable(`Sales by customer ${from} to ${to}`, title, head, data.customers.map(x => [x.name, x.docs, Math.round(x.amount), Math.round(x.vat), Math.round(x.total)]), ['Total', data.docs, Math.round(data.amount), Math.round(data.vat), Math.round(data.total)]);
      }
      total = ['Total', nested === 'a' ? '' : data.docs, amt(data.amount), amt(data.vat), money(data.total)];
      note = 'Orders and invoices by their date (invoiced, else ordered); quotations and cancelled ones left out.';
    } else if (tab === 'spending') {
      cards = <>{card('Purchases', short(data.purchases), `${data.suppliers.reduce((t, x) => t + x.count, 0)} purchases`)}
        {card('Expenses', short(data.expenses), `${data.categories.reduce((t, x) => t + x.count, 0)} expenses`)}
        {card('Not paid', short(data.owed), 'of these, still owed')}</>;
      nestedTabs = [['a', 'Purchases by supplier'], ['b', 'Expenses by category']];
      const list = nested === 'a' ? data.suppliers : data.categories;
      head = [nested === 'a' ? 'Supplier' : 'Category', nested === 'a' ? 'Purchases' : 'Expenses', 'Total (TZS)', 'Paid (TZS)', 'Owed (TZS)'];
      rows = list.map(x => [x.name, x.count, amt(x.total), amt(x.paid), x.owed > 0.5 ? amt(x.owed) : '']);
      const tt = f => list.reduce((t, x) => t + x[f], 0);
      total = ['Total', list.reduce((t, x) => t + x.count, 0), money(tt('total')), amt(tt('paid')), amt(tt('owed'))];
      xl = () => exportTable(`${nested === 'a' ? 'Purchases' : 'Expenses'} ${from} to ${to}`, title, head, list.map(x => [x.name, x.count, Math.round(x.total), Math.round(x.paid), Math.round(x.owed)]), ['Total', '', Math.round(tt('total')), Math.round(tt('paid')), Math.round(tt('owed'))]);
    } else if (tab === 'materials') {
      const cost = data.reduce((t, x) => t + x.cost, 0);
      const over = data.filter(x => x.diffPct != null && x.diffPct > 5);
      cards = <>{card('Materials used', short(cost), `${data.length} materials`, 'Their cost as they left the store (first in, first out)')}
        {card('Over the recipe', over.length, over.length ? 'more than 5% above' : 'all within 5%', 'Actual use above recipe × bags by more than 5%')}
        {card('Counted', `${data.filter(x => x.counted > 0).length}`, 'materials counted for real', 'The rest were taken as the recipe says, so recipe and actual are the same')}</>;
      head = ['Material', 'Recipe (standard)', 'Actual', 'Difference', 'Difference %', 'Counted', 'Cost (TZS)'];
      rows = data.map(x => [<span key="n">{x.name}<div className="pl-help">{x.category}</div></span>, `${n2(x.standard)} ${x.unit}`, `${n2(x.actual)} ${x.unit}`, x.diff != null ? `${x.diff > 0 ? '+' : ''}${n2(x.diff)}` : '',
        x.diffPct != null ? <span key="p" className={Math.abs(x.diffPct) > 5 ? 'text-warning' : ''}>{x.diffPct > 0 ? '+' : ''}{n1(x.diffPct)}%</span> : '', x.counted ? n2(x.counted) : '', x.costKnown ? amt(x.cost) : <span key="c">{amt(x.cost)} <span className="pl-help">part</span></span>]);
      total = ['Total', '', '', '', '', '', money(cost)];
      xl = () => exportTable(`Materials used ${from} to ${to}`, title, ['Material', 'Category', 'Unit', 'Recipe', 'Actual', 'Difference', 'Difference %', 'Counted', 'Cost'],
        data.map(x => [x.name, x.category, x.unit, x.standard, x.actual, x.diff, x.diffPct, x.counted, Math.round(x.cost)]), ['Total', '', '', '', '', '', '', '', Math.round(cost)]);
      note = 'Recipe = the recipe × the bags of cement; actual = what left the store. Only counted materials can differ.';
    } else if (tab === 'profit') {
      const pct = data.sales ? (data.margin / data.sales) * 100 : null;
      cards = <>{card('Delivered', short(data.sales), `${data.deliveries} lines · without VAT`)}
        {card('Gross margin', short(data.margin), pct != null ? `${n1(pct)}% of delivered` : '—', 'Delivered value without VAT less the production cost of the stock that left')}
        {card('Profit', short(data.net), 'after other costs', 'Gross margin less expenses not already in product cost and office/running staff pay')}</>;
      head = ['', 'Amount (TZS)'];
      rows = [
        ['Goods delivered or collected (without VAT)', amt(data.sales)],
        [<span key="c">Their production cost<div className="pl-help">materials, electricity, overheads, labour{data.noCost ? ` · ${data.noCost} lines had no cost` : ''}{data.estimated ? ` · ${amt(data.estimated)} estimated` : ''}</div></span>, `− ${amt(data.cost)}`],
        [<strong key="g">Gross margin</strong>, <strong key="gv">{amt(data.margin)}</strong>],
        ...data.expenses.map(x => [<span key={x.name} style={{ paddingLeft: 12 }}>{x.name}</span>, `− ${amt(x.total)}`]),
        ...(data.officePay != null ? [[<span key="o" style={{ paddingLeft: 12 }}>Office & running staff pay (paid sheets)</span>, `− ${amt(data.officePay)}`]] : []),
      ];
      total = ['Profit', money(data.net)];
      xl = () => exportTable(`Profit ${from} to ${to}`, title, ['', 'Amount'], [['Goods delivered (without VAT)', Math.round(data.sales)], ['Production cost', -Math.round(data.cost)], ['Gross margin', Math.round(data.margin)],
        ...data.expenses.map(x => [x.name, -Math.round(x.total)]), ...(data.officePay != null ? [['Office & running staff pay', -Math.round(data.officePay)]] : [])], ['Profit', Math.round(data.net)]);
      note = 'Basic: electricity, production overheads and production staff are already in the production cost, so their expenses are left out here. Cash timing, depreciation and tax are not included.';
    } else if (tab === 'branches') {
      const tt = f => data.reduce((t, x) => t + x[f], 0);
      cards = <>{card('Branches', data.length, `${dateText(from)} to ${dateText(to)}`)}
        {card('Sales', short(tt('sales')), 'orders & invoices')}
        {card('Pieces cast', formatAmount(tt('pieces')), `${n2(tt('bags'))} bags of cement`)}</>;
      head = ['Branch', 'Batches', 'Cement bags', 'Pieces cast', 'Sales (TZS)', 'Purchases (TZS)', 'Expenses (TZS)'];
      rows = data.map(x => [x.name, x.batches, n2(x.bags), formatAmount(x.pieces), amt(x.sales), amt(x.purchases), amt(x.expenses)]);
      total = ['Total', tt('batches'), n2(tt('bags')), formatAmount(tt('pieces')), money(tt('sales')), amt(tt('purchases')), amt(tt('expenses'))];
      xl = () => exportTable(`Branches ${from} to ${to}`, title, head, data.map(x => [x.name, x.batches, x.bags, x.pieces, Math.round(x.sales), Math.round(x.purchases), Math.round(x.expenses)]),
        ['Total', tt('batches'), tt('bags'), tt('pieces'), Math.round(tt('sales')), Math.round(tt('purchases')), Math.round(tt('expenses'))]);
      note = 'Every branch you can see, whichever branch is chosen above.';
    }
  }
  const numCol = i => i > 0;

  return (
    <PageShell title="Reports" subtitle="Reports"
      description={`Production, sales, spending, materials, profit and branches — ${where}.`}>
      <PageTabs tabs={TABS} value={tab} onChange={setTab} />
      {error ? <div className="card"><ErrorState message={error} onRetry={load} /></div> : (
        <>
          <div className="mm-stats">{cards || <>{card('…', '…', '')}{card('…', '…', '')}{card('…', '…', '')}</>}</div>
          <div className="flex items-center gap-8" style={{ margin: '12px 0', flexWrap: 'wrap' }}>
            <input type="date" className="form-input" style={{ width: 160 }} aria-label="From" max={to} value={from} onChange={e => setRange([e.target.value || from, to])} />
            <span className="pl-help">to</span>
            <input type="date" className="form-input" style={{ width: 160 }} aria-label="To" min={from} max={today} value={to} onChange={e => setRange([from, e.target.value || to])} />
            {presets.map(([l, r]) => <button key={l} type="button" className={`btn btn-sm ${r[0] === from && r[1] === to ? 'btn-primary' : 'btn-ghost'}`} onClick={() => setRange(r)}>{l}</button>)}
            <button type="button" className="btn btn-outline btn-sm" style={{ marginLeft: 'auto' }} disabled={!xl} onClick={() => xl?.()}><Download size={14} /> Excel</button>
          </div>
          {nestedTabs && <div style={{ marginBottom: 8 }}><PageTabs nested tabs={nestedTabs} value={nested} onChange={setNested} /></div>}
          <div className="card"><div className="table-container">
            <table>
              <thead><tr>{(head.length ? head : ['']).map((h, i) => <th key={i} className={numCol(i) ? 'num' : ''}>{h}</th>)}</tr></thead>
              <tbody>
                {data === null ? <tr><td colSpan={Math.max(head.length, 1)}><span className="skeleton" /></td></tr>
                : rows.length === 0 ? <tr><td colSpan={Math.max(head.length, 1)} className="text-muted">Nothing in this range.</td></tr>
                : rows.map((r, i) => <tr key={i}>{r.map((c, j) => <td key={j} className={numCol(j) ? 'num' : ''}>{j === 0 && typeof c === 'string' ? <strong>{c}</strong> : c}</td>)}</tr>)}
              </tbody>
              {total && rows.length > 0 && <tfoot><tr>{total.map((c, j) => <td key={j} className={numCol(j) ? 'num' : ''}><strong>{c}</strong></td>)}</tr></tfoot>}
            </table>
          </div></div>
          {note && <p className="pl-help" style={{ marginTop: 8 }}>{note}</p>}
          <p className="pl-help" style={{ marginTop: 8 }}>
            Also: <Link to="/stock" className="link-btn">Stock</Link> (current and as of a date, by branch and warehouse) ·{' '}
            <Link to="/movements" className="link-btn">Movements</Link> · <Link to="/customers" className="link-btn">Customer balances</Link> ·{' '}
            <Link to="/purchases" className="link-btn">Supplier balances</Link> · <Link to="/costing" className="link-btn">Costing</Link> ·{' '}
            <Link to="/daily-report" className="link-btn">Daily report</Link>
          </p>
        </>
      )}
    </PageShell>
  );
}
