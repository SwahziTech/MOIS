#!/usr/bin/env node
/**
 * Live cross-tenant isolation test (AGENTS.md §1).
 *
 *   node scripts/isolation-test/run.js
 *
 * 1. fixture.js creates/reuses a throwaway second tenant ("Isolation Test
 *    Org") with a password-less user (nobody can sign in as it).
 * 2. Runs SQL on the linked project (supabase db query --linked) that
 *    impersonates each identity exactly as PostgREST does (JWT claims +
 *    SET ROLE), so the real RLS policies are evaluated.
 * 3. Every write attempt runs in a sub-transaction that is always rolled
 *    back — even a successful attack leaves no data behind.
 *
 * Exits 1 if any expectation fails. Requires the Supabase CLI linked to the
 * project and .env with SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY.
 */
const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ids = JSON.parse(execFileSync('node', [path.join(__dirname, 'fixture.js')], { encoding: 'utf8' }).trim());

const TABLES = ['organizations','branches','warehouses','profiles','roles','role_permissions','user_roles','units','materials',
  'product_categories','products','product_branch_pricing','category_color_pricing_rules',
  'recipe_versions','recipe_items','recipe_version_products','permissions',
  'color_palette','product_category_colors','category_color_price_items',
  'material_categories','material_unit_conversions','material_branch_sources','review_flags','audit_log',
  'suppliers','inventory_movements','inventory_transactions','stock_balances','identity_decisions','stock_import_drafts',
  'branch_products','product_size_specs','branch_yield_overrides','pending_changes',
  'purchases','purchase_lines','expense_categories','expenses','reject_reasons','production_batches','production_batch_materials','production_batch_rejects','production_batch_outputs','production_material_variance'];

const readBlock = (who, claims) => `
DO $$
DECLARE t text; n bigint; ns bigint; nt bigint; orgcol text;
BEGIN
  PERFORM set_config('request.jwt.claims', '${JSON.stringify(claims)}', true);
  EXECUTE 'SET LOCAL ROLE ${claims.role}';
  FOREACH t IN ARRAY ARRAY[${TABLES.map(t => `'${t}'`).join(',')}] LOOP
    BEGIN
      EXECUTE format('SELECT count(*) FROM public.%I', t) INTO n;
      orgcol := CASE WHEN t = 'organizations' THEN 'id'
                     WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=t AND column_name='organization_id') THEN 'organization_id' END;
      IF orgcol IS NOT NULL THEN
        EXECUTE format('SELECT count(*) FROM public.%I WHERE %I = %L', t, orgcol, '${ids.stumarcotOrg}') INTO ns;
        EXECUTE format('SELECT count(*) FROM public.%I WHERE %I = %L', t, orgcol, '${ids.testOrg}') INTO nt;
        INSERT INTO iso_results(who, test, result) VALUES ('${who}', 'read '||t, format('visible=%s stumarcot=%s testorg=%s', n, ns, nt));
      ELSE
        INSERT INTO iso_results(who, test, result) VALUES ('${who}', 'read '||t, format('visible=%s', n));
      END IF;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO iso_results(who, test, result) VALUES ('${who}', 'read '||t, 'DENIED: '||SQLERRM);
    END;
  END LOOP;
  EXECUTE 'RESET ROLE';
END $$;`;

const attempt = (label, sql, isUpdate) => `
  BEGIN
    ${sql};
    ${isUpdate ? "GET DIAGNOSTICS n = ROW_COUNT; RAISE EXCEPTION 'ROWS_AFFECTED=%', n;" : "RAISE EXCEPTION 'WRITE_SUCCEEDED';"}
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO iso_results(who, test, result) VALUES ('test user', '${label}', SQLERRM);
  END;`;

