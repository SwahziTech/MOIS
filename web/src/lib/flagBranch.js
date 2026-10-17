import { supabase } from './supabase';

// Review flags on branch-level records belong to that branch; flags on
// shared records (products, suppliers, name decisions, size specs, shared
// materials) belong to every branch. With a branch picked, screens show
// its flags plus the shared ones (decided 2026-10-17).
const BRANCH_TABLES = {
  branch_product:     'branch_products',
  material:           'materials',               // a branch's own material (032); NULL = shared
  product_price:      'product_branch_pricing',
  color_pricing_rule: 'category_color_pricing_rules',
};

/** Resolves to f => branch id of the flag's record, or null for a shared record */
export async function loadFlagBranches(flags) {
  const map = {};
  await Promise.all(Object.entries(BRANCH_TABLES).map(async ([type, table]) => {
    const ids = flags.filter(f => f.entity_type === type).map(f => f.entity_id);
    if (!ids.length) return;
    const { data } = await supabase.from(table).select('id, branch_id').in('id', ids);
    for (const r of data || []) map[`${type}:${r.id}`] = r.branch_id;
  }));
  return f => map[`${f.entity_type}:${f.entity_id}`] ?? null;
}
