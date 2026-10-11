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
 */

const path = require('path');
const fs   = require('fs');

// --- Load data files -------------------------------------------------------
const DOCS = path.join(__dirname, '..', 'assets', 'docs', 'Stumarcot');
const productMaster       = JSON.parse(fs.readFileSync(path.join(DOCS, 'product_master.json'), 'utf8'));
const ratiosMolds         = JSON.parse(fs.readFileSync(path.join(DOCS, 'ratios_and_molds.json'), 'utf8'));
const priceListStructured = JSON.parse(fs.readFileSync(path.join(DOCS, 'price_list_structured.json'), 'utf8'));

let supabase; // created in main() — not needed for --plan

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
      permissions: ['products.view','materials.view','materials.manage',
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
    console.log(`  ↳ Role '${roleDef.name}' — ${permRows.length} permissions`);
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
  // 6. MATERIALS
  // From the unique ingredient names across all ratios_and_molds.json categories
  // =========================================================================
  console.log('\n6. Creating materials...');
  const materialDefs = [
    { name: 'Cement',             code: 'CEM',  symbol: 'bag',    notes: '50kg bag' },
    { name: 'Mchanga (Sand)',      code: 'MCH',  symbol: 'bucket', notes: '1 ndoo = 10L ≈ 20kg' },
    { name: 'Chipping',           code: 'CHIP', symbol: 'bucket', notes: 'Fine aggregate' },
    { name: 'Kokoto (Aggregate)', code: 'KOK',  symbol: 'bucket', notes: 'Coarse aggregate' },
    { name: 'Dawa (Additive)',    code: 'DAWA', symbol: 'L',      notes: 'Chemical hardener/additive' },
    { name: 'Rangi (Pigment)',    code: 'RNG',  symbol: 'kg',     notes: 'Color pigment — Red: 4kg, Grey: 1kg, Black: 2kg per bag' },
    { name: 'Dust',               code: 'DUST', symbol: 'bucket', notes: 'Stone dust — used in press paving mixes' },
  ];
  for (const m of materialDefs) {
    const { data: existing } = await supabase
      .from('materials')
      .select('id')
      .eq('organization_id', orgId)
      .eq('name', m.name)
      .maybeSingle();
    if (!existing) {
      const { error } = await supabase
        .from('materials')
        .insert({
          organization_id: orgId,
          name:    m.name,
          code:    m.code,
          unit_id: unitBySymbol[m.symbol] || null,
          notes:   m.notes,
          status:  'active',
        });
      if (error) throw new Error(`Material insert failed: ${error.message}`);
    }
  }
  const { data: materialRows } = await supabase
    .from('materials')
    .select('id, code')
    .eq('organization_id', orgId);
  const matByCode = Object.fromEntries(materialRows.map(m => [m.code, m.id]));
  console.log(`  ↳ ${materialRows.length} materials`);

  // =========================================================================
  // 7. PRODUCT CATEGORIES (from product_master.json — as-is)
  // =========================================================================
  console.log('\n7. Creating product categories...');
  const categoryMap = {}; // category_id_ref → DB uuid

  for (let i = 0; i < productMaster.categories.length; i++) {
    const cat = productMaster.categories[i];
    const row = {
      organization_id: orgId,
      category_id_ref: cat.category_id,
      name:            cat.category_id.replace(/_/g, ' ')
                         .replace(/\b\w/g, c => c.toUpperCase()),
      display_format:  cat.display_format,
      stock_unit:      cat.stock_unit,
      color_columns:   cat.color_columns || null,
      sort_order:      i,
    };
    const { data: existing } = await supabase
      .from('product_categories')
      .select('id')
      .eq('organization_id', orgId)
      .eq('category_id_ref', cat.category_id)
      .maybeSingle();
    if (existing) {
      categoryMap[cat.category_id] = existing.id;
    } else {
      const { data: inserted, error } = await supabase
        .from('product_categories')
        .insert(row)
        .select('id')
        .single();
      if (error) throw new Error(`Category insert failed: ${error.message}`);
      categoryMap[cat.category_id] = inserted.id;
    }
  }
  console.log(`  ↳ ${Object.keys(categoryMap).length} categories`);

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

  for (const recipe of plan) {
    const catDbId = categoryMap[recipe.categoryRef];

    const { data: existingRV } = await supabase
      .from('recipe_versions')
      .select('id')
      .eq('organization_id', orgId)
      .eq('category_id', catDbId)
      .eq('color_label', recipe.colorLabel)
      .eq('version_number', 1)
      .maybeSingle();

    let rvId;
    if (existingRV) {
      rvId = existingRV.id;
    } else {
      const { data: rv, error } = await supabase
        .from('recipe_versions')
        .insert({
          organization_id: orgId,
          category_id:     catDbId,
          color_label:     recipe.colorLabel,
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
      const matId  = matByCode[materialCodeForName(comp.material)];
      const unitId = unitSymbolToId(comp.unit, unitBySymbol);
      if (!matId) {
        console.warn(`  ⚠ Unknown material '${comp.material}' in ${recipe.categoryRef}/${recipe.colorLabel}`);
        continue;
      }

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
  for (const r of plan) (expectedByCategory[r.categoryRef] ||= new Set()).add(r.colorLabel);
  for (const [categoryRef, labels] of Object.entries(expectedByCategory)) {
    const { data: activeRVs } = await supabase
      .from('recipe_versions')
      .select('id, color_label')
      .eq('organization_id', orgId)
      .eq('category_id', categoryMap[categoryRef])
      .eq('version_number', 1)
      .eq('status', 'active');
    for (const rv of activeRVs || []) {
      if (labels.has(rv.color_label)) continue;
      const { error } = await supabase.from('recipe_versions').update({ status: 'archived' }).eq('id', rv.id);
      if (error) throw new Error(`RecipeVersion archive failed [${categoryRef}/${rv.color_label}]: ${error.message}`);
      console.log(`  ↳ Archived stale recipe ${categoryRef}/${rv.color_label}`);
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
          const { error } = await supabase
            .from('category_color_pricing_rules')
            .insert({
              organization_id: orgId,
              category_id:     catDbId,
              branch_id:       branchId,
              base_color:      colorRule.base_color || 'OffWhite',
              pricing_type:    colorRule.pricing_type,
              color_prices:    colorRule.other_colors || {},
              raw_notes:       colorRule.raw_notes || null,
            });
          if (error) console.warn(`  ⚠ Color rule insert failed [${priceCat.category_raw}/${branchName}]: ${error.message}`);
          else colorRuleRows++;
        }
      }
    }

    // Seed per-product pricing
    for (const product of priceCat.products) {
      // canonical_match is an object { category_id, product_id, canonical_name } or null
      if (!product.canonical_match || typeof product.canonical_match !== 'object') {
        unmatched.push(`${priceCat.category_raw}: ${product.description_raw}${product.size_mm ? ` (${product.size_mm})` : ''}`);
        continue; // not confirmed — per AGENTS.md: never fill a null by guessing
      }

      const productDbId = productMap[product.canonical_match.product_id];
      if (!productDbId) {
        console.warn(`  ⚠ canonical_match.product_id '${product.canonical_match.product_id}' not found in products`);
        unmatched.push(`${priceCat.category_raw}: ${product.description_raw}`);
        continue;
      }

      for (const [branchName, pricing] of Object.entries(product.available_in_branches || {})) {
        const branchId = branchByName[branchName];
        if (!branchId) continue;

        // The price list carries no per-row color: every row is the
        // base (OffWhite) price, stored as color = NULL. Other colors come
        // from category_color_pricing_rules.
        const color = product.color || null;
        let existingQuery = supabase
          .from('product_branch_pricing')
          .select('id')
          .eq('product_id', productDbId)
          .eq('branch_id', branchId);
        existingQuery = color === null ? existingQuery.is('color', null) : existingQuery.eq('color', color);
        const { data: existingPricing } = await existingQuery.maybeSingle();
        if (existingPricing) continue;

        const { error } = await supabase
          .from('product_branch_pricing')
          .insert({
            organization_id:                  orgId,
            product_id:                       productDbId,
            branch_id:                        branchId,
            color,
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
          console.warn(`  ⚠ Pricing insert failed [${product.canonical_match.product_id}/${branchName}]: ${error.message}`);
        } else {
          pricingRows++;
        }
      }
    }
  }
  console.log(`  ↳ ${pricingRows} pricing rows, ${colorRuleRows} color rules`);
  if (unmatched.length) {
    console.log(`  ↳ ${unmatched.length} price-list rows skipped — no confirmed canonical_match (confirm with SwahziTech):`);
    for (const u of unmatched) console.log(`      - ${u}`);
  }

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
 *   ratio, linked to every product in that product_master category.
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

  const plan = [];
  for (const ratCat of ratiosMolds.categories) {
    if (Array.isArray(ratCat.ratios)) {
      const productRefs = productsByCategory[ratCat.category_id];
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
        const label = mixLabel(item.ratio);
        const key = `${categoryRef}|${label}`;
        if (!groups.has(key)) groups.set(key, { categoryRef, label, components: item.ratio, items: [] });
        groups.get(key).items.push(item);
      }
      for (const g of groups.values()) {
        plan.push({
          categoryRef: g.categoryRef,
          colorLabel:  g.label,
          notes:       `${ratCat.name} mix shared by: ${g.items.map(i => i.name).join(', ')}.`,
          components:  mergeComponents(g.components),
          productRefs: g.items.map(i => i.item_id),
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
    const code = materialCodeForName(c.material) || c.material;
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

function materialCodeForName(name) {
  const lower = (name || '').toLowerCase().replace(/[^a-z]/g, '');
  const map = {
    cement:    'CEM',
    mchanga:   'MCH',
    mch:       'MCH',
    sand:      'MCH',
    chip:      'CHIP',
    chipping:  'CHIP',
    chips:     'CHIP',
    kok:       'KOK',
    kokoto:    'KOK',
    aggregate: 'KOK',
    dawa:      'DAWA',
    additive:  'DAWA',
    rangi:     'RNG',
    rangired:  'RNG',
    rangigrey: 'RNG',
    rangiblack:'RNG',
    pigment:   'RNG',
    dust:      'DUST',
    stonedust: 'DUST',
  };
  return map[lower] || null;
}

function unitSymbolToId(unitStr, unitBySymbol) {
  // 'unit' (used by several ratios in the source) is deliberately NOT mapped:
  // the notebook does not say which measure it is, so it stays null.
  const map = {
    '50kg bag':   'bag',
    'bag':        'bag',
    'bucket':     'bucket',
    'ndoo':       'bucket',
    'litre':      'L',
    'l':          'L',
    'liter':      'L',
    'kg':         'kg',
    'sqm':        'SQM',
    'pcs':        'PCS',
  };
  const sym = map[(unitStr || '').toLowerCase()] || unitStr;
  return unitBySymbol[sym] || null;
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

module.exports = { buildRecipePlan, buildYieldLookup };
