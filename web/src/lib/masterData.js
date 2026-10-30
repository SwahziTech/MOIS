import { supabase } from './supabase';
import { datesInText } from './format';

/**
 * Shared helpers for every master-data screen (products, materials,
 * categories, palette, recipes, prices, ...). The rules themselves —
 * permissions, audit trail, deactivate-only — are enforced in the database
 * (migration 018); these only make them readable in the UI.
 */

/** entity_type values used by audit_log / review_flags → readable labels */
export const ENTITY_LABELS = {
  product: 'Product',
  product_category: 'Product category',
  product_category_color: 'Category colour',
  color: 'Colour',
  material: 'Material',
  material_category: 'Material category',
  material_unit_conversion: 'Unit conversion',
  material_source: 'Material source',
  unit: 'Unit',
  recipe_version: 'Recipe',
  recipe_item: 'Recipe ingredient',
  recipe_product: 'Recipe product link',
  product_price: 'Price',
  color_pricing_rule: 'Colour pricing rule',
  color_price: 'Colour price',
  review_flag: 'Review flag',
  supplier: 'Supplier',
  import_alias: 'Import name match',
  identity_decision: 'Name match',
  production_batch: 'Production batch',
};

/** A message safe to show the user, for an error from a master-data write. */
export function dbErrorMessage(err, fallback = "We couldn't save this change. Please try again.") {
  if (!err) return fallback;
  console.error(err);
  switch (err.code) {
    case '23505': return 'That name is already in use here. Choose a different one.';
    case '42501':
      if (/deactivate/i.test(err.message || '')) return 'Records cannot be deleted — deactivate them instead.';
      // Postgres' own access errors are not user-facing; our functions' messages are
      return !err.message || /row-level security|permission denied for/i.test(err.message)
        ? "You don't have permission to change this."
        : datesInText(err.message);
    case '23514': return err.message && !/violates check constraint/i.test(err.message)
      ? datesInText(err.message)                      // our own trigger messages are user-facing
      : 'That value is not allowed here.';
    case '23503': return 'This is still used elsewhere, so it cannot be changed this way.';
    default: return fallback;
  }
}

/** Activate / deactivate any master record that has a status column. */
export async function setStatus(table, id, status) {
  const { error } = await supabase.from(table).update({ status }).eq('id', id);
  if (error) throw new Error(dbErrorMessage(error));
}

/** Lowercase identifier from a name, e.g. 'Floor Tiles' → 'floor_tiles' */
export function slugify(name) {
  return String(name).normalize('NFKD').toLowerCase()
    .replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'item';
}

/** Compact display of a value stored in audit_log (jsonb) */
export function auditValue(v) {
  if (v == null) return '—';
  if (typeof v === 'string') {
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v) ? `ref …${v.slice(-6)}` : v;
  }
  if (typeof v === 'object') return '(record)';
  return String(v);
}
