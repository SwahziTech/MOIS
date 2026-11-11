import { useEffect, useMemo, useState } from 'react';
import { shortRange } from '../../lib/periods';
import { useSessionPeriod } from '../../lib/sessionPeriod';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { ArrowLeft, ChevronLeft, ChevronRight, ExternalLink } from 'lucide-react';
import { useAuth } from '../../hooks/useAuth';
import { useBranch } from '../../hooks/useBranch';
import { formatAmount, formatMoney, formatMoneyShort, dateText, tableDate } from '../../lib/format';
import { loadInventoryRefs, orgToday, qtyText } from '../../lib/inventory';
import { loadDirectorBoard, loadStockBlock, periodsFor, periodSteps, grainOf, cardsFor, productionFor, trendFrom, historyFor, monthShort } from '../../lib/directorBoard';
import ErrorState from '../ErrorState';
import { loadProofs, WaitingSlips } from '../sales/PaymentProofs';
import { PayModal, PaidList } from './DirectorPayments';
import { PayPurchaseModal } from '../purchases/ProcurementPanels';
import { supabase } from '../../lib/supabase';

const fmt = v => formatAmount(Math.round(Number(v || 0)));
const SHOW = 5;
const DROPDOWN = [['Monthly', [['month', 'This month'], ['lastmonth', 'Last month']]],
  ['Quarterly', [['quarter', 'This quarter'], ['lastquarter', 'Last quarter']]], ['Yearly', [['year', 'This year'], ['lastyear', 'Last year']]]];
const LAST_OF = { week: 'lastweek', month: 'lastmonth', quarter: 'lastquarter', year: 'lastyear' };

/* Opens on this month (user, 2026-11-09; was this week). From it › goes to today and ‹ to last week; from today ‹ steps back a day at a
   time to Monday, then last week, then last month. Away from this week a small This week button brings it back.
   The dropdown: this week, its days (today, yesterday … Monday), last week, then months, quarters and years. */
