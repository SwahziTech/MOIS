import { supabase } from './supabase';
import { stockKey, qtyText, warehouseLabel } from './inventory';

/*
 * Double entries (2026-10-17). The ledger accepts the same stock twice —
 * e.g. an item's opening balance entered again in another store. The app
 * spots likely repeats before posting, and lists the ones already posted,
 * and asks the user what is right. Fixes are ordinary posted movements
 * (reversal / adjustment / opening balance), so the history stays complete.
 */

const LINE_COLS = 'id, movement_id, warehouse_id, branch_id, material_id, product_id, color_id, quantity, stock_unit_id, transaction_type, transaction_date, created_at';
export const DOUBLE_ENTRY_FLAG = 'stock_double_entry';

/** Ledger lines that still count: not reversal lines, not in a reversed movement */
async function liveLines(build) {
  const [lines, rev] = await Promise.all([
    build(supabase.from('inventory_transactions').select(LINE_COLS)),
    supabase.from('inventory_movements').select('reverses_movement_id').not('reverses_movement_id', 'is', null),
  ]);
  if (lines.error) throw lines.error;
  if (rev.error) throw rev.error;
  const reversed = new Set((rev.data || []).map(r => r.reverses_movement_id));
  return (lines.data || []).filter(l => l.transaction_type !== 'reversal' && !reversed.has(l.movement_id));
}

/** movement id → number of lines in it (a one-line movement is undone by reversing it) */
async function lineCounts(movementIds) {
  if (!movementIds.length) return {};
  const { data, error } = await supabase.from('inventory_transactions').select('movement_id').in('movement_id', movementIds);
  if (error) throw error;
  const n = {};
  for (const r of data || []) n[r.movement_id] = (n[r.movement_id] || 0) + 1;
  return n;
}

const itemFilter = lines => {
  const mats = [...new Set(lines.filter(l => l.material_id).map(l => l.material_id))];
  const prods = [...new Set(lines.filter(l => l.product_id).map(l => l.product_id))];
  return [mats.length && `material_id.in.(${mats.join(',')})`, prods.length && `product_id.in.(${prods.join(',')})`].filter(Boolean).join(',');
};

/**
 * Before posting: what in the ledger this entry may repeat.
 *  - opening balance: the item already has one at the store's branch (any store)
 *  - receipt / issue / transfer / adjustment: same item, store, date and quantity
 * lines: [{ idx, material_id | product_id, color_id, qty }] — qty in the stock unit, signed as posted
 * Returns [{ idx, existing: [ledger line, …] }]
 */
export async function findRepeats({ type, warehouse, date, lines }) {
  if (type === 'count' || !lines.length || !warehouse) return [];
  const txType = type === 'transfer' ? 'transfer_out' : type;
  const existing = await liveLines(q => {
    q = q.eq('branch_id', warehouse.branch_id).eq('transaction_type', txType).or(itemFilter(lines));
    return type === 'opening_balance' ? q : q.eq('warehouse_id', warehouse.id).eq('transaction_date', date);
  });
  return lines.map(l => ({
    idx: l.idx,
    existing: existing.filter(e => stockKey(e) === stockKey(l)
      && (type === 'opening_balance' || Math.abs(Number(e.quantity) - l.qty) < 1e-9))
      .sort((a, b) => a.created_at.localeCompare(b.created_at)),
  })).filter(f => f.existing.length);
}

/**
 * Already posted: items with more than one opening balance at a branch,
 * except those someone has already looked at (a closed review flag on the
 * same set of entries). Returns [{ key, branchId, entries: [line + lineCount] }]
 */
export async function findOpeningDuplicates() {
  const [lines, flags] = await Promise.all([
    liveLines(q => q.eq('transaction_type', 'opening_balance')),
    supabase.from('review_flags').select('entity_id').eq('entity_type', DOUBLE_ENTRY_FLAG).neq('status', 'open'),
  ]);
  const seen = new Set((flags.data || []).map(f => f.entity_id));
  const groups = {};
  for (const l of lines) (groups[`${l.branch_id}|${stockKey(l)}`] ||= []).push(l);
  const dups = Object.entries(groups)
    .filter(([, es]) => es.length > 1 && !seen.has(entriesId(es)))
    .map(([key, es]) => ({ key, branchId: es[0].branch_id, entries: es.sort((a, b) => a.created_at.localeCompare(b.created_at)) }));
  const counts = await lineCounts([...new Set(dups.flatMap(d => d.entries.map(e => e.movement_id)))]);
  for (const d of dups) for (const e of d.entries) e.lineCount = counts[e.movement_id] || 1;
  return dups;
}

