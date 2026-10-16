// manage-users — server-side user administration for an organization.
//
// Needs the service-role key (invite by email, ban/unban), which must never
// reach the browser (AGENTS.md §6), so it lives here. Every request is
// authorized against the CALLER's own organization and permissions; the
// client cannot choose which org it acts on.
//
// POST { action: 'invite', email, first_name?, last_name?, role_id,
//        branch_id?, warehouse_id?, redirect_to? }          needs users.invite (org-wide)
// POST { action: 'set_status', user_id, status: 'active'|'inactive' }
//                                                            needs users.manage (org-wide)
// Only a Technical admin (system role 'owner') grants that role or changes
// a Technical admin's status (migration 034).
import { createClient } from 'npm:@supabase/supabase-js@2.117.2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY     = Deno.env.get('SUPABASE_ANON_KEY')!;

const CORS = {
  'Access-Control-Allow-Origin': '*', // bearer-token auth, no cookies
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const BAN_FOREVER = '876000h'; // ~100 years; 'none' lifts it

/** Resolves the signed-in caller, their active org and permission codes. */
async function getCaller(req: Request) {
  const authHeader = req.headers.get('Authorization') ?? '';
  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: { user }, error } = await userClient.auth.getUser();
  if (error || !user) throw new HttpError(401, 'Not signed in.');

  const { data: profile } = await admin
    .from('profiles').select('organization_id, status').eq('id', user.id).maybeSingle();
  if (!profile?.organization_id || profile.status !== 'active') {
    throw new HttpError(403, 'Your account is not active in an organization.');
  }
  const orgId = profile.organization_id as string;

  const { data: grants, error: gErr } = await admin
    .from('user_roles')
    .select('branch_id, warehouse_id, role:roles(name, role_permissions(permission:permissions(code)))')
    .eq('user_id', user.id)
    .eq('organization_id', orgId);
  if (gErr) throw gErr;

  // Staffing is an org-wide right: a branch- or store-scoped grant of
  // users.invite / users.manage does not count here
  const permissions = new Set<string>();
  let isOwner = false;
  for (const g of grants ?? []) {
    // deno-lint-ignore no-explicit-any
    const role = (g as any).role;
    if (role?.name === 'owner') isOwner = true;
    // deno-lint-ignore no-explicit-any
    if ((g as any).branch_id || (g as any).warehouse_id) continue;
    for (const rp of role?.role_permissions ?? []) if (rp.permission?.code) permissions.add(rp.permission.code);
  }
  return { userId: user.id, orgId, permissions, isOwner };
}

type Caller = Awaited<ReturnType<typeof getCaller>>;

function requirePermission(caller: Caller, code: string) {
  if (!caller.permissions.has(code)) throw new HttpError(403, 'You do not have permission to do this.');
}

