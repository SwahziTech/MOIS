import { supabase } from './supabase';

/*
 * Reports (1f, PRD 4.15, 2026-10-29): read for a date range, newest first,
 * filtered to the branches the viewer sees. Each loader returns plain rows
 * the Reports page lists, totals and exports.
 */

const sum = (list, f) => list.reduce((t, x) => t + Number((typeof f === 'function' ? f(x) : x[f]) || 0), 0);
const nameOf = (refs, key) => refs.items[key]?.name ?? '?';
const productLabel = (refs, pid, cid) => [nameOf(refs, `p:${pid}`), cid ? refs.colorById?.[cid]?.name : null].filter(Boolean).join(' ');

/** Production: per main product (and colour) — batches, cement, pieces, passed, rejected, material cost */
export async function loadProduction({ from, to, inBranch, refs }) {
  const { data, error } = await supabase.from('production_batches')
    .select('id, branch_id, batch_date, cement_bags, status, material_cost, outputs:production_batch_outputs(product_id, color_id, is_primary, pieces_cast, pieces_passed), rejects:production_batch_rejects(pieces)')
    .gte('batch_date', from).lte('batch_date', to).neq('status', 'void');
  if (error) throw error;
  const batches = (data || []).filter(b => inBranch(b.branch_id));
  const by = {};
  for (const b of batches) {
    const main = (b.outputs || []).find(o => o.is_primary);
    if (!main) continue;
    const k = `${main.product_id}|${main.color_id ?? ''}`;
    const r = (by[k] ||= { key: k, name: productLabel(refs, main.product_id, main.color_id), batches: 0, bags: 0, pieces: 0, leftovers: 0, passed: 0, released: 0, rejected: 0, cost: 0, curing: 0 });
    r.batches += 1; r.bags += Number(b.cement_bags); r.pieces += main.pieces_cast;
    r.leftovers += sum((b.outputs || []).filter(o => !o.is_primary), 'pieces_cast');
    if (b.status === 'released') { r.released += main.pieces_cast; r.passed += Number(main.pieces_passed ?? main.pieces_cast); r.rejected += sum(b.rejects || [], 'pieces'); }
    if (b.status === 'curing') r.curing += main.pieces_cast;
    r.cost += Number(b.material_cost || 0);
  }
  const rows = Object.values(by).map(r => ({ ...r, wastani: r.bags ? (r.pieces + r.leftovers) / r.bags : null, rejectPct: r.released ? (r.rejected / r.released) * 100 : null, perPiece: r.pieces ? r.cost / (r.pieces + r.leftovers) : null }))
    .sort((a, b) => b.pieces - a.pieces);
  return { rows, batches: batches.length };
}

/** Sales: orders and invoices dated in the range — per product and per customer; payments received in the range */
export async function loadSales({ from, to, inBranch, refs }) {
  const [s, p, c, bal] = await Promise.all([
    supabase.from('sales').select('id, branch_id, stage, customer_id, walk_in_name, sale_date, ordered_on, invoiced_on, subtotal, vat, total, lines:sale_lines(product_id, color_id, quantity, unit_id, amount, vat, total)')
      .in('stage', ['order', 'invoice']),
    supabase.from('sale_payments').select('amount, paid_on, sale:sales!inner(branch_id)').gte('paid_on', from).lte('paid_on', to),
    supabase.from('customers').select('id, name'),
    supabase.from('sale_balances').select('branch_id, stage, balance').in('stage', ['order', 'invoice']),
  ]);
  if (s.error) throw s.error;
  const dateOf = x => x.invoiced_on || x.ordered_on || x.sale_date;
  const sales = (s.data || []).filter(x => inBranch(x.branch_id) && dateOf(x) >= from && dateOf(x) <= to);
  const prod = {}; const cust = {};
  for (const x of sales) {
    const who = x.customer_id ? (c.data || []).find(k => k.id === x.customer_id)?.name ?? '?' : (x.walk_in_name || 'Walk-in');
    const cr = (cust[who] ||= { name: who, docs: 0, amount: 0, vat: 0, total: 0 });
    cr.docs += 1; cr.amount += Number(x.subtotal); cr.vat += Number(x.vat); cr.total += Number(x.total);
    for (const l of x.lines || []) {
      const k = `${l.product_id}|${l.color_id ?? ''}`;
      const pr = (prod[k] ||= { key: k, name: productLabel(refs, l.product_id, l.color_id), unit: refs.unitById[l.unit_id]?.symbol ?? '', quantity: 0, amount: 0, vat: 0, total: 0 });
      pr.quantity += Number(l.quantity); pr.amount += Number(l.amount); pr.vat += Number(l.vat); pr.total += Number(l.total);
    }
  }
  return {
    docs: sales.length, amount: sum(sales, 'subtotal'), vat: sum(sales, 'vat'), total: sum(sales, 'total'),
    received: sum((p.data || []).filter(x => inBranch(x.sale.branch_id)), 'amount'),
    owed: sum((bal.data || []).filter(x => inBranch(x.branch_id) && Number(x.balance) > 0), 'balance'),
    products: Object.values(prod).sort((a, b) => b.total - a.total),
    customers: Object.values(cust).sort((a, b) => b.total - a.total),
  };
}

