#!/usr/bin/env node
/**
 * MOIS Cleanup Script — removes duplicate org from double seed run.
 * Keeps only the MOST RECENT organization (second run was the clean one).
 * SAFE: only deletes the older duplicate org and its cascading children.
 */
require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });
const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false } }
);

async function main() {
  const { data: orgs } = await supabase
    .from('organizations')
    .select('id, legal_name, created_at')
    .eq('legal_name', 'STUMARCOT CO LTD')
    .order('created_at');

  if (orgs.length <= 1) {
    console.log('Only one org found — nothing to clean up.');
    return;
  }

  console.log(`Found ${orgs.length} orgs:`);
  orgs.forEach(o => console.log(`  ${o.created_at} → ${o.id}`));

  // Keep the newest, delete the rest
  const toDelete = orgs.slice(0, orgs.length - 1);
  for (const org of toDelete) {
    console.log(`\nDeleting old org: ${org.id}`);
    // Delete in FK dependency order
    const tables = [
      'recipe_version_products', 'recipe_items', 'recipe_versions',
      'category_color_pricing_rules', 'product_branch_pricing',
      'products', 'product_categories',
      'materials', 'units',
      'user_roles', 'role_permissions', 'roles',
      'warehouses', 'branches',
      'profiles',
    ];
    for (const table of tables) {
      const { error } = await supabase.from(table).delete().eq('organization_id', org.id);
      if (error && !error.message.includes('does not exist')) {
        console.warn(`  ⚠ ${table}: ${error.message}`);
      } else {
        console.log(`  ✓ cleared ${table}`);
      }
    }
    const { error: orgErr } = await supabase.from('organizations').delete().eq('id', org.id);
    if (orgErr) console.warn(`  ⚠ org delete: ${orgErr.message}`);
    else console.log(`  ✓ deleted org ${org.id}`);
  }

  // Final counts
  console.log('\n=== FINAL ROW COUNTS (after cleanup) ===');
  const tables = [
    'organizations', 'branches', 'warehouses',
    'profiles', 'roles', 'permissions', 'role_permissions', 'user_roles',
    'units', 'materials',
    'product_categories', 'products', 'product_branch_pricing', 'category_color_pricing_rules',
    'recipe_versions', 'recipe_items', 'recipe_version_products',
  ];
  for (const table of tables) {
    const { count } = await supabase.from(table).select('*', { count: 'exact', head: true });
    console.log(`  ${table.padEnd(35)} ${String(count ?? '?').padStart(4)} rows`);
  }
  console.log('\n✅ Cleanup done.');
}

main().catch(err => { console.error('Cleanup failed:', err.message); process.exit(1); });
