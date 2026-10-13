#!/usr/bin/env node
/**
 * MOIS Phase 1a — Stumarcot Seed Script
 *
 * SERVICE ROLE KEY RULES:
 *   - Read from .env (plain file, server-side only)
 *   - NEVER from .env.local or any VITE_-prefixed variable
 *   - NEVER committed to git (.env is in .gitignore)
 *
 * Reads data files AS-IS — no reshaping, renaming, or reinterpreting:
 *   - assets/docs/Stumarcot/product_master.json
 *   - assets/docs/Stumarcot/ratios_and_molds.json
 *   - assets/docs/Stumarcot/price_list_structured.json
 *
 * Creates (idempotent — safe to re-run):
 *   - Stumarcot organization (looked up by legal_name before inserting)
 *   - 3 branches: Mwanza, Dar es Salaam, Dodoma
 *   - 3 warehouses per branch (raw_materials, finished_goods, general)
 *   - System roles + permission assignments
 *   - Units
 *   - Product categories + products (from product_master.json;
 *     wastani_per_bag filled from ratios_and_molds.json molds/items)
 *   - Materials (from ratios_and_molds.json ingredient names)
 *   - Recipe versions + items (shared per category+color, per AGENTS.md §3)
 *   - Product branch pricing (from price_list_structured.json)
 *   - One seed admin user (SEED_ADMIN_EMAIL / SEED_ADMIN_PASSWORD from .env)
 *
 * Usage:
 *   node seed.js            write to the database
 *   node seed.js --plan     print the recipe plan only (no DB access)
 *
 * Organizations edited in the app are protected: once anyone has changed an
 * organization's data in the app (an audit_log row recorded as an app
 * change), the app is that organization's source of truth and this script
 * refuses to run against it — re-seeding would overwrite those edits with the
 * JSON files (e.g. reactivate merged products, recreate moved prices). The
 * only override is passing this flag explicitly; nothing passes it by default:
 *   node seed.js --force-reseed-org-with-app-edits
 */

const path = require('path');
const fs   = require('fs');

// --- Load data files -------------------------------------------------------
const DOCS = path.join(__dirname, '..', 'assets', 'docs', 'Stumarcot');
const productMaster       = JSON.parse(fs.readFileSync(path.join(DOCS, 'product_master.json'), 'utf8'));
const ratiosMolds         = JSON.parse(fs.readFileSync(path.join(DOCS, 'ratios_and_molds.json'), 'utf8'));
const priceListStructured = JSON.parse(fs.readFileSync(path.join(DOCS, 'price_list_structured.json'), 'utf8'));
const materialsMaster     = JSON.parse(fs.readFileSync(path.join(DOCS, 'materials_master.json'), 'utf8'));
const {
  MATERIAL_UNITS, unitSymbolFor, resolveMaterialRef, isUnpigmented, buildMaterialPlan, productReviewFlags,
} = require('./lib/materials');

let supabase; // created in main() — not needed for --plan

const OVERRIDE_FLAG = '--force-reseed-org-with-app-edits';

/**
 * Refuse to seed an organization whose data has been edited in the app,
 * unless OVERRIDE_FLAG is passed. Fails closed: if the check can't run, the
 * seed doesn't either.
 */
async function refuseIfEditedInApp(org) {
  const { count, error } = await supabase
    .from('audit_log')
    .select('id', { count: 'exact', head: true })
    .eq('organization_id', org.id)
    .eq('changed_via', 'app');
  if (error) throw new Error(`Could not check for app edits (audit_log): ${error.message} — not seeding.`);
  if (!count) return;

  const changes = `${count} change${count === 1 ? '' : 's'}`;
  if (!process.argv.includes(OVERRIDE_FLAG)) {
    console.error(
      `\nREFUSED: ${org.name} (${org.id}) has ${changes} made in the app (audit_log).\n` +
      'Its data is now maintained in the app, not in the JSON files. Re-seeding would overwrite\n' +
      'those edits (e.g. reactivate merged products, recreate moved prices, rewrite recipe history).\n\n' +
      'Make the change in the app instead. Nothing was written.\n\n' +
      `To overwrite app edits anyway (rarely right), pass ${OVERRIDE_FLAG} explicitly.`
    );
    process.exit(2);
  }
  console.warn(`  ⚠ ${OVERRIDE_FLAG}: seeding over ${changes} made in the app for ${org.name}.`);
}

// --------------------------------------------------------------------------
async function main() {
  // --- Load env (service role key from .env only, never .env.local) --------
  require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

  const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY } = process.env;
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    console.error('ERROR: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set in .env');
    process.exit(1);
  }

  const { createClient } = require('@supabase/supabase-js');

  // Service role client — bypasses RLS for seeding purposes
  supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
  });

  console.log('=== MOIS Phase 1a Seed — Stumarcot ===\n');

  // =========================================================================
  // 1. ORGANIZATION
  //    organizations has no natural unique key, so look it up first —
  //    inserting blindly is what created the duplicate org on the 2nd run.
  // =========================================================================
  console.log('1. Organization...');
  const LEGAL_NAME = 'STUMARCOT CO LTD';
  const { data: existingOrgs, error: findErr } = await supabase
    .from('organizations')
    .select('id, name')
    .eq('legal_name', LEGAL_NAME)
    .order('created_at');
  if (findErr) throw new Error(`Organization lookup failed: ${findErr.message}`);

  if (existingOrgs.length > 1) {
    throw new Error(
      `${existingOrgs.length} organizations named '${LEGAL_NAME}' exist. ` +
      'Resolve the duplicate (scripts/cleanup_duplicate_org.js) before re-seeding.'
    );
  }

  let org = existingOrgs[0];
  if (org) {
    console.log(`  ↳ Already exists: ${org.name} (${org.id})`);
    await refuseIfEditedInApp(org);   // before any write
  } else {
    const { data: inserted, error: orgErr } = await supabase
      .from('organizations')
      .insert({
        name:       'Stumarcot',
        legal_name: LEGAL_NAME,
        brand_config: {
          primary_color: '#B7A57A',
          accent_color:  '#4B3621',
          font:          'Google Sans',
        },
        status: 'active'
      })
      .select('id, name')
      .single();
    if (orgErr) throw new Error(`Organization insert failed: ${orgErr.message}`);
    org = inserted;
    console.log(`  ↳ Created: ${org.name} (${org.id})`);
  }

  // Tenant setting: Stumarcot prices in Tanzanian shillings (price list "TSH").
  // Tenant configuration: money in TZS; "today" for the stock ledger is Tanzanian time (023)
  const { error: curErr } = await supabase.from('organizations')
    .update({ currency_code: 'TZS', timezone: 'Africa/Dar_es_Salaam' }).eq('id', org.id);
  if (curErr) throw new Error(`Currency update failed: ${curErr.message}`);

  await seedWithOrg(org);
}

