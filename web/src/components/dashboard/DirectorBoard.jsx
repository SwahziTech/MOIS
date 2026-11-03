import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ChevronLeft, ChevronRight } from 'lucide-react';
import { useAuth } from '../../hooks/useAuth';
import { useBranch } from '../../hooks/useBranch';
import { formatAmount, formatMoneyShort, dateText } from '../../lib/format';
import { loadInventoryRefs, orgToday } from '../../lib/inventory';
import { loadDirectorBoard, loadStockBlock, periodsFor, periodSteps, cardsFor, productionFor, trendFrom, monthShort } from '../../lib/directorBoard';
import ErrorState from '../ErrorState';

const fmt = v => formatAmount(Math.round(Number(v || 0)));
const SHOW = 5;
const DROPDOWN = [['Monthly', [['month', 'This month'], ['lastmonth', 'Last month']]],
  ['Quarterly', [['quarter', 'This quarter'], ['lastquarter', 'Last quarter']]], ['Yearly', [['year', 'This year'], ['lastyear', 'Last year']]]];
const LAST_OF = { week: 'lastweek', month: 'lastmonth', quarter: 'lastquarter', year: 'lastyear' };

/* Opens on this week (user, 2026-11-03). From it › goes to today and ‹ to last week; from today ‹ steps back a day at a
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
      <span><strong>{period.label}</strong> · {period.note}</span>
      {periodKey !== 'week' && <button type="button" className="btn btn-outline btn-sm dd-reset" onClick={() => setPeriodKey('week')}>This week</button>}
      <select className="form-input dd-select" aria-label="Period" value={periodKey} onChange={e => setPeriodKey(e.target.value)}>
        <optgroup label="Weekly">
          <option value="week">This week</option>
          {days.map(p => <option key={p.key} value={p.key}>{p.label}</option>)}
          <option value="lastweek">Last week</option>
        </optgroup>
        {DROPDOWN.map(([group, opts]) => <optgroup key={group} label={group}>{opts.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</optgroup>)}
      </select>
    </div>
  );
}
const CARD = { sales: { to: '/sales' }, cash: { to: '/weekly-cash' }, purchases: { to: '/purchases' } };

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
  const { organization } = useAuth();
  const { branchId, branchName, branches, inBranch } = useBranch();
  const today = orgToday(organization?.timezone);
  const short = v => formatMoneyShort(v, organization?.currency_code);
  const navigate = useNavigate();
  const [d, setD] = useState(null);
  const [stock, setStock] = useState(undefined);   // undefined loading, null failed
  const [error, setError] = useState('');
  const [periodKey, setPeriodKey] = useState('week');
  const periods = useMemo(() => periodsFor(today), [today]);
  const period = periods.find(p => p.key === periodKey);

  async function load() {
    setError(''); setD(null); setStock(undefined);
    try {
      const refs = await loadInventoryRefs();
      setD(await loadDirectorBoard({ inBranch, today, refs }));
      // stock at cost asks the database item by item, so it follows when ready
      loadStockBlock({ inBranch, branchId, branches, today, refs }).then(setStock).catch(e => { console.error(e); setStock(null); });
    } catch (e) { console.error(e); setError("We couldn't load the dashboard."); }
  }
  useEffect(() => { load(); }, [branchId, branches.length]); // eslint-disable-line react-hooks/exhaustive-deps

  // a card opens its page (user, 2026-11-03); Sales opens the Sales book on the same period
  const open = card => navigate(card === 'sales'
    ? `/sales?tab=book&from=${period.from}&to=${period.to}&label=${encodeURIComponent(period.label)}` : CARD[card].to);
  if (error) return <div className="card"><ErrorState message={error} onRetry={load} /></div>;
  if (!d) return <div className="dd"><div className="card"><div className="card-body"><span className="skeleton" /></div></div></div>;
  const bar = <PeriodBar period={period} periods={periods} periodKey={periodKey} setPeriodKey={setPeriodKey} today={today} />;

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
            {needs.map(x => <Link key={x.key} to={x.to} className="dd-need"><strong>{x.count}</strong><span>{x.label}</span></Link>)}
          </div>
        </section>
      ) : <p className="pl-help">Nothing needs you right now.</p>}

      {bar}

      {c ? (
        <div className="dd-cards">
          <button type="button" className="dd-num dd-num-big" onClick={() => open('sales')}>
            <span className="pl-label">Sales</span><strong>{short(c.sales)}</strong>
            <span className="pl-help">received, not yet approved{change == null ? '' : ` · ${change >= 0 ? '+' : ''}${change}% vs ${period.compare.label}`}</span>
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
      <p className="pl-help">{branchId ? branchName : 'All branches'} · {dateText(today)}. Days left are an estimate from the last 14 days&apos; use. Money out counts only what&apos;s recorded in MOIS.</p>
    </div>
  );
}

