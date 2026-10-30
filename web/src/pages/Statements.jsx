import { useEffect, useMemo, useState } from 'react';
import { Download, Printer } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatAmount, formatMoney, formatMoneyShort, dateText, tableDate } from '../lib/format';
import { orgToday } from '../lib/inventory';
import { exportTable, loadProfit } from '../lib/reports';
import { loadOwing, ageByBuyer, AGE_BUCKETS } from '../lib/receivables';
import { loadBalanceSheet, cashTools } from '../lib/statements';
import { useUrlTab } from '../lib/urlTab';
import PageShell from '../components/PageShell';
import { PageTabs } from '../components/ListControls';
import ErrorState from '../components/ErrorState';

const amt = v => formatAmount(Math.round(Number(v || 0)));
const monthName = m => new Date(`${m}-01T00:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });
const prevMonth = m => { const d = new Date(`${m}-01T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() - 1); return d.toISOString().slice(0, 7); };
const monthEnd = m => { const x = new Date(`${m}-01T00:00:00Z`); x.setUTCMonth(x.getUTCMonth() + 1); x.setUTCDate(0); return x.toISOString().slice(0, 10); };
const dayBefore = d => { const x = new Date(`${d}T00:00:00Z`); x.setUTCDate(x.getUTCDate() - 1); return x.toISOString().slice(0, 10); };
const KIND = { sale: 'Sale payment', topup: 'Weekly cash from directors', purchase: 'Supplier payment', wages: 'Wages', statutory: 'PAYE · NSSF · WCF · SDL', expense: 'Expense' };
const openDoc = url => window.open(url, '_blank', 'noopener');

/*
 * Statements (Finance & Accounting, 2026-10-30), at the branch in the sidebar:
 *   Financial              — profit & loss for a month; the balance sheet today (lib/statements);
 *   Accounts               — one account's statement: opening, each movement, running balance, closing;
 *   Customers & suppliers  — who owes us (by age) and whom we owe, each with a printable statement.
 * Read only — everything comes from sales, payments, purchases, pay sheets and stock as recorded.
 */
export default function Statements() {
  const { organization } = useAuth();
  const { branchId, branchName, branches, inBranch } = useBranch();
  const today = orgToday(organization?.timezone);
  const cur = organization?.currency_code;
  const money = v => formatMoney(Math.round(Number(v || 0)), cur);
  const short = v => formatMoneyShort(v, cur);
  const [tab, setTab] = useUrlTab('financial');
  const where = branchId ? branchName : 'all branches';
  const props = { today, money, short, inBranch, branchId, where, branchIds: branchId ? [branchId] : branches.map(b => b.id) };

  return (
    <PageShell title="Statements" subtitle="Finance & Accounting"
      description={`Profit & loss, the balance sheet, account statements and who owes whom — ${where}.`}>
      <PageTabs tabs={[['financial', 'Financial'], ['accounts', 'Accounts'], ['parties', 'Customers & suppliers']]} value={tab} onChange={setTab} />
      {tab === 'accounts' ? <AccountStatement {...props} /> : tab === 'parties' ? <Parties {...props} /> : <Financial {...props} />}
    </PageShell>
  );
}

/* ---------- Financial: profit & loss, balance sheet ---------- */
function Financial(p) {
  const [view, setView] = useState('pl');
  return (
    <>
      <div style={{ marginBottom: 8 }}><PageTabs nested tabs={[['pl', 'Profit & loss'], ['bs', 'Balance sheet']]} value={view} onChange={setView} /></div>
      {view === 'pl' ? <ProfitLoss {...p} /> : <BalanceSheet {...p} />}
    </>
  );
}

