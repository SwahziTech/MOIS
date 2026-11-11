/*
 * Advanced costing (2026-11-11, migration 118). Pure sums over costing_outputs() rows:
 *
 *   breakdown — a product's full cost a unit in four parts (materials, labour, electricity,
 *               overheads), the same parts as output_cost_per_unit(), so they add up to it;
 *   trend     — the same, month by month;
 *   standard  — what a product SHOULD cost, from the 3 months before (SwahziTech chose):
 *               materials = its recipe a cement bag × the average price paid for each material,
 *               labour / electricity / overheads = the branch's average a cement bag,
 *               yield = its average expected yield a bag;
 *   variance  — actual − standard for what was made, split by cause:
 *               material prices, materials used (vs the recipe), labour, electricity,
 *               overheads, yield. These add up exactly to the difference.
 *   rejects   — pieces that failed quality, at their full cost (a loss, apart from the variance).
 */
import { supabase } from './supabase';

const n = v => (v == null ? 0 : Number(v));
export const keyOf = r => `${r.product_id}|${r.color_id ?? ''}`;
const PARTS = ['material', 'labour', 'power', 'overhead'];
export const PART_LABEL = { material: 'Materials', labour: 'Labour', power: 'Electricity', overhead: 'Overheads' };

export async function loadOutputs(branchId, from, to) {
  const { data, error } = await supabase.rpc('costing_outputs', { p_branch: branchId, p_from: from, p_to: to });
  if (error) throw error;
  return (data || []).map(r => ({
    ...r,
    cement_share: n(r.cement_share), bags: n(r.bags),
    qty_cast: n(r.qty_cast), qty_passed: r.qty_passed == null ? null : n(r.qty_passed), qty_expected: r.qty_expected == null ? null : n(r.qty_expected),
    material: r.material == null ? null : n(r.material), labour: n(r.labour), power: n(r.power), overhead: n(r.overhead),
    materials: (r.materials || []).map(m => ({ id: m.material_id, used: n(m.used), recipe: n(m.recipe), cost: n(m.cost) })),
  }));
}

/** Totals for a set of rows (only outputs with a material cost — the rest aren't costed yet) */
export function totals(rows) {
  const t = { batches: new Set(), bags: 0, qtyCast: 0, qtyPassed: 0, qtyReleased: 0, qtyExpected: 0, material: 0, labour: 0, power: 0, overhead: 0, materials: {} };
  for (const r of rows) {
    if (r.material == null || !(r.qty_cast > 0)) continue;
    t.batches.add(r.batch_id);
    t.bags += r.bags; t.qtyCast += r.qty_cast; t.qtyExpected += r.qty_expected ?? 0;
    if (r.qty_passed != null) { t.qtyPassed += r.qty_passed; t.qtyReleased += r.qty_cast; }
    for (const p of PARTS) t[p] += r[p];
    for (const m of r.materials) {
      const x = (t.materials[m.id] ||= { used: 0, recipe: 0, cost: 0 });
      x.used += m.used; x.recipe += m.recipe; x.cost += m.cost;
    }
  }
  t.total = t.material + t.labour + t.power + t.overhead;
  t.count = t.batches.size;
  return t;
}

/** A cost a unit in its four parts */
export function perUnit(t) {
  if (!(t.qtyCast > 0)) return null;
  return Object.fromEntries([...PARTS, 'total'].map(p => [p, t[p] / t.qtyCast]));
}

/** Month by month (yyyy-mm) for one product and colour */
export function trend(rows) {
  const by = {};
  for (const r of rows) (by[r.batch_date.slice(0, 7)] ||= []).push(r);
  return Object.entries(by).sort(([a], [b]) => b.localeCompare(a))   // newest on top
    .map(([month, rs]) => { const t = totals(rs); return { month, made: t.qtyCast, batches: t.count, unit: perUnit(t) }; })
    .filter(x => x.unit);
}

/**
 * Standards from the rows of the 3 months before:
 *   price[material]    = cost ÷ quantity used (all products)
 *   conv[part]          = labour / electricity / overheads a cement bag (the branch, all products)
 *   byKey[product|colour] = { matPerBag (recipe × price), yieldPerBag, unit (cost a unit), parts }
 */