async function seedWithOrg(org) {
  const orgId = org.id;

  // =========================================================================
  // 2. BRANCHES
  // =========================================================================
  console.log('\n2. Creating branches...');
  const branchDefs = [
    { name: 'Mwanza',        location: 'Mwanza, Tanzania' },
    { name: 'Dar es Salaam', location: 'Dar es Salaam, Tanzania' },
    { name: 'Dodoma',        location: 'Dodoma, Tanzania' },
  ];

  const branches = {};
  for (const b of branchDefs) {
    const { data: existing } = await supabase
      .from('branches')
      .select('id, name')
      .eq('organization_id', orgId)
      .eq('name', b.name)
      .maybeSingle();
    if (existing) {
      branches[b.name] = existing;
      console.log(`  ↳ Already exists: ${b.name} (${existing.id})`);
    } else {
      const { data: inserted, error } = await supabase
        .from('branches')
        .insert({ ...b, organization_id: orgId, status: 'active' })
        .select('id, name')
        .single();
      if (error) throw new Error(`Branch insert failed: ${error.message}`);
      branches[b.name] = inserted;
      console.log(`  ↳ Created: ${inserted.name} (${inserted.id})`);
    }
  }

  // =========================================================================
  // 3. WAREHOUSES (3 per branch)
  // =========================================================================
  console.log('\n3. Creating warehouses...');
  const warehouseTypes = [
    { name: 'Raw Materials Store', type: 'raw_materials' },
    { name: 'Finished Goods Store', type: 'finished_goods' },
    { name: 'General Store', type: 'general' },
  ];

  let warehouseCount = 0;
  for (const branch of Object.values(branches)) {
    for (const wt of warehouseTypes) {
      const { data: existing } = await supabase
        .from('warehouses')
        .select('id')
        .eq('organization_id', orgId)
        .eq('branch_id', branch.id)
        .eq('name', wt.name)
        .maybeSingle();
      if (!existing) {
        const { error } = await supabase
          .from('warehouses')
          .insert({ ...wt, organization_id: orgId, branch_id: branch.id, status: 'active' });
        if (error) throw new Error(`Warehouse insert failed: ${error.message}`);
        warehouseCount++;
      }
    }
  }
  console.log(`  ↳ ${warehouseCount} warehouses created (3 × ${Object.keys(branches).length} branches)`);

  // =========================================================================
  // 4. SYSTEM ROLES + PERMISSION ASSIGNMENTS
  // =========================================================================
  console.log('\n4. Creating system roles...');
  const systemRoles = [
    {
      name: 'owner',
      description: 'Organization owner — full access to all modules and settings',
      permissions: ['org.manage','users.invite','users.manage','branches.manage','warehouses.manage',
                    'products.view','products.manage','materials.view','materials.manage',
                    'inventory.view','inventory.receive','inventory.issue','inventory.transfer',
                    'inventory.adjust','inventory.count',
                    'procurement.view','procurement.request','procurement.approve','procurement.order','procurement.receive',
                    'production.view','production.create','production.execute','production.complete',
                    'sales.view','sales.create','invoices.create','payments.record',
                    'reports.view','reports.financial'],
    },
    {
      name: 'branch_manager',
      description: 'Branch / factory manager — branch-scoped operational access',
      // No master-data management: build-plan 1a.1 makes that org-admin only
      permissions: ['products.view','materials.view',
                    'inventory.view','inventory.receive','inventory.issue','inventory.transfer','inventory.adjust','inventory.count',
                    'procurement.view','procurement.request','procurement.approve',
                    'production.view','production.create','production.execute','production.complete',
                    'sales.view','sales.create','reports.view'],
    },
    {
      name: 'storekeeper',
      description: 'Storekeeper / inventory user — warehouse-scoped inventory transactions',
      permissions: ['products.view','materials.view',
                    'inventory.view','inventory.receive','inventory.issue','inventory.transfer','inventory.count'],
    },
    {
      name: 'production_user',
      description: 'Production user — production execution and consumption recording',
      permissions: ['products.view','materials.view',
                    'inventory.view','inventory.issue',
                    'production.view','production.create','production.execute','production.complete'],
    },
    {
      name: 'sales_user',
      description: 'Sales / administrative user — catalogue, quotations, invoices, payments',
      permissions: ['products.view','inventory.view',
                    'sales.view','sales.create','invoices.create','payments.record','reports.view'],
    },
  ];

  // Load all permissions into a code→id map
  const { data: allPerms, error: permErr } = await supabase.from('permissions').select('id, code');
  if (permErr) throw new Error(`Permissions load failed: ${permErr.message}`);
  const permByCode = Object.fromEntries(allPerms.map(p => [p.code, p.id]));

  for (const roleDef of systemRoles) {
    const missing = roleDef.permissions.filter(code => !permByCode[code]);
    if (missing.length) console.warn(`  ⚠ Role '${roleDef.name}': unknown permission codes ${missing.join(', ')}`);

    let roleRow;
    const { data: existingRole } = await supabase
      .from('roles')
      .select('id')
      .eq('organization_id', orgId)
      .eq('name', roleDef.name)
      .maybeSingle();

    if (existingRole) {
      roleRow = existingRole;
    } else {
      const { data: newRole, error } = await supabase
        .from('roles')
        .insert({ organization_id: orgId, name: roleDef.name, description: roleDef.description, is_system_role: true })
        .select('id')
        .single();
      if (error) throw new Error(`Role insert failed: ${error.message}`);
      roleRow = newRole;
    }

    // Assign permissions
    const permRows = roleDef.permissions
      .filter(code => permByCode[code])
      .map(code => ({ role_id: roleRow.id, permission_id: permByCode[code] }));
    if (permRows.length) {
      const { error } = await supabase
        .from('role_permissions')
        .upsert(permRows, { onConflict: 'role_id,permission_id', ignoreDuplicates: true });
      if (error) throw new Error(`role_permissions upsert failed: ${error.message}`);
    }
    // System roles are MOIS-defined: drop permissions no longer in the definition
    const wanted = permRows.map(r => r.permission_id);
    let extraQuery = supabase.from('role_permissions').delete().eq('role_id', roleRow.id);
    if (wanted.length) extraQuery = extraQuery.not('permission_id', 'in', `(${wanted.join(',')})`);
    const { data: removedPerms, error: rmErr } = await extraQuery.select('permission_id');
    if (rmErr) throw new Error(`role_permissions cleanup failed: ${rmErr.message}`);
    console.log(`  ↳ Role '${roleDef.name}' — ${permRows.length} permissions${removedPerms.length ? `, ${removedPerms.length} removed` : ''}`);
  }

  // =========================================================================
  // 5. UNITS
  // =========================================================================
  console.log('\n5. Creating units...');
  const unitDefs = [
    { symbol: 'bag',    name: 'Cement Bag (50kg)',        notes: '1 bag = 50kg cement' },
    { symbol: 'bucket', name: 'Bucket / Ndoo (10L/20kg)', notes: '1 ndoo = 10L = ~20kg for sand/chip/kokoto/dust' },
    { symbol: 'kg',     name: 'Kilogram',                 notes: null },
    { symbol: 'L',      name: 'Litre',                    notes: null },
    { symbol: 'SQM',    name: 'Square Metre',             notes: 'Coverage unit for tiles and paving' },
    { symbol: 'PCS',    name: 'Pieces',                   notes: 'Count unit for curbstones, culverts, matofali, posts' },
    { symbol: 'm',      name: 'Metre',                    notes: null },
    ...Object.entries(MATERIAL_UNITS).map(([symbol, u]) => ({ symbol, ...u })),
  ];
  for (const u of unitDefs) {
    const { data: existing } = await supabase
      .from('units')
      .select('id')
      .eq('organization_id', orgId)
      .eq('symbol', u.symbol)
      .maybeSingle();
    if (!existing) {
      const { error } = await supabase
        .from('units')
        .insert({ ...u, organization_id: orgId });
      if (error) throw new Error(`Unit insert failed: ${error.message}`);
    }
  }
  const { data: unitsRows } = await supabase
    .from('units')
    .select('id, symbol')
    .eq('organization_id', orgId);
  const unitBySymbol = Object.fromEntries(unitsRows.map(u => [u.symbol, u.id]));
  console.log(`  ↳ ${unitsRows.length} units`);

  // =========================================================================
  // 6. MATERIALS (from materials_master.json — as-is)
  //    Global: category, stock unit, unit conversions. Per branch: sources.
  //    No stock or price: those come from 1b's ledger transactions.
  // =========================================================================
  console.log('\n6. Materials...');
  const materialPlan = buildMaterialPlan(materialsMaster, Object.keys(branches));

  const { data: matCatData, error: matCatErr } = await supabase
    .from('material_categories')
    .upsert(materialPlan.categories.map((name, i) => ({ organization_id: orgId, name, display_order: i + 1 })),
            { onConflict: 'organization_id,name' })
    .select('id, name');
  if (matCatErr) throw new Error(`Material categories upsert failed: ${matCatErr.message}`);
  const materialCategoryByName = Object.fromEntries(matCatData.map(c => [c.name, c.id]));

  const { data: materialData, error: materialErr } = await supabase
    .from('materials')
    .upsert(materialPlan.materials.map(m => ({
      organization_id: orgId,
      material_id_ref: m.ref,
      name:            m.name,
      category_id:     materialCategoryByName[m.category],
      stock_unit_id:   m.stockUnit ? requireUnit(unitBySymbol, m.stockUnit, `material ${m.ref}`) : null,
      notes:           m.notes,
      status:          'active',
    })), { onConflict: 'organization_id,material_id_ref' })
    .select('id, material_id_ref');
  if (materialErr) throw new Error(`Materials upsert failed: ${materialErr.message}`);
  const materialByRef = Object.fromEntries(materialData.map(m => [m.material_id_ref, m.id]));

  if (materialPlan.conversions.length) {
    const { error } = await supabase
      .from('material_unit_conversions')
      .upsert(materialPlan.conversions.map(c => ({
        organization_id:      orgId,
        material_id:          materialByRef[c.ref],
        unit_id:              requireUnit(unitBySymbol, c.unit, `conversion for ${c.ref}`),
        factor_to_stock_unit: c.factor,
        notes:                c.notes,
      })), { onConflict: 'material_id,unit_id' });
    if (error) throw new Error(`Unit conversions upsert failed: ${error.message}`);
  }

  if (materialPlan.sources.length) {
    const { error } = await supabase
      .from('material_branch_sources')
      .upsert(materialPlan.sources.map(src => ({
        organization_id:  orgId,
        material_id:      materialByRef[src.ref],
        branch_id:        branches[src.branch]?.id ?? (() => { throw new Error(`Unknown branch '${src.branch}'`); })(),
        source_name:      src.sourceName,
        purchase_unit_id: src.purchaseUnit ? requireUnit(unitBySymbol, src.purchaseUnit, `source for ${src.ref}`) : null,
        is_primary:       src.isPrimary,
        notes:            src.notes,
      })), { onConflict: 'material_id,branch_id,source_name' });
    if (error) throw new Error(`Material sources upsert failed: ${error.message}`);
  }

  // Materials no longer in the file are retired once no active recipe uses them
  const { data: liveMaterials } = await supabase
    .from('materials').select('id, material_id_ref, name, status').eq('organization_id', orgId);
  for (const m of liveMaterials.filter(x => x.status === 'active' && !materialByRef[x.material_id_ref])) {
    const { count } = await supabase
      .from('recipe_items')
      .select('id, recipe_versions!inner(status)', { count: 'exact', head: true })
      .eq('material_id', m.id)
      .eq('recipe_versions.status', 'active');
    if (count) { console.warn(`  ⚠ ${m.name} is not in materials_master.json but ${count} active recipe line(s) still use it`); continue; }
    const { error } = await supabase.from('materials').update({ status: 'inactive' }).eq('id', m.id);
    if (error) throw new Error(`Material retire failed [${m.name}]: ${error.message}`);
    console.log(`  ↳ Marked inactive (no longer in materials_master.json): ${m.name}`);
  }
  console.log(`  ↳ ${materialData.length} materials, ${materialPlan.categories.length} categories, ` +
              `${materialPlan.conversions.length} unit conversions, ${materialPlan.sources.length} branch sources`);

  // =========================================================================
  // 7. PRODUCT CATEGORIES (from product_master.json — as-is)
  // =========================================================================
  console.log('\n7. Colour palette and product categories...');

  // Palette: every colour named in the categories' colour columns, under its
  // canonical name (canonColor), in first-appearance order. Colours already
  // in the palette — including ones an admin added — are left as they are.
  const colourOrder = [];
  for (const cat of productMaster.categories) {
    for (const c of cat.color_columns || []) {
      const name = canonColor(c);
      if (!colourOrder.includes(name)) colourOrder.push(name);
    }
  }
  const { data: paletteRows, error: palErr } = await supabase
    .from('color_palette').select('id, name').eq('organization_id', orgId);
  if (palErr) throw new Error(`Palette load failed: ${palErr.message}`);
  const paletteByName = Object.fromEntries(paletteRows.map(c => [c.name, c.id]));
  for (const [i, name] of colourOrder.entries()) {
    if (paletteByName[name]) continue;
    const { data: inserted, error } = await supabase
      .from('color_palette')
      .insert({ organization_id: orgId, name, display_order: i + 1 })
      .select('id').single();
    if (error) throw new Error(`Palette insert failed [${name}]: ${error.message}`);
    paletteByName[name] = inserted.id;
  }
  const colourId = name => {
    const id = paletteByName[canonColor(name)];
    if (!id) throw new Error(`Colour '${name}' is not in the palette`);
    return id;
  };
  console.log(`  ↳ palette: ${colourOrder.join(', ')}`);

  // Categories: upserted so name, order and suggested unit follow the file.
  // (A category whose id_ref changes must be renamed in place beforehand —
  // see scripts/one-off — or it would be created anew.)
  const categoryRows = productMaster.categories.map((cat, i) => ({
    organization_id: orgId,
    category_id_ref: cat.category_id,
    name:            cat.name || cat.category_id.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase()),
    display_format:  cat.display_format,
    // Suggested unit for new products in this category (migration 015)
    default_unit_id: requireUnit(unitBySymbol, cat.stock_unit, `category ${cat.category_id}`),
    sort_order:      i,
  }));
  const { data: catData, error: catErr } = await supabase
    .from('product_categories')
    .upsert(categoryRows, { onConflict: 'organization_id,category_id_ref' })
    .select('id, category_id_ref');
  if (catErr) throw new Error(`Category upsert failed: ${catErr.message}`);
  const categoryMap = Object.fromEntries(catData.map(c => [c.category_id_ref, c.id])); // category_id_ref → DB uuid

  // Colours each category comes in (adds missing links; never removes ones
  // an admin added)
  const categoryColourRows = productMaster.categories.flatMap(cat =>
    (cat.color_columns || []).map((c, i) => ({
      organization_id: orgId,
      category_id:     categoryMap[cat.category_id],
      color_id:        colourId(c),
      display_order:   i + 1,
    })));
  if (categoryColourRows.length) {
    const { error } = await supabase
      .from('product_category_colors')
      .upsert(categoryColourRows, { onConflict: 'category_id,color_id', ignoreDuplicates: true });
    if (error) throw new Error(`Category colours upsert failed: ${error.message}`);
  }
  console.log(`  ↳ ${Object.keys(categoryMap).length} categories, ${categoryColourRows.length} category colours`);

  // =========================================================================
  // 8. PRODUCTS (from product_master.json — as-is, nulls preserved)
  //    wastani_per_bag is recipe-yield data that lives in ratios_and_molds.json
  //    (molds[].wastani_per_bag / items[].wastani_per_bag). product_master only
  //    carries it for press paving, so fill the rest from ratios_and_molds.
  //    Upsert so a re-run brings existing rows up to date.
  // =========================================================================
  console.log('\n8. Upserting products...');
  const yieldSource = buildYieldLookup(ratiosMolds);
  const productRows = [];

  for (const cat of productMaster.categories) {
    for (const p of cat.products) {
      const mold = yieldSource.byId[p.product_id] ||
                   yieldSource.byName[`${cat.category_id}|${p.canonical_name}`] || null;
      const masterYield = p.wastani_per_bag ?? null;
      const moldYield   = mold?.wastani_per_bag ?? null;
      if (masterYield != null && moldYield != null && masterYield !== moldYield) {
        console.warn(`  ⚠ wastani_per_bag conflict for ${p.product_id}: product_master=${masterYield}, ratios_and_molds=${moldYield} — using product_master`);
      }
      productRows.push({
        organization_id: orgId,
        category_id:     categoryMap[cat.category_id],
        product_id_ref:  p.product_id,
        canonical_name:  p.canonical_name,
        // Stock unit is fixed per product (AGENTS.md §3); product_master sets it per category
        unit_id:         requireUnit(unitBySymbol, p.stock_unit ?? cat.stock_unit, `product ${p.product_id}`),
        size_cm:         p.size_cm != null ? String(p.size_cm) : null,
        pcs_per_sqm:     p.pcs_per_sqm ?? null,
        wastani_per_bag: masterYield ?? moldYield,
        notes:           p.note || null,
        status:          'active',
      });
    }
  }

  const { data: productData, error: productErr } = await supabase
    .from('products')
    .upsert(productRows, { onConflict: 'organization_id,product_id_ref' })
    .select('id, product_id_ref');
  if (productErr) throw new Error(`Product upsert failed: ${productErr.message}`);
  const productMap = Object.fromEntries(productData.map(p => [p.product_id_ref, p.id]));
  const withYield = productRows.filter(r => r.wastani_per_bag != null).length;
  console.log(`  ↳ ${productData.length} products (${withYield} with wastani_per_bag)`);

  // Products the master no longer lists (e.g. culverts_400 after the N/R
  // split) are marked inactive — kept for history, never deleted.
  const masterRefs = productRows.map(r => r.product_id_ref);
  const { data: retired, error: retireErr } = await supabase
    .from('products')
    .update({ status: 'inactive' })
    .eq('organization_id', orgId)
    .eq('status', 'active')
    .not('product_id_ref', 'in', `(${masterRefs.map(r => `"${r}"`).join(',')})`)
    .select('product_id_ref');
  if (retireErr) throw new Error(`Product retire failed: ${retireErr.message}`);
  for (const r of retired) console.log(`  ↳ Marked inactive (no longer in product_master): ${r.product_id_ref}`);

  // =========================================================================
  // 9. RECIPE VERSIONS + ITEMS
  //    Shared per category + color (AGENTS.md §3) — see buildRecipePlan().
  // =========================================================================
  console.log('\n9. Creating recipe versions and items...');
  const plan = buildRecipePlan(productMaster, ratiosMolds);
  let recipeVersionCount = 0;
  let recipeItemCount    = 0;
  let recipeProductLinks = 0;
  let archivedCount      = 0;

  // A recipe label that names one of its category's colours is a colour
  // recipe (color_id); anything else is a named variant (variant_label).
  const categoryColours = Object.fromEntries(productMaster.categories.map(c =>
    [c.category_id, new Set((c.color_columns || []).map(canonColor))]));
  const recipeKey = recipe => {
    const name = canonColor(recipe.colorLabel);
    return categoryColours[recipe.categoryRef]?.has(name)
      ? { color_id: colourId(name), variant_label: null, display: name }
      : { color_id: null, variant_label: recipe.colorLabel, display: recipe.colorLabel };
  };

  for (const recipe of plan) {
    const catDbId = categoryMap[recipe.categoryRef];
    const key = recipeKey(recipe);

    let rvQuery = supabase
      .from('recipe_versions')
      .select('id')
      .eq('organization_id', orgId)
      .eq('category_id', catDbId)
      .eq('version_number', 1);
    rvQuery = key.color_id
      ? rvQuery.eq('color_id', key.color_id).is('variant_label', null)
      : rvQuery.is('color_id', null).eq('variant_label', key.variant_label);
    const { data: existingRV } = await rvQuery.maybeSingle();

    let rvId;
    if (existingRV) {
      rvId = existingRV.id;
    } else {
      const { data: rv, error } = await supabase
        .from('recipe_versions')
        .insert({
          organization_id: orgId,
          category_id:     catDbId,
          color_id:        key.color_id,
          variant_label:   key.variant_label,
          version_number:  1,
          effective_date:  '2026-09-27',
          status:          'active',
          notes:           recipe.notes,
        })
        .select('id')
        .single();
      if (error) throw new Error(`RecipeVersion insert failed [${recipe.categoryRef}/${recipe.colorLabel}]: ${error.message}`);
      rvId = rv.id;
      recipeVersionCount++;
    }

    // Insert recipe items (ingredients)
    for (const comp of recipe.components) {
      const ingredientCtx = { colour: key.color_id ? key.display : null, sandRef: recipe.sandRef };
      if (isUnpigmented(comp, ingredientCtx)) continue; // White: no pigment by design
      const materialRef = resolveMaterialRef(comp, ingredientCtx);
      if (!materialRef) {
        console.warn(`  ⚠ Unknown material '${comp.material}' in ${recipe.categoryRef}/${key.display}`);
        continue;
      }
      const matId  = materialByRef[materialRef];
      const unitSymbol = unitSymbolFor(comp.unit);
      const unitId = unitSymbol ? requireUnit(unitBySymbol, unitSymbol, `recipe ${recipe.categoryRef}/${key.display}`) : null;
      if (!matId) throw new Error(`Recipe ${recipe.categoryRef}/${key.display} uses '${materialRef}', which is not in materials_master.json`);

      const { data: existingItem } = await supabase
        .from('recipe_items')
        .select('id')
        .eq('recipe_version_id', rvId)
        .eq('material_id', matId)
        .maybeSingle();

      if (!existingItem) {
        const { error } = await supabase
          .from('recipe_items')
          .insert({
            recipe_version_id:   rvId,
            material_id:         matId,
            quantity:            comp.quantity ?? 0,
            unit_id:             unitId,
            quantity_confirmed:  comp.quantity !== null,
            notes:               null,
          });
        if (error) throw new Error(`RecipeItem insert failed: ${error.message}`);
        recipeItemCount++;
      }
    }

    // Link the products that use this recipe
    for (const productRef of recipe.productRefs) {
      const productDbId = productMap[productRef];
      if (!productDbId) continue;

      const { data: existingLink } = await supabase
        .from('recipe_version_products')
        .select('recipe_version_id')
        .eq('recipe_version_id', rvId)
        .eq('product_id', productDbId)
        .maybeSingle();

      if (!existingLink) {
        const { error } = await supabase
          .from('recipe_version_products')
          .insert({ recipe_version_id: rvId, product_id: productDbId });
        if (error) throw new Error(`RecipeVersionProduct insert failed: ${error.message}`);
        recipeProductLinks++;
      }
    }
  }

  // Archive v1 recipes this seed created earlier under labels the plan no
  // longer produces (e.g. the old incomplete 'Red (add-on)' paving rows).
  // Archiving keeps the history; nothing is deleted.
  const expectedByCategory = {};
  for (const r of plan) (expectedByCategory[r.categoryRef] ||= new Set()).add(recipeKey(r).display);
  for (const [categoryRef, labels] of Object.entries(expectedByCategory)) {
    const { data: activeRVs } = await supabase
      .from('recipe_versions')
      .select('id, variant_label, color:color_palette(name)')
      .eq('organization_id', orgId)
      .eq('category_id', categoryMap[categoryRef])
      .eq('version_number', 1)
      .eq('status', 'active');
    for (const rv of activeRVs || []) {
      const label = rv.color?.name ?? rv.variant_label;
      if (labels.has(label)) continue;
      const { error } = await supabase.from('recipe_versions').update({ status: 'archived' }).eq('id', rv.id);
      if (error) throw new Error(`RecipeVersion archive failed [${categoryRef}/${label}]: ${error.message}`);
      console.log(`  ↳ Archived stale recipe ${categoryRef}/${label}`);
      archivedCount++;
    }
  }
  console.log(`  ↳ ${recipeVersionCount} recipe versions, ${recipeItemCount} items, ${recipeProductLinks} product links, ${archivedCount} archived`);

  // =========================================================================
  // 10. PRODUCT BRANCH PRICING (from price_list_structured.json — as-is)
  //     canonical_match=null rows skipped (not confirmed — per AGENTS.md)
  //     Genuine per-branch price differences preserved
  // =========================================================================
  console.log('\n10. Seeding product branch pricing...');
  let pricingRows = 0;
  let colorRuleRows = 0;
  const unmatched = [];
  const nameMatched = [];
  const held = [];
  const noPrice = [];
  const collisions = [];
  const pricedBy = {}; // productId|branchId → price-list row that priced it this run

  const branchByName = Object.fromEntries(Object.entries(branches).map(([name, b]) => [name, b.id]));

  for (const priceCat of priceListStructured.categories) {
    // Seed category-level color pricing rules
    if (priceCat.color_pricing_by_branch) {
      const catDbId = findCategoryForPriceCategory(priceCat, categoryMap);
      for (const [branchName, colorRule] of Object.entries(priceCat.color_pricing_by_branch)) {
        if (!colorRule) continue; // category sold in one color only
        if (!catDbId) {
          console.warn(`  ⚠ No product category mapped for price section '${priceCat.category_raw}' — color rule skipped`);
          break;
        }
        const branchId = branchByName[branchName];
        if (!branchId) continue;

        const { data: existingRule } = await supabase
          .from('category_color_pricing_rules')
          .select('id')
          .eq('organization_id', orgId)
          .eq('category_id', catDbId)
          .eq('branch_id', branchId)
          .maybeSingle();

        if (!existingRule) {
          if (!colorRule.base_color) {
            console.warn(`  ⚠ Color rule [${priceCat.category_raw}/${branchName}] names no base colour — skipped`);
            continue;
          }
          const { data: rule, error } = await supabase
            .from('category_color_pricing_rules')
            .insert({
              organization_id: orgId,
              category_id:     catDbId,
              branch_id:       branchId,
              base_color_id:   colourId(colorRule.base_color),
              pricing_type:    PRICING_TYPE[colorRule.pricing_type] ?? colorRule.pricing_type,
              raw_notes:       colorRule.raw_notes || null,
            })
            .select('id').single();
          if (error) { console.warn(`  ⚠ Color rule insert failed [${priceCat.category_raw}/${branchName}]: ${error.message}`); continue; }
          const items = Object.entries(colorRule.other_colors || {}).map(([colour, amount]) => ({
            organization_id: orgId, rule_id: rule.id, color_id: colourId(colour), amount,
          }));
          if (items.length) {
            const { error: itemErr } = await supabase.from('category_color_price_items').insert(items);
            if (itemErr) throw new Error(`Color price items insert failed [${priceCat.category_raw}/${branchName}]: ${itemErr.message}`);
          }
          colorRuleRows++;
        }
      }
    }

    // Seed per-product pricing
    for (const product of priceCat.products) {
      // canonical_match is an object { category_id, product_id, canonical_name } or null.
      // Fallback for null: confirmed name/alias (CULVERTS, PAVING BLOCKS (PRESS)).
      let productRef = product.canonical_match?.product_id;
      if (!productRef) {
        productRef = matchByConfirmedName(priceCat, product, productMaster);
        if (productRef) nameMatched.push(`${priceCat.category_raw}: ${product.description_raw.trim()} → ${productRef}`);
      }
      if (productRef && PRICING_ON_HOLD[productRef]) {
        held.push(`${productRef} (${product.description_raw.trim()}): ${PRICING_ON_HOLD[productRef]}`);
        continue;
      }
      if (!productRef) {
        unmatched.push(`${priceCat.category_raw}: ${product.description_raw}${product.size_mm ? ` (${product.size_mm})` : ''}`);
        continue; // not confirmed — per AGENTS.md: never fill a null by guessing
      }

      const productDbId = productMap[productRef];
      if (!productDbId) {
        console.warn(`  ⚠ product_id '${productRef}' not found in products`);
        unmatched.push(`${priceCat.category_raw}: ${product.description_raw}`);
        continue;
      }

      for (const [branchName, pricing] of Object.entries(product.available_in_branches || {})) {
        const branchId = branchByName[branchName];
        if (!branchId) continue;

        // No price recorded for this branch: leave it unpriced (to be filled
        // in later), never an empty price row
        if (pricing.price_inclusive == null && pricing.price_exclusive == null && pricing.price_per_sqmt == null) {
          noPrice.push(`${productRef} / ${branchName} (${product.description_raw.trim()})`);
          continue;
        }

        // Two price-list rows for one product+branch can't both be the base
        // price — report it instead of silently keeping whichever came first
        const pairKey = `${productDbId}|${branchId}`;
        const thisRow = `${priceCat.category_raw}: ${product.description_raw.trim()} #${pricing.item_no}`;
        if (pricedBy[pairKey] && pricedBy[pairKey] !== thisRow) {
          collisions.push(`${productRef} / ${branchName}: '${pricedBy[pairKey]}' and '${thisRow}' — second not seeded`);
          continue;
        }
        pricedBy[pairKey] = thisRow;

        // The price list carries no per-row colour: every row is the base
        // price, stored as color_id = NULL. Other colours come from
        // category_color_pricing_rules.
        const { data: existingPricing } = await supabase
          .from('product_branch_pricing')
          .select('id')
          .eq('product_id', productDbId)
          .eq('branch_id', branchId)
          .is('color_id', null)
          .maybeSingle();
        if (existingPricing) continue;

        const { error } = await supabase
          .from('product_branch_pricing')
          .insert({
            organization_id:                  orgId,
            product_id:                       productDbId,
            branch_id:                        branchId,
            color_id:                         null,
            price_per_unit_exclusive:         pricing.price_exclusive ?? null,
            vat_per_unit:                     pricing.vat ?? null,
            price_per_unit_inclusive:         pricing.price_inclusive ?? null,
            price_per_sqm_inclusive:          pricing.price_per_sqmt ?? null,
            pcs_per_sqm_at_pricing:           pricing.pcs_per_sqmt_or_unit ?? null,
            is_available:                     true,
            price_consistent_across_branches: product.price_consistent_across_branches ?? true,
            source_item_no:                   pricing.item_no ?? null,
            raw_notes:                        product.description_raw || null,
          });
        if (error) {
          console.warn(`  ⚠ Pricing insert failed [${productRef}/${branchName}]: ${error.message}`);
        } else {
          pricingRows++;
        }
      }
    }
  }
  console.log(`  ↳ ${pricingRows} pricing rows, ${colorRuleRows} color rules`);
  for (const [title, list] of [
    ['price rows ON HOLD (not seeded)', held],
    ['branch entries with no price in the source (left unpriced)', noPrice],
    ['PRICE COLLISIONS (two price-list rows → one product+branch)', collisions],
  ]) {
    if (!list.length) continue;
    console.log(`  ↳ ${list.length} ${title}:`);
    for (const m of list) console.log(`      - ${m}`);
  }
  if (nameMatched.length) {
    console.log(`  ↳ ${nameMatched.length} price-list rows matched by confirmed name/alias:`);
    for (const m of nameMatched) console.log(`      - ${m}`);
  }
  if (unmatched.length) {
    console.log(`  ↳ ${unmatched.length} price-list rows skipped — no confirmed canonical_match (confirm with SwahziTech):`);
    for (const u of unmatched) console.log(`      - ${u}`);
  }

  // =========================================================================
  // 10b. REVIEW FLAGS — gaps the source files themselves mark as unresolved
  //      Raised once: a flag an admin resolved or dismissed is not re-opened.
  // =========================================================================
  console.log('\n10b. Review flags...');
  const flagsWanted = [
    ...materialPlan.flags.map(f => ({ entity: f.entity, id: materialByRef[f.ref], code: f.code, reason: f.reason })),
    ...productReviewFlags(productMaster).map(f => ({ entity: f.entity, id: productMap[f.ref], code: f.code, reason: f.reason })),
  ];
  let flagsRaised = 0;
  for (const f of flagsWanted) {
    if (!f.id) throw new Error(`Review flag for unknown ${f.entity}`);
    const { data: existingFlag } = await supabase
      .from('review_flags')
      .select('id')
      .eq('organization_id', orgId)
      .eq('entity_type', f.entity)
      .eq('entity_id', String(f.id))
      .eq('reason_code', f.code)
      .limit(1)
      .maybeSingle();
    if (existingFlag) continue;
    const { error } = await supabase.from('review_flags').insert({
      organization_id: orgId, entity_type: f.entity, entity_id: String(f.id), reason_code: f.code, reason: f.reason,
    });
    if (error) throw new Error(`Review flag insert failed [${f.entity}/${f.code}]: ${error.message}`);
    flagsRaised++;
  }
  console.log(`  ↳ ${flagsWanted.length} review flags wanted, ${flagsRaised} newly raised`);

  // =========================================================================
  // 11. SEED ADMIN USER
  //     Credentials come from .env — never hardcode them here.
  // =========================================================================
  console.log('\n11. Seed admin user...');
  const ADMIN_EMAIL = process.env.SEED_ADMIN_EMAIL;
  const ADMIN_PASS  = process.env.SEED_ADMIN_PASSWORD;

  let adminUserId;
  if (!ADMIN_EMAIL) {
    console.warn('  ⚠ SEED_ADMIN_EMAIL not set in .env — skipping admin user');
  } else {
    adminUserId = await findUserIdByEmail(ADMIN_EMAIL);
    if (adminUserId) {
      console.log(`  ↳ Admin user already exists: ${ADMIN_EMAIL} (${adminUserId})`);
    } else if (!ADMIN_PASS) {
      console.warn('  ⚠ SEED_ADMIN_PASSWORD not set in .env — cannot create admin user');
    } else {
      const { data: adminUser, error: userErr } = await supabase.auth.admin.createUser({
        email:          ADMIN_EMAIL,
        password:       ADMIN_PASS,
        email_confirm:  true, // mark as confirmed (dev mode — skip email verification)
        user_metadata:  { first_name: 'MOIS', last_name: 'Admin' },
      });
      if (userErr) throw new Error(`Admin user creation failed: ${userErr.message}`);
      adminUserId = adminUser.user.id;
      console.log(`  ↳ Created admin user: ${ADMIN_EMAIL} (${adminUserId})`);
    }
  }

  // Associate admin user with Stumarcot org
  if (adminUserId) {
    const { error: profileErr } = await supabase
      .from('profiles')
      .update({ organization_id: orgId })
      .eq('id', adminUserId);
    if (profileErr) throw new Error(`Profile org association failed: ${profileErr.message}`);

    // Assign 'owner' role
    const { data: ownerRole } = await supabase
      .from('roles')
      .select('id')
      .eq('organization_id', orgId)
      .eq('name', 'owner')
      .single();
    if (ownerRole) {
      const { data: existingGrant } = await supabase
        .from('user_roles')
        .select('id')
        .eq('user_id', adminUserId)
        .eq('role_id', ownerRole.id)
        .eq('organization_id', orgId)
        .is('branch_id', null)
        .is('warehouse_id', null)
        .maybeSingle();
      if (existingGrant) {
        console.log(`  ↳ Admin already has 'owner' role`);
      } else {
        const { error: urErr } = await supabase
          .from('user_roles')
          .insert({ user_id: adminUserId, role_id: ownerRole.id, organization_id: orgId });
        if (urErr) console.warn(`  ⚠ user_roles insert: ${urErr.message}`);
        else console.log(`  ↳ Assigned 'owner' role to admin`);
      }
    }
  }

  // =========================================================================
  // 12. ROW COUNT REPORT (this organization only)
  // =========================================================================
  console.log('\n=== CHECKPOINT — Row Counts (this org) ===');
  const tables = [
    'branches', 'warehouses', 'profiles', 'roles', 'user_roles',
    'units', 'materials',
    'product_categories', 'products', 'product_branch_pricing', 'category_color_pricing_rules',
    'recipe_versions',
  ];
  for (const table of tables) {
    const { count } = await supabase
      .from(table)
      .select('*', { count: 'exact', head: true })
      .eq('organization_id', orgId);
    console.log(`  ${table.padEnd(35)} ${String(count ?? '?').padStart(4)} rows`);
  }
  console.log('\n✅ Seed complete.');
}

