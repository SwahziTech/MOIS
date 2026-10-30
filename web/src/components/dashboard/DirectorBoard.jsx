import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../../hooks/useAuth';
import { useBranch } from '../../hooks/useBranch';
import { formatAmount, formatMoneyShort } from '../../lib/format';
import { loadInventoryRefs, orgToday } from '../../lib/inventory';
import { loadDirectorBoard } from '../../lib/directorBoard';
import ErrorState from '../ErrorState';

const monthShort = m => new Date(`${m}-01T00:00:00Z`).toLocaleDateString('en-GB', { month: 'short', timeZone: 'UTC' });
const fmt = v => formatAmount(Math.round(Number(v || 0)));
const SHOW = 5;

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
const Num = ({ to, label, figure, note, warn }) => (
  <Link to={to} className="dd-num"><span className="pl-label">{label}</span><strong>{figure}</strong><span className={`pl-help${warn ? ' text-warning' : ''}`}>{note}</span></Link>
);

/*
 * The director's dashboard (2026-10-30), one screen with no tabs, built for
 * the phone first: what needs them on top, then four numbers, production,
 * stock at risk, six months of sales against money paid out, the most overdue
 * customers and, on All branches, the branches side by side. Every figure
 * opens the page behind it. No profit here (the user's choice).
 */
export default function DirectorBoard() {
  const { organization } = useAuth();
  const { branchId, branchName, branches, inBranch } = useBranch();
  const today = orgToday(organization?.timezone);
  const short = v => formatMoneyShort(v, organization?.currency_code);
  const [d, setD] = useState(null);
  const [error, setError] = useState('');

  async function load() {
    setError(''); setD(null);
    try {
      const refs = await loadInventoryRefs();
      setD(await loadDirectorBoard({ inBranch, branchId, branches, today, refs }));
    } catch (e) { console.error(e); setError("We couldn't load the dashboard."); }
  }
  useEffect(() => { load(); }, [branchId, branches.length]); // eslint-disable-line react-hooks/exhaustive-deps

  if (error) return <div className="card"><ErrorState message={error} onRetry={load} /></div>;
  if (!d) return <div className="dd"><div className="card"><div className="card-body"><span className="skeleton" /></div></div></div>;
  const { needs, money: m, factory: f, risk: r } = d;
  const change = m && m.lastMonth > 0 ? Math.round((m.sales / m.lastMonth - 1) * 100) : null;
  const top = m ? Math.max(1, ...m.trend.flatMap(x => [x.sales, x.costs])) : 1;
  const unavailable = <p className="pl-help">Couldn&apos;t load this part.</p>;

  return (
    <div className="dd">
      {needs === null ? null : needs.length > 0 ? (
        <section className="dd-block dd-needs">
          <div className="dd-head"><span>Needs you now</span><span className="pl-help">{needs.reduce((t, x) => t + x.count, 0)} items</span></div>
          <div className="dd-needs-row">
            {needs.map(x => <Link key={x.key} to={x.to} className="dd-need"><strong className={x.warn ? 'text-warning' : ''}>{x.count}</strong><span>{x.label}</span></Link>)}
          </div>
        </section>
      ) : <p className="pl-help">Nothing needs you right now.</p>}

      {m ? (
        <div className="dd-nums">
          <Num to="/cash-flow" label="Cash now" figure={short(m.cash)} note={m.unset ? "Opening balances not set" : `${m.accounts} accounts`} warn={m.unset > 0} />
          <Num to="/sales" label="Sales this month" figure={short(m.sales)} note={change == null ? 'Nothing to compare yet' : `${change >= 0 ? '+' : ''}${change}% vs same days in ${monthShort(m.prevMonth)}`} />
          <Num to="/customers?tab=owing" label="Customers owe us" figure={short(m.owedToUs)} note={d.overdueTotal > 0 ? `${short(d.overdueTotal)} overdue` : 'None overdue'} warn={d.overdueTotal > 0} />
          <Num to="/statements?tab=parties" label="We owe suppliers" figure={short(m.weOwe)} note={`${m.supplierCount} suppliers`} />
        </div>
      ) : unavailable}

      <div className="dd-two">
        <Block title="Production" note="this month" to="/production">
          {f ? <>
            <Line label="Cement bags today" value={fmt(f.bagsToday)} />
            <Line label="Cement bags this month" value={fmt(f.bagsMonth)} />
            <Line label="Pieces curing" value={f.ready ? `${fmt(f.curing)} · ${f.ready} batches ready` : fmt(f.curing)} />
            <Line to="/review" label="Batches outside the yield band" value={f.flags} warn={f.flags > 0} />
            <Line to="/production/ledger" label="Pieces rejected" value={fmt(f.rejected)} warn={f.rejected > 0} />
          </> : unavailable}
        </Block>
        <Block title="Stock at risk" note="only what's low" to="/stock">
          {r ? (r.materials.length + r.products.length === 0 ? <p className="pl-help">Nothing is low.</p> : <>
            {r.materials.slice(0, SHOW).map(x => <Line key={x.id} to="/stock" label={x.name} value={`about ${x.days} day${x.days === 1 ? '' : 's'} left`} warn />)}
            {r.products.slice(0, Math.max(SHOW - r.materials.length, 0)).map(x => <Line key={x.key} to="/stock" label={x.name} value="below reorder" />)}
            {r.materials.length + r.products.length > SHOW && <Link to="/stock" className="pl-help dd-more">{r.materials.length + r.products.length - SHOW} more</Link>}
          </>) : unavailable}
        </Block>
      </div>

      {m && (
        <Block title="Sales vs money paid out" note="last 6 months" to="/cash-flow?tab=monthly">
          <div className="dd-legend"><span><i className="dd-key is-sales" />Sales</span><span><i className="dd-key is-costs" />Paid out</span></div>
          <div className="dd-chart" role="img" aria-label={m.trend.map(x => `${monthShort(x.month)}: sales ${fmt(x.sales)}, paid out ${fmt(x.costs)}`).join('; ')}>
            {m.trend.map(x => (
              <div key={x.month} className="dd-col" title={`${monthShort(x.month)}\nSales: ${fmt(x.sales)}\nPaid out: ${fmt(x.costs)}`}>
                <div className="dd-bars">
                  <div className="dd-bar is-sales" style={{ height: `${(x.sales / top) * 100}%` }} />
                  <div className="dd-bar is-costs" style={{ height: `${(x.costs / top) * 100}%` }} />
                </div>
                <span className="pl-help">{monthShort(x.month)}</span>
              </div>
            ))}
          </div>
        </Block>
      )}

      <div className="dd-two">
        <Block title="Top overdue customers" note="days late" to="/customers?tab=owing">
          {d.overdue.length === 0 ? <p className="pl-help">Nobody is overdue.</p>
            : d.overdue.slice(0, SHOW).map(x => <Line key={x.key} to="/customers?tab=owing" label={`${x.name} · ${short(x.amount)}`} value={x.days} warn={x.days > 30} />)}
        </Block>
        {!branchId && m && m.branches.length > 1 && (
          <Block title="Branches" note="this month">
            {m.branches.map(b => <Line key={b.id} label={b.name} value={`Sales ${short(b.sales)} · cash ${short(b.cash)}`} />)}
          </Block>
        )}
      </div>
      <p className="pl-help">{branchId ? branchName : 'All branches'} · {today}. Days left are an estimate from the last 14 days&apos; use. Sales include VAT.</p>
    </div>
  );
}
