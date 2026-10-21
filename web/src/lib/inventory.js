import { supabase } from './supabase';

/**
 * Inventory movement types (migration 022). Stock only ever changes by
 * posting one of these through post_inventory_movement(); there is no
 * screen that sets a stock number.
 */
export const MOVEMENT_TYPES = {
  receipt:         { label: 'Receive',         noun: 'Receipt',         perm: 'inventory.receive',
                     help: 'Goods arriving at a store, e.g. a delivery from a supplier.' },
  issue:           { label: 'Issue',           noun: 'Issue',           perm: 'inventory.issue',
                     help: 'Stock leaving a store for use, e.g. materials to production.' },
  transfer:        { label: 'Transfer',        noun: 'Transfer',        perm: 'inventory.transfer',
                     help: 'Moving stock from one store to another, in the same or another branch.' },
  adjustment:      { label: 'Adjust',          noun: 'Adjustment',      perm: 'inventory.adjust',
                     help: 'Correcting stock for a known reason, e.g. damage or loss. A reason is required.' },
  count:           { label: 'Count',           noun: 'Stock count',     perm: 'inventory.count',
                     help: 'Enter what you physically found; the difference to the records is posted.' },
  opening_balance: { label: 'Opening balance', noun: 'Opening balance', perm: 'inventory.adjust',
                     help: 'Stock already on hand when you start using MOIS — once per item per store.' },
  reversal:        { label: 'Reversal',        noun: 'Reversal',        perm: 'inventory.adjust', help: '' },
  // stock moved from one product to another when a name is resolved (migration 028)
  reclassification: { label: 'Reclassify',     noun: 'Reclassification', perm: 'products.manage', help: '' },
  // posted by production batches (migration 042), never from the stock forms
  production_use:    { label: 'Production use',    noun: 'Production use',      perm: 'production.create',   help: '' },
  production_output: { label: 'Into curing',       noun: 'Production — curing', perm: 'production.create',   help: '' },
  curing_release:    { label: 'Quality release',   noun: 'Quality release',     perm: 'production.complete', help: '' },
};

/**
 * Corrective stock entries — adjustments, opening balances, reversals, and
 * anything dated before today — need an org admin's approval unless the
 * user is one (migration 033). Receive, issue, transfer and counts don't.
 */
export const isCorrective = (type, date, today) =>
  ['adjustment', 'opening_balance', 'reversal'].includes(type) || (!!date && date < today);

/** "Dodoma — Raw Materials Store" */
export const warehouseLabel = w => (w ? `${w.branch?.name ?? ''} — ${w.name}` : '—');

/** Item key used across inventory screens: 'm:<id>' or 'p:<id>' */
export const itemKey = row => (row.material_id ? `m:${row.material_id}` : `p:${row.product_id}`);

/** Stock key: the item, plus its colour for coloured products (migration 024) */
export const stockKey = row => `${itemKey(row)}${row.color_id ? `|c:${row.color_id}` : ''}`;

/**
 * A product's colours, in order (046): its own list when an admin set one
 * (own_colors; empty = no colour), else its category's.
 * catColors: product_category_colors rows; ownColors: product_colors rows
 */
export function productColorIds(product, catColors = [], ownColors = []) {
  const rows = product?.own_colors
    ? ownColors.filter(c => c.product_id === product.id)
    : catColors.filter(c => c.category_id === product?.category_id);
  return [...rows].sort((a, b) => a.display_order - b.display_order).map(c => c.color_id);
}