export const entriesId = es => es.map(e => e.id).sort().join(',');

/**
 * The movements that make an item's opening stock at a branch = qty in one
 * store: the entry already in that store is adjusted to qty; the others are
 * undone (reversed when alone in their movement, else adjusted away); with
 * none in that store, an opening balance is posted there.
 */
export function planOpeningFix({ entries, item, colorId, target, whById, reason }) {
  const steps = [];
  const kept = entries.find(e => e.warehouse_id === target.warehouseId);
  const line = qty => ({
    [item.kind === 'material' ? 'material_id' : 'product_id']: item.id,
    ...(colorId ? { color_id: colorId } : {}), quantity: qty, unit_id: item.stockUnitId,
  });
  const sym = target.unitSymbol ?? '';
  for (const e of entries) {
    if (e === kept) continue;
    if (e.lineCount === 1) {
      steps.push({ kind: 'reverse', movementId: e.movement_id, reason,
        summary: `Reverse the opening balance of ${e.transaction_date} at ${warehouseLabel(whById[e.warehouse_id])} (${qtyText(e.quantity)} ${sym} ${item.name}) — ${reason}` });
    } else {
      steps.push({ kind: 'movement', payload: { type: 'adjustment', warehouse_id: e.warehouse_id, movement_date: e.transaction_date, reason, lines: [line(-Number(e.quantity))] },
        summary: `Adjustment at ${warehouseLabel(whById[e.warehouse_id])}, dated ${e.transaction_date}: remove ${qtyText(e.quantity)} ${sym} ${item.name} — ${reason}` });
    }
  }
  if (kept) {
    const diff = target.qty - Number(kept.quantity);
    if (Math.abs(diff) > 1e-9) {
      steps.push({ kind: 'movement', payload: { type: 'adjustment', warehouse_id: kept.warehouse_id, movement_date: kept.transaction_date, reason, lines: [line(diff)] },
        summary: `Adjustment at ${warehouseLabel(whById[kept.warehouse_id])}, dated ${kept.transaction_date}: ${diff > 0 ? 'add' : 'remove'} ${qtyText(Math.abs(diff))} ${sym} ${item.name} — ${reason}` });
    }
  } else if (target.qty > 0) {
    const date = entries.map(e => e.transaction_date).sort()[0];
    steps.push({ kind: 'movement', payload: { type: 'opening_balance', warehouse_id: target.warehouseId, movement_date: date, reason, lines: [line(target.qty)] },
      summary: `Opening balance at ${warehouseLabel(whById[target.warehouseId])}, dated ${date}: ${qtyText(target.qty)} ${sym} ${item.name} — ${reason}` });
  }
  return steps;
}

/**
 * Post the steps — or, for someone without stock-adjustment rights across
 * the organization, send each to the Approvals queue like any correction (033).
 * Returns { sent: n sent for approval, posted: n posted }; throws on the first error.
 */
export async function runSteps(steps, viaApproval) {
  let sent = 0, posted = 0;
  for (const s of steps) {
    let res;
    if (viaApproval) {
      res = s.kind === 'reverse'
        ? await supabase.rpc('request_change', { p_kind: 'stock_reversal', p_branch_id: null, p_payload: { movement_id: s.movementId, reason: s.reason }, p_summary: s.summary })
        : await supabase.rpc('request_change', { p_kind: 'stock_movement', p_branch_id: null, p_payload: s.payload, p_summary: s.summary });
      if (!res.error) sent++;
    } else {
      res = s.kind === 'reverse'
        ? await supabase.rpc('reverse_inventory_movement', { p_movement_id: s.movementId, p_reason: s.reason })
        : await supabase.rpc('post_inventory_movement', { p: s.payload });
      if (!res.error) posted++;
    }
    if (res.error) throw Object.assign(res.error, { sent, posted });
  }
  return { sent, posted };
}

/** Remember that someone looked at a set of entries (so the alert doesn't come back) */
export async function closeDoubleEntry({ organizationId, entries, status, note, reason }) {
  const { data: { user } } = await supabase.auth.getUser();
  return supabase.from('review_flags').insert({
    organization_id: organizationId, entity_type: DOUBLE_ENTRY_FLAG, entity_id: entriesId(entries),
    reason_code: 'possible_double_entry', reason, status,
    created_by: user?.id, resolved_by: user?.id, resolved_at: new Date().toISOString(), resolution_note: note,
  });
}