// --- Recipe plan -----------------------------------------------------------

/**
 * Turns ratios_and_molds.json into one entry per recipe_version to create:
 *   { categoryRef, colorLabel, notes, components[], productRefs[] }
 *
 * - Categories with `ratios` (tiles, paving, curbstones, ...): one recipe per
 *   ratio, linked to every product in that product_master category except
 *   products that carry their own press mix (ratiosMolds items).
 *   Labels marked '(add-on)' are pigment additions on top of the '(base)'
 *   ratio ("Color additions on top of white base, per bag of cement"), so
 *   they are combined with the base components.
 * - Press machine `items` carry their own ratio per product and map onto two
 *   product_master categories (bricks/kerbstones and paving). Items with an
 *   identical mix share one recipe (AGENTS.md §3), labelled by the mix.
 */
function buildRecipePlan(productMaster, ratiosMolds) {
  const productsByCategory = {};
  const categoryOfProduct  = {};
  for (const cat of productMaster.categories) {
    productsByCategory[cat.category_id] = cat.products.map(p => p.product_id);
    for (const p of cat.products) categoryOfProduct[p.product_id] = cat.category_id;
  }

  // Products with their own per-item mix (press machine items) never take a
  // category's shared recipe — e.g. press kerbstones filed under Curbstones
  // must not also get the vibro curbstone 'Standard' ratio.
  const ownMixProducts = new Set(
    ratiosMolds.categories.flatMap(c => (c.items || []).map(i => i.item_id)));

  const plan = [];
  for (const ratCat of ratiosMolds.categories) {
    if (Array.isArray(ratCat.ratios)) {
      const productRefs = productsByCategory[ratCat.category_id]?.filter(ref => !ownMixProducts.has(ref));
      if (!productRefs) {
        console.warn(`  ⚠ ratios category '${ratCat.category_id}' has no product_master category — skipped`);
        continue;
      }
      const base = ratCat.ratios.find(r => /\(base\)/i.test(r.label || ''));
      for (const ratio of ratCat.ratios) {
        const isAddOn = /\(add-on\)/i.test(ratio.label || '');
        if (isAddOn && !base) {
          console.warn(`  ⚠ ${ratCat.category_id}/${ratio.label} is an add-on but the category has no base ratio — skipped`);
          continue;
        }
        plan.push({
          categoryRef: ratCat.category_id,
          colorLabel:  cleanRatioLabel(ratio.label),
          notes:       isAddOn
            ? [`Base ratio '${base.label}' plus this color's pigment.`, ratio.notes].filter(Boolean).join(' ')
            : ratio.notes || null,
          components:  mergeComponents(isAddOn ? [...base.components, ...ratio.components] : ratio.components),
          productRefs,
          sandRef:     ratCat.sand_material_id ?? null,
        });
      }
    } else if (Array.isArray(ratCat.items)) {
      const groups = new Map();
      for (const item of ratCat.items) {
        const categoryRef = categoryOfProduct[item.item_id];
        if (!categoryRef) {
          console.warn(`  ⚠ ${ratCat.category_id} item '${item.item_id}' is not in product_master — skipped`);
          continue;
        }
        if (!Array.isArray(item.ratio) || item.ratio.length === 0) {
          console.warn(`  ⚠ ${item.item_id} (${item.name}) has no ratio in ratios_and_molds.json — no recipe created`);
          continue;
        }
        const label = mixLabel(item.ratio);
        const key = `${categoryRef}|${label}`;
        if (!groups.has(key)) groups.set(key, { categoryRef, label, components: item.ratio, items: [] });
        groups.get(key).items.push(item);
      }
      for (const g of groups.values()) {
        const sands = [...new Set(g.items.map(i => i.sand_material_id ?? null))];
        if (sands.length > 1) {
          throw new Error(`Mix '${g.label}' in ${g.categoryRef} is shared by items with different sands: ${sands.join(', ')}`);
        }
        plan.push({
          categoryRef: g.categoryRef,
          colorLabel:  g.label,
          notes:       `${ratCat.name} mix shared by: ${g.items.map(i => i.name).join(', ')}.`,
          components:  mergeComponents(g.components),
          productRefs: g.items.map(i => i.item_id),
          sandRef:     sands[0],
        });
      }
    }
  }
  return plan;
}

