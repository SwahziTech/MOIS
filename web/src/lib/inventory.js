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
};

/** "Dodoma — Raw Materials Store" */
export const warehouseLabel = w => (w ? `${w.branch?.name ?? ''} — ${w.name}` : '—');

/** Item key used across inventory screens: 'm:<id>' or 'p:<id>' */
export const itemKey = row => (row.material_id ? `m:${row.material_id}` : `p:${row.product_id}`);

/** Reference data every inventory screen needs, in one round trip */
export async function loadInventoryRefs() {
  const [wh, mat, prod, units, sup] = await Promise.all([
    supabase.from('warehouses').select('id, name, type, status, branch_id, branch:branches(id, name, status)').order('name'),
    supabase.from('materials')
      .select('id, name, status, stock_unit_id, conversions:material_unit_conversions(unit_id, factor_to_stock_unit)')
      .order('name'),
    supabase.from('products').select('id, canonical_name, product_id_ref, status, unit_id, category:product_categories(name)').order('canonical_name'),
    supabase.from('units').select('id, symbol, name'),
    supabase.from('suppliers').select('id, name, status').order('name'),
  ]);
  const error = wh.error || mat.error || prod.error || units.error || sup.error;
  if (error) throw error;
  const warehouses = (wh.data || []).sort((a, b) =>
    (a.branch?.name || '').localeCompare(b.branch?.name || '') || a.name.localeCompare(b.name));
  const unitById = Object.fromEntries((units.data || []).map(u => [u.id, u]));
  const items = {};
  for (const m of mat.data || []) {
    items[`m:${m.id}`] = { key: `m:${m.id}`, kind: 'material', id: m.id, name: m.name, status: m.status,
      stockUnitId: m.stock_unit_id,
      units: m.stock_unit_id ? [{ id: m.stock_unit_id, factor: 1 }, ...m.conversions.map(c => ({ id: c.unit_id, factor: Number(c.factor_to_stock_unit) }))] : [] };
  }
  for (const p of prod.data || []) {
    items[`p:${p.id}`] = { key: `p:${p.id}`, kind: 'product', id: p.id, name: p.canonical_name, ref: p.product_id_ref,
      category: p.category?.name, status: p.status, stockUnitId: p.unit_id, units: [{ id: p.unit_id, factor: 1 }] };
  }
  return { warehouses, items, unitById, suppliers: sup.data || [] };
}

/** Trim a numeric for display: 2.5000 → 2.5 */
export const qtyText = n => (n == null ? '—' : new Intl.NumberFormat('en-US', { maximumFractionDigits: 4 }).format(Number(n)));
