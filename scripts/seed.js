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
 *   - assets/docs/product_master.json
 *   - assets/docs/ratios_and_molds.json
 *   - assets/docs/price_list_structured.json
 *
 * Creates:
 *   - Stumarcot organization
 *   - 3 branches: Mwanza, Dar es Salaam, Dodoma
 *   - 3 warehouses per branch (raw_materials, finished_goods, general)
 *   - System roles + permission assignments
 *   - Units
 *   - Product categories + products (from product_master.json)
 *   - Materials (from ratios_and_molds.json ingredient names)
 *   - Recipe versions + items (shared per category+color, per AGENTS.md §3)
 *   - Product branch pricing (from price_list_structured.json)
 *   - One seed admin user: admin@stumarcot.co.tz
 */

const path = require('path');
const fs   = require('fs');

// --- Load env (service role key from .env only, never .env.local) ----------
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

const SUPABASE_URL            = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error('ERROR: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set in .env');
  process.exit(1);
}

const { createClient } = require('@supabase/supabase-js');

// Service role client — bypasses RLS for seeding purposes
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

// --- Load data files -------------------------------------------------------
const DOCS = path.join(__dirname, '..', 'assets', 'docs');
const productMaster       = JSON.parse(fs.readFileSync(path.join(DOCS, 'product_master.json'), 'utf8'));
const ratiosMolds         = JSON.parse(fs.readFileSync(path.join(DOCS, 'ratios_and_molds.json'), 'utf8'));
const priceListStructured = JSON.parse(fs.readFileSync(path.join(DOCS, 'price_list_structured.json'), 'utf8'));

// --- Helper ----------------------------------------------------------------
async function insertOrGet(table, matchOn, data) {
  const filter = Object.fromEntries(matchOn.map(k => [k, data[k]]));
  const { data: existing } = await supabase.from(table).select('id').match(filter).single();
  if (existing) return existing;
  const { data: inserted, error } = await supabase.from(table).insert(data).select('id').single();
  if (error) throw new Error(`${table} insert failed: ${error.message}\nData: ${JSON.stringify(data, null, 2)}`);
  return inserted;
}

async function upsert(table, conflictCols, rows) {
  if (!rows.length) return [];
  const { data, error } = await supabase
    .from(table)
    .upsert(rows, { onConflict: conflictCols.join(','), ignoreDuplicates: false })
    .select('id');
  if (error) throw new Error(`${table} upsert failed: ${error.message}`);
  return data;
}

