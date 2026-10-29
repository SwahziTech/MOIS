import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { Download } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatAmount, formatMoney, formatMoneyShort } from '../lib/format';
import { orgToday } from '../lib/inventory';
import { dbErrorMessage } from '../lib/masterData';
import { exportTable } from '../lib/reports';
import PageShell from '../components/PageShell';
import { PageTabs } from '../components/ListControls';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import NumberInput from '../components/NumberInput';

const KIND = { sale: 'Sale payment', topup: 'Weekly cash from directors', purchase: 'Supplier payment', wages: 'Wages', statutory: 'PAYE · NSSF · WCF · SDL', expense: 'Expense' };
const ACCOUNT_KIND = { cash: 'Cash', bank: 'Bank', mobile_money: 'Mobile money' };
const NO_ACCOUNT = '-';
const monthName = m => new Date(`${m}-01T00:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });
const prevMonth = m => { const d = new Date(`${m}-01T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() - 1); return d.toISOString().slice(0, 7); };
const amt = v => formatAmount(Math.round(Number(v || 0)));
// last month's first and last day
const lastMonth = today => { const m = prevMonth(today.slice(0, 7)); const end = new Date(`${today.slice(0, 7)}-01T00:00:00Z`); end.setUTCDate(0); return [`${m}-01`, end.toISOString().slice(0, 10)]; };

/*
 * Cash flow (CRM & Cash flow part 1, migration 094, 2026-10-30): money in and
 * out by account, a month's statement and a forecast, at the chosen branch.
 *   Accounts  — each account's balance now (opening balance + in − out after
 *               its opening date), and every movement, newest first, with the
 *               running balance when one account is chosen;
 *   Statement — a month: money in and out by type, the net change;
 *   Forecast  — cash now, what's expected in (customers owe, weekly cash
 *               approved) and out (suppliers, PAYE/NSSF…, pay sheets), the
 *               cash left after.
 * Movements without an account (older expenses, weekly cash) show as
 * "Account not set". Opening balances are set under ⚙.
 */
export default function CashFlow() {
  const { organization, canAt } = useAuth();
  const { branchId, branchName, inBranch } = useBranch();
  const today = orgToday(organization?.timezone);
  const cur = organization?.currency_code;
  const money = v => formatMoney(Math.round(Number(v || 0)), cur);
  const short = v => formatMoneyShort(v, cur);
  const [tab, setTab] = useState('accounts');
  const [accounts, setAccounts] = useState(null);
  const [moves, setMoves] = useState(null);
  const [error, setError] = useState('');
  const [account, setAccount] = useState('');
  const [range, setRange] = useState(() => [`${today.slice(0, 7)}-01`, today]);
  const [month, setMonth] = useState(today.slice(0, 7));
  const [settings, setSettings] = useState(false);

  async function load() {
    setError('');
    const [a, m] = await Promise.all([
      supabase.from('payment_accounts').select('*').order('display_order'),
      supabase.from('cash_movements').select('*').order('day', { ascending: false }).order('created_at', { ascending: false }),
    ]);
    if (a.error || m.error) { console.error(a.error || m.error); setError("We couldn't load cash flow."); setAccounts([]); setMoves([]); return; }
    setAccounts(a.data || []); setMoves(m.data || []);
  }
  useEffect(() => { load(); }, []);

  const accs = useMemo(() => (accounts || []).filter(a => inBranch(a.branch_id)), [accounts, inBranch]);
  const mv = useMemo(() => (moves || []).filter(x => inBranch(x.branch_id)), [moves, inBranch]);
  // an account's balance on a day: opening balance + movements after its opening date up to that day
  const balanceOf = (a, upTo = today) => Number(a.opening_balance || 0) + mv
    .filter(x => x.account_id === a.id && (!a.opening_date || x.day >= a.opening_date) && x.day <= upTo)
    .reduce((t, x) => t + (x.direction === 'in' ? 1 : -1) * Number(x.amount), 0);
  const unassigned = mv.filter(x => !x.account_id || !accs.some(a => a.id === x.account_id));
  const unassignedNet = unassigned.reduce((t, x) => t + (x.direction === 'in' ? 1 : -1) * Number(x.amount), 0);
  const cashNow = accs.filter(a => a.status === 'active').reduce((t, a) => t + balanceOf(a), 0);
  const canSet = !!branchId && canAt('sales.discount', branchId);

  return (
    <PageShell title="Cash flow" subtitle="Finance" onSettings={() => setSettings(true)}
      description={`Money in and out by account — ${branchId ? branchName : 'all branches'}.`}>
      <PageTabs tabs={[['accounts', 'Accounts'], ['statement', 'Statement'], ['forecast', 'Forecast']]} value={tab} onChange={setTab} />
      {error ? <div className="card"><ErrorState message={error} onRetry={load} /></div>
      : accounts === null ? <div className="card"><span className="skeleton" /></div>
      : tab === 'accounts' ? (
        <AccountsTab {...{ accs, mv, balanceOf, unassigned, unassignedNet, account, setAccount, range, setRange, today, money, short, cashNow, branchId }} />
      ) : tab === 'statement' ? (
        <StatementTab {...{ mv, month, setMonth, today, money, short }} />
      ) : (
        <ForecastTab {...{ cashNow, inBranch, money, short, today }} />
      )}
      {settings && <OpeningBalances accounts={accs} canSet={canSet} today={today} onClose={() => setSettings(false)} onSaved={load} />}
    </PageShell>
  );
}

