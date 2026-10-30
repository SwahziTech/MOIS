import { supabase } from './supabase';
import { loadOwing, ageByBuyer } from './receivables';

/*
 * Statements (Finance & Accounting, 2026-10-30) — read from what MOIS already
 * records; nothing here writes.
 *   balanceSheet — what the business holds and owes today, at the chosen
 *     branch: cash in the accounts, what customers owe, finished stock and
 *     materials at cost (first in, first out), staff advances still to take
 *     back; less suppliers still to pay and pay sheets ended but not paid.
 *     The difference is the owners' share. Machines, buildings and loans are
 *     not in MOIS, so they are left out.
 *   periods — money in and out a week or a month, by type, with the opening
 *     and closing cash (Cash flow › Monthly).
 */
const n = v => Number(v || 0);
const sum = (rows, f) => rows.reduce((t, x) => t + n(typeof f === 'function' ? f(x) : x[f]), 0);

/** an account's money counts from its opening date; money without an account always counts */
export function cashTools(accounts, moves) {
  const byId = Object.fromEntries(accounts.map(a => [a.id, a]));
  const counts = x => { const a = byId[x.account_id]; return !a || !a.opening_date || x.day >= a.opening_date; };
  const counted = moves.filter(counts);
  // cash at the end of a day: opening balances set by then + every counted movement up to it
  const cashAt = day => sum(accounts.filter(a => !a.opening_date || a.opening_date <= day), 'opening_balance')
    + sum(counted.filter(x => x.day <= day), x => (x.direction === 'in' ? 1 : -1) * n(x.amount));
  return { counted, cashAt };
}

const dayBefore = d => { const x = new Date(`${d}T00:00:00Z`); x.setUTCDate(x.getUTCDate() - 1); return x.toISOString().slice(0, 10); };
const addDays = (d, k) => { const x = new Date(`${d}T00:00:00Z`); x.setUTCDate(x.getUTCDate() + k); return x.toISOString().slice(0, 10); };
const mondayOf = d => { const x = new Date(`${d}T00:00:00Z`); const w = (x.getUTCDay() + 6) % 7; return addDays(d, -w); };
const monthEnd = m => { const x = new Date(`${m}-01T00:00:00Z`); x.setUTCMonth(x.getUTCMonth() + 1); x.setUTCDate(0); return x.toISOString().slice(0, 10); };

/** the last `count` weeks (Monday–Sunday) or months, newest first: { label, from, to, opening, ins: {kind: amount}, outs, closing } */
export function cashPeriods({ accounts, moves, today, by = 'month', count = 12 }) {
  const { counted, cashAt } = cashTools(accounts, moves);
  const out = [];
  let from = by === 'week' ? mondayOf(today) : `${today.slice(0, 7)}-01`;
  for (let i = 0; i < count; i++) {
    const to = by === 'week' ? addDays(from, 6) : monthEnd(from.slice(0, 7));
    const rows = counted.filter(x => x.day >= from && x.day <= to);
    const by_ = dir => rows.filter(x => x.direction === dir).reduce((m, x) => ({ ...m, [x.kind]: (m[x.kind] || 0) + n(x.amount) }), {});
    const end = to > today ? today : to;
    out.push({ from, to, ins: by_('in'), outs: by_('out'), opening: cashAt(dayBefore(from)), closing: cashAt(end) });
    from = by === 'week' ? addDays(from, -7) : `${dayBefore(from).slice(0, 7)}-01`;
  }
  return out;
}

/** Finished stock and materials at cost today, branch by branch (product_costing 058; material_stock_value 052) */
export async function stockAtCost(branchIds) {
  const bal = await supabase.from('stock_balances').select('branch_id, material_id, quantity').not('material_id', 'is', null).gt('quantity', 0);
  let finished = 0; let materials = 0; let uncosted = 0;
  for (const b of branchIds) {
    const pc = await supabase.rpc('product_costing', { p_branch_id: b });
    if (!pc.error) for (const r of pc.data || []) { finished += n(r.value); if (n(r.uncosted_quantity) > 0) uncosted += 1; }
    const mats = [...new Set((bal.data || []).filter(x => x.branch_id === b).map(x => x.material_id))];
    const vals = await Promise.all(mats.map(m => supabase.rpc('material_stock_value', { p_branch_id: b, p_material_id: m })));
    for (const v of vals) { const r = v.data?.[0]; if (r) { materials += n(r.value); if (n(r.uncosted_quantity) > 0) uncosted += 1; } }
  }
  return { finished, materials_value: materials, uncosted };
}

/** The balance sheet today at the branches in view */
export async function loadBalanceSheet({ branchIds, inBranch, today }) {
  const [acc, mv, sup, pay, adv] = await Promise.all([
    supabase.from('payment_accounts').select('*'),
    supabase.from('cash_movements').select('account_id, branch_id, day, direction, amount'),
    supabase.from('supplier_balances').select('branch_id, owed'),
    supabase.from('pay_sheets').select('branch_id, status, period_end, total').in('status', ['draft', 'approved']),
    supabase.from('staff_advance_balances').select('branch_id, status, outstanding'),
  ]);
  if (acc.error || mv.error) throw acc.error || mv.error;
  const accounts = (acc.data || []).filter(a => inBranch(a.branch_id) && a.status === 'active');
  const { cashAt } = cashTools(accounts, (mv.data || []).filter(x => inBranch(x.branch_id) && accounts.some(a => a.id === x.account_id)));
  const cash = cashAt(today);

  const sales = (await loadOwing()).filter(s => inBranch(s.branch_id));
  const receivable = sum(ageByBuyer(sales, [], today), 'owed');

  const { finished, materials_value: materials, uncosted } = await stockAtCost(branchIds);
  const advances = adv.error ? 0 : sum((adv.data || []).filter(a => inBranch(a.branch_id) && a.status !== 'void'), 'outstanding');
  const suppliers = sup.error ? 0 : sum((sup.data || []).filter(s => inBranch(s.branch_id) && n(s.owed) > 0), 'owed');
  const wages = pay.error ? 0 : sum((pay.data || []).filter(p => inBranch(p.branch_id) && (p.status === 'approved' || p.period_end < today)), 'total');

  const assets = [['Cash in the accounts', cash], ['Customers owe', receivable], ['Finished stock at cost', finished], ['Materials at cost', materials], ['Staff advances to take back', advances]];
  const liabilities = [['Suppliers to pay', suppliers], ['Pay sheets ended, not paid', wages]];
  const tA = sum(assets, 1); const tL = sum(liabilities, 1);
  return { assets, liabilities, totalAssets: tA, totalLiabilities: tL, equity: tA - tL, uncosted, accounts: accounts.length };
}
