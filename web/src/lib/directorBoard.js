import { supabase } from './supabase';
import { loadCuring, loadLowStock } from './dashboard';
import { loadMaterialUse } from './reports';
import { stockAtCost } from './statements';
import { dateText } from './format';

/*
 * The director's dashboard (2026-10-30, draft 2 of the design), read only, at
 * the chosen branch. Three cards for a period: Sales (money received), Weekly
 * cash (sent, spent, left), Purchases (bought, paid, still to pay); production
 * for the period; stock at cost with what's at risk; six months of money in
 * against money out; branches side by side. Each block loads on its own, so
 * one failing leaves the others standing. Weeks run Sunday to Saturday, as on
 * the Weekly cash page.
 */
const n = v => Number(v || 0);
const sum = (rows, f) => rows.reduce((t, x) => t + n(f(x)), 0);
const safe = p => p.catch(e => { console.error(e); return null; });
const iso = d => d.toISOString().slice(0, 10);
const utc = s => new Date(`${s}T00:00:00Z`);
export const dayShift = (d, k) => { const x = utc(d); x.setUTCDate(x.getUTCDate() + k); return iso(x); };
const monthsBack = (m, k) => { const d = utc(`${m}-01`); d.setUTCMonth(d.getUTCMonth() - k); return iso(d).slice(0, 7); };
const lastDay = m => { const x = utc(`${m}-01`); x.setUTCMonth(x.getUTCMonth() + 1); x.setUTCDate(0); return iso(x); };
const sundayOf = d => dayShift(d, -utc(d).getUTCDay());
const daysSinceMonday = d => (utc(d).getUTCDay() + 6) % 7;
const shortDay = d => dateText(d);
export const monthShort = m => utc(`${m}-01`).toLocaleDateString('en-GB', { month: 'short', timeZone: 'UTC' });
const monthLong = m => utc(`${m}-01`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });
const inRange = (d, from, to) => !!d && d >= from && d <= to;
const USE_DAYS = 14;      // recent use a material's days left are worked out from
const LOW_DAYS = 7;       // fewer days left than this counts as at risk

/**
 * The periods the Sort / Filter menu offers; the first, today, is the default.
 * The earlier days of this week (back to Monday) come after yesterday.
 * Each: { key, label, note, from, to, compare: { from, to, label } }
 */
export function periodsFor(today) {
  const month = today.slice(0, 7);
  const sameDayIn = m => [`${m}-${today.slice(8)}`, lastDay(m)].sort()[0];
  const y = dayShift(today, -1);
  const sun = sundayOf(today);
  const lastSun = dayShift(sun, -7);
  const prevM = monthsBack(month, 1);
  const prevPrev = monthsBack(month, 2);
  const quarterStart = monthsBack(month, (Number(month.slice(5)) - 1) % 3);
  const prevQ = monthsBack(quarterStart, 3);
  const year = today.slice(0, 4);
  const lastYear = String(Number(year) - 1);
  const earlier = Array.from({ length: Math.max(daysSinceMonday(today) - 1, 0) }, (_, i) => {
    const d = dayShift(today, -(i + 2));
    return { key: `day-${i + 2}`, label: `${i + 2} days ago`, note: dateText(d), from: d, to: d, compare: { from: dayShift(d, -1), to: dayShift(d, -1), label: 'the day before' } };
  });
  return [
    { key: 'today', label: 'Today', note: dateText(today), from: today, to: today, compare: { from: y, to: y, label: 'yesterday' } },
    { key: 'yesterday', label: 'Yesterday', note: dateText(y), from: y, to: y, compare: { from: dayShift(y, -1), to: dayShift(y, -1), label: 'the day before' } },
    ...earlier,
    { key: 'week', label: 'This week', note: `${shortDay(sun)} – ${shortDay(dayShift(sun, 6))}`, from: sun, to: today, compare: { from: lastSun, to: dayShift(today, -7), label: 'last week' } },
    { key: 'lastweek', label: 'Last week', note: `${shortDay(lastSun)} – ${shortDay(dayShift(lastSun, 6))}`, from: lastSun, to: dayShift(lastSun, 6), compare: { from: dayShift(lastSun, -7), to: dayShift(lastSun, -1), label: 'the week before' } },
    { key: 'month', label: 'This month', note: monthLong(month), from: `${month}-01`, to: today, compare: { from: `${prevM}-01`, to: sameDayIn(prevM), label: `same days ${monthShort(prevM)}` } },
    { key: 'lastmonth', label: 'Last month', note: monthLong(prevM), from: `${prevM}-01`, to: lastDay(prevM), compare: { from: `${prevPrev}-01`, to: lastDay(prevPrev), label: monthShort(prevPrev) } },
    { key: 'quarter', label: 'This quarter', note: `${monthShort(quarterStart)} – today`, from: `${quarterStart}-01`, to: today, compare: { from: `${prevQ}-01`, to: sameDayIn(monthsBack(month, 3)), label: 'same days last quarter' } },
    { key: 'year', label: 'This year', note: year, from: `${year}-01-01`, to: today, compare: { from: `${lastYear}-01-01`, to: `${lastYear}${today.slice(4)}`, label: `same days ${lastYear}` } },
  ];
}

