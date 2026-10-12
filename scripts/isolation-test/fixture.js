// Creates a throwaway second tenant for the live isolation test.
// Idempotent: reuses the org/user if they already exist.
const path = require('path');
const P = path.join(__dirname, '..', '..') + '/';
require(P + 'scripts/node_modules/dotenv').config({ path: P + '.env', quiet: true });
const { createClient } = require(P + 'scripts/node_modules/@supabase/supabase-js');
const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });

const ORG_NAME = 'Isolation Test Org (throwaway)';
const EMAIL = 'isolation-test@mois-isolation.test';

async function must(p, what) { const r = await p; if (r.error) throw new Error(`${what}: ${r.error.message}`); return r.data; }

(async () => {
  // Org
  let org = (await must(sb.from('organizations').select('id').eq('name', ORG_NAME).maybeSingle(), 'org lookup'));
  if (!org) org = await must(sb.from('organizations').insert({ name: ORG_NAME, legal_name: 'ISOLATION TEST', status: 'active' }).select('id').single(), 'org insert');

  // User — no password: nobody can sign in as it; it exists only so RLS has an identity to evaluate.
  let userId;
  for (let page = 1; !userId; page++) {
    const { data } = await sb.auth.admin.listUsers({ page, perPage: 1000 });
    userId = data.users.find(u => u.email === EMAIL)?.id;
    if (data.users.length < 1000) break;
  }
  if (!userId) {
    const created = await must(sb.auth.admin.createUser({ email: EMAIL, email_confirm: true, user_metadata: { first_name: 'Isolation', last_name: 'Tester' } }), 'user create');
    userId = created.user.id;
  }
  await must(sb.from('profiles').update({ organization_id: org.id }).eq('id', userId), 'profile org');

  // Minimal tenant data so the reverse direction (Stumarcot reading this org) is testable too
  let branch = await must(sb.from('branches').select('id').eq('organization_id', org.id).eq('name', 'Test Branch').maybeSingle(), 'branch lookup');
  if (!branch) branch = await must(sb.from('branches').insert({ organization_id: org.id, name: 'Test Branch' }).select('id').single(), 'branch');
  const wh = await must(sb.from('warehouses').select('id').eq('branch_id', branch.id).maybeSingle(), 'wh lookup');
  if (!wh) await must(sb.from('warehouses').insert({ organization_id: org.id, branch_id: branch.id, name: 'Test Store' }), 'warehouse');
  let unit = await must(sb.from('units').select('id').eq('organization_id', org.id).eq('symbol', 'PCS').maybeSingle(), 'unit lookup');
  if (!unit) unit = await must(sb.from('units').insert({ organization_id: org.id, symbol: 'PCS', name: 'Pieces' }).select('id').single(), 'unit');
  let cat = await must(sb.from('product_categories').select('id').eq('organization_id', org.id).eq('category_id_ref', 'test_cat').maybeSingle(), 'cat lookup');
  if (!cat) cat = await must(sb.from('product_categories').insert({ organization_id: org.id, category_id_ref: 'test_cat', name: 'Test Category', display_format: 'plain', default_unit_id: unit.id }).select('id').single(), 'category');
  await must(sb.from('products').upsert({ organization_id: org.id, category_id: cat.id, unit_id: unit.id, product_id_ref: 'test_secret_product', canonical_name: 'TEST ORG SECRET PRODUCT' }, { onConflict: 'organization_id,product_id_ref' }), 'product');
  let role = await must(sb.from('roles').select('id').eq('organization_id', org.id).eq('name', 'owner').maybeSingle(), 'role lookup');
  if (!role) role = await must(sb.from('roles').insert({ organization_id: org.id, name: 'owner', is_system_role: true }).select('id').single(), 'role');
  const ur = await must(sb.from('user_roles').select('id').eq('user_id', userId).eq('role_id', role.id).maybeSingle(), 'ur lookup');
  if (!ur) await must(sb.from('user_roles').insert({ user_id: userId, role_id: role.id, organization_id: org.id }), 'user_role');

  const { data: stuma } = await sb.from('organizations').select('id').eq('legal_name', 'STUMARCOT CO LTD').single();
  const { data: admin } = await sb.from('profiles').select('id').eq('organization_id', stuma.id).limit(1).single();
  const { data: stumaRole } = await sb.from('roles').select('id').eq('organization_id', stuma.id).eq('name', 'owner').single();
  const { data: stumaCat } = await sb.from('product_categories').select('id').eq('organization_id', stuma.id).limit(1).single();
  console.log(JSON.stringify({ testOrg: org.id, testUser: userId, stumarcotOrg: stuma.id, stumarcotAdmin: admin.id, stumarcotOwnerRole: stumaRole.id, stumarcotCategory: stumaCat.id }));
})().catch(e => { console.error('FIXTURE FAILED:', e.message); process.exit(1); });