function ProfitLoss({ today, money, short, inBranch, branchId, where }) {
  const [month, setMonth] = useState(today.slice(0, 7));
  const [d, setD] = useState(null);
  const [error, setError] = useState('');
  const from = `${month}-01`; const to = month === today.slice(0, 7) ? today : monthEnd(month);
  useEffect(() => {
    let live = true; setD(null); setError('');
    loadProfit({ from, to, inBranch }).then(x => live && setD(x)).catch(e => { console.error(e); if (live) setError("We couldn't work out the profit."); });
    return () => { live = false; };
  }, [month, branchId]); // eslint-disable-line react-hooks/exhaustive-deps
  const months = Array.from({ length: 12 }, (_, i) => { let m = today.slice(0, 7); for (let k = 0; k < i; k++) m = prevMonth(m); return m; });
  const rows = d ? [
    ['Sales delivered (without VAT)', d.sales, 'h'],
    ['Cost of the goods delivered', -d.cost],
    ['Gross margin', d.margin, 't'],
    ...d.expenses.map(e => [e.name, -e.total]),
    ...(d.officePay != null ? [['Pay of staff outside product cost', -d.officePay]] : []),
  ] : [];
  const xl = () => exportTable(`Profit and loss ${month}`, `Profit & loss — ${monthName(month)}, ${where}`, ['', 'Amount'],
    rows.map(([l, v]) => [l, Math.round(v)]), ['Net profit', Math.round(d.net)]);
  return (
    <>
      {d && (
        <div className="mm-stats">
          <div className="mm-stat"><span className="pl-label">Sales</span><strong>{short(d.sales)}</strong><span className="pl-help">{d.deliveries} deliveries, without VAT</span></div>
          <div className="mm-stat"><span className="pl-label">Gross margin</span><strong>{short(d.margin)}</strong><span className="pl-help">{d.sales ? `${Math.round(d.margin / d.sales * 100)}% of sales` : '—'}</span></div>
          <div className="mm-stat"><span className="pl-label">Net profit</span><strong className={d.net < 0 ? 'text-warning' : ''}>{short(d.net)}</strong><span className="pl-help">{monthName(month)}</span></div>
        </div>
      )}
      <div className="flex items-center gap-8" style={{ margin: '12px 0' }}>
        <select className="form-input" style={{ maxWidth: 200 }} aria-label="Month" value={month} onChange={e => setMonth(e.target.value)}>
          {months.map(m => <option key={m} value={m}>{monthName(m)}</option>)}
        </select>
        <button type="button" className="btn btn-outline btn-sm" style={{ marginLeft: 'auto' }} disabled={!d} onClick={xl}><Download size={14} /> Excel</button>
      </div>
      {error ? <div className="card"><ErrorState message={error} /></div> : !d ? <div className="card"><span className="skeleton" /></div> : (
        <div className="card"><div className="table-container">
          <table>
            <thead><tr><th>{monthName(month)}</th><th className="num">Amount (TZS)</th></tr></thead>
            <tbody>
              {rows.map(([l, v, k]) => (
                <tr key={l}><td style={k ? undefined : { paddingLeft: 24 }}>{k === 't' ? <strong>{l}</strong> : l}</td>
                  <td className="num">{k === 't' ? <strong>{amt(v)}</strong> : v < 0 ? `− ${amt(-v)}` : amt(v)}</td></tr>
              ))}
            </tbody>
            <tfoot><tr><td><strong>Net profit</strong></td><td className="num"><strong>{money(d.net)}</strong></td></tr></tfoot>
          </table>
        </div></div>
      )}
      {d?.noCost > 0 && <p className="pl-help" style={{ marginTop: 8 }}>{d.noCost} delivered line{d.noCost === 1 ? ' has' : 's have'} no production cost yet, so the margin is higher than it will be.</p>}
      <p className="pl-help" style={{ marginTop: 4 }}>Sales and cost as goods were delivered; expenses as recorded; wages of production staff are inside the cost of the goods.</p>
    </>
  );
}