/** The back arrow's path, nearest first: today, each day back to Monday, last week, last month */
export function periodSteps(today) {
  const days = daysSinceMonday(today);
  return ['today', ...(days >= 1 ? ['yesterday'] : []), ...Array.from({ length: Math.max(days - 1, 0) }, (_, i) => `day-${i + 2}`), 'lastweek', 'lastmonth'];
}

async function loadNeeds({ inBranch, today }) {
  const [ch, cr, ps, pr] = await Promise.all([
    supabase.from('pending_changes').select('branch_id').eq('status', 'pending'),
    supabase.from('cash_requests').select('branch_id').eq('status', 'with_directors'),
    supabase.from('pay_sheets').select('branch_id, status, period_end').in('status', ['draft', 'approved']),
    supabase.from('purchase_requests').select('branch_id').eq('status', 'waiting'),
  ]);
  const pay = (ps.data || []).filter(x => inBranch(x.branch_id));
  return [
    { key: 'requests', count: (pr.data || []).filter(x => inBranch(x.branch_id)).length, label: 'purchase requests waiting', to: '/purchases?tab=requests' },
    { key: 'cash', count: (cr.data || []).filter(x => inBranch(x.branch_id)).length, label: 'weekly cash requests', to: '/weekly-cash' },
    { key: 'approvals', count: (ch.data || []).filter(x => !x.branch_id || inBranch(x.branch_id)).length, label: 'approvals waiting', to: '/approvals' },
    { key: 'pay-approve', count: pay.filter(x => x.status === 'draft' && x.period_end < today).length, label: 'pay sheets to approve', to: '/staff?tab=pay' },
    { key: 'pay-pay', count: pay.filter(x => x.status === 'approved').length, label: 'pay sheets to pay', to: '/staff?tab=pay' },
  ].filter(x => x.count > 0);
}

/** Everything the cards and their detail pages count, once; a period is then only a filter */
export async function loadMoneyData() {
  const [pa, mv, cr, pu, tot, ba] = await Promise.all([
    supabase.from('sale_payments').select('paid_on, amount, sale:sales!inner(branch_id)'),
    supabase.from('cash_movements').select('branch_id, day, direction, amount, kind'),
    supabase.from('cash_requests').select('branch_id, week_ending, status, opening_balance'),
    supabase.from('purchases').select('id, branch_id, purchase_date, lines:purchase_lines(line_amount, tx:inventory_transactions(entered_quantity, material:materials(name), unit:units!inventory_transactions_entered_unit_id_fkey(symbol)))').neq('status', 'void'),
    supabase.from('purchase_totals').select('purchase_id, total, amount_paid, balance'),
    supabase.from('production_batches').select('branch_id, batch_date, cement_bags, status, outputs:production_batch_outputs(is_primary), rejects:production_batch_rejects(pieces)').neq('status', 'void'),
  ]);
  const err = pa.error || mv.error || cr.error || pu.error;
  if (err) throw err;
  const totals = Object.fromEntries((tot.data || []).map(t => [t.purchase_id, t]));
  return {
    received: (pa.data || []).map(p => ({ branch_id: p.sale.branch_id, day: p.paid_on, amount: n(p.amount) })),
    moves: mv.data || [],
    requests: (cr.data || []).filter(r => !['cancelled', 'rejected'].includes(r.status)),
    purchases: (pu.data || []).map(p => ({ branch_id: p.branch_id, day: p.purchase_date, total: n(totals[p.id]?.total), paid: n(totals[p.id]?.amount_paid), toPay: Math.max(n(totals[p.id]?.balance), 0),
      items: (p.lines || []).filter(l => l.tx?.material?.name).map(l => ({ name: l.tx.material.name, unit: l.tx.unit?.symbol ?? '', qty: n(l.tx.entered_quantity), amount: n(l.line_amount) })) })),
    batches: (ba.data || []).filter(b => (b.outputs || []).some(o => o.is_primary)),
  };
}