const testUser = { sub: ids.testUser, role: 'authenticated' };
const S = ids.stumarcotOrg, T = ids.testOrg;
const writes = `
DO $$
DECLARE n bigint;
BEGIN
  PERFORM set_config('request.jwt.claims', '${JSON.stringify(testUser)}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  ${attempt('WRITE insert product into other tenant', `INSERT INTO public.products (organization_id, category_id, unit_id, product_id_ref, canonical_name) VALUES ('${S}','${ids.stumarcotCategory}','${ids.stumarcotUnit}','iso_probe','probe')`)}
  ${attempt('WRITE update other tenant products', `UPDATE public.products SET canonical_name = 'hacked' WHERE organization_id = '${S}'`, true)}
  ${attempt('WRITE delete other tenant products', `DELETE FROM public.products WHERE organization_id = '${S}'`, true)}
  ${attempt('WRITE update other tenant org', `UPDATE public.organizations SET name = 'hacked' WHERE id = '${S}'`, true)}
  ${attempt('WRITE grant self other tenant owner role', `INSERT INTO public.user_roles (user_id, role_id, organization_id) VALUES ('${ids.testUser}','${ids.stumarcotOwnerRole}','${S}')`)}
  ${attempt('WRITE grant self other tenant role under own org', `INSERT INTO public.user_roles (user_id, role_id, organization_id) VALUES ('${ids.testUser}','${ids.stumarcotOwnerRole}','${T}')`)}
  ${attempt('WRITE move own profile into other tenant', `UPDATE public.profiles SET organization_id = '${S}' WHERE id = '${ids.testUser}'`, true)}
  ${attempt('WRITE update other tenant catalogue', `UPDATE public.branch_products SET status = 'inactive' WHERE organization_id = '${S}'`, true)}
  ${attempt('WRITE update other tenant materials', `UPDATE public.materials SET notes = 'hacked' WHERE organization_id = '${S}'`, true)}
  ${attempt('WRITE request approval at other tenant store', `PERFORM public.request_change('stock_movement', NULL, jsonb_build_object('type','adjustment','warehouse_id','${ids.stumarcotWarehouse}','lines','[]'::jsonb), 'probe')`)}
  ${attempt('WRITE record purchase at other tenant store', `PERFORM public.record_purchase(jsonb_build_object('receipt', jsonb_build_object('type','receipt','warehouse_id','${ids.stumarcotWarehouse}','lines','[]'::jsonb), 'new_supplier_name','probe','lines','[]'::jsonb))`)}
  ${attempt('WRITE record expense at other tenant branch', `PERFORM public.record_expense(jsonb_build_object('branch_id','${ids.stumarcotBranch}','expense_date','2026-10-18','category_id',(SELECT id FROM public.expense_categories WHERE organization_id = '${T}' LIMIT 1),'description','probe','amount',1))`)}
  ${attempt('WRITE set other tenant branch VAT', `PERFORM public.set_branch_vat_rate('${ids.stumarcotBranch}', 0)`)}
  ${attempt('WRITE insert expense category into other tenant', `INSERT INTO public.expense_categories (organization_id, name) VALUES ('${S}', 'iso_probe')`)}
  ${attempt('WRITE update other tenant expense categories', `UPDATE public.expense_categories SET name = name || 'x' WHERE organization_id = '${S}'`, true)}
  ${attempt('WRITE record production batch at other tenant store', `PERFORM public.record_production_batch(jsonb_build_object('raw_warehouse_id','${ids.stumarcotWarehouse}','curing_warehouse_id','${ids.stumarcotWarehouse}','product_id','${ids.testProduct}','cement_bags',1,'pieces_cast',1))`)}
  ${attempt('WRITE save a production day at other tenant store', `PERFORM public.record_production_batches(jsonb_build_object('batches', jsonb_build_array(jsonb_build_object('raw_warehouse_id','${ids.stumarcotWarehouse}','curing_warehouse_id','${ids.stumarcotWarehouse}','cement_bags',1,'outputs',jsonb_build_array(jsonb_build_object('product_id','${ids.testProduct}','pieces',1))))))`)}
  ${attempt('WRITE insert reject reason into other tenant', `INSERT INTO public.reject_reasons (organization_id, name) VALUES ('${S}', 'iso_probe')`)}
  ${attempt('WRITE insert production batch directly', `INSERT INTO public.production_batches (organization_id, branch_id, batch_date, product_id, recipe_version_id, raw_warehouse_id, curing_warehouse_id, cement_bags, pieces_cast, curing_until) SELECT '${T}', w.branch_id, current_date, '${ids.testProduct}', gen_random_uuid(), w.id, w.id, 1, 1, current_date FROM public.warehouses w WHERE w.id = '${ids.testWarehouse}'`)}
  ${attempt('WRITE update other tenant pricing', `UPDATE public.product_branch_pricing SET price_per_unit_inclusive = 1 WHERE organization_id = '${S}'`, true)}
  ${attempt('WRITE update permissions catalog', `UPDATE public.permissions SET description = 'x'`, true)}
  ${attempt('WRITE post stock into other tenant warehouse', `PERFORM public.post_inventory_movement(jsonb_build_object('type','opening_balance','warehouse_id','${ids.stumarcotWarehouse}','lines',jsonb_build_array(jsonb_build_object('product_id','${ids.testProduct}','quantity',1,'unit_id','${ids.testProductUnit}'))))`)}
  ${attempt('WRITE insert supplier into other tenant', `INSERT INTO public.suppliers (organization_id, name) VALUES ('${S}', 'iso_probe')`)}
  ${attempt('WRITE insert ledger row directly', `INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, created_by) SELECT '${T}', 'adjustment', w.branch_id, w.id, current_date, '${ids.testUser}' FROM public.warehouses w WHERE w.id = '${ids.testWarehouse}'`)}
  ${attempt('CONTROL post stock in own warehouse', `PERFORM public.post_inventory_movement(jsonb_build_object('type','receipt','warehouse_id','${ids.testWarehouse}','lines',jsonb_build_array(jsonb_build_object('product_id','${ids.testProduct}','quantity',1,'unit_id','${ids.testProductUnit}'))))`)}
  ${attempt('CONTROL insert product into own org', `INSERT INTO public.products (organization_id, category_id, unit_id, product_id_ref, canonical_name) SELECT '${T}', c.id, c.default_unit_id, 'iso_control', 'control' FROM public.product_categories c WHERE c.organization_id = '${T}' LIMIT 1`)}
  EXECUTE 'RESET ROLE';
END $$;`;

