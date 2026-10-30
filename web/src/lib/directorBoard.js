import { supabase } from './supabase';
import { loadCuring, loadLowStock } from './dashboard';
import { loadProduction, loadMaterialUse } from './reports';
import { cashTools } from './statements';

/*
 * The director's dashboard (2026-10-30): what needs them, cash, sales, who
 * owes whom, production, stock at risk, six months of sales against money
 * paid out, and the branches side by side. Read only, at the chosen branch.
 * Each block loads on its own, so one failing leaves the others standing.
 */
const n = v => Number(v || 0);
const sum = (rows, f) => rows.reduce((t, x) => t + n(f(x)), 0);
const safe = p => p.catch(e => { console.error(e); return null; });
const dayShift = (d, k) => { const x = new Date(`${d}T00:00:00Z`); x.setUTCDate(x.getUTCDate() + k); return x.toISOString().slice(0, 10); };
const monthsBack = (m, k) => { const d = new Date(`${m}-01T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() - k); return d.toISOString().slice(0, 7); };
const lastDay = m => { const x = new Date(`${m}-01T00:00:00Z`); x.setUTCMonth(x.getUTCMonth() + 1); x.setUTCDate(0); return x.toISOString().slice(0, 10); };
const saleDay = s => s.invoiced_on || s.ordered_on || s.sale_date;
const USE_DAYS = 14;      // recent use a material's days left are worked out from
const LOW_DAYS = 7;       // fewer days left than this counts as at risk

async function loadNeeds({ inBranch, today, overdue }) {
  const [ch, cr, ps] = await Promise.all([
    supabase.from('pending_changes').select('branch_id').eq('status', 'pending'),
    supabase.from('cash_requests').select('branch_id').eq('status', 'with_directors'),
    supabase.from('pay_sheets').select('branch_id, status, period_end').in('status', ['draft', 'approved']),
  ]);
  const pay = (ps.data || []).filter(x => inBranch(x.branch_id));
  return [
    { key: 'approvals', count: (ch.data || []).filter(x => !x.branch_id || inBranch(x.branch_id)).length, label: 'approvals waiting', to: '/approvals' },
    { key: 'cash', count: (cr.data || []).filter(x => inBranch(x.branch_id)).length, label: 'weekly cash requests', to: '/weekly-cash' },
    { key: 'pay-approve', count: pay.filter(x => x.status === 'draft' && x.period_end < today).length, label: 'pay sheets to approve', to: '/staff?tab=pay' },
    { key: 'pay-pay', count: pay.filter(x => x.status === 'approved').length, label: 'pay sheets to pay', to: '/staff?tab=pay' },
    { key: 'overdue', count: overdue.length, label: 'invoices overdue', to: '/customers?tab=owing', warn: true },
  ].filter(x => x.count > 0);
}

async function loadMoney({ inBranch, branches, today }) {
  const month = today.slice(0, 7);
  const start = `${monthsBack(month, 5)}-01`;
  const [ac, mv, sa, su, ow] = await Promise.all([
    supabase.from('payment_accounts').select('*').eq('status', 'active'),
    supabase.from('cash_movements').select('account_id, branch_id, day, direction, amount, kind'),
    supabase.from('sales').select('branch_id, stage, sale_date, ordered_on, invoiced_on, total').in('stage', ['order', 'invoice']).gte('sale_date', `${monthsBack(month, 7)}-01`),
    supabase.from('supplier_balances').select('branch_id, supplier_id, owed'),
    supabase.from('sale_balances').select('branch_id, stage, balance').in('stage', ['order', 'invoice']),
  ]);
  if (ac.error || mv.error || sa.error) throw ac.error || mv.error || sa.error;
  const cashOf = accounts => cashTools(accounts, (mv.data || []).filter(x => accounts.some(a => a.id === x.account_id))).cashAt(today);
  const accounts = (ac.data || []).filter(a => inBranch(a.branch_id));
  const sales = (sa.data || []).filter(s => inBranch(s.branch_id));
  const inRange = (from, to) => sales.filter(s => saleDay(s) >= from && saleDay(s) <= to);
  const thisMonth = sum(inRange(`${month}-01`, today), s => s.total);
  // last month up to the same day, so a part month is compared fairly
  const prev = monthsBack(month, 1);
  const prevTo = [`${prev}-${today.slice(8)}`, lastDay(prev)].sort()[0];
  const lastMonth = sum(inRange(`${prev}-01`, prevTo), s => s.total);
  const out = (mv.data || []).filter(x => inBranch(x.branch_id) && x.direction === 'out' && x.day >= start);
  const trend = Array.from({ length: 6 }, (_, i) => {
    const m = monthsBack(month, 5 - i);
    return { month: m, sales: sum(inRange(`${m}-01`, lastDay(m)), s => s.total), costs: sum(out.filter(x => x.day.startsWith(m)), x => x.amount) };
  });
  const suppliers = (su.error ? [] : su.data || []).filter(x => inBranch(x.branch_id) && n(x.owed) > 0);
  return {
    cash: cashOf(accounts), accounts: accounts.length, unset: accounts.filter(a => !a.opening_date).length,
    sales: thisMonth, lastMonth, prevMonth: prev, trend,
    owedToUs: sum((ow.data || []).filter(x => inBranch(x.branch_id) && n(x.balance) > 0), x => x.balance),
    weOwe: sum(suppliers, x => x.owed), supplierCount: new Set(suppliers.map(x => x.supplier_id)).size,
    branches: branches.map(b => ({ id: b.id, name: b.name,
      sales: sum((sa.data || []).filter(s => s.branch_id === b.id && saleDay(s) >= `${month}-01` && saleDay(s) <= today), s => s.total),
      cash: cashOf((ac.data || []).filter(a => a.branch_id === b.id)) })),
  };
}

async function loadFactory({ inBranch, today, refs }) {
  const [day, month, curing, flags] = await Promise.all([
    loadProduction({ from: today, to: today, inBranch, refs }),
    loadProduction({ from: `${today.slice(0, 7)}-01`, to: today, inBranch, refs }),
    loadCuring({ inBranch, today, refs }),
    supabase.from('review_flags').select('id', { count: 'exact', head: true }).eq('status', 'open').eq('reason_code', 'yield_out_of_band'),
  ]);
  return { bagsToday: sum(day.rows, r => r.bags), bagsMonth: sum(month.rows, r => r.bags), curing: curing.pieces, ready: curing.ready.length,
    flags: flags.error ? 0 : flags.count ?? 0, rejected: sum(month.rows, r => r.rejected) };
}

async function loadRisk({ inBranch, branchId, branches, today, refs }) {
  const ids = branchId ? [branchId] : branches.map(b => b.id);
  const [low, used, bal] = await Promise.all([
    Promise.all(ids.map(id => loadLowStock({ branchId: id, refs }))),
    loadMaterialUse({ from: dayShift(today, -USE_DAYS + 1), to: today, inBranch, refs }),
    supabase.from('stock_balances').select('branch_id, material_id, quantity').not('material_id', 'is', null),
  ]);
  const onHand = {};
  for (const b of (bal.data || []).filter(x => inBranch(x.branch_id))) onHand[b.material_id] = (onHand[b.material_id] || 0) + n(b.quantity);
  const materials = used.filter(m => m.actual > 0).map(m => ({ id: m.id, name: m.name, days: Math.floor(Math.max(onHand[m.id] || 0, 0) / (m.actual / USE_DAYS)) }))
    .filter(m => m.days < LOW_DAYS).sort((a, b) => a.days - b.days);
  const products = low.flatMap((l, i) => l.rows.map(r => ({ ...r, key: `${ids[i]}|${r.id}` })));
  return { materials, products };
}

/** The most overdue customers: what each owes past due, and the longest it has been late */
function topOverdue(rows, customers) {
  const by = {};
  for (const s of rows) {
    const k = s.customer_id || `w:${s.walk_in_name || 'Walk-in'}`;
    const c = (by[k] ||= { key: k, name: s.customer_id ? customers.find(x => x.id === s.customer_id)?.name ?? '—' : s.walk_in_name || 'Walk-in', amount: 0, days: 0 });
    c.amount += n(s.balance); c.days = Math.max(c.days, n(s.days_overdue));
  }
  return Object.values(by).sort((a, b) => b.amount - a.amount);
}

export async function loadDirectorBoard({ inBranch, branchId, branches, today, refs }) {
  const [od, cu] = await Promise.all([
    supabase.from('overdue_sales').select('branch_id, customer_id, walk_in_name, balance, days_overdue'),
    supabase.from('customers').select('id, name'),
  ]);
  const overdue = (od.error ? [] : od.data || []).filter(x => inBranch(x.branch_id));
  const [needs, money, factory, risk] = await Promise.all([
    safe(loadNeeds({ inBranch, today, overdue })),
    safe(loadMoney({ inBranch, branches, today })),
    safe(loadFactory({ inBranch, today, refs })),
    safe(loadRisk({ inBranch, branchId, branches, today, refs })),
  ]);
  return { needs, money, factory, risk, overdueTotal: sum(overdue, x => x.balance), overdue: topOverdue(overdue, cu.data || []) };
}