function AccountsTab({ accs, mv, balanceOf, unassigned, unassignedNet, account, setAccount, range, setRange, today, money, short, cashNow, branchId }) {
  const [from, to] = range;
  const shown = mv.filter(x => x.day >= from && x.day <= to && (!account || (account === NO_ACCOUNT ? !x.account_id || !accs.some(a => a.id === x.account_id) : x.account_id === account)));
  const sel = accs.find(a => a.id === account);
  // running balance (one account): the balance after each movement, newest first
  const running = useMemo(() => {
    if (!sel) return null;
    const asc = mv.filter(x => x.account_id === sel.id && (!sel.opening_date || x.day >= sel.opening_date)).slice().reverse();
    let b = Number(sel.opening_balance || 0); const out = {};
    for (const x of asc) { b += (x.direction === 'in' ? 1 : -1) * Number(x.amount); out[`${x.kind}|${x.doc_id}|${x.day}|${x.created_at}`] = b; }
    return out;
  }, [sel, mv]);
  const inSum = shown.filter(x => x.direction === 'in').reduce((t, x) => t + Number(x.amount), 0);
  const outSum = shown.filter(x => x.direction === 'out').reduce((t, x) => t + Number(x.amount), 0);
  const nameOf = id => accs.find(a => a.id === id)?.name ?? 'Account not set';
  const xl = () => exportTable(`Cash movements ${from} to ${to}`, `Cash movements — ${sel?.name ?? (account === NO_ACCOUNT ? 'account not set' : 'all accounts')}, ${from} to ${to}`,
    ['Date', 'Account', 'What', 'Reference', 'In', 'Out'], shown.map(x => [x.day, nameOf(x.account_id), KIND[x.kind], x.ref, x.direction === 'in' ? Number(x.amount) : '', x.direction === 'out' ? Number(x.amount) : '']),
    ['Total', '', '', '', inSum, outSum]);

  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Cash now</span><strong>{short(cashNow)}</strong><span className="pl-help">{accs.filter(a => a.status === 'active').length} accounts</span></div>
        <div className="mm-stat"><span className="pl-label">In · {from === `${today.slice(0, 7)}-01` && to === today ? 'this month' : 'the range'}</span><strong>{short(inSum)}</strong><span className="pl-help">{shown.filter(x => x.direction === 'in').length} payments</span></div>
        <div className="mm-stat"><span className="pl-label">Out</span><strong>{short(outSum)}</strong><span className="pl-help">net {short(inSum - outSum)}</span></div>
      </div>
      <div className="cf-accounts">
        {accs.map(a => (
          <button key={a.id} type="button" className={`cf-acc${account === a.id ? ' is-on' : ''}${a.status !== 'active' ? ' is-inactive' : ''}`} onClick={() => setAccount(account === a.id ? '' : a.id)}>
            <span className="pl-label">{a.name}</span><strong>{money(balanceOf(a))}</strong>
            <span className="pl-help">{ACCOUNT_KIND[a.kind]}{a.opening_date ? ` · from ${a.opening_date}` : ' · opening balance not set'}</span>
          </button>
        ))}
        {unassigned.length > 0 && (
          <button type="button" className={`cf-acc is-unset${account === NO_ACCOUNT ? ' is-on' : ''}`} onClick={() => setAccount(account === NO_ACCOUNT ? '' : NO_ACCOUNT)}
            title="Money recorded without an account — older expenses and weekly cash from the directors. New expenses name their account.">
            <span className="pl-label">Account not set</span><strong>{money(unassignedNet)}</strong><span className="pl-help">{unassigned.length} movements</span>
          </button>
        )}
        {accs.length === 0 && <p className="pl-help">No payment accounts{branchId ? ' at this branch' : ''} — they're added under Sales ⚙.</p>}
      </div>
      <div className="flex items-center gap-8" style={{ margin: '12px 0', flexWrap: 'wrap' }}>
        <input type="date" className="form-input" style={{ width: 160 }} aria-label="From" max={to} value={from} onChange={e => setRange([e.target.value || from, to])} />
        <span className="pl-help">to</span>
        <input type="date" className="form-input" style={{ width: 160 }} aria-label="To" min={from} max={today} value={to} onChange={e => setRange([from, e.target.value || to])} />
        <button type="button" className="btn btn-ghost btn-sm" onClick={() => setRange([`${today.slice(0, 7)}-01`, today])}>This month</button>
        <button type="button" className="btn btn-ghost btn-sm" onClick={() => setRange(lastMonth(today))}>Last month</button>
        <span className="pl-help">{sel ? `${sel.name} — click it again to see all` : 'Click an account to see only its movements'}</span>
        <button type="button" className="btn btn-outline btn-sm" style={{ marginLeft: 'auto' }} disabled={!shown.length} onClick={xl}><Download size={14} /> Excel</button>
      </div>
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>Date</th><th>Account</th><th>What</th><th>Reference</th><th className="num">In (TZS)</th><th className="num">Out (TZS)</th>{running && <th className="num">Balance (TZS)</th>}</tr></thead>
          <tbody>
            {shown.length === 0 ? <tr><td colSpan={running ? 7 : 6} className="text-muted">No money in or out in this range.</td></tr>
            : shown.map((x, i) => (
              <tr key={i}>
                <td>{x.day}</td><td>{nameOf(x.account_id)}</td><td>{KIND[x.kind]}</td><td>{x.ref}</td>
                <td className="num">{x.direction === 'in' ? amt(x.amount) : ''}</td>
                <td className="num">{x.direction === 'out' ? amt(x.amount) : ''}</td>
                {running && <td className="num">{amt(running[`${x.kind}|${x.doc_id}|${x.day}|${x.created_at}`])}</td>}
              </tr>
            ))}
          </tbody>
          {shown.length > 0 && <tfoot><tr><td colSpan={4}><strong>Total</strong></td><td className="num"><strong>{amt(inSum)}</strong></td><td className="num"><strong>{amt(outSum)}</strong></td>{running && <td />}</tr></tfoot>}
        </table>
      </div></div>
    </>
  );
}