/** Reference data every inventory screen needs, in one round trip */
export async function loadInventoryRefs() {
  const [wh, mat, prod, units, sup, cats, catRows, colors, bp, own] = await Promise.all([
    supabase.from('warehouses').select('id, name, type, status, branch_id, branch:branches(id, name, status)').order('name'),
    supabase.from('materials')
      .select('id, name, code, status, stock_unit_id, branch_id, category:material_categories(*), conversions:material_unit_conversions(unit_id, factor_to_stock_unit)')
      .order('name'),
    supabase.from('products').select('*, category:product_categories(name)').order('canonical_name'),
    supabase.from('units').select('id, symbol, name'),
    supabase.from('suppliers').select('id, name, status').order('name'),
    supabase.from('product_category_colors').select('category_id, color_id, display_order'),
    supabase.from('product_categories').select('id, name, parent_category_id, sort_order, status'),
    supabase.from('color_palette').select('id, name, display_order, is_active'),
    supabase.from('branch_products').select('branch_id, product_id').eq('status', 'active'),
    supabase.from('product_colors').select('product_id, color_id, display_order'),   // 046; none before it
  ]);
  const error = wh.error || mat.error || prod.error || units.error || sup.error || cats.error || catRows.error || colors.error || bp.error;
  if (error) throw error;
  const warehouses = (wh.data || []).sort((a, b) =>
    (a.branch?.name || '').localeCompare(b.branch?.name || '') || a.name.localeCompare(b.name));
  const unitById = Object.fromEntries((units.data || []).map(u => [u.id, u]));
  const items = {};
  for (const m of mat.data || []) {
    items[`m:${m.id}`] = { key: `m:${m.id}`, kind: 'material', id: m.id, name: m.name, code: m.code, status: m.status, branchId: m.branch_id,
      rank: m.category?.display_order ?? 999, materialCategory: m.category?.name ?? null,
      inRecipes: m.category?.used_in_recipes !== false,
      stockUnitId: m.stock_unit_id,
      units: m.stock_unit_id ? [{ id: m.stock_unit_id, factor: 1 }, ...m.conversions.map(c => ({ id: c.unit_id, factor: Number(c.factor_to_stock_unit) }))] : [] };
  }
  // "Paving Blocks › Vibro" for a category under a group (038)
  const catById = Object.fromEntries((catRows.data || []).map(c => [c.id, c]));
  const catLabel = id => { const c = catById[id]; const g = c?.parent_category_id && catById[c.parent_category_id]; return c ? (g ? `${g.name} › ${c.name}` : c.name) : null; };
  for (const p of prod.data || []) {
    items[`p:${p.id}`] = { key: `p:${p.id}`, kind: 'product', id: p.id, name: p.canonical_name, ref: p.product_id_ref, size: p.size_cm,
      category: catLabel(p.category_id) ?? p.category?.name, categoryId: p.category_id, status: p.status, stockUnitId: p.unit_id, units: [{ id: p.unit_id, factor: 1 }],
      // coloured products are stocked per colour: the product's own colours, else its category's (046)
      colorIds: productColorIds(p, cats.data || [], own.error ? [] : own.data || []) };
  }
  const colorById = Object.fromEntries((colors.data || []).map(c => [c.id, c]));
  // each branch's own catalogue (031): product ids it carries
  const carriedByBranch = {};
  for (const r of bp.data || []) (carriedByBranch[r.branch_id] ||= new Set()).add(r.product_id);
  return { warehouses, items, unitById, colorById, suppliers: sup.data || [], carriedByBranch, categoryRows: catRows.data || [] };
}

/** Trim a numeric for display: 2.5000 → 2.5 */
export const qtyText = n => (n == null ? '—' : new Intl.NumberFormat('en-US', { maximumFractionDigits: 4 }).format(Number(n)));

/** Today's date (YYYY-MM-DD) in the organization's time zone */
export function orgToday(timezone) {
  try { return new Intl.DateTimeFormat('en-CA', { timeZone: timezone || 'UTC' }).format(new Date()); }
  catch { return new Date().toISOString().slice(0, 10); }
}

// --- Supplier names --------------------------------------------------------
// Same rule as the database's unique index (migration 023): case, spaces and
// punctuation don't make a different supplier.
export const normalizeName = s => String(s ?? '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');

// For suggestions only: company-form words don't distinguish suppliers
const FORM_WORDS = /\b(ltd|limited|co|company|plc|inc|corp|enterprises?|group|the|and)\b/g;
const core = s => normalizeName(String(s ?? '').toLowerCase().replace(/&/g, ' and ').replace(/[.,]/g, ' ').replace(FORM_WORDS, ' '));

function similarity(a, b) {
  if (!a || !b) return 0;
  const prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    let diag = prev[0];
    prev[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const tmp = prev[j];
      prev[j] = Math.min(prev[j] + 1, prev[j - 1] + 1, diag + (a[i - 1] === b[j - 1] ? 0 : 1));
      diag = tmp;
    }
  }
  return 1 - prev[b.length] / Math.max(a.length, b.length);
}

/**
 * Existing suppliers matching a typed name: { exact, similar[] }. exact is
 * the same name ignoring case/spacing/punctuation (the database refuses a
 * second one); similar are likely the same supplier written differently.
 */
export function matchSuppliers(typed, suppliers) {
  const n = normalizeName(typed);
  if (!n) return { exact: null, similar: [] };
  const exact = suppliers.find(s => normalizeName(s.name) === n) ?? null;
  const c = core(typed);
  const similar = suppliers
    .filter(s => s !== exact)
    .map(s => {
      const sc = core(s.name);
      const score = Math.max(similarity(c, sc),
        c.length >= 3 && sc.length >= 3 && (sc.includes(c) || c.includes(sc)) ? 0.85 : 0);
      return { supplier: s, score };
    })
    .filter(x => x.score >= 0.75)
    .sort((a, b) => b.score - a.score)
    .slice(0, 4)
    .map(x => x.supplier);
  return { exact, similar };
}

/**
 * The order materials appear in everywhere — recipes, batches, tables,
 * pickers (decided 2026-10-20): by their material category's order
 * (Materials → categories: Cement, Sand, Dust, Chipping, Kokoto, Dawa,
 * Rangi, … Steel), then by name. Items: { rank, name }.
 */
export const byMaterialOrder = (a, b) => (a.rank ?? 999) - (b.rank ?? 999) || String(a.name).localeCompare(String(b.name));