function PeriodBar({ period, periods, periodKey, setPeriodKey, today }) {
  const steps = useMemo(() => periodSteps(today), [today]);
  const at = steps.indexOf(periodKey);
  const earlier = at >= 0 ? steps[at + 1] : LAST_OF[periodKey];
  const later = at >= 0 ? steps[at - 1] : Object.keys(LAST_OF).find(k => LAST_OF[k] === periodKey) ?? 'today';
  const days = periods.filter(p => steps.includes(p.key) && p.key !== 'lastweek' && p.key !== 'lastmonth');
  return (
    <div className="dd-period">
      <button type="button" className="dd-step" aria-label="Earlier" disabled={!earlier} onClick={() => setPeriodKey(earlier)}><ChevronLeft size={18} /></button>
      <button type="button" className="dd-step" aria-label="Later" disabled={!later} onClick={() => setPeriodKey(later)}><ChevronRight size={18} /></button>
      <span><strong>{period.label}</strong> · {shortRange(period.from, period.to, today)}</span>
      {periodKey !== 'month' && <button type="button" className="btn btn-outline btn-sm dd-reset" onClick={() => setPeriodKey('month')}>This month</button>}
      <select className="form-input dd-select" aria-label="Period" value={periodKey} onChange={e => setPeriodKey(e.target.value)}>
        {DROPDOWN.slice(0, 1).map(([group, opts]) => <optgroup key={group} label={group}>{opts.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</optgroup>)}
        <optgroup label="Weekly">
          <option value="week">This week</option>
          {days.map(p => <option key={p.key} value={p.key}>{p.label}</option>)}
          <option value="lastweek">Last week</option>
        </optgroup>
        {DROPDOWN.slice(1).map(([group, opts]) => <optgroup key={group} label={group}>{opts.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</optgroup>)}
      </select>
    </div>
  );
}
const BY_HEAD = { day: 'Date', week: 'Week', month: 'Month' };
const CARD = {
  sales: { title: 'Sales', to: '/sales?tab=book', page: 'Open Sales book' },
  cash: { title: 'Weekly cash', heads: ['Sent (TZS)', 'Spent (TZS)'], to: '/weekly-cash', page: 'Open Weekly cash' },
  purchases: { title: 'Purchases', showItems: true, heads: ['Bought (TZS)', 'Paid (TZS)', 'To pay (TZS)'], to: '/purchases?tab=purchases', page: 'Open Purchases' },
  paid: { title: 'Paid by directors', to: '/cash-flow', page: 'Open Cash flow' },   // 106
};
// a page opened on the dashboard's period
const pageFor = (card, period, extra = '') => `${CARD[card].to}${CARD[card].to.includes('?') ? '&' : '?'}from=${period.from}&to=${period.to}&label=${encodeURIComponent(period.label)}${extra}`;

const Block = ({ title, note, to, children }) => (
  <section className="dd-block">
    <div className="dd-head">{to ? <Link to={to}>{title}</Link> : <span>{title}</span>}{note && <span className="pl-help">{note}</span>}</div>
    {children}
  </section>
);
const Line = ({ to, label, value, warn }) => {
  const inner = <><span>{label}</span><span className={warn ? 'text-warning' : 'text-muted'}>{value}</span></>;
  return to ? <Link to={to} className="dd-line">{inner}</Link> : <div className="dd-line">{inner}</div>;
};

/*
 * The director's dashboard (2026-10-30, draft 2), one screen with no tabs,
 * built for the phone first: what needs them; three cards for today, arrows back through
 * this week's days to last week and last month, or a period from the dropdown; production; stock at cost with
 * what's at risk; money in against money out; branches. A card opens its
 * rows for the chosen period, with the same arrows and dropdown. No profit, by the user's
 * choice. Until receipts are approved in MOIS (stage 2), Sales says so.
 */
export default function DirectorBoard() {
  const { organization, can } = useAuth();
  const [paying, setPaying] = useState(false);   // the Pay window (106)
  const canPay = can('finance.pay');
  const canConfirm = can('sales.confirm_payments');   // the waiting slips show as lines to check
  const { branchId, branchName, branches, inBranch } = useBranch();
  const today = orgToday(organization?.timezone);
  const short = v => formatMoneyShort(v, organization?.currency_code);
  const full = v => formatMoney(Math.round(Number(v || 0)), organization?.currency_code);   // tables: the whole figure, Tsh on totals
  const navigate = useNavigate();
  // a card's report, shown here (2026-11-03); kept in the address (?card=) so Back closes it
  const [params, setParams] = useSearchParams();
  const openCard = CARD[params.get('card')] ? params.get('card') : null;
  const setOpenCard = card => setParams(p => { const n = new URLSearchParams(p); if (card) n.set('card', card); else n.delete('card'); return n; });
  const [refs, setRefs] = useState(null);
  const [d, setD] = useState(null);
  const [stock, setStock] = useState(undefined);   // undefined loading, null failed
  const [error, setError] = useState('');
  const [periodKey, setPeriodKey] = useSessionPeriod('director-view');   // this month first (2026-11-09)
  const periods = useMemo(() => periodsFor(today), [today]);
  const period = periods.find(p => p.key === periodKey);

  async function load() {
    setError(''); setD(null); setStock(undefined);
    try {
      const refs = await loadInventoryRefs();
      setRefs(refs);
      setD(await loadDirectorBoard({ inBranch, today, refs }));
      // stock at cost asks the database item by item, so it follows when ready
      loadStockBlock({ inBranch, branchId, branches, today, refs }).then(setStock).catch(e => { console.error(e); setStock(null); });
    } catch (e) { console.error(e); setError("We couldn't load the dashboard."); }
  }
  useEffect(() => { load(); }, [branchId, branches.length]); // eslint-disable-line react-hooks/exhaustive-deps

  // a card opens its report here; its rows and open icon go to the real page (user, 2026-11-03)
  const open = card => setOpenCard(card);
  if (error) return <div className="card"><ErrorState message={error} onRetry={load} /></div>;
  if (!d) return <div className="dd"><div className="card"><div className="card-body"><span className="skeleton" /></div></div></div>;
  const bar = <PeriodBar period={period} periods={periods} periodKey={periodKey} setPeriodKey={setPeriodKey} today={today} />;
  if (openCard === 'paid') return (
    <div className="dd">
      <ReportHead card="paid" period={period} onBack={() => setOpenCard(null)} go={navigate} />
      <PaidList />
    </div>
  );
  if (openCard && d.money) {
    const back = () => setOpenCard(null);
    if (openCard === 'purchases') return <PurchasesReport data={d.money} inBranch={inBranch} full={full} currency={organization?.currency_code} canPay={canPay} period={period} bar={bar} onBack={back} go={navigate} onPaid={load} />;
    return openCard === 'sales'
      ? <SalesReport data={d.money} refs={refs} inBranch={inBranch} short={short} full={full} period={period} bar={bar} onBack={back} go={navigate} />
      : <CardHistory card={openCard} data={d.money} inBranch={inBranch} today={today} short={short} full={full} period={period} periodKey={periodKey} bar={bar} onBack={back} go={navigate} />;
  }

  const { needs, money, curing } = d;
  const c = money && cardsFor(money, period, inBranch);
  const f = money && productionFor(money, period, inBranch, today);
  const trend = money && trendFrom(money, inBranch, today);
  const top = trend ? Math.max(1, ...trend.flatMap(x => [x.in, x.out])) : 1;
  const change = c && c.salesBefore > 0 ? Math.round((c.sales / c.salesBefore - 1) * 100) : null;
  const unavailable = <p className="pl-help">Couldn&apos;t load this part.</p>;
  const risks = stock ? stock.materials.length + stock.products.length : 0;

  return (
    <div className="dd">
      {needs === null ? null : needs.length > 0 ? (
        <section className="dd-block dd-needs">
          <div className="dd-head"><span>Needs you now</span><span className="pl-help">{needs.reduce((t, x) => t + x.count, 0)} items</span></div>
          <div className="dd-needs-row">
            {needs.filter(x => !(canConfirm && x.key === 'proofs')).map(x => <Link key={x.key} to={x.to} className="dd-need"><strong>{x.count}</strong><span>{x.label}</span></Link>)}
          </div>
          {canConfirm && <WaitingSlips inBranch={inBranch} onChanged={load} />}
        </section>
      ) : <p className="pl-help">Nothing needs you right now.</p>}

      <div className="dd-pay">
        {canPay && <button type="button" className="btn btn-primary btn-sm" onClick={() => setPaying(true)}>Pay</button>}
        <button type="button" className="btn btn-outline btn-sm" onClick={() => open('paid')}>Paid by directors</button>
      </div>
      {paying && <PayModal onClose={() => setPaying(false)} onSaved={() => { setPaying(false); open('paid'); }} />}

      {bar}

      {c ? (
        <div className="dd-cards">
          <button type="button" className="dd-num dd-num-big" onClick={() => open('sales')}>
            <span className="pl-label">Sales</span><strong>{short(c.sales)}</strong>
            <span className="pl-help">{c.salesCount} sale{c.salesCount === 1 ? '' : 's'} made{change == null ? '' : ` · ${change >= 0 ? '+' : ''}${change}% vs ${period.compare.label}`}</span>
          </button>
          <button type="button" className="dd-num" onClick={() => open('cash')}>
            <span className="pl-label">Weekly cash</span><strong>{short(c.sent)} sent</strong>
            <span className="pl-help">{c.hasRequests ? `${short(c.spent)} spent · ${short(c.left)} left` : 'No requests yet'}</span>
          </button>
          <button type="button" className="dd-num" onClick={() => open('purchases')}>
            <span className="pl-label">Purchases</span><strong>{short(c.paid)} paid</strong>
            <span className="pl-help">{short(c.bought)} bought · <span className={c.toPay > 0 ? 'text-warning' : ''}>{short(c.toPay)} to pay</span></span>
          </button>
        </div>
      ) : unavailable}

      <div className="dd-two">
        <Block title="Production" note={period.label.toLowerCase()} to="/production">
          {f ? <>
            <Line label="Cement bags" value={fmt(f.bags)} />
            {curing && <Line label="Pieces curing" value={curing.ready ? `${fmt(curing.curing)} · ${curing.ready} batches ready` : fmt(curing.curing)} />}
            {curing && <Line to="/review" label="Batches outside the yield band" value={curing.flags} warn={curing.flags > 0} />}
            <Line to="/production/ledger" label="Pieces rejected" value={fmt(f.rejected)} warn={f.rejected > 0} />
          </> : unavailable}
        </Block>
        <Block title="Stock" note="at cost, today" to="/stock">
          {stock === undefined ? <span className="skeleton" /> : stock === null ? unavailable : <>
            <Line to="/stock" label="Products" value={short(stock.finished)} />
            <Line to="/stock" label="Materials" value={short(stock.materials_value)} />
            {stock.materials.slice(0, SHOW).map(x => <Line key={x.id} to="/stock" label={x.name} value={`about ${x.days} day${x.days === 1 ? '' : 's'} left`} warn />)}
            {stock.products.slice(0, Math.max(SHOW - stock.materials.length, 0)).map(x => <Line key={x.key} to="/stock" label={x.name} value="below reorder" />)}
            {risks > SHOW && <Link to="/stock" className="pl-help dd-more">{risks - SHOW} more at risk</Link>}
            {stock.uncosted > 0 && <p className="pl-help dd-more">{stock.uncosted} items have no cost yet, so the value is lower than it will be.</p>}
          </>}
        </Block>
      </div>

      {trend && (
        <Block title="Money in vs out" note="last 6 months" to="/cash-flow?tab=monthly">
          <div className="dd-legend"><span><i className="dd-key is-sales" />In</span><span><i className="dd-key is-costs" />Out</span></div>
          <div className="dd-chart" role="img" aria-label={trend.map(x => `${monthShort(x.month)}: in ${fmt(x.in)}, out ${fmt(x.out)}`).join('; ')}>
            {trend.map(x => (
              <div key={x.month} className="dd-col" title={`${monthShort(x.month)}\nIn: ${fmt(x.in)}\nOut: ${fmt(x.out)}`}>
                <div className="dd-bars">
                  <div className="dd-bar is-sales" style={{ height: `${(x.in / top) * 100}%` }} />
                  <div className="dd-bar is-costs" style={{ height: `${(x.out / top) * 100}%` }} />
                </div>
                <span className="pl-help">{monthShort(x.month)}</span>
              </div>
            ))}
          </div>
        </Block>
      )}

      {!branchId && money && branches.length > 1 && (
        <Block title="Branches" note={period.label.toLowerCase()}>
          {branches.map(b => {
            const here = id => id === b.id;
            return <Line key={b.id} label={b.name} value={`${short(cardsFor(money, period, here).sales)} · ${fmt(productionFor(money, period, here, today).bags)} bags`} />;
          })}
        </Block>
      )}
      <p className="pl-help" title="Days left: from the last 14 days' use. Money out: only what's recorded in MOIS.">{branchId ? branchName : 'All branches'} · {dateText(today)}</p>
    </div>
  );
}


const ReportHead = ({ card, period, onBack, go }) => (
  <div className="dd-back">
    <button type="button" className="btn btn-ghost btn-sm" onClick={onBack}><ArrowLeft size={15} /> Dashboard</button>
    <strong>{CARD[card].title}</strong>
    <button type="button" className="btn btn-outline btn-sm" onClick={() => go(pageFor(card, period))}><ExternalLink size={14} /> {CARD[card].page}</button>
  </div>
);

/* The Sales card opened: a short summary, then each product sold — date, product, quantity, amount, account.
   A row (or its icon) opens that sale in the Sales book. */
// each sale's proof of payment (2026-11-04): not posted, waiting for a director, queried, or approved
const PROOF_STATE = { none: ['No proof', 'badge-neutral'], waiting: ['Waiting', 'badge-warning'], queried: ['Queried', 'badge-error'], approved: ['Approved', 'badge-success'], unpaid: ['Not paid', 'badge-neutral'] };
function proofOfSale(x, proofs) {
  if (!x.payments.length) return 'unpaid';
  const st = x.payments.map(p => proofs[p.id]?.status ?? 'none');
  return st.includes('queried') ? 'queried' : st.includes('none') ? 'none' : st.includes('waiting') ? 'waiting' : 'approved';
}
function SalesReport({ data, refs, inBranch, short, full, period, bar, onBack, go }) {
  const [proofs, setProofs] = useState(null);
  const [show, setShow] = useState('');   // a proof state, or '' for all
  useEffect(() => { loadProofs().then(setProofs); }, []);
  const inPeriod = data.sales.filter(x => inBranch(x.branch_id) && x.day >= period.from && x.day <= period.to);
  const stateOf = x => (proofs ? proofOfSale(x, proofs) : null);
  const count = k => inPeriod.filter(x => stateOf(x) === k).length;
  const sales = inPeriod.filter(x => !show || stateOf(x) === show)
    .sort((a, b) => (a.day === b.day ? b.no - a.no : a.day < b.day ? 1 : -1));
  const name = l => (!l.product_id ? `${l.item_name} (other)` : null) ?? [refs?.items[`p:${l.product_id}`]?.name ?? '—', l.color_id ? refs?.colorById[l.color_id]?.name : null].filter(Boolean).join(' ');
  const unit = l => refs?.unitById[refs?.items[`p:${l.product_id}`]?.stockUnitId]?.symbol ?? '';
  const total = sales.reduce((t, x) => t + x.total, 0); const paid = sales.reduce((t, x) => t + x.paid, 0);
  let lastDay = null;
  return (
    <div className="dd">
      <ReportHead card="sales" period={period} onBack={onBack} go={go} />
      {bar}
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Sales</span><strong>{sales.length}</strong><span className="pl-help">{period.label.toLowerCase()}</span></div>
        <div className="mm-stat"><span className="pl-label">Value</span><strong>{short(total)}</strong><span className="pl-help">orders and invoices</span></div>
        <div className="mm-stat"><span className="pl-label">Paid</span><strong>{short(paid)}</strong><span className="pl-help">{total > paid ? `${short(total - paid)} still owed` : 'all paid'}</span></div>
      </div>
      <div className="filter-chips" style={{ margin: '0 0 8px' }} aria-label="Proof of payment">
        {[['', 'All', inPeriod.length], ...['none', 'waiting', 'queried', 'approved'].map(k => [k, PROOF_STATE[k][0], count(k)])].map(([k, l, c]) => (
          <button key={k || 'all'} type="button" className={`filter-chip${show === k ? ' is-on' : ''}`} onClick={() => setShow(k)}>{l} ({c})</button>))}
      </div>
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>Date</th><th>Product</th><th className="num">Qty</th><th className="num">Amount (TZS)</th><th>Account</th><th>Proof</th><th aria-label="Open" /></tr></thead>
          <tbody>
            {sales.length === 0 ? <tr><td colSpan={7} className="text-muted">{show ? 'None here.' : 'No sales in this period.'}</td></tr>
            : sales.flatMap(x => x.lines.map((l, i) => {
              const showDay = x.day !== lastDay; lastDay = x.day;
              const open = () => go(pageFor('sales', period, `&sale=${x.id}`));
              return (
                <tr key={`${x.id}-${i}`} className="dd-report-row" title={`Open sale #${x.no}`} onClick={open}>
                  <td>{showDay ? tableDate(x.day) : ''}</td>
                  <td>{name(l)}</td>
                  <td className="num">{l.product_id ? `${qtyText(l.quantity)} ${unit(l)}` : ''}</td>
                  <td className="num">{fmt(l.total)}</td>
                  <td>{i === 0 ? (x.accounts.map(a => data.accountName[a]).filter(Boolean).join(', ') || <span className="text-muted">not paid</span>) : ''}</td>
                  <td>{i === 0 && stateOf(x) && <span className={`badge ${PROOF_STATE[stateOf(x)][1]}`}>{PROOF_STATE[stateOf(x)][0]}</span>}</td>
                  <td className="num">{i === 0 && <button type="button" className="icon-btn" aria-label={`Open sale #${x.no}`} onClick={e => { e.stopPropagation(); open(); }}><ExternalLink size={14} /></button>}</td>
                </tr>
              );
            }))}
          </tbody>
          {sales.length > 0 && <tfoot><tr><td colSpan={3}><strong>Total</strong></td><td className="num"><strong>{full(total)}</strong></td><td colSpan={3} /></tr></tfoot>}
        </table>
      </div></div>
    </div>
  );
}

/* Weekly cash or Purchases opened: the period's rows, newest first; a row opens the page on the period */
function CardHistory({ card, data, inBranch, today, short, full, period, periodKey, bar, onBack, go }) {
  const by = grainOf(periodKey);
  const cfg = CARD[card];
  const rows = useMemo(() => historyFor(data, card, by, inBranch, today, period), [data, card, by, inBranch, today, period]);
  const cols = ['a', 'b', 'c'].slice(0, cfg.heads.length);
  const openRow = r => go(by === 'day' ? pageFor(card, { from: r.key, to: r.key, label: tableDate(r.key) }) : pageFor(card, period));
  return (
    <div className="dd">
      <ReportHead card={card} period={period} onBack={onBack} go={go} />
      {bar}
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>{BY_HEAD[by]}</th>{cfg.showItems && <><th>Item</th><th className="num">Qty</th><th className="num">Amount (TZS)</th></>}{cfg.heads.map(h => <th key={h} className="num">{h}</th>)}</tr></thead>
          <tbody>
            {rows.length === 0 ? <tr><td colSpan={cols.length + (cfg.showItems ? 4 : 1)} className="text-muted">Nothing recorded yet.</td></tr>
            : rows.map(r => <tr key={r.key} className="dd-report-row" title={`Open ${cfg.title}`} onClick={() => openRow(r)}><td>{r.label}</td>{cfg.showItems && (() => { const its = Object.values(r.items || {}); return <>
                <td>{its.map(i => <div key={`${i.name}|${i.unit}`} className="dd-item">{i.name}</div>)}</td>
                <td className="num">{its.map(i => <div key={`${i.name}|${i.unit}`} className="dd-item">{qtyText(i.qty)} {i.unit}</div>)}</td>
                <td className="num">{its.map(i => <div key={`${i.name}|${i.unit}`} className="dd-item">{fmt(i.amount)}</div>)}</td>
              </>; })()}{cols.map(k => <td key={k} className="num">{fmt(r[k])}</td>)}</tr>)}
          </tbody>
          {rows.length > 0 && <tfoot><tr><td><strong>Total</strong></td>{cfg.showItems && <><td /><td /><td /></>}{cols.map(k => <td key={k} className="num"><strong>{full(rows.reduce((t, r) => t + r[k], 0))}</strong></td>)}</tr></tfoot>}
        </table>
      </div></div>
    </div>
  );
}

/* The Purchases card opened (2026-11-04): each purchase — supplier, product, quantity, price, amount,
   paid, to pay — whether it is paid, and Pay (the payment window, with the slip) */
function PurchasesReport({ data, inBranch, full, currency, canPay, period, bar, onBack, go, onPaid }) {
  const [paying, setPaying] = useState(null);
  const [accounts, setAccounts] = useState([]);
  const rows = data.purchases.filter(x => x.id && inBranch(x.branch_id) && x.day >= period.from && x.day <= period.to)
    .sort((a, b) => (a.day === b.day ? 0 : a.day < b.day ? 1 : -1));
  const sum = k => rows.reduce((t, x) => t + x[k], 0);
  const status = x => (x.toPay <= 0.004 ? ['Paid', 'badge-success'] : x.paid > 0 ? ['Part paid', 'badge-warning'] : ['Not paid', 'badge-error']);
  async function openPay(x) {
    const { data: ac } = await supabase.from('payment_accounts').select('id, name, status').eq('branch_id', x.branch_id).order('display_order').order('name');
    setAccounts((ac || []).filter(a => a.status === 'active'));
    setPaying(x);
  }
  let lastDay = null;
  return (
    <div className="dd">
      <ReportHead card="purchases" period={period} onBack={onBack} go={go} />
      {bar}
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>Date</th><th>Supplier</th><th>Product</th><th className="num">Qty</th><th className="num">Price (TZS)</th><th className="num">Amount (TZS)</th>
            <th className="num">Paid (TZS)</th><th className="num">To pay (TZS)</th><th>Status</th><th aria-label="Pay" /></tr></thead>
          <tbody>
            {rows.length === 0 ? <tr><td colSpan={10} className="text-muted">No purchases in this period.</td></tr>
            : rows.flatMap(x => (x.items.length ? x.items : [{ name: '—', unit: '', qty: 0, price: 0, amount: x.total }]).map((i, k) => {
              const showDay = k === 0 && x.day !== lastDay; if (k === 0) lastDay = x.day;
              const [label, badge] = status(x);
              return (
                <tr key={`${x.id}-${k}`}>
                  <td>{showDay ? tableDate(x.day) : ''}</td>
                  <td>{k === 0 ? <>{x.supplier || '—'}{x.ref ? <div className="pl-help">{x.ref}</div> : null}</> : ''}</td>
                  <td>{i.name}</td>
                  <td className="num">{i.qty ? `${qtyText(i.qty)} ${i.unit}` : ''}</td>
                  <td className="num">{i.price ? fmt(i.price) : ''}</td>
                  <td className="num">{fmt(i.amount)}</td>
                  <td className="num">{k === 0 ? fmt(x.paid) : ''}</td>
                  <td className="num">{k === 0 ? <strong className={x.toPay > 0.004 ? 'text-warning' : ''}>{fmt(x.toPay)}</strong> : ''}</td>
                  <td>{k === 0 && <span className={`badge ${badge}`}>{label}</span>}</td>
                  <td style={{ textAlign: 'right' }}>{k === 0 && canPay && x.toPay > 0.004 && <button type="button" className="btn btn-primary btn-sm" onClick={() => openPay(x)}>Pay</button>}</td>
                </tr>
              );
            }))}
          </tbody>
          {rows.length > 0 && <tfoot><tr><td colSpan={5}><strong>Total</strong></td><td className="num"><strong>{full(sum('total'))}</strong></td>
            <td className="num"><strong>{full(sum('paid'))}</strong></td><td className="num"><strong>{full(sum('toPay'))}</strong></td><td colSpan={2} /></tr></tfoot>}
        </table>
      </div></div>
      {paying && <PayPurchaseModal purchase={paying.raw} total={paying.total} supplierName={paying.supplier || 'the supplier'} accounts={accounts} currency={currency}
        onClose={() => setPaying(null)} onSaved={async () => { setPaying(null); await onPaid(); }} />}
    </div>
  );
}