/** Purchases by supplier and expenses by category, dated in the range */
export async function loadSpending({ from, to, inBranch }) {
  const [p, e, sup, cat] = await Promise.all([
    supabase.from('purchases').select('id, branch_id, supplier_id, purchase_date, status').eq('status', 'recorded').gte('purchase_date', from).lte('purchase_date', to),
    supabase.from('expenses').select('branch_id, category_id, amount, amount_paid, expense_date, status').eq('status', 'recorded').gte('expense_date', from).lte('expense_date', to),
    supabase.from('suppliers').select('id, name'),
    supabase.from('expense_categories').select('id, name'),
  ]);
  if (p.error) throw p.error;
  const buys = (p.data || []).filter(x => inBranch(x.branch_id));
  const t = buys.length ? await supabase.from('purchase_totals').select('purchase_id, total, amount_paid, balance').in('purchase_id', buys.map(x => x.id)) : { data: [] };
  const totals = Object.fromEntries((t.data || []).map(x => [x.purchase_id, x]));
  const bySup = {};
  for (const x of buys) {
    const n = (sup.data || []).find(s => s.id === x.supplier_id)?.name ?? 'No supplier';
    const r = (bySup[n] ||= { name: n, count: 0, total: 0, paid: 0, owed: 0 });
    const tt = totals[x.id] || {};
    r.count += 1; r.total += Number(tt.total || 0); r.paid += Number(tt.amount_paid || 0); r.owed += Number(tt.balance || 0);
  }
  const exps = (e.data || []).filter(x => inBranch(x.branch_id));
  const byCat = {};
  for (const x of exps) {
    const n = (cat.data || []).find(k => k.id === x.category_id)?.name ?? 'No category';
    const r = (byCat[n] ||= { name: n, count: 0, total: 0, paid: 0, owed: 0 });
    r.count += 1; r.total += Number(x.amount); r.paid += Number(x.amount_paid); r.owed += Number(x.amount) - Number(x.amount_paid);
  }
  const suppliers = Object.values(bySup).sort((a, b) => b.total - a.total);
  const categories = Object.values(byCat).sort((a, b) => b.total - a.total);
  return { suppliers, categories, purchases: sum(suppliers, 'total'), expenses: sum(categories, 'total'), owed: sum(suppliers, 'owed') + sum(categories, 'owed') };
}

/** Materials used by production: recipe (standard) vs actual, in stock units, and their cost */
export async function loadMaterialUse({ from, to, inBranch, refs }) {
  const { data, error } = await supabase.from('production_batch_materials')
    .select('material_id, quantity, unit_id, stock_quantity, standard_quantity, source, cost, batch:production_batches!inner(branch_id, batch_date, status)')
    .gte('batch.batch_date', from).lte('batch.batch_date', to).neq('batch.status', 'void');
  if (error) throw error;
  const by = {};
  for (const m of (data || []).filter(x => inBranch(x.batch.branch_id))) {
    const it = refs.items[`m:${m.material_id}`];
    const factor = it?.units.find(u => u.id === m.unit_id)?.factor ?? 1;
    const r = (by[m.material_id] ||= { id: m.material_id, name: it?.name ?? '?', category: it?.materialCategory ?? '', rank: it?.rank ?? 999, unit: refs.unitById[it?.stockUnitId]?.symbol ?? '', actual: 0, standard: 0, counted: 0, cost: 0, costKnown: true });
    r.actual += Number(m.stock_quantity);
    if (m.standard_quantity != null) r.standard += Number(m.standard_quantity) * factor;
    if (m.source === 'counted') r.counted += Number(m.stock_quantity);
    if (m.cost == null) r.costKnown = false; else r.cost += Number(m.cost);
  }
  return Object.values(by).map(r => ({ ...r, diff: r.standard ? r.actual - r.standard : null, diffPct: r.standard ? ((r.actual - r.standard) / r.standard) * 100 : null }))
    .sort((a, b) => a.rank - b.rank || a.name.localeCompare(b.name));
}

/**
 * Basic profit for the range: goods delivered (without VAT) less their production cost = gross margin;
 * less the expenses not already in product cost (categories not ticked into it, not electricity, not
 * wages/statutory) and the pay of staff outside product cost (office and running staff).
 */