/** 'White (base)' → 'White', 'Red (add-on)' → 'Red', missing → 'Plain' */
function cleanRatioLabel(label) {
  const clean = (label || '').replace(/\s*\((base|add-on)\)\s*$/i, '').trim();
  return clean || 'Plain';
}

/** Deterministic label for a press mix, e.g. 'Cem 1 : Mch 40 : Chip 14' */
function mixLabel(components) {
  const short = { cement: 'Cem', mchanga: 'Mch', chip: 'Chip', kokoto: 'Kok', dust: 'Dust', dawa: 'Dawa', rangi: 'Rangi' };
  return components.map(c => `${short[c.material] || c.material} ${c.quantity ?? '?'}`).join(' : ');
}

/** recipe_items is unique per (version, material) — refuse silent double-counting. */
function mergeComponents(components) {
  const seen = new Set();
  const out = [];
  for (const c of components) {
    const code = String(c.material || '').toLowerCase();
    if (seen.has(code)) {
      console.warn(`  ⚠ Material '${c.material}' appears twice in one recipe — second entry ignored`);
      continue;
    }
    seen.add(code);
    out.push(c);
  }
  return out;
}

/** product_id → mold/item (ids match between the two files), with a name fallback. */
function buildYieldLookup(ratiosMolds) {
  const byId = {};
  const byName = {};
  for (const cat of ratiosMolds.categories) {
    for (const m of cat.molds || []) {
      byId[m.mold_id] = m;
      byName[`${cat.category_id}|${m.name}`] = m;
    }
    for (const it of cat.items || []) byId[it.item_id] = it;
  }
  return { byId, byName };
}