const SPENT = new Set(['purchase', 'expense', 'wages', 'statutory']);

/** Sales received, weekly cash and purchases for one period */
export function cardsFor(data, { from, to, compare }, inBranch) {
  const received = (a, b) => sum(data.received.filter(x => inBranch(x.branch_id) && inRange(x.day, a, b)), x => x.amount);
  const moves = data.moves.filter(x => inBranch(x.branch_id));
  const sentIn = (a, b) => sum(moves.filter(x => x.kind === 'topup' && inRange(x.day, a, b)), x => x.amount);
  const spentIn = (a, b) => sum(moves.filter(x => SPENT.has(x.kind) && inRange(x.day, a, b)), x => x.amount);
  const bought = data.purchases.filter(x => inBranch(x.branch_id) && inRange(x.day, from, to));
  return {
    sales: received(from, to),
    salesBefore: compare ? received(compare.from, compare.to) : null,
    sent: sentIn(from, to),
    spent: spentIn(from, to),
    left: weeklyCashLeft(data, to, inBranch),
    hasRequests: data.requests.some(r => inBranch(r.branch_id)),
    bought: sum(bought, x => x.total),
    // money actually paid to suppliers in the period, whenever the goods were bought
    paid: sum(moves.filter(x => x.kind === 'purchase' && inRange(x.day, from, to)), x => x.amount),
    // what's owed doesn't belong to one period: everything bought up to its end and still unpaid
    toPay: sum(data.purchases.filter(x => inBranch(x.branch_id) && !!x.day && x.day <= to), x => x.toPay),
  };
}

/** What's left with the branches at the end of a day, as on Weekly cash: brought forward + sent − spent, from the first request */
function weeklyCashLeft(data, upTo, inBranch) {
  const byBranch = {};
  for (const r of data.requests) if (inBranch(r.branch_id)) (byBranch[r.branch_id] ||= []).push(r);
  let left = 0;
  for (const [branch, rows] of Object.entries(byBranch)) {
    const sorted = rows.slice().sort((a, b) => (a.week_ending < b.week_ending ? -1 : 1));
    const started = sorted.filter(r => dayShift(r.week_ending, -6) <= upTo);
    if (!started.length) continue;
    const base = [...started].reverse().find(r => r.opening_balance != null) ?? started[0];
    const start = dayShift(base.week_ending, -6);
    const moves = data.moves.filter(x => x.branch_id === branch && inRange(x.day, start, upTo));
    left += n(base.opening_balance) + sum(moves, x => (x.kind === 'topup' ? n(x.amount) : SPENT.has(x.kind) ? -n(x.amount) : 0));
  }
  return left;
}

export function productionFor(data, { from, to }, inBranch, today) {
  const batches = data.batches.filter(b => inBranch(b.branch_id));
  const inPeriod = batches.filter(b => inRange(b.batch_date, from, to));
  return {
    bagsToday: sum(batches.filter(b => b.batch_date === today), b => b.cement_bags),
    bags: sum(inPeriod, b => b.cement_bags),
    rejected: sum(inPeriod.filter(b => b.status === 'released'), b => sum(b.rejects || [], r => r.pieces)),
  };
}