// --------------------------------------------------------------------------
async function main() {
  console.log('=== MOIS Phase 1a Seed — Stumarcot ===\n');

  // =========================================================================
  // 1. ORGANIZATION
  // =========================================================================
  console.log('1. Creating Stumarcot organization...');
  const { data: org, error: orgErr } = await supabase
    .from('organizations')
    .insert({
      name:       'Stumarcot',
      legal_name: 'STUMARCOT CO LTD',
      brand_config: {
        primary_color: '#B7A57A',
        accent_color:  '#4B3621',
        font:          'Google Sans',
      },
      status: 'active'
    })
    .select('id, name')
    .single();
  if (orgErr) {
    // If already seeded, fetch it
    const { data: existing } = await supabase
      .from('organizations')
      .select('id, name')
      .eq('legal_name', 'STUMARCOT CO LTD')
      .single();
    if (!existing) throw new Error(`Organization insert failed: ${orgErr.message}`);
    console.log(`  ↳ Already exists: ${existing.name} (${existing.id})`);
    return await seedWithOrg(existing);
  }
  console.log(`  ↳ Created: ${org.name} (${org.id})`);
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
      .single();
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
  for (const [branchName, branch] of Object.entries(branches)) {
    for (const wt of warehouseTypes) {
      const { data: existing } = await supabase
        .from('warehouses')
        .select('id')
        .eq('organization_id', orgId)
        .eq('branch_id', branch.id)
        .eq('name', wt.name)
        .single();
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
  const { data: allPerms } = await supabase.from('permissions').select('id, code');
  const permByCode = Object.fromEntries(allPerms.map(p => [p.code, p.id]));

  for (const roleDef of systemRoles) {
    let roleRow;
    const { data: existingRole } = await supabase
      .from('roles')
      .select('id')
      .eq('organization_id', orgId)
      .eq('name', roleDef.name)
      .single();

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
      .single();
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
      .single();
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
      .single();
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
  // =========================================================================
  console.log('\n8. Creating products...');
  const productMap = {}; // product_id_ref → DB uuid
  let productCount = 0;

  for (const cat of productMaster.categories) {
    const catDbId = categoryMap[cat.category_id];
    for (const p of cat.products) {
      const row = {
        organization_id: orgId,
        category_id:     catDbId,
        product_id_ref:  p.product_id,
        canonical_name:  p.canonical_name,
        size_cm:         p.size_cm ? String(p.size_cm) : null,
        pcs_per_sqm:     p.pcs_per_sqm ?? null,
        wastani_per_bag: p.wastani_per_bag ?? null,
        notes:           p.note || null,
        status:          'active',
      };
      const { data: existing } = await supabase
        .from('products')
        .select('id')
        .eq('organization_id', orgId)
        .eq('product_id_ref', p.product_id)
        .single();
      if (existing) {
        productMap[p.product_id] = existing.id;
      } else {
        const { data: inserted, error } = await supabase
          .from('products')
          .insert(row)
          .select('id')
          .single();
        if (error) throw new Error(`Product insert failed [${p.product_id}]: ${error.message}`);
        productMap[p.product_id] = inserted.id;
        productCount++;
      }
    }
  }
  console.log(`  ↳ ${productCount} products created`);

  // =========================================================================
  // 9. RECIPE VERSIONS + ITEMS
  //    Shared per category + color (AGENTS.md §3).
  //    One recipe_version row per (category_id, color_label).
  //    All products in that category+color link to the same recipe_version.
  // =========================================================================
  console.log('\n9. Creating recipe versions and items...');
  let recipeVersionCount = 0;
  let recipeItemCount    = 0;
  let recipeProductLinks = 0;

  for (const ratCat of ratiosMolds.categories) {
    const catDbId = categoryMap[ratCat.category_id];
    if (!catDbId) continue; // skip if not in product_master

    for (const ratio of ratCat.ratios) {
      const colorLabel = ratio.label || 'Plain';

      // Check if recipe_version already exists
      const { data: existingRV } = await supabase
        .from('recipe_versions')
        .select('id')
        .eq('organization_id', orgId)
        .eq('category_id', catDbId)
        .eq('color_label', colorLabel)
        .eq('version_number', 1)
        .single();

      let rvId;
      if (existingRV) {
        rvId = existingRV.id;
      } else {
        const { data: rv, error } = await supabase
          .from('recipe_versions')
          .insert({
            organization_id: orgId,
            category_id:     catDbId,
            color_label:     colorLabel,
            version_number:  1,
            effective_date:  '2026-09-27',
            status:          'active',
            notes:           ratio.notes || null,
          })
          .select('id')
          .single();
        if (error) throw new Error(`RecipeVersion insert failed [${ratCat.category_id}/${colorLabel}]: ${error.message}`);
        rvId = rv.id;
        recipeVersionCount++;
      }

      // Insert recipe items (ingredients)
      for (const comp of ratio.components) {
        const matCode = materialCodeForName(comp.material);
        const matId   = matByCode[matCode];
        const unitId  = unitSymbolToId(comp.unit, unitBySymbol);

        if (!matId) {
          console.warn(`  ⚠ Unknown material '${comp.material}' in ${ratCat.category_id}/${colorLabel}`);
          continue;
        }

        const { data: existingItem } = await supabase
          .from('recipe_items')
          .select('id')
          .eq('recipe_version_id', rvId)
          .eq('material_id', matId)
          .single();

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

      // Link all products in this category to this recipe_version
      const masterCat = productMaster.categories.find(c => c.category_id === ratCat.category_id);
      if (masterCat) {
        for (const p of masterCat.products) {
          const productDbId = productMap[p.product_id];
          if (!productDbId) continue;

          const { data: existingLink } = await supabase
            .from('recipe_version_products')
            .select('recipe_version_id')
            .eq('recipe_version_id', rvId)
            .eq('product_id', productDbId)
            .single();

          if (!existingLink) {
            const { error } = await supabase
              .from('recipe_version_products')
              .insert({ recipe_version_id: rvId, product_id: productDbId });
            if (error) throw new Error(`RecipeVersionProduct insert failed: ${error.message}`);
            recipeProductLinks++;
          }
        }
      }
    }
  }
  console.log(`  ↳ ${recipeVersionCount} recipe versions, ${recipeItemCount} items, ${recipeProductLinks} product links`);

  // =========================================================================
  // 10. PRODUCT BRANCH PRICING (from price_list_structured.json — as-is)
  //     canonical_match=null rows skipped (not confirmed — per AGENTS.md)
  //     Genuine per-branch price differences preserved
  // =========================================================================
  console.log('\n10. Seeding product branch pricing...');
  let pricingRows = 0;
  let skippedNoMatch = 0;
  let colorRuleRows = 0;

  // Build branch name → id map
  const branchByName = {};
  for (const [name, b] of Object.entries(branches)) {
    branchByName[name] = b.id;
  }

  for (const priceCat of priceListStructured.categories) {
    // Seed category-level color pricing rules
    if (priceCat.color_pricing_by_branch) {
      const catDbId = findCategoryForPriceCategory(priceCat, categoryMap);
      if (catDbId) {
        for (const [branchName, colorRule] of Object.entries(priceCat.color_pricing_by_branch)) {
          if (!colorRule) continue; // null safety
          const branchId = branchByName[branchName];
          if (!branchId) continue;

          const { data: existingRule } = await supabase
            .from('category_color_pricing_rules')
            .select('id')
            .eq('organization_id', orgId)
            .eq('category_id', catDbId)
            .eq('branch_id', branchId)
            .single();

          if (!existingRule) {
            const { error } = await supabase
              .from('category_color_pricing_rules')
              .insert({
                organization_id: orgId,
                category_id:     catDbId,
                branch_id:       branchId,
                base_color:      colorRule.base_color || 'OffWhite',
                pricing_type:    colorRule.pricing_type || 'delta_per_sqmt_over_offwhite',
                color_prices:    colorRule.other_colors || {},
                raw_notes:       colorRule.raw_notes || null,
              });
            if (!error) colorRuleRows++;
          }
        }
      }
    }

    // Seed per-product pricing
    for (const product of priceCat.products) {
      // canonical_match is an object { category_id, product_id, canonical_name } or null
      if (!product.canonical_match || typeof product.canonical_match !== 'object') {
        skippedNoMatch++;
        continue; // not confirmed — per AGENTS.md: never fill a null by guessing
      }

      const productDbId = productMap[product.canonical_match.product_id];
      if (!productDbId) {
        console.warn(`  ⚠ canonical_match.product_id '${product.canonical_match.product_id}' not found in products`);
        skippedNoMatch++;
        continue;
      }

      const branchPricing = product.available_in_branches || {};
      for (const [branchName, pricing] of Object.entries(branchPricing)) {
        const branchId = branchByName[branchName];
        if (!branchId) continue;

        const row = {
          organization_id:                 orgId,
          product_id:                      productDbId,
          branch_id:                       branchId,
          color:                           product.color || null,
          price_per_unit_exclusive:        pricing.price_exclusive ?? null,
          vat_per_unit:                    pricing.vat ?? null,
          price_per_unit_inclusive:        pricing.price_inclusive ?? null,
          price_per_sqm_inclusive:         pricing.price_per_sqmt ?? null,
          pcs_per_sqm_at_pricing:          pricing.pcs_per_sqmt_or_unit ?? null,
          is_available:                    true,
          price_consistent_across_branches: product.price_consistent_across_branches ?? true,
          source_item_no:                  pricing.item_no ?? null,
          raw_notes:                       product.raw_notes || null,
        };

        const { data: existingPricing } = await supabase
          .from('product_branch_pricing')
          .select('id')
          .eq('product_id', productDbId)
          .eq('branch_id', branchId)
          .eq('color', product.color || null)
          .maybeSingle();

        if (!existingPricing) {
          const { error } = await supabase
            .from('product_branch_pricing')
            .insert(row);
          if (error) {
            console.warn(`  ⚠ Pricing insert failed [${product.canonical_match}/${branchName}]: ${error.message}`);
          } else {
            pricingRows++;
          }
        }
      }
    }
  }
  console.log(`  ↳ ${pricingRows} pricing rows, ${colorRuleRows} color rules, ${skippedNoMatch} skipped (no canonical_match)`);

  // =========================================================================
  // 11. SEED ADMIN USER
  // =========================================================================
  console.log('\n11. Creating seed admin user...');
  const ADMIN_EMAIL = 'admin@stumarcot.co.tz';
  const ADMIN_PASS  = 'MoisAdmin2026!'; // change on first login

  // Try to create the user via admin API
  const { data: adminUser, error: userErr } = await supabase.auth.admin.createUser({
    email:          ADMIN_EMAIL,
    password:       ADMIN_PASS,
    email_confirm:  true, // mark as confirmed (dev mode — skip email verification)
    user_metadata:  { first_name: 'MOIS', last_name: 'Admin' },
  });

  let adminUserId;
  if (userErr) {
    if (userErr.message.includes('already been registered') || userErr.message.includes('already exists')) {
      const { data: users } = await supabase.auth.admin.listUsers();
      const existing = users?.users?.find(u => u.email === ADMIN_EMAIL);
      if (existing) {
        adminUserId = existing.id;
        console.log(`  ↳ Admin user already exists: ${ADMIN_EMAIL} (${adminUserId})`);
      }
    } else {
      throw new Error(`Admin user creation failed: ${userErr.message}`);
    }
  } else {
    adminUserId = adminUser.user.id;
    console.log(`  ↳ Created admin user: ${ADMIN_EMAIL} (${adminUserId})`);
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
      const { error: urErr } = await supabase
        .from('user_roles')
        .upsert({
          user_id: adminUserId,
          role_id: ownerRole.id,
          organization_id: orgId,
        }, { onConflict: 'user_id,role_id,organization_id,branch_id,warehouse_id', ignoreDuplicates: true });
      if (urErr) console.warn(`  ⚠ user_roles upsert: ${urErr.message}`);
      else console.log(`  ↳ Assigned 'owner' role to admin`);
    }
  }

  // =========================================================================
  // 12. ROW COUNT REPORT
  // =========================================================================
  console.log('\n=== CHECKPOINT 4 — Row Counts ===');
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
  console.log('\n✅ Seed complete.');
}

// --- Helpers ---------------------------------------------------------------

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
  // Map price_list_structured category_raw names to category_id_refs
  const mapping = {
    'PAVING BLOCKS (PRESS)':   'press_machine_paving',
    'FLOOR TILES':             'floor_tiles',
    'WALL TILES':              'wall_tiles',
    'PAVING BLOCKS (VIBRO)':   'paving_blocks_vibro',
    'CURBSTONES':              'curbstones',
    'TRENCH COVERS':           'trench_covers',
    'CULVERTS':                'culverts',
    'NGUZO / POSTS & BICONS':  'posts_and_bicons',
    'MATOFALI / BLOCKS':       'press_machine_bricks_and_kerbstones',
  };
  const raw = (priceCat.category_raw || '').trim().toUpperCase();
  const ref  = mapping[raw];
  return ref ? categoryMap[ref] : null;
}

// --------------------------------------------------------------------------
main().catch(err => {
  console.error('\n❌ Seed failed:', err.message);
  process.exit(1);
});
