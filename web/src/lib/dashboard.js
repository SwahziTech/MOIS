import { supabase } from './supabase';

/*
 * Dashboards (1f, PRD 4.15, 2026-10-29): what needs attention now, at the
 * chosen branch. The month's figures come from the report loaders
 * (lib/reports); these read the live state — curing, open orders, stock
 * against reorder levels, what's waiting for someone.
 */

const productLabel = (refs, pid, cid) => [refs.items[`p:${pid}`]?.name ?? '?', cid ? refs.colorById?.[cid]?.name : null].filter(Boolean).join(' ');

/** Batches curing: all of them, and those whose curing is done (ready to release) */
export async function loadCuring({ inBranch, today, refs }) {
  const { data, error } = await supabase.from('production_batches')
    .select('id, branch_id, batch_date, curing_until, outputs:production_batch_outputs(product_id, color_id, is_primary, pieces_cast)')
    .eq('status', 'curing').order('curing_until');
  if (error) throw error;
  const rows = (data || []).filter(b => inBranch(b.branch_id)).map(b => {
    const main = (b.outputs || []).find(o => o.is_primary);
    return { id: b.id, date: b.batch_date, until: b.curing_until, ready: b.curing_until <= today, name: main ? productLabel(refs, main.product_id, main.color_id) : '?',
      pieces: (b.outputs || []).reduce((t, o) => t + o.pieces_cast, 0) };
  });
  return { rows, pieces: rows.reduce((t, r) => t + r.pieces, 0), ready: rows.filter(r => r.ready) };
}

/** Open production orders with their progress (048) */
export async function loadOpenOrders({ inBranch, today }) {
  const { data, error } = await supabase.from('production_orders')
    .select('id, branch_id, order_no, reference, due_date, status, lines:production_order_lines(id)').eq('status', 'open').order('due_date', { nullsFirst: false });
  if (error) return { rows: [], dueSoon: 0 };
  const orders = (data || []).filter(o => inBranch(o.branch_id));
  const ids = orders.flatMap(o => (o.lines || []).map(l => l.id));
  const pr = ids.length ? await supabase.from('production_order_line_progress').select('*').in('line_id', ids) : { data: [] };
  const soon = new Date(`${today}T00:00:00Z`); soon.setUTCDate(soon.getUTCDate() + 7);
  const rows = orders.map(o => {
    const ls = (pr.data || []).filter(p => p.order_id === o.id);
    const planned = ls.reduce((t, p) => t + p.planned, 0);
    return { id: o.id, no: o.order_no, reference: o.reference, due: o.due_date, planned, cast: ls.reduce((t, p) => t + p.cast_pieces, 0),
      passed: ls.reduce((t, p) => t + p.passed, 0), curing: ls.reduce((t, p) => t + p.curing, 0), late: !!o.due_date && o.due_date < today };
  });
  return { rows, dueSoon: rows.filter(r => r.due && r.due <= soon.toISOString().slice(0, 10)).length };
}

/** Finished products at the branch against their reorder levels (049) */
export async function loadLowStock({ branchId, refs }) {
  if (!branchId) return { rows: [], inStock: 0 };
  const whs = new Set(refs.warehouses.filter(w => w.branch_id === branchId).map(w => w.id));
  const [bal, rl] = await Promise.all([
    supabase.from('stock_balances').select('warehouse_id, product_id, quantity').not('product_id', 'is', null),
    supabase.from('branch_products').select('product_id, reorder_level').eq('branch_id', branchId).eq('status', 'active'),
  ]);
  const qty = {};
  for (const r of (bal.data || []).filter(x => whs.has(x.warehouse_id))) qty[r.product_id] = (qty[r.product_id] || 0) + Number(r.quantity);
  const rows = (rl.data || []).filter(x => x.reorder_level != null && (qty[x.product_id] || 0) < Number(x.reorder_level))
    .map(x => ({ id: x.product_id, name: refs.items[`p:${x.product_id}`]?.name ?? '?', unit: refs.unitById[refs.items[`p:${x.product_id}`]?.stockUnitId]?.symbol ?? '',
      qty: qty[x.product_id] || 0, level: Number(x.reorder_level) }))
    .sort((a, b) => a.qty / (a.level || 1) - b.qty / (b.level || 1));
  return { rows, inStock: Object.values(qty).filter(v => v > 0).length };
}

/** What we owe suppliers (purchases and expenses) */
export async function loadPayables({ inBranch }) {
  const { data, error } = await supabase.from('supplier_balances').select('branch_id, owed');
  if (error) return null;
  return (data || []).filter(x => inBranch(x.branch_id)).reduce((t, x) => t + Math.max(Number(x.owed), 0), 0);
}

/** The newest sales (orders and invoices) with what's still owed */
export async function loadRecentSales({ inBranch }) {
  const [s, b, c] = await Promise.all([
    supabase.from('sales').select('id, branch_id, sale_no, stage, customer_id, walk_in_name, sale_date, ordered_on, invoiced_on, total').in('stage', ['order', 'invoice'])
      .order('created_at', { ascending: false }).limit(40),
    supabase.from('sale_balances').select('sale_id, balance'),
    supabase.from('customers').select('id, name'),
  ]);
  if (s.error) return [];
  return (s.data || []).filter(x => inBranch(x.branch_id)).slice(0, 8).map(x => ({
    id: x.id, no: x.sale_no, stage: x.stage, date: x.invoiced_on || x.ordered_on || x.sale_date,
    who: x.customer_id ? (c.data || []).find(k => k.id === x.customer_id)?.name ?? '?' : (x.walk_in_name || 'Walk-in'),
    total: Number(x.total), balance: Number((b.data || []).find(k => k.sale_id === x.id)?.balance ?? 0),
  }));
}

/** Things waiting for someone: pay sheets, purchase requests, review flags */
export async function loadWaiting({ inBranch, today }) {
  const [ps, pr, rf, ld] = await Promise.all([
    supabase.from('pay_sheets').select('branch_id, status').in('status', ['draft', 'approved']),
    supabase.from('purchase_requests').select('branch_id, status').eq('status', 'waiting'),
    supabase.from('review_flags').select('id', { count: 'exact', head: true }).eq('status', 'open'),
    supabase.from('leads').select('branch_id, next_follow_up, stage').not('stage', 'in', '(won,lost)').lte('next_follow_up', today),
  ]);
  return {
    payToApprove: (ps.data || []).filter(x => inBranch(x.branch_id) && x.status === 'draft').length,
    payToPay: (ps.data || []).filter(x => inBranch(x.branch_id) && x.status === 'approved').length,
    requests: (pr.data || []).filter(x => inBranch(x.branch_id)).length,
    flags: rf.count ?? 0,
    followUps: ld.error ? 0 : (ld.data || []).filter(x => inBranch(x.branch_id)).length,
  };
}