export async function loadProfit({ from, to, inBranch }) {
  const [d, e, cat, pay, st] = await Promise.all([
    supabase.from('sale_delivery_lines').select('value, cost, estimated_cost, line:sale_lines!inner(amount, total), delivery:sale_deliveries!inner(delivered_on, sale:sales!inner(branch_id))')
      .gte('delivery.delivered_on', from).lte('delivery.delivered_on', to),
    supabase.from('expenses').select('branch_id, category_id, amount, status, expense_date').eq('status', 'recorded').gte('expense_date', from).lte('expense_date', to),
    supabase.from('expense_categories').select('*'),
    supabase.from('pay_sheet_lines').select('*, sheet:pay_sheets!inner(branch_id, status, paid_on)').eq('sheet.status', 'paid').gte('sheet.paid_on', from).lte('sheet.paid_on', to),
    supabase.from('staff').select('id, in_production_cost'),
  ]);
  if (d.error) throw d.error;
  const lines = (d.data || []).filter(x => inBranch(x.delivery.sale.branch_id));
  const exVat = x => (Number(x.line.total) ? Number(x.value) * Number(x.line.amount) / Number(x.line.total) : Number(x.value));
  const sales = sum(lines, exVat);
  const cost = sum(lines, 'cost');
  const noCost = lines.filter(x => x.cost == null).length;
  const estimated = sum(lines, 'estimated_cost');
  const skip = c => !c || c.in_production_cost || /electric|luku|umeme|wages|statutory/i.test(c.name);
  const byCat = {};
  for (const x of (e.data || []).filter(y => inBranch(y.branch_id))) {
    const c = (cat.data || []).find(k => k.id === x.category_id);
    if (skip(c)) continue;
    const r = (byCat[c.name] ||= { name: c.name, total: 0 });
    r.total += Number(x.amount);
  }
  const office = new Set((st.data || []).filter(s => !s.in_production_cost).map(s => s.id));
  const officePay = pay.error ? null : sum((pay.data || []).filter(l => inBranch(l.sheet.branch_id) && office.has(l.staff_id)),
    l => Number(l.gross ?? l.amount) + Number(l.nssf_employer || 0) + Number(l.wcf || 0) + Number(l.sdl || 0));
  const expenses = Object.values(byCat).sort((a, b) => b.total - a.total);
  const other = sum(expenses, 'total') + Number(officePay || 0);
  return { sales, cost, margin: sales - cost, noCost, estimated, expenses, officePay, net: sales - cost - other, deliveries: lines.length };
}

/** Each branch side by side: production, sales, purchases, expenses */
export async function loadBranches({ from, to, inBranch, branches }) {
  const [b, s, p, e] = await Promise.all([
    supabase.from('production_batches').select('branch_id, cement_bags, outputs:production_batch_outputs(is_primary, pieces_cast)').gte('batch_date', from).lte('batch_date', to).neq('status', 'void'),
    supabase.from('sales').select('branch_id, stage, sale_date, ordered_on, invoiced_on, total').in('stage', ['order', 'invoice']),
    supabase.from('purchases').select('id, branch_id').eq('status', 'recorded').gte('purchase_date', from).lte('purchase_date', to),
    supabase.from('expenses').select('branch_id, amount').eq('status', 'recorded').gte('expense_date', from).lte('expense_date', to),
  ]);
  if (b.error) throw b.error;
  const t = (p.data || []).length ? await supabase.from('purchase_totals').select('purchase_id, branch_id, total').in('purchase_id', (p.data || []).map(x => x.id)) : { data: [] };
  const dateOf = x => x.invoiced_on || x.ordered_on || x.sale_date;
  return branches.filter(br => inBranch(br.id)).map(br => {
    const bb = (b.data || []).filter(x => x.branch_id === br.id);
    return {
      id: br.id, name: br.name,
      batches: bb.length, bags: sum(bb, 'cement_bags'),
      pieces: sum(bb, x => sum((x.outputs || []).filter(o => o.is_primary), 'pieces_cast')),
      sales: sum((s.data || []).filter(x => x.branch_id === br.id && dateOf(x) >= from && dateOf(x) <= to), 'total'),
      purchases: sum((t.data || []).filter(x => x.branch_id === br.id), 'total'),
      expenses: sum((e.data || []).filter(x => x.branch_id === br.id), 'amount'),
    };
  });
}

/** An Excel file of one table: [head], rows, (total row) */
export async function exportTable(fileName, title, head, rows, total) {
  const ExcelJS = (await import('exceljs')).default;
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet(title.slice(0, 30));
  ws.addRow([title]).font = { bold: true };
  ws.addRow([]);
  ws.addRow(head).font = { bold: true };
  rows.forEach(r => ws.addRow(r));
  if (total) ws.addRow(total).font = { bold: true };
  ws.columns.forEach((c, i) => { c.width = i === 0 ? 32 : 16; });
  const buf = await wb.xlsx.writeBuffer();
  const url = URL.createObjectURL(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }));
  const a = document.createElement('a'); a.href = url; a.download = `${fileName}.xlsx`; document.body.appendChild(a); a.click(); a.remove();
  URL.revokeObjectURL(url);
}