// --- Helpers ---------------------------------------------------------------

function requireUnit(unitBySymbol, symbol, what) {
  const id = unitBySymbol[symbol];
  if (!id) throw new Error(`No unit '${symbol}' in this organization's units table (needed by ${what})`);
  return id;
}

async function findUserIdByEmail(email) {
  const target = email.toLowerCase();
  for (let page = 1; ; page++) {
    const { data, error } = await supabase.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw new Error(`listUsers failed: ${error.message}`);
    const hit = data.users.find(u => (u.email || '').toLowerCase() === target);
    if (hit) return hit.id;
    if (data.users.length < 1000) return null;
  }
}

// Products whose price-list rows must NOT be seeded until a pending
// confirmation arrives. Existing prices for them are left untouched.
const PRICING_ON_HOLD = {
  // (empty — trench_covers_01 released 2026-10-12: Stumarcot confirmed 11,500)
};

// price_list_structured.json still uses the pre-migration-016 rule name
const PRICING_TYPE = {
  delta_per_sqmt_over_offwhite: 'delta_over_base_color',
};

// Tenant colour naming (Stumarcot, confirmed 2026-10-12): the source files
// spell the base colour 'White', 'OffWhite' and 'White/OffWhite' — one
// colour, named 'White'. Other names are used as written.
const COLOUR_ALIASES = { 'White/OffWhite': 'White', 'OffWhite': 'White' };
function canonColor(name) {
  const clean = String(name ?? '').replace(/\s*\((base|add-on)\)\s*$/i, '').trim();
  return COLOUR_ALIASES[clean] ?? clean;
}

