import { useEffect, useMemo, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { loadFlagBranches } from '../lib/flagBranch';
import { formatAmount, formatMoneyShort, dateText, tableDate } from '../lib/format';
import { orgToday, loadInventoryRefs } from '../lib/inventory';
import { loadProduction, loadSales, loadMaterialUse, loadProfit } from '../lib/reports';
import { loadCuring, loadOpenOrders, loadLowStock, loadPayables, loadRecentSales, loadWaiting } from '../lib/dashboard';
import PageShell from '../components/PageShell';
import { PageTabs } from '../components/ListControls';
import MeterReadingsTask from '../components/dashboard/MeterReadingsTask';
import DirectorBoard from '../components/dashboard/DirectorBoard';
import { primaryRole } from '../lib/menu';

/*
 * One card per master-data table, counted for the branch picked in the
 * sidebar (b) — or the whole organization on "All branches" (b = '').
 * Categories and branches have no branch dimension.
 */
const active = q => q.eq('status', 'active');
const STATS = [
  { key: 'categories', label: 'Product Categories', sub: () => 'Active categories', table: () => 'product_categories', to: '/categories', filter: active },
  { key: 'products',   label: 'Products', to: '/products',
    sub: (b, n) => (b ? `In ${n}'s list` : 'Active products'),
    table: b => (b ? 'branch_products' : 'products'),
    filter: (q, b) => (b ? active(q).eq('branch_id', b) : active(q)) },
  { key: 'recipes',    label: 'Recipes / BOM', to: '/recipes',
    sub: (b, n) => (b ? `Active at ${n}` : 'Active recipes'), table: () => 'recipe_versions',
    filter: (q, b) => (b ? active(q).eq('branch_id', b) : active(q)) },
  { key: 'materials',  label: 'Materials', to: '/materials',
    sub: (b, n) => (b ? `Shared + ${n}'s own` : 'Active materials'), table: () => 'materials',
    filter: (q, b) => (b ? active(q).or(`branch_id.is.null,branch_id.eq.${b}`) : active(q)) },
  { key: 'branches',   label: 'Branches', sub: () => 'Active locations', table: () => 'branches', to: '/branches', filter: active },
  { key: 'pricing',    label: 'Price Entries', to: '/pricing',
    sub: (b, n) => (b ? `At ${n}` : 'Across all branches'), table: () => 'product_branch_pricing',
    filter: (q, b) => (b ? q.eq('branch_id', b) : q) },
];

const fmt = new Intl.NumberFormat('en-US');
const n1 = v => (v == null ? '—' : new Intl.NumberFormat('en-US', { maximumFractionDigits: 1 }).format(v));
const STAGE = { order: 'Order', invoice: 'Invoice' };

/*
 * Dashboard (1f, PRD 4.15, 2026-10-29): a tab a view, each shown to those
 * who work in that area — Overview (management: money, production, what
 * needs attention), Production, Inventory, Sales — and Setup (the master-data
 * counts). The month to date at the chosen branch; today's meter readings
 * stay at the top for those who take them.
 */
export default function Dashboard() {
  const { userRoles } = useAuth();
  // directors get their own screen (2026-10-30); the Technical admin can see it as a tab
  if (primaryRole(userRoles) === 'director') {
    return <PageShell title="Dashboard" subtitle="Overview"><DirectorBoard /></PageShell>;
  }
  return <RoleDashboard isOwner={primaryRole(userRoles) === 'owner'} />;
}

function RoleDashboard({ isOwner }) {
  const { organization, can, canAnywhere } = useAuth();
  const { branchId, branchName, inBranch, branches } = useBranch();
  const today = orgToday(organization?.timezone);
  const cur = organization?.currency_code;
  const short = v => formatMoneyShort(v, cur);
  const sees = code => (canAnywhere ?? can)(code);
  const tabs = useMemo(() => [
    isOwner && ['director', 'Director view'],
    sees('products.manage') && ['overview', 'Overview'],
    sees('production.view') && ['production', 'Production'],
    sees('inventory.view') && ['inventory', 'Inventory'],
    sees('sales.view') && ['sales', 'Sales'],
    ['setup', 'Setup'],
  ].filter(Boolean), [can, canAnywhere, isOwner]); // eslint-disable-line react-hooks/exhaustive-deps
  const [tab, setTab] = useState(() => (new URLSearchParams(window.location.search).get('card') ? 'director' : null));
  const shown = tab && tabs.some(t => t[0] === tab) ? tab : tabs.find(t => t[0] !== 'director')[0];
  const [refs, setRefs] = useState(null);
  const [loaded, setLoaded] = useState(null);   // { tab, value }
  const [error, setError] = useState('');
  const reqRef = useRef(0);
  const from = `${today.slice(0, 7)}-01`;

  useEffect(() => { loadInventoryRefs().then(setRefs).catch(() => setError('Failed to load dashboard data.')); }, []);
  useEffect(() => {
    if (!refs || shown === 'setup' || shown === 'director') return;
    const req = ++reqRef.current; const forTab = shown;
    setError(''); setLoaded(null);
    const args = { from, to: today, today, inBranch, branchId, refs, branches };
    const jobs = {
      overview: async () => {
        const [sales, prod, profit, payables, curing, low, waiting, orders] = await Promise.all([
          loadSales(args), loadProduction(args), loadProfit(args).catch(() => null), loadPayables(args), loadCuring(args), loadLowStock(args), loadWaiting(args), loadOpenOrders(args)]);
        return { sales, prod, profit, payables, curing, low, waiting, orders };
      },
      production: async () => {
        const [prod, curing, orders, mats] = await Promise.all([loadProduction(args), loadCuring(args), loadOpenOrders(args), loadMaterialUse(args).catch(() => [])]);
        return { prod, curing, orders, mats };
      },
      inventory: async () => {
        const [low, mats] = await Promise.all([loadLowStock(args), loadMaterialUse(args).catch(() => [])]);
        return { low, mats };
      },
      sales: async () => {
        const [sales, recent] = await Promise.all([loadSales(args), loadRecentSales(args)]);
        return { sales, recent };
      },
    };
    jobs[forTab]().then(value => { if (req === reqRef.current) setLoaded({ tab: forTab, value }); })
      .catch(e => { console.error(e); if (req === reqRef.current) setError('Failed to load dashboard data.'); });
  }, [shown, refs, branchId]); // eslint-disable-line react-hooks/exhaustive-deps
  const d = loaded?.tab === shown ? loaded.value : null;

  const card = (label, figure, note, to, title) => {
    const body = <><span className="pl-label">{label}</span><strong>{figure}</strong><span className="pl-help" title={title}>{note}</span></>;
    return to ? <Link to={to} className="mm-stat db-link">{body}</Link> : <div className="mm-stat">{body}</div>;
  };
  const wait = <>{card('…', '…', '')}{card('…', '…', '')}{card('…', '…', '')}{card('…', '…', '')}</>;
  const pcsOf = p => p.rows.reduce((t, r) => t + r.pieces, 0);
  const bagsOf = p => p.rows.reduce((t, r) => t + r.bags, 0);

  // what needs attention (Overview)
  const alerts = d && shown === 'overview' ? [
    d.curing.ready.length && { text: `${d.curing.ready.length} batch${d.curing.ready.length === 1 ? '' : 'es'} done curing — ready to release`, to: '/production' },
    d.orders.rows.filter(r => r.late).length && { text: `${d.orders.rows.filter(r => r.late).length} production order(s) past their due date`, to: '/production', warn: true },
    d.orders.dueSoon && { text: `${d.orders.dueSoon} production order(s) due within 7 days`, to: '/production' },
    d.low.rows.length && { text: `${d.low.rows.length} product(s) below their reorder level`, to: '/stock', warn: true },
    d.waiting.payToApprove && { text: `${d.waiting.payToApprove} pay sheet(s) to approve`, to: '/staff' },
    d.waiting.payToPay && { text: `${d.waiting.payToPay} approved pay sheet(s) to pay`, to: '/staff' },
    d.waiting.requests && { text: `${d.waiting.requests} purchase request(s) waiting for a decision`, to: '/purchases?tab=requests' },
    d.waiting.flags && { text: `${d.waiting.flags} open review flag(s)`, to: '/review' },
    d.waiting.followUps && { text: `${d.waiting.followUps} lead follow-up(s) due`, to: '/customers' },
  ].filter(Boolean) : [];

  return (
    <PageShell title="Dashboard" description={`An overview of ${branchId ? branchName : 'every branch'}${shown === 'director' ? '' : ' — this month'}.`}>
      <PageTabs tabs={tabs} value={shown} onChange={setTab} />
      {/* today's jobs first: the meters read morning and evening (secretary, branch manager) */}
      <MeterReadingsTask branchId={branchId} />
      {error && <div className="alert alert-error mb-16" role="alert">{error}</div>}

      {shown === 'director' ? <DirectorBoard />
      : shown === 'setup' ? <SetupCounts branchId={branchId} branchName={branchName} inBranch={inBranch} />
      : shown === 'overview' ? (
        <>
          <div className="mm-stats">{!d ? wait : <>
            {card('Sales', short(d.sales.total), `${d.sales.docs} orders & invoices`, '/reports')}
            {card('Received', short(d.sales.received), 'payments this month', '/sales')}
            {card('Customers owe', short(d.sales.owed), 'all open sales', '/customers')}
            {card('We owe', d.payables == null ? '—' : short(d.payables), 'suppliers & expenses', '/purchases')}
            {card('Production', `${formatAmount(pcsOf(d.prod))} pcs`, `${formatAmount(bagsOf(d.prod))} bags of cement`, '/production/ledger')}
            {card('Gross margin', d.profit ? short(d.profit.margin) : '—', d.profit?.sales ? `${n1((d.profit.margin / d.profit.sales) * 100)}% of delivered` : 'nothing delivered', '/reports', 'Delivered without VAT less its production cost')}
          </>}</div>
          <div className="card db-list">
            <div className="card-header"><h2 className="card-title">Needs attention</h2></div>
            <div className="card-body">
              {!d ? <span className="skeleton" /> : alerts.length === 0 ? <p className="text-sm text-muted">Nothing waiting.</p> : (
                <ul className="db-alerts">{alerts.map((a, i) => <li key={i}><Link to={a.to} className={a.warn ? 'text-warning' : ''}>{a.text} ›</Link></li>)}</ul>
              )}
            </div>
          </div>
        </>
      ) : shown === 'production' ? (
        <>
          <div className="mm-stats">{!d ? wait : <>
            {card('Cast this month', `${formatAmount(pcsOf(d.prod))} pcs`, `${d.prod.batches} batches`, '/production/ledger')}
            {card('Cement', `${formatAmount(bagsOf(d.prod))} bags`, `wastani ${bagsOf(d.prod) ? n1(d.prod.rows.reduce((t, r) => t + r.pieces + r.leftovers, 0) / bagsOf(d.prod)) : '—'} a bag`)}
            {card('Curing now', `${formatAmount(d.curing.pieces)} pcs`, `${d.curing.ready.length} batch${d.curing.ready.length === 1 ? '' : 'es'} ready to release`, '/production')}
            {(() => { const rel = d.prod.rows.reduce((t, r) => t + r.released, 0); const rej = d.prod.rows.reduce((t, r) => t + r.rejected, 0);
              return card('Rejected', formatAmount(rej), rel ? `${n1((rej / rel) * 100)}% of released` : 'nothing released'); })()}
            {card('Open orders', d.orders.rows.length, `${d.orders.dueSoon} due within 7 days`, '/production')}
            {card('Over the recipe', d.mats.filter(m => m.diffPct != null && m.diffPct > 5).length, 'materials > 5% above', '/reports')}
          </>}</div>
          <div className="db-two">
            <div className="card"><div className="card-header"><h2 className="card-title">Ready to release</h2></div><div className="table-container">
              <table><thead><tr><th>Cast on</th><th>Product</th><th className="num">Pieces</th><th>Cured by</th></tr></thead>
                <tbody>{!d ? <tr><td colSpan={4}><span className="skeleton" /></td></tr>
                  : d.curing.rows.length === 0 ? <tr><td colSpan={4} className="text-muted">Nothing curing.</td></tr>
                  : d.curing.rows.slice(0, 10).map(r => <tr key={r.id}><td>{tableDate(r.date)}</td><td>{r.name}</td><td className="num">{formatAmount(r.pieces)}</td>
                    <td>{r.ready ? <span className="badge badge-success">ready</span> : r.until}</td></tr>)}</tbody></table>
            </div></div>
            <div className="card"><div className="card-header"><h2 className="card-title">Open production orders</h2></div><div className="table-container">
              <table><thead><tr><th>Order</th><th>Due</th><th className="num">Planned</th><th className="num">Cast</th><th className="num">Passed</th></tr></thead>
                <tbody>{!d ? <tr><td colSpan={5}><span className="skeleton" /></td></tr>
                  : d.orders.rows.length === 0 ? <tr><td colSpan={5} className="text-muted">No open orders.</td></tr>
                  : d.orders.rows.slice(0, 10).map(r => <tr key={r.id}><td>#{r.no}{r.reference ? <div className="pl-help">{r.reference}</div> : null}</td>
                    <td className={r.late ? 'text-warning' : ''}>{r.due || '—'}</td><td className="num">{formatAmount(r.planned)}</td>
                    <td className="num">{formatAmount(r.cast)}</td><td className="num">{formatAmount(r.passed)}</td></tr>)}</tbody></table>
            </div></div>
          </div>
        </>
      ) : shown === 'inventory' ? (
        <>
          <div className="mm-stats">{!d ? wait : <>
            {card('Products in stock', branchId ? d.low.inStock : '—', branchId ? 'with stock at the branch' : 'choose a branch', '/stock')}
            {card('Below reorder', branchId ? d.low.rows.length : '—', branchId ? 'products to make' : 'choose a branch', '/stock')}
            {card('Materials used', short(d.mats.reduce((t, m) => t + m.cost, 0)), 'this month, at cost', '/reports')}
            {card('Over the recipe', d.mats.filter(m => m.diffPct != null && m.diffPct > 5).length, 'materials > 5% above', '/reports')}
          </>}</div>
          <div className="db-two">
            <div className="card"><div className="card-header"><h2 className="card-title">Below reorder level</h2></div><div className="table-container">
              <table><thead><tr><th>Product</th><th className="num">In stock</th><th className="num">Reorder level</th></tr></thead>
                <tbody>{!d ? <tr><td colSpan={3}><span className="skeleton" /></td></tr>
                  : !branchId ? <tr><td colSpan={3} className="text-muted">Choose a branch.</td></tr>
                  : d.low.rows.length === 0 ? <tr><td colSpan={3} className="text-muted">Everything is above its reorder level.</td></tr>
                  : d.low.rows.slice(0, 12).map(r => <tr key={r.id}><td>{r.name}</td><td className="num text-warning">{n1(r.qty)} {r.unit}</td><td className="num">{n1(r.level)} {r.unit}</td></tr>)}</tbody></table>
            </div></div>
            <div className="card"><div className="card-header"><h2 className="card-title">Materials this month</h2></div><div className="table-container">
              <table><thead><tr><th>Material</th><th className="num">Used</th><th className="num">vs recipe</th></tr></thead>
                <tbody>{!d ? <tr><td colSpan={3}><span className="skeleton" /></td></tr>
                  : d.mats.length === 0 ? <tr><td colSpan={3} className="text-muted">No production this month.</td></tr>
                  : d.mats.map(m => <tr key={m.id}><td>{m.name}<div className="pl-help">{m.category}</div></td><td className="num">{n1(m.actual)} {m.unit}</td>
                    <td className={`num${m.diffPct != null && Math.abs(m.diffPct) > 5 ? ' text-warning' : ''}`}>{m.diffPct != null ? `${m.diffPct > 0 ? '+' : ''}${n1(m.diffPct)}%` : '—'}</td></tr>)}</tbody></table>
            </div></div>
          </div>
        </>
      ) : (
        <>
          <div className="mm-stats">{!d ? wait : <>
            {card('Sales', short(d.sales.total), `${d.sales.docs} orders & invoices`, '/sales')}
            {card('Received', short(d.sales.received), 'payments this month', '/sales')}
            {card('Customers owe', short(d.sales.owed), 'all open sales', '/customers')}
            {card('VAT', short(d.sales.vat), 'on this month\'s sales')}
          </>}</div>
          <div className="card"><div className="card-header"><h2 className="card-title">Latest sales</h2></div><div className="table-container">
            <table><thead><tr><th>Date</th><th>No.</th><th>Customer</th><th>Stage</th><th className="num">Total (TZS)</th><th className="num">Owed (TZS)</th></tr></thead>
              <tbody>{!d ? <tr><td colSpan={6}><span className="skeleton" /></td></tr>
                : d.recent.length === 0 ? <tr><td colSpan={6} className="text-muted">No orders or invoices yet.</td></tr>
                : d.recent.map(r => <tr key={r.id}><td>{tableDate(r.date)}</td><td>{r.no}</td><td>{r.who}</td><td>{STAGE[r.stage]}</td>
                  <td className="num">{formatAmount(r.total)}</td><td className="num">{r.balance > 0.5 ? formatAmount(r.balance) : ''}</td></tr>)}</tbody></table>
          </div></div>
        </>
      )}
    </PageShell>
  );
}

/* The master-data counts (the first dashboard, kept as Setup) */
function SetupCounts({ branchId, branchName, inBranch }) {
  const [counts,  setCounts]  = useState({});
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');

  useEffect(() => {
    let cancelled = false;

    async function load() {
      setLoading(true);
      setError('');
      try {
        const [results, flags, catRows] = await Promise.all([
          Promise.all(STATS.map(s => {
            let q = supabase.from(s.table(branchId)).select('*', { count: 'exact', head: true });
            if (s.filter) q = s.filter(q, branchId);
            return q;
          })),
          supabase.from('review_flags').select('entity_type, entity_id').eq('status', 'open'),
          supabase.from('product_categories').select('id, parent_category_id').eq('status', 'active'),
        ]);
        if (cancelled) return;
        // open flags: the branch's own plus those on shared records
        const of = await loadFlagBranches(flags.data || []);
        if (cancelled) return;

        const next = {};
        let failed = false;
        results.forEach((res, i) => {
          if (res.error) { failed = true; console.error(STATS[i].table, res.error); return; }
          next[STATS[i].key] = res.count ?? 0;
        });
        // categories that hold products — a group (038) is only a heading
        if (!catRows.error) {
          const groups = new Set((catRows.data || []).map(c => c.parent_category_id).filter(Boolean));
          next.categories = (catRows.data || []).filter(c => !groups.has(c.id)).length;
        }
        if (flags.error) { failed = true; console.error(flags.error); }
        else next.review = (flags.data || []).filter(f => { const b = of(f); return b == null || inBranch(b); }).length;
        setCounts(next);
        if (failed) setError('Failed to load dashboard data.');
      } catch (e) {
        console.error(e);
        if (!cancelled) setError('Failed to load dashboard data.');
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    load();
    return () => { cancelled = true; };
  }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  const cards = [...STATS, { key: 'review', label: 'Needs Review', sub: () => (branchId ? `${branchName}'s and shared` : 'Open review flags'), to: '/review' }];

  return (
    <>
      {error && <div className="alert alert-error mb-16" role="alert">{error}</div>}
      <section className="stat-grid mb-24" aria-label="Master data summary">
        {cards.map(s => (
          <Link key={s.key} id={`stat-${s.key}`} to={s.to} className="stat-card">
            <div className="stat-card-label">{s.label}</div>
            <div className="stat-card-value">
              {loading
                ? <span className="skeleton" />
                : counts[s.key] != null ? fmt.format(counts[s.key]) : '—'}
            </div>
            <div className="stat-card-sub">{s.sub(branchId, branchName)}</div>
          </Link>
        ))}
      </section>
    </>
  );
}