function StatementTab({ mv, month, setMonth, today, money, short }) {
  const rows = mv.filter(x => x.day.startsWith(month));
  const by = k => rows.filter(x => x.kind === k).reduce((t, x) => t + Number(x.amount), 0);
  const ins = ['sale', 'topup'].map(k => [k, by(k)]);
  const outs = ['purchase', 'wages', 'statutory', 'expense'].map(k => [k, by(k)]);
  const tIn = ins.reduce((t, [, v]) => t + v, 0); const tOut = outs.reduce((t, [, v]) => t + v, 0);
  const months = Array.from({ length: 12 }, (_, i) => { let m = today.slice(0, 7); for (let k = 0; k < i; k++) m = prevMonth(m); return m; });
  const xl = () => exportTable(`Cash flow ${month}`, `Cash flow statement — ${monthName(month)}`, ['', 'Amount'],
    [['MONEY IN', ''], ...ins.map(([k, v]) => [KIND[k], Math.round(v)]), ['Total in', Math.round(tIn)], ['MONEY OUT', ''], ...outs.map(([k, v]) => [KIND[k], Math.round(v)]), ['Total out', Math.round(tOut)]],
    ['Net change', Math.round(tIn - tOut)]);
  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Money in</span><strong>{short(tIn)}</strong><span className="pl-help">{monthName(month)}</span></div>
        <div className="mm-stat"><span className="pl-label">Money out</span><strong>{short(tOut)}</strong><span className="pl-help">{rows.filter(x => x.direction === 'out').length} payments</span></div>
        <div className="mm-stat"><span className="pl-label">Net change</span><strong className={tIn - tOut < 0 ? 'text-warning' : ''}>{short(tIn - tOut)}</strong><span className="pl-help">{tIn - tOut < 0 ? 'more went out than came in' : 'more came in than went out'}</span></div>
      </div>
      <div className="flex items-center gap-8" style={{ margin: '12px 0' }}>
        <select className="form-input" style={{ maxWidth: 200 }} aria-label="Month" value={month} onChange={e => setMonth(e.target.value)}>
          {months.map(m => <option key={m} value={m}>{monthName(m)}</option>)}
        </select>
        <button type="button" className="btn btn-outline btn-sm" style={{ marginLeft: 'auto' }} onClick={xl}><Download size={14} /> Excel</button>
      </div>
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>{monthName(month)}</th><th className="num">Amount (TZS)</th></tr></thead>
          <tbody>
            <tr><td className="pl-label">Money in</td><td /></tr>
            {ins.map(([k, v]) => <tr key={k}><td style={{ paddingLeft: 24 }}>{KIND[k]}</td><td className="num">{amt(v)}</td></tr>)}
            <tr><td><strong>Total in</strong></td><td className="num"><strong>{amt(tIn)}</strong></td></tr>
            <tr><td className="pl-label">Money out</td><td /></tr>
            {outs.map(([k, v]) => <tr key={k}><td style={{ paddingLeft: 24 }}>{KIND[k]}</td><td className="num">{v ? `− ${amt(v)}` : '0'}</td></tr>)}
            <tr><td><strong>Total out</strong></td><td className="num"><strong>− {amt(tOut)}</strong></td></tr>
          </tbody>
          <tfoot><tr><td><strong>Net change</strong></td><td className="num"><strong>{money(tIn - tOut)}</strong></td></tr></tfoot>
        </table>
      </div></div>
      <p className="pl-help" style={{ marginTop: 8 }}>Money as it moved (payments made and received), not sales or bills — those are in Reports.</p>
    </>
  );
}