// Price-list sections whose rows SwahziTech confirmed on 2026-10-12 map to
// product_master products by name/alias (the price list itself still has
// canonical_match = null for them). Other sections are never name-matched.
const NAME_MATCH_SECTIONS = {
  'CULVERTS':              'culverts',
  'PAVING BLOCKS (PRESS)': 'press_machine_paving',
};

/**
 * Splits a name like 'Rectangular (30-35MPa, 8cm)', 'Paving Zigzag 30MPa (6cm)'
 * or a price row 'ZIGZAG (30 Mpa)' + '210*100*60mm' into
 * { family, grade, thickness }. grade/thickness are null when not stated.
 */
function nameSignature(text, sizeMm) {
  const s = (text || '').toLowerCase();
  const grade = s.match(/(\d+(?:\s*-\s*\d+)?)\s*mpa/)?.[1].replace(/\s/g, '') ?? null;
  let thickness = s.match(/(\d+)\s*cm\b/)?.[1] ?? null;
  if (!thickness && sizeMm) {
    const mm = String(sizeMm).match(/(\d+(?:\.\d+)?)\s*mm\s*$/i)?.[1];
    if (mm) thickness = String(Number(mm) / 10);
  }
  const family = s
    .replace(/\([^)]*\)/g, ' ')
    .replace(/\d+(?:\s*-\s*\d+)?\s*mpa/g, ' ')
    .replace(/\d+\s*cm\b/g, ' ')
    .replace(/\bpaving\b/g, ' ')
    .replace(/[^a-z0-9]/g, '');
  return { family, grade, thickness };
}