/** Rows for a card's detail page, newest first. by: day | week | month | quarter | year */
export function historyFor(data, card, by, inBranch, today) {
  const keyOf = d => (by === 'day' ? d : by === 'week' ? sundayOf(d) : by === 'month' ? d.slice(0, 7)
    : by === 'quarter' ? `${d.slice(0, 4)}-Q${Math.ceil(Number(d.slice(5, 7)) / 3)}` : d.slice(0, 4));
  const label = k => (by === 'day' ? shortDay(k) : by === 'week' ? `${shortDay(k)} – ${shortDay(dayShift(k, 6))}` : by === 'month' ? monthLong(k) : k.replace('-Q', ' Q'));
  const rows = {};
  const add = (d, f) => { if (!d || d > today) return; const k = keyOf(d); f(rows[k] ||= { key: k, label: label(k), a: 0, b: 0, c: 0 }); };
  if (card === 'sales') for (const x of data.received) { if (inBranch(x.branch_id)) add(x.day, r => { r.a += x.amount; }); }
  if (card === 'cash') for (const x of data.moves) {
    if (!inBranch(x.branch_id)) continue;
    if (x.kind === 'topup') add(x.day, r => { r.a += n(x.amount); });
    if (SPENT.has(x.kind)) add(x.day, r => { r.b += n(x.amount); });
  }
  if (card === 'purchases') for (const x of data.purchases) { if (inBranch(x.branch_id)) add(x.day, r => { r.a += x.total; r.b += x.paid; r.c += x.toPay; r.items ||= {}; for (const i of x.items) { const it = r.items[`${i.name}|${i.unit}`] ||= { name: i.name, unit: i.unit, qty: 0, amount: 0 }; it.qty += i.qty; it.amount += i.amount; } }); }
  return Object.values(rows).sort((p, q) => (p.key < q.key ? 1 : -1));
}

async function loadCuringNow({ inBranch, today, refs }) {
  const [curing, flags] = await Promise.all([
    loadCuring({ inBranch, today, refs }),
    supabase.from('review_flags').select('id', { count: 'exact', head: true }).eq('status', 'open').eq('reason_code', 'yield_out_of_band'),
  ]);
  return { curing: curing.pieces, ready: curing.ready.length, flags: flags.error ? 0 : flags.count ?? 0 };
}

/** Stock at cost today, and what's at risk: materials running out, products below reorder */
export async function loadStockBlock({ inBranch, branchId, branches, today, refs }) {
  const ids = branchId ? [branchId] : branches.map(b => b.id);
  const [low, used, bal, value] = await Promise.all([
    Promise.all(ids.map(id => loadLowStock({ branchId: id, refs }))),
    loadMaterialUse({ from: dayShift(today, -USE_DAYS + 1), to: today, inBranch, refs }),
    supabase.from('stock_balances').select('branch_id, material_id, quantity').not('material_id', 'is', null),
    stockAtCost(ids),
  ]);
  const onHand = {};
  for (const b of (bal.data || []).filter(x => inBranch(x.branch_id))) onHand[b.material_id] = (onHand[b.material_id] || 0) + n(b.quantity);
  const materials = used.filter(m => m.actual > 0).map(m => ({ id: m.id, name: m.name, days: Math.floor(Math.max(onHand[m.id] || 0, 0) / (m.actual / USE_DAYS)) }))
    .filter(m => m.days < LOW_DAYS).sort((a, b) => a.days - b.days);
  const products = low.flatMap((l, i) => l.rows.map(r => ({ ...r, key: `${ids[i]}|${r.id}` })));
  return { ...value, materials, products };
}

/** Six months of money in (sale payments) against money out (everything paid) */
export function trendFrom(data, inBranch, today) {
  const month = today.slice(0, 7);
  const moves = data.moves.filter(x => inBranch(x.branch_id));
  return Array.from({ length: 6 }, (_, i) => {
    const m = monthsBack(month, 5 - i);
    return { month: m, in: sum(data.received.filter(x => inBranch(x.branch_id) && x.day?.startsWith(m)), x => x.amount),
      out: sum(moves.filter(x => SPENT.has(x.kind) && x.day?.startsWith(m)), x => x.amount) };
  });
}

export async function loadDirectorBoard({ inBranch, today, refs }) {
  const [needs, money, curing] = await Promise.all([
    safe(loadNeeds({ inBranch, today })),
    safe(loadMoneyData()),
    safe(loadCuringNow({ inBranch, today, refs })),
  ]);
  return { needs, money, curing };
}