function BalanceSheet({ today, money, short, inBranch, branchId, branchIds, where }) {
  const [d, setD] = useState(null);
  const [error, setError] = useState('');
  useEffect(() => {
    let live = true; setD(null); setError('');
    loadBalanceSheet({ branchIds, inBranch, today }).then(x => live && setD(x)).catch(e => { console.error(e); if (live) setError("We couldn't put the balance sheet together."); });
    return () => { live = false; };
  }, [branchId, branchIds.length]); // eslint-disable-line react-hooks/exhaustive-deps
  if (error) return <div className="card"><ErrorState message={error} /></div>;
  if (!d) return <div className="card"><div className="card-body"><span className="skeleton" /> <span className="pl-help">Working out stock at cost…</span></div></div>;
  const xl = () => exportTable(`Balance sheet ${today}`, `Balance sheet — ${today}, ${where}`, ['', 'Amount'],
    [['WHAT THE BUSINESS HOLDS', ''], ...d.assets.map(([l, v]) => [l, Math.round(v)]), ['Total held', Math.round(d.totalAssets)],
      ['WHAT IT OWES', ''], ...d.liabilities.map(([l, v]) => [l, Math.round(v)]), ['Total owed', Math.round(d.totalLiabilities)]],
    ["Owners' share", Math.round(d.equity)]);
  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Holds</span><strong>{short(d.totalAssets)}</strong><span className="pl-help">cash, owed to us, stock</span></div>
        <div className="mm-stat"><span className="pl-label">Owes</span><strong>{short(d.totalLiabilities)}</strong><span className="pl-help">suppliers, pay</span></div>
        <div className="mm-stat"><span className="pl-label">Owners&apos; share</span><strong className={d.equity < 0 ? 'text-warning' : ''}>{short(d.equity)}</strong><span className="pl-help">today, {dateText(today)}</span></div>
      </div>
      <div className="flex items-center gap-8" style={{ margin: '12px 0' }}>
        <span className="pl-help">As of today. Machines, buildings and loans aren&apos;t recorded in MOIS, so they&apos;re not here.</span>
        <button type="button" className="btn btn-outline btn-sm" style={{ marginLeft: 'auto' }} onClick={xl}><Download size={14} /> Excel</button>
      </div>
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>Balance sheet — {dateText(today)}</th><th className="num">Amount (TZS)</th></tr></thead>
          <tbody>
            <tr><td className="pl-label">What the business holds</td><td /></tr>
            {d.assets.map(([l, v]) => <tr key={l}><td style={{ paddingLeft: 24 }}>{l}</td><td className="num">{amt(v)}</td></tr>)}
            <tr><td><strong>Total held</strong></td><td className="num"><strong>{amt(d.totalAssets)}</strong></td></tr>
            <tr><td className="pl-label">What it owes</td><td /></tr>
            {d.liabilities.map(([l, v]) => <tr key={l}><td style={{ paddingLeft: 24 }}>{l}</td><td className="num">{amt(v)}</td></tr>)}
            <tr><td><strong>Total owed</strong></td><td className="num"><strong>{amt(d.totalLiabilities)}</strong></td></tr>
          </tbody>
          <tfoot><tr><td><strong>Owners&apos; share (held − owed)</strong></td><td className="num"><strong>{money(d.equity)}</strong></td></tr></tfoot>
        </table>
      </div></div>
      {d.uncosted > 0 && <p className="pl-help" style={{ marginTop: 8 }}>{d.uncosted} stock item{d.uncosted === 1 ? ' has' : 's have'} some quantity with no cost yet — the stock figures are lower than they will be.</p>}
      {d.accounts === 0 && <p className="pl-help">No payment accounts here yet — cash shows 0. They&apos;re added under Sales ⚙; opening balances under Cash flow ⚙.</p>}
    </>
  );
}