async function invite(caller: Caller, body: Record<string, unknown>) {
  requirePermission(caller, 'users.invite');

  const email = String(body.email ?? '').trim().toLowerCase();
  const firstName = String(body.first_name ?? '').trim();
  const lastName  = String(body.last_name ?? '').trim();
  const roleId = String(body.role_id ?? '');
  const branchId = body.branch_id ? String(body.branch_id) : null;
  const warehouseId = body.warehouse_id ? String(body.warehouse_id) : null;
  if (!EMAIL_RE.test(email)) throw new HttpError(400, 'Enter a valid email address.');
  if (!roleId) throw new HttpError(400, 'Choose a role.');

  // Role / branch / warehouse must belong to the caller's org
  const { data: role } = await admin
    .from('roles').select('id, name').eq('id', roleId).eq('organization_id', caller.orgId).maybeSingle();
  if (!role) throw new HttpError(400, 'That role does not exist in your organization.');
  if (role.name === 'owner' && !caller.isOwner) throw new HttpError(403, 'Only the Technical admin can grant the Technical admin role.');
  if (branchId) {
    const { data } = await admin.from('branches').select('id').eq('id', branchId).eq('organization_id', caller.orgId).maybeSingle();
    if (!data) throw new HttpError(400, 'That branch does not exist in your organization.');
  }
  if (warehouseId) {
    let q = admin.from('warehouses').select('id').eq('id', warehouseId).eq('organization_id', caller.orgId);
    if (branchId) q = q.eq('branch_id', branchId);
    const { data } = await q.maybeSingle();
    if (!data) throw new HttpError(400, 'That warehouse does not exist in the selected branch.');
  }

  // Existing account (e.g. signed up with Google before being added)?
  const { data: existing } = await admin
    .from('profiles').select('id, organization_id').ilike('email', email).maybeSingle();

  let userId: string;
  let invited = false;
  if (existing) {
    if (existing.organization_id === caller.orgId) throw new HttpError(409, 'This person is already a member of your organization.');
    // Deliberately vague: do not reveal which other tenant they belong to
    if (existing.organization_id) throw new HttpError(409, 'This email cannot be added. Contact MOIS support.');
    userId = existing.id;
  } else {
    const redirectTo = typeof body.redirect_to === 'string' && /^https?:\/\//.test(body.redirect_to)
      ? body.redirect_to : undefined;
    const { data, error } = await admin.auth.admin.inviteUserByEmail(email, {
      data: { first_name: firstName, last_name: lastName },
      redirectTo,
    });
    if (error) {
      console.error('inviteUserByEmail failed', error);
      throw new HttpError(502, 'The invitation email could not be sent. Please try again.');
    }
    userId = data.user.id;
    invited = true;
  }

  const profileUpdate: Record<string, unknown> = { organization_id: caller.orgId, status: 'active' };
  if (firstName) profileUpdate.first_name = firstName;
  if (lastName) profileUpdate.last_name = lastName;
  const { error: pErr } = await admin.from('profiles').update(profileUpdate).eq('id', userId);
  if (pErr) throw pErr;

  const { error: urErr } = await admin.from('user_roles').insert({
    user_id: userId, role_id: roleId, organization_id: caller.orgId,
    branch_id: branchId, warehouse_id: warehouseId, created_by: caller.userId,
  });
  if (urErr) throw urErr;

  return { user_id: userId, invited };
}

async function setStatus(caller: Caller, body: Record<string, unknown>) {
  requirePermission(caller, 'users.manage');

  const userId = String(body.user_id ?? '');
  const status = body.status;
  if (status !== 'active' && status !== 'inactive') throw new HttpError(400, 'Invalid status.');
  if (userId === caller.userId) throw new HttpError(400, 'You cannot change your own account status.');

  const { data: target } = await admin
    .from('profiles').select('id').eq('id', userId).eq('organization_id', caller.orgId).maybeSingle();
  if (!target) throw new HttpError(404, 'User not found in your organization.');

  // A Technical admin can only be deactivated by another Technical admin
  const { data: targetRoles } = await admin
    .from('user_roles').select('role:roles(name)').eq('user_id', userId).eq('organization_id', caller.orgId);
  // deno-lint-ignore no-explicit-any
  if ((targetRoles ?? []).some((r: any) => r.role?.name === 'owner') && !caller.isOwner) {
    throw new HttpError(403, 'Only the Technical admin can change a Technical admin\'s status.');
  }

  const { error: pErr } = await admin.from('profiles').update({ status }).eq('id', userId);
  if (pErr) throw pErr;

  // Block sign-in too; RLS already denies data access via get_my_org_id()
  const { error: bErr } = await admin.auth.admin.updateUserById(userId, {
    ban_duration: status === 'inactive' ? BAN_FOREVER : 'none',
  });
  if (bErr) throw bErr;

  return { user_id: userId, status };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json(405, { error: 'Method not allowed.' });

  try {
    const caller = await getCaller(req);
    const body = await req.json().catch(() => ({}));
    switch (body.action) {
      case 'invite':     return json(200, await invite(caller, body));
      case 'set_status': return json(200, await setStatus(caller, body));
      default:           return json(400, { error: 'Unknown action.' });
    }
  } catch (e) {
    if (e instanceof HttpError) return json(e.status, { error: e.message });
    console.error('manage-users failed', e); // details stay in function logs (PRD §10.12)
    return json(500, { error: 'Something went wrong. Please try again.' });
  }
});