function ForecastTab({ cashNow, inBranch, money, short, today }) {
  const [d, setD] = useState(null);
  useEffect(() => {
    (async () => {
      const [sb, sp, ex, ps, cr, od] = await Promise.all([
        supabase.from('sale_balances').select('branch_id, stage, balance').in('stage', ['order', 'invoice']),
        supabase.from('supplier_balances').select('branch_id, owed'),
        supabase.from('expenses').select('branch_id, amount, amount_paid, supplier_id, status, category:expense_categories(name)').eq('status', 'recorded'),
        supabase.from('pay_sheets').select('branch_id, status, total, period_end').in('status', ['draft', 'approved']),
        supabase.from('cash_requests').select('branch_id, status, lines:cash_request_lines(amount, approved_amount)').eq('status', 'approved'),
        supabase.from('overdue_sales').select('branch_id, balance'),   // 097: past their due date
      ]);
      const sum = (list, f) => list.reduce((t, x) => t + Number(f(x) || 0), 0);
      const own = l => (l.data || []).filter(x => inBranch(x.branch_id));
      const unpaidNoSupplier = own(ex).filter(x => !x.supplier_id && Number(x.amount) > Number(x.amount_paid));
      setD({
        customers: sum(own(sb).filter(x => Number(x.balance) > 0), x => x.balance),
        overdue: od.error ? null : sum(own(od), x => x.balance),
        topups: sum(own(cr), r => sum(r.lines || [], l => l.approved_amount ?? l.amount)),
        suppliers: sum(own(sp).filter(x => Number(x.owed) > 0), x => x.owed),
        statutory: sum(unpaidNoSupplier.filter(x => /statutory/i.test(x.category?.name || '')), x => Number(x.amount) - Number(x.amount_paid)),
        otherBills: sum(unpaidNoSupplier.filter(x => !/statutory/i.test(x.category?.name || '')), x => Number(x.amount) - Number(x.amount_paid)),
        pay: sum(own(ps), x => x.total),
        sheets: own(ps).length,
      });
    })();
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
  if (!d) return <div className="card"><span className="skeleton" /></div>;
  const tIn = d.customers + d.topups;
  const tOut = d.suppliers + d.statutory + d.otherBills + d.pay;
  const after = cashNow + tIn - tOut;
  const line = (label, v, to, note, sign) => (
    <tr><td style={{ paddingLeft: 24 }}>{to ? <Link to={to} className="link-btn">{label}</Link> : label}{note && <div className="pl-help">{note}</div>}</td>
      <td className="num">{v ? `${sign}${formatAmount(Math.round(v))}` : '0'}</td></tr>
  );
  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Cash now</span><strong>{short(cashNow)}</strong><span className="pl-help">all accounts today</span></div>
        <div className="mm-stat"><span className="pl-label">Coming in · going out</span><strong>{short(tIn)} · {short(tOut)}</strong><span className="pl-help">owed to us · owed by us</span></div>
        <div className="mm-stat"><span className="pl-label">Cash after</span><strong className={after < 0 ? 'text-warning' : ''}>{short(after)}</strong>
          <span className="pl-help" title="Cash now + everything owed to us − everything we owe, if all were settled">{after < 0 ? 'short — plan payments' : 'if everything is settled'}</span></div>
      </div>
      <div className="card" style={{ marginTop: 12 }}><div className="table-container">
        <table>
          <thead><tr><th>As of {today}</th><th className="num">Amount (TZS)</th></tr></thead>
          <tbody>
            <tr><td><strong>Cash now</strong></td><td className="num"><strong>{formatAmount(Math.round(cashNow))}</strong></td></tr>
            <tr><td className="pl-label">Coming in</td><td /></tr>
            {d.overdue == null ? line('Customers owe', d.customers, '/customers', 'orders and invoices not fully paid', '+ ') : <>
              {line('Customers owe — overdue', d.overdue, '/customers', 'past their due date: chase these', '+ ')}
              {line('Customers owe — not yet due', d.customers - d.overdue, '/customers', 'within their payment terms', '+ ')}
            </>}
            {line('Weekly cash approved, not yet paid', d.topups, '/weekly-cash', 'from the directors', '+ ')}
            <tr><td className="pl-label">Going out</td><td /></tr>
            {line('Suppliers owed', d.suppliers, '/purchases', 'purchases and expenses not fully paid', '− ')}
            {line('PAYE · NSSF · WCF · SDL owed', d.statutory, '/staff', 'from paid pay sheets, until remitted', '− ')}
            {line('Other unpaid expenses', d.otherBills, '/purchases', 'without a supplier', '− ')}
            {line('Pay sheets to pay', d.pay, '/staff', `${d.sheets} sheet${d.sheets === 1 ? '' : 's'} not yet paid (net pay)`, '− ')}
          </tbody>
          <tfoot><tr><td><strong>Cash after</strong></td><td className="num"><strong>{money(after)}</strong></td></tr></tfoot>
        </table>
      </div></div>
      <p className="pl-help" style={{ marginTop: 8 }}>What is owed today: sales carry due dates (overdue apart); bills from suppliers don't yet — this shows where cash stands if everything owed were settled.</p>
    </>
  );
}

/* ⚙: where each account starts — its balance on a date (those who manage payment accounts) */
function OpeningBalances({ accounts, canSet, today, onClose, onSaved }) {
  const [f, setF] = useState(() => Object.fromEntries(accounts.map(a => [a.id, { balance: String(Number(a.opening_balance || 0)), date: a.opening_date || '' }])));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function save() {
    setError(''); setBusy(true);
    for (const a of accounts) {
      const v = f[a.id];
      if (Number(v.balance) === Number(a.opening_balance || 0) && (v.date || null) === (a.opening_date || null)) continue;
      const { error: err } = await supabase.from('payment_accounts').update({ opening_balance: Number(v.balance) || 0, opening_date: v.date || null }).eq('id', a.id);
      if (err) { setBusy(false); setError(dbErrorMessage(err)); return; }
    }
    setBusy(false); await onSaved(); onClose();
  }
  return (
    <Modal title="Cash flow settings" onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Close</button>
        {canSet && <button type="button" className="btn btn-primary" disabled={busy} onClick={save}>Save</button>}</>}>
      <div className="modal-form">
        <p className="pl-help">Each account's balance on a date (e.g. counted cash, the bank statement). Money in and out after that date adds up from there. Set by the branch manager or a director.</p>
        <div className="table-container">
          <table>
            <thead><tr><th>Account</th><th className="num">Opening balance (TZS)</th><th>On</th></tr></thead>
            <tbody>
              {accounts.length === 0 ? <tr><td colSpan={3} className="text-muted">No payment accounts — add them under Sales ⚙.</td></tr>
              : accounts.map(a => (
                <tr key={a.id}>
                  <td><strong>{a.name}</strong><div className="pl-help">{ACCOUNT_KIND[a.kind]}</div></td>
                  <td className="num"><NumberInput step="any" className="form-input" style={{ width: 160 }} disabled={!canSet} value={f[a.id].balance} onChange={e => setF(x => ({ ...x, [a.id]: { ...x[a.id], balance: e.target.value } }))} /></td>
                  <td><input type="date" className="form-input" max={today} disabled={!canSet} value={f[a.id].date} onChange={e => setF(x => ({ ...x, [a.id]: { ...x[a.id], date: e.target.value } }))} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </Modal>
  );
}
