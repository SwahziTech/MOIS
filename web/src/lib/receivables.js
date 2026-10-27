import { supabase } from './supabase';

/*
 * What customers owe (1e, 2026-10-27): orders and invoices (never quotations
 * or cancelled sales) less what was paid on each, aged from the day the sale
 * became owed — the order date, else the invoice date, else the sale date.
 * Walk-in buyers are kept by their name. Every figure comes from the sales
 * and payments as saved; nothing here changes them.
 */
export const AGE_BUCKETS = [[0, 30, '0–30 days'], [31, 60, '31–60 days'], [61, 90, '61–90 days'], [91, Infinity, 'Over 90 days']];
const r2 = n => Math.round(n * 100) / 100;
const daysBetween = (a, b) => Math.round((new Date(`${b}T00:00:00Z`) - new Date(`${a}T00:00:00Z`)) / 864e5);
export const owedSince = s => s.ordered_on || s.invoiced_on || s.sale_date;

/** The sales that count (orders and invoices) with their payments, optionally for one customer */
export async function loadOwing({ customerId } = {}) {
  let q = supabase.from('sales')
    .select('id, sale_no, branch_id, stage, customer_id, walk_in_name, walk_in_phone, sale_date, ordered_on, invoiced_on, total, efd_receipt_no, payments:sale_payments(id, paid_on, amount, receipt_no, method, created_at)')
    .in('stage', ['order', 'invoice']);
  if (customerId) q = q.eq('customer_id', customerId);
  const { data, error } = await q;
  if (error) throw error;
  return data || [];
}

/** Per buyer: owed, by age, oldest unpaid day, last payment */
export function ageByBuyer(sales, customers, today) {
  const byId = Object.fromEntries((customers || []).map(c => [c.id, c]));
  const out = {};
  for (const s of sales) {
    const paid = (s.payments || []).reduce((t, p) => t + Number(p.amount), 0);
    const bal = r2(Number(s.total) - paid);
    const key = s.customer_id || `walkin:${(s.walk_in_name || 'Walk-in').trim().toLowerCase()}`;
    const b = out[key] ??= {
      key, customer: s.customer_id ? byId[s.customer_id] ?? null : null,
      name: s.customer_id ? byId[s.customer_id]?.name ?? '—' : (s.walk_in_name || 'Walk-in').trim(), phone: s.customer_id ? byId[s.customer_id]?.phone : s.walk_in_phone,
      owed: 0, buckets: AGE_BUCKETS.map(() => 0), oldest: null, lastPaid: null, sales: 0, total: 0, paid: 0,
    };
    b.sales += 1; b.total += Number(s.total); b.paid += paid;
    for (const p of s.payments || []) if (!b.lastPaid || p.paid_on > b.lastPaid) b.lastPaid = p.paid_on;
    if (bal <= 0.004) continue;
    const since = owedSince(s);
    const age = daysBetween(since, today);
    const i = AGE_BUCKETS.findIndex(([lo, hi]) => age >= lo && age <= hi);
    b.buckets[i < 0 ? 0 : i] += bal;
    b.owed += bal;
    if (!b.oldest || since < b.oldest) b.oldest = since;
  }
  return Object.values(out).map(b => ({ ...b, owed: r2(b.owed), buckets: b.buckets.map(r2), total: r2(b.total), paid: r2(b.paid) }));
}

/**
 * A customer's statement for a period: the balance brought forward, then each
 * sale owed (a charge) and each payment, by date, with the running balance.
 */
export function statementLines(sales, from, to) {
  const moves = [];
  for (const s of sales) {
    moves.push({ date: owedSince(s), kind: 'sale', sale: s, ref: `${s.stage === 'invoice' ? 'Invoice' : 'Order'} #${s.sale_no}`, charge: Number(s.total), paid: 0, order: 0 });
    for (const p of s.payments || []) moves.push({ date: p.paid_on, kind: 'payment', sale: s, payment: p, ref: `Payment — #${s.sale_no}${p.receipt_no ? ` (receipt ${p.receipt_no})` : ''}`, charge: 0, paid: Number(p.amount), order: 1, at: p.created_at });
  }
  moves.sort((a, b) => (a.date === b.date ? a.order - b.order || String(a.at ?? '').localeCompare(String(b.at ?? '')) : a.date < b.date ? -1 : 1));
  const opening = r2(moves.filter(m => from && m.date < from).reduce((t, m) => t + m.charge - m.paid, 0));
  let bal = opening;
  const rows = moves.filter(m => (!from || m.date >= from) && (!to || m.date <= to)).map(m => { bal = r2(bal + m.charge - m.paid); return { ...m, balance: bal }; });
  return { opening, rows, closing: bal, charged: r2(rows.reduce((t, m) => t + m.charge, 0)), paid: r2(rows.reduce((t, m) => t + m.paid, 0)) };
}