export function standards(rows) {
  const all = totals(rows);
  const price = {};
  for (const [id, m] of Object.entries(all.materials)) if (m.used > 0) price[id] = m.cost / m.used;
  const conv = all.bags > 0 ? { labour: all.labour / all.bags, power: all.power / all.bags, overhead: all.overhead / all.bags } : { labour: 0, power: 0, overhead: 0 };
  const groups = {};
  for (const r of rows) (groups[keyOf(r)] ||= []).push(r);
  const byKey = {};
  for (const [k, rs] of Object.entries(groups)) {
    const t = totals(rs);
    if (!(t.bags > 0) || !(t.qtyExpected > 0)) continue;
    let matPerBag = 0, priced = true;
    for (const [id, m] of Object.entries(t.materials)) {
      if (price[id] == null) { priced = false; continue; }
      matPerBag += (m.recipe / t.bags) * price[id];
    }
    const yieldPerBag = t.qtyExpected / t.bags;
    const parts = { material: matPerBag / yieldPerBag, labour: conv.labour / yieldPerBag, power: conv.power / yieldPerBag, overhead: conv.overhead / yieldPerBag };
    byKey[k] = { matPerBag, yieldPerBag, parts, unit: parts.material + parts.labour + parts.power + parts.overhead, batches: t.count, priced };
  }
  return { price, conv, byKey };
}

/**
 * Actual against standard for what was made (t = totals of the period's rows for one product+colour).
 * The causes add up to actual − standard exactly.
 */
export function variance(t, std, s) {
  if (!std || !(t.qtyCast > 0)) return null;
  const stdTotal = t.qtyCast * std.unit;
  let matPrice = 0, matUsage = 0, recipeMix = 0;
  for (const [id, m] of Object.entries(t.materials)) {
    const p = s.price[id] ?? (m.used > 0 ? m.cost / m.used : 0);   // no history: this period's own price (no price difference)
    matPrice += m.cost - m.used * p;
    matUsage += (m.used - m.recipe) * p;
    recipeMix += m.recipe * p;
  }
  recipeMix -= t.bags * std.matPerBag;   // a recipe that changed in between
  const causes = {
    matPrice,
    matUsage: matUsage + recipeMix,
    labour: t.labour - t.bags * s.conv.labour,
    power: t.power - t.bags * s.conv.power,
    overhead: t.overhead - t.bags * s.conv.overhead,
    yield: std.unit * (t.bags * std.yieldPerBag - t.qtyCast),
  };
  const rejectQty = Math.max(t.qtyReleased - t.qtyPassed, 0);
  return {
    stdTotal, actualTotal: t.total, diff: t.total - stdTotal,
    stdUnit: std.unit, actualUnit: t.total / t.qtyCast,
    causes,
    rejects: { qty: rejectQty, cost: rejectQty * (t.total / t.qtyCast) },
  };
}

export const CAUSE_LABEL = {
  matPrice: 'Material prices', matUsage: 'Materials used', labour: 'Labour', power: 'Electricity', overhead: 'Overheads', yield: 'Yield',
};
export const CAUSE_HELP = {
  matPrice: 'Paid more (+) or less (−) for the materials than their average over the 3 months before',
  matUsage: 'Used more (+) or less (−) material than the recipe calls for, at the average price',
  labour: 'Labour a cement bag above (+) or below (−) the 3-month average',
  power: 'Electricity a cement bag above (+) or below (−) the 3-month average',
  overhead: 'Production overheads a cement bag above (+) or below (−) the 3-month average',
  yield: 'Fewer (+) or more (−) pieces / m² from the bags than the usual yield',
};

/** The 3 full months before a period's first day: [from, to] */
export function standardWindow(from) {
  const d = new Date(`${from}T00:00:00Z`);
  const end = new Date(d); end.setUTCDate(end.getUTCDate() - 1);
  const start = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() - 3, 1));
  return [start.toISOString().slice(0, 10), end.toISOString().slice(0, 10)];
}