/* ---------- Accounts: one account's statement ---------- */
function AccountStatement({ today, money, short, inBranch, where }) {
  const [accounts, setAccounts] = useState(null);
  const [moves, setMoves] = useState([]);
  const [error, setError] = useState('');
  const [account, setAccount] = useState('');
  const [range, setRange] = useState([`${today.slice(0, 7)}-01`, today]);
  useEffect(() => {
    (async () => {
      const [a, m] = await Promise.all([
        supabase.from('payment_accounts').select('*').order('display_order'),
        supabase.from('cash_movements').select('*').order('day').order('created_at'),
      ]);
      if (a.error || m.error) { setError("We couldn't load the accounts."); setAccounts([]); return; }
      setAccounts(a.data || []); setMoves(m.data || []);
    })();
  }, []);
  const accs = useMemo(() => (accounts || []).filter(a => inBranch(a.branch_id)), [accounts, inBranch]);
  const sel = accs.find(a => a.id === account) ?? accs[0];
  const [from, to] = range;
  const st = useMemo(() => {
    if (!sel) return null;
    const { counted, cashAt } = cashTools([sel], moves.filter(x => x.account_id === sel.id));
    const opening = cashAt(dayBefore(from));
    let b = opening;
    const rows = counted.filter(x => x.day >= from && x.day <= to).map(x => { b += (x.direction === 'in' ? 1 : -1) * Number(x.amount); return { ...x, balance: b }; });
    const tin = rows.filter(x => x.direction === 'in').reduce((t, x) => t + Number(x.amount), 0);
    return { opening, rows, closing: b, tin, tout: rows.reduce((t, x) => t + Number(x.amount), 0) - tin };
  }, [sel, moves, from, to]);
  if (error) return <div className="card"><ErrorState message={error} /></div>;
  if (accounts === null) return <div className="card"><span className="skeleton" /></div>;
  if (!sel) return <p className="pl-help">No payment accounts at {where} — they&apos;re added under Sales ⚙.</p>;
  const xl = () => exportTable(`Statement ${sel.name} ${from} to ${to}`, `Account statement — ${sel.name}, ${from} to ${to}`, ['Date', 'What', 'Reference', 'In', 'Out', 'Balance'],
    [['', 'Opening balance', '', '', '', Math.round(st.opening)], ...st.rows.map(x => [x.day, KIND[x.kind], x.ref, x.direction === 'in' ? Number(x.amount) : '', x.direction === 'out' ? Number(x.amount) : '', Math.round(x.balance)])],
    ['', 'Closing balance', '', st.tin, st.tout, Math.round(st.closing)]);
  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Opening</span><strong>{short(st.opening)}</strong><span className="pl-help">{dateText(from)}</span></div>
        <div className="mm-stat"><span className="pl-label">In · out</span><strong>{short(st.tin)}</strong><span className="pl-help">out {short(st.tout)}</span></div>
        <div className="mm-stat"><span className="pl-label">Closing</span><strong>{short(st.closing)}</strong><span className="pl-help">{dateText(to)}</span></div>
      </div>
      <div className="flex items-center gap-8" style={{ margin: '12px 0', flexWrap: 'wrap' }}>
        <select className="form-input" style={{ maxWidth: 220 }} aria-label="Account" value={sel.id} onChange={e => setAccount(e.target.value)}>
          {accs.map(a => <option key={a.id} value={a.id}>{a.name}{a.status !== 'active' ? ' (inactive)' : ''}</option>)}
        </select>
        <input type="date" className="form-input" style={{ width: 160 }} aria-label="From" max={to} value={from} onChange={e => setRange([e.target.value || from, to])} />
        <span className="pl-help">to</span>
        <input type="date" className="form-input" style={{ width: 160 }} aria-label="To" min={from} max={today} value={to} onChange={e => setRange([from, e.target.value || to])} />
        <button type="button" className="btn btn-outline btn-sm" style={{ marginLeft: 'auto' }} onClick={xl}><Download size={14} /> Excel</button>
      </div>
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>Date</th><th>What</th><th>Reference</th><th className="num">In (TZS)</th><th className="num">Out (TZS)</th><th className="num">Balance (TZS)</th></tr></thead>
          <tbody>
            <tr><td /><td><strong>Opening balance</strong></td><td /><td /><td /><td className="num"><strong>{amt(st.opening)}</strong></td></tr>
            {st.rows.slice().reverse().map((x, i) => (
              <tr key={i}><td>{tableDate(x.day)}</td><td>{KIND[x.kind]}</td><td>{x.ref}</td>
                <td className="num">{x.direction === 'in' ? amt(x.amount) : ''}</td><td className="num">{x.direction === 'out' ? amt(x.amount) : ''}</td><td className="num">{amt(x.balance)}</td></tr>
            ))}
          </tbody>
          <tfoot><tr><td /><td><strong>Closing balance</strong></td><td /><td className="num"><strong>{amt(st.tin)}</strong></td><td className="num"><strong>{amt(st.tout)}</strong></td><td className="num"><strong>{money(st.closing)}</strong></td></tr></tfoot>
        </table>
      </div></div>
      <p className="pl-help" style={{ marginTop: 8 }}>{sel.opening_date ? `Counted from the opening balance on ${dateText(sel.opening_date)}.` : 'No opening balance set — set it under Cash flow ⚙.'} Newest first.</p>
    </>
  );
}