// Deactivation (migration 014): an inactive profile must resolve to no org.
// Status change + reads happen in a sub-transaction that is always undone.
const deactivation = `
DO $$
DECLARE n bigint;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', '{}', true); -- trusted context for the status change
    UPDATE public.profiles SET status = 'inactive' WHERE id = '${ids.testUser}';
    PERFORM set_config('request.jwt.claims', '${JSON.stringify(testUser)}', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT (SELECT count(*) FROM public.products) + (SELECT count(*) FROM public.branches)
         + (SELECT count(*) FROM public.organizations) INTO n;
    RAISE EXCEPTION 'DEACTIVATED_VISIBLE=%', n;
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO iso_results(who, test, result) VALUES ('deactivated user', 'read org data after deactivation', SQLERRM);
  END;
END $$;`;

const sql = `
CREATE TEMP TABLE iso_results (seq serial, who text, test text, result text);
GRANT ALL ON iso_results TO authenticated, anon;
GRANT USAGE ON SEQUENCE iso_results_seq_seq TO authenticated, anon;
${readBlock('test user', testUser)}
${writes}
${readBlock('stumarcot admin', { sub: ids.stumarcotAdmin, role: 'authenticated' })}
${readBlock('anon', { role: 'anon' })}
${deactivation}
SELECT who, test, result FROM iso_results ORDER BY seq;`;

const file = path.join(os.tmpdir(), `mois_isolation_${Date.now()}.sql`);
fs.writeFileSync(file, sql);
const raw = execFileSync('supabase', ['db', 'query', '--linked', '-f', file, '-o', 'json'],
  { encoding: 'utf8', cwd: path.join(__dirname, '..', '..'), shell: process.platform === 'win32' });
fs.unlinkSync(file);
const rows = JSON.parse(raw.slice(raw.indexOf('{'))).rows;

// --- Expectations ----------------------------------------------------------
const failures = [];
for (const r of rows) {
  const m = r.result.match(/visible=(\d+)(?: stumarcot=(\d+) testorg=(\d+))?/);
  let ok = true;
  if (r.who === 'anon')              ok = !!m && m[1] === '0';
  else if (r.who === 'test user' && m && m[2] != null) ok = m[2] === '0';
  else if (r.who === 'stumarcot admin' && m && m[3] != null) ok = m[3] === '0';
  else if (r.test.startsWith('WRITE')) ok = r.result !== 'WRITE_SUCCEEDED' && !/ROWS_AFFECTED=[1-9]/.test(r.result);
  else if (r.test.startsWith('CONTROL')) ok = r.result === 'WRITE_SUCCEEDED';
  else if (r.who === 'deactivated user') ok = r.result === 'DEACTIVATED_VISIBLE=0';
  if (/DENIED/.test(r.result) && r.who !== 'anon') ok = false; // reads should filter, not error
  if (!ok) failures.push(r);
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${r.who.padEnd(16)} ${r.test.padEnd(50)} ${r.result}`);
}
console.log(failures.length ? `\n${failures.length} FAILURE(S)` : '\nAll isolation checks passed.');
process.exit(failures.length ? 1 : 0);