/** product_id for a price row in a confirmed section, or null if not exactly one match. */
function matchByConfirmedName(priceCat, row, productMaster) {
  const categoryRef = NAME_MATCH_SECTIONS[(priceCat.category_raw || '').trim().toUpperCase()];
  if (!categoryRef) return null;
  const cat = productMaster.categories.find(c => c.category_id === categoryRef);
  const target = nameSignature(row.description_raw, row.size_mm);
  if (!cat || !target.family) return null;

  const hits = new Set();
  for (const p of cat.products) {
    for (const name of [p.canonical_name, ...(p.alt_names || [])]) {
      const sig = nameSignature(name);
      if (!sig.family || sig.family !== target.family) continue;
      if (sig.grade && sig.grade !== target.grade) continue;
      if (sig.thickness && sig.thickness !== target.thickness) continue;
      hits.add(p.product_id);
    }
  }
  if (hits.size > 1) console.warn(`  ⚠ '${row.description_raw}' matches several products (${[...hits].join(', ')}) — skipped`);
  return hits.size === 1 ? [...hits][0] : null;
}

function findCategoryForPriceCategory(priceCat, categoryMap) {
  // price_list_structured.json `category_raw` (exact strings in the file)
  // → product_master category_id. Only sections that carry color pricing
  // need a mapping; the plain sections have no color rules.
  const mapping = {
    'PAVING BLOCKS (PRESS)':     'press_machine_paving',
    'PAVING BLOCKS (VIBRATION)': 'paving_blocks_vibro',
    'FLOOR TILES':               'floor_tiles',
    'WALL TILES':                'wall_tiles',
  };
  const raw = (priceCat.category_raw || '').trim().toUpperCase();
  const ref = mapping[raw];
  return ref ? categoryMap[ref] : null;
}

// --------------------------------------------------------------------------
if (require.main === module) {
  if (process.argv.includes('--plan')) {
    for (const r of buildRecipePlan(productMaster, ratiosMolds)) {
      console.log(`${r.categoryRef.padEnd(38)} ${r.colorLabel.padEnd(36)} ` +
        `${r.components.map(c => `${c.material}=${c.quantity}`).join(' ')}  → ${r.productRefs.length} products`);
    }
  } else {
    main().catch(err => {
      console.error('\n❌ Seed failed:', err.message);
      process.exit(1);
    });
  }
}

module.exports = { buildRecipePlan, buildYieldLookup, matchByConfirmedName, canonColor };