/* ---------- Customers & suppliers ---------- */
function Parties({ today, money, inBranch, branchId }) {
  const [view, setView] = useState('customers');
  const [d, setD] = useState(null);
  const [error, setError] = useState('');
  useEffect(() => {
    let live = true;
    (async () => {
      try {
        const [sales, cu, sb, su] = await Promise.all([
          loadOwing(), supabase.from('customers').select('id, name, phone'),
          supabase.from('supplier_balances').select('branch_id, supplier_id, bills, billed, paid, owed, owed_since'),
          supabase.from('suppliers').select('id, name, phone'),
        ]);
        if (live) setD({ sales, customers: cu.data || [], balances: sb.error ? [] : sb.data || [], suppliers: su.data || [] });
      } catch (e) { console.error(e); if (live) setError("We couldn't load who owes whom."); }
    })();
    return () => { live = false; };
  }, []);
  const owing = useMemo(() => (d ? ageByBuyer(d.sales.filter(s => inBranch(s.branch_id)), d.customers, today).filter(b => b.owed > 0).sort((a, b) => b.owed - a.owed) : []), [d, inBranch, today, branchId]); // eslint-disable-line react-hooks/exhaustive-deps
  const owe = useMemo(() => {
    if (!d) return [];
    const m = {};
    for (const r of d.balances.filter(x => inBranch(x.branch_id))) {
      const s = (m[r.supplier_id] ??= { id: r.supplier_id, name: d.suppliers.find(x => x.id === r.supplier_id)?.name ?? '—', bills: 0, billed: 0, paid: 0, owed: 0, since: null });
      s.bills += Number(r.bills); s.billed += Number(r.billed); s.paid += Number(r.paid); s.owed += Number(r.owed);
      if (r.owed_since && (!s.since || r.owed_since < s.since)) s.since = r.owed_since;
    }
    return Object.values(m).filter(s => s.owed > 0.004).sort((a, b) => b.owed - a.owed);
  }, [d, inBranch, branchId]); // eslint-disable-line react-hooks/exhaustive-deps
  if (error) return <div className="card"><ErrorState message={error} /></div>;
  if (!d) return <div className="card"><span className="skeleton" /></div>;
  const tot = (rows, f) => rows.reduce((t, x) => t + f(x), 0);
  const yearStart = `${today.slice(0, 4)}-01-01`;
  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Customers owe us</span><strong>{money(tot(owing, b => b.owed))}</strong><span className="pl-help">{owing.length} buyers</span></div>
        <div className="mm-stat"><span className="pl-label">Over 90 days</span><strong>{money(tot(owing, b => b.buckets[3]))}</strong><span className="pl-help">the oldest debts</span></div>
        <div className="mm-stat"><span className="pl-label">We owe suppliers</span><strong>{money(tot(owe, s => s.owed))}</strong><span className="pl-help">{owe.length} suppliers</span></div>
      </div>
      <div style={{ marginBottom: 8 }}><PageTabs nested tabs={[['customers', `Customers (${owing.length})`], ['suppliers', `Suppliers (${owe.length})`]]} value={view} onChange={setView} /></div>
      <div className="card"><div className="table-container">
        {view === 'customers' ? (
          <table>
            <thead><tr><th>Customer</th>{AGE_BUCKETS.map(([, , l]) => <th key={l} className="num">{l} (TZS)</th>)}<th className="num">Owes (TZS)</th><th>Owed since</th><th aria-label="Statement" /></tr></thead>
            <tbody>
              {owing.length === 0 ? <tr><td colSpan={8} className="text-muted">Nobody owes anything.</td></tr> : owing.map(b => (
                <tr key={b.key}>
                  <td>{b.name}{!b.customer && <span className="text-muted text-xs"> · walk-in</span>}</td>
                  {b.buckets.map((v, i) => <td key={i} className="num">{v ? amt(v) : ''}</td>)}
                  <td className="num"><strong>{amt(b.owed)}</strong></td><td>{b.oldest}</td>
                  <td style={{ textAlign: 'right' }}>{b.customer && <button type="button" className="btn btn-ghost btn-sm" onClick={() => openDoc(`/print/statement/${b.customer.id}?from=${yearStart}&to=${today}`)}><Printer size={13} /> Statement</button>}</td>
                </tr>
              ))}
            </tbody>
            {owing.length > 0 && <tfoot><tr><td><strong>Total</strong></td>{AGE_BUCKETS.map((_, i) => <td key={i} className="num"><strong>{amt(tot(owing, b => b.buckets[i]))}</strong></td>)}<td className="num"><strong>{money(tot(owing, b => b.owed))}</strong></td><td colSpan={2} /></tr></tfoot>}
          </table>
        ) : (
          <table>
            <thead><tr><th>Supplier</th><th className="num">Bills</th><th className="num">Billed (TZS)</th><th className="num">Paid (TZS)</th><th className="num">To pay (TZS)</th><th>Owed since</th><th aria-label="Statement" /></tr></thead>
            <tbody>
              {owe.length === 0 ? <tr><td colSpan={7} className="text-muted">Nothing to pay suppliers.</td></tr> : owe.map(s => (
                <tr key={s.id}>
                  <td>{s.name}</td><td className="num">{s.bills}</td><td className="num">{amt(s.billed)}</td><td className="num">{amt(s.paid)}</td>
                  <td className="num"><strong>{amt(s.owed)}</strong></td><td>{tableDate(s.since) ?? ''}</td>
                  <td style={{ textAlign: 'right' }}><button type="button" className="btn btn-ghost btn-sm" onClick={() => openDoc(`/print/supplier-statement/${s.id}?from=${yearStart}&to=${today}`)}><Printer size={13} /> Statement</button></td>
                </tr>
              ))}
            </tbody>
            {owe.length > 0 && <tfoot><tr><td colSpan={4}><strong>Total</strong></td><td className="num"><strong>{money(tot(owe, s => s.owed))}</strong></td><td colSpan={2} /></tr></tfoot>}
          </table>
        )}
      </div></div>
      <p className="pl-help" style={{ marginTop: 8 }}>Each statement covers 1 January this year to today.</p>
    </>
  );
}
