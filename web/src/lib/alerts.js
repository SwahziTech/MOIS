import { supabase } from './supabase';

/*
 * In-app alerts (PRD 4.16, 2026-10-30): worked out from the data each person
 * may see (RLS) at the chosen branch, by what they work on (permissions):
 * low stock, approvals waiting, overdue invoices, production variance,
 * quality rejections, late purchase orders, deliveries still on the way,
 * lead follow-ups due, pay sheets and purchase requests waiting.
 * → [{ key, level: 'warn' | 'info', text, to, count }]
 * Push to phones comes with the mobile app (Firebase, PRD 4.16).
 */
const days = (d, n) => { const x = new Date(`${d}T00:00:00Z`); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
const ok = r => (r && !r.error ? r.data || [] : []);

export async function loadAlerts({ can, inBranch, today }) {
  const out = [];
  const add = (key, count, level, text, to) => { if (count > 0) out.push({ key, count, level, text, to }); };
  const jobs = [];

  if (can('inventory.view')) {
    jobs.push((async () => {
      const r = await supabase.from('pending_changes').select('branch_id').eq('status', 'pending');
      const n = ok(r).filter(x => !x.branch_id || inBranch(x.branch_id)).length;
      add('approvals', n, 'warn', `${n} change${n === 1 ? '' : 's'} waiting for approval`, '/approvals');
    })());
    jobs.push((async () => {
      const [wh, bal, rl] = await Promise.all([
        supabase.from('warehouses').select('id, branch_id'),
        supabase.from('stock_balances').select('warehouse_id, product_id, quantity').not('product_id', 'is', null),
        supabase.from('branch_products').select('branch_id, product_id, reorder_level').not('reorder_level', 'is', null).eq('status', 'active'),
      ]);
      const brOf = Object.fromEntries(ok(wh).map(w => [w.id, w.branch_id]));
      const qty = {};
      for (const b of ok(bal)) { const k = `${brOf[b.warehouse_id]}|${b.product_id}`; qty[k] = (qty[k] || 0) + Number(b.quantity); }
      const n = ok(rl).filter(x => inBranch(x.branch_id) && (qty[`${x.branch_id}|${x.product_id}`] || 0) < Number(x.reorder_level)).length;
      add('low-stock', n, 'warn', `${n} product${n === 1 ? '' : 's'} below the reorder level`, '/stock');
    })());
  }
  if (can('sales.view')) {
    jobs.push((async () => {
      const r = await supabase.from('overdue_sales').select('branch_id, balance');
      const rows = ok(r).filter(x => inBranch(x.branch_id));
      add('overdue', rows.length, 'warn', `${rows.length} invoice${rows.length === 1 ? '' : 's'} / order${rows.length === 1 ? '' : 's'} overdue`, '/customers');
    })());
    jobs.push((async () => {
      const r = await supabase.from('sale_deliveries').select('status, delivered_on, sale:sales!inner(branch_id)').eq('status', 'on_the_way').lt('delivered_on', today);
      const n = ok(r).filter(x => inBranch(x.sale.branch_id)).length;
      add('deliveries', n, 'info', `${n} deliver${n === 1 ? 'y' : 'ies'} still on the way from before today — confirm or check`, '/sales');
    })());
    jobs.push((async () => {
      const r = await supabase.from('leads').select('branch_id').not('stage', 'in', '(won,lost)').lte('next_follow_up', today);
      const n = ok(r).filter(x => inBranch(x.branch_id)).length;
      add('leads', n, 'info', `${n} lead follow-up${n === 1 ? '' : 's'} due`, '/customers');
    })());
  }
  if (can('products.view')) {
    jobs.push((async () => {
      const r = await supabase.from('review_flags').select('id', { count: 'exact', head: true }).eq('status', 'open').eq('reason_code', 'yield_out_of_band');
      const n = r.error ? 0 : r.count ?? 0;
      add('variance', n, 'warn', `${n} batch${n === 1 ? '' : 'es'} outside the yield band to review`, '/review');
    })());
  }
  if (can('production.view')) {
    jobs.push((async () => {
      const r = await supabase.from('production_batches').select('branch_id, rejects:production_batch_rejects(pieces)').eq('status', 'released').gte('batch_date', days(today, -14));
      const n = ok(r).filter(b => inBranch(b.branch_id) && (b.rejects || []).some(x => Number(x.pieces) > 0)).length;
      add('rejects', n, 'info', `${n} batch${n === 1 ? '' : 'es'} with rejected pieces in the last 2 weeks`, '/production/ledger');
    })());
  }
  if (can('procurement.view')) {
    jobs.push((async () => {
      const r = await supabase.from('purchase_orders').select('branch_id').eq('status', 'open').lt('expected_on', today);
      const n = ok(r).filter(x => inBranch(x.branch_id)).length;
      add('late-po', n, 'warn', `${n} purchase order${n === 1 ? '' : 's'} past the expected date`, '/purchases?tab=requests');
    })());
  }
  if (can('procurement.approve')) {
    jobs.push((async () => {
      const r = await supabase.from('purchase_requests').select('branch_id').eq('status', 'waiting');
      const n = ok(r).filter(x => inBranch(x.branch_id)).length;
      add('requests', n, 'info', `${n} purchase request${n === 1 ? '' : 's'} waiting for a decision`, '/purchases?tab=requests');
    })());
  }
  if (can('payroll.approve')) {
    jobs.push((async () => {
      const r = await supabase.from('pay_sheets').select('branch_id, status').in('status', ['draft', 'approved']).lt('period_end', today);
      const rows = ok(r).filter(x => inBranch(x.branch_id));
      const a = rows.filter(x => x.status === 'draft').length; const p = rows.filter(x => x.status === 'approved').length;
      add('pay-approve', a, 'info', `${a} pay sheet${a === 1 ? '' : 's'} ended — to approve`, '/staff?tab=pay');
      add('pay-pay', p, 'warn', `${p} approved pay sheet${p === 1 ? '' : 's'} to pay`, '/staff?tab=pay');
    })());
  }
  await Promise.all(jobs.map(j => j.catch(() => null)));
  return out.sort((x, y) => (x.level === y.level ? 0 : x.level === 'warn' ? -1 : 1));
}
