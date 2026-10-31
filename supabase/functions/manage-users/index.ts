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
//
// Invitations and username sign-in (migration 100, 2026-10-31):
// POST { action: 'create_invitation', first_name, last_name?, role_id, branch_id?, warehouse_id?, origin }
//        Technical admin; a Branch Manager for their own branch and roles below theirs
// POST { action: 'cancel_invitation', id }
// POST { action: 'create_reset', user_id, origin }   a username user's password; same people
// Without signing in, holding a link or code:
// POST { action: 'invitation_check', token | code }
// POST { action: 'username_available', token | code, username }
// POST { action: 'invitation_claim', token | code, method: 'email'|'username', email | username, password }
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
  const managedBranches = new Set<string>();   // where they are Branch Manager
  for (const g of grants ?? []) {
    // deno-lint-ignore no-explicit-any
    const role = (g as any).role;
    if (role?.name === 'owner') isOwner = true;
    // deno-lint-ignore no-explicit-any
    if (role?.name === 'branch_manager' && (g as any).branch_id) managedBranches.add((g as any).branch_id);
    // deno-lint-ignore no-explicit-any
    if ((g as any).branch_id || (g as any).warehouse_id) continue;
    for (const rp of role?.role_permissions ?? []) if (rp.permission?.code) permissions.add(rp.permission.code);
  }
  return { userId: user.id, orgId, permissions, isOwner, managedBranches };
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

// ---- Invitations and username sign-in (migration 100) ----

const INVITE_HOURS = 48;
const HIDDEN_EMAIL_DOMAIN = 'users.mois.invalid';   // same as web/src/lib/authId.js
const USERNAME_RE = /^[a-z0-9][a-z0-9._-]{2,29}$/;
const MIN_PASSWORD = 8;
const BM_MAY_INVITE = new Set(['secretary', 'storekeeper', 'sales_user', 'production_user']);
const CODE_LETTERS = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';   // none that read alike
const MAX_WRONG = 20;
const WRONG_WINDOW_MINUTES = 15;

async function sha256(text: string) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
}
function newToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function newCode() {
  const bytes = crypto.getRandomValues(new Uint8Array(6));
  return Array.from(bytes).map(b => CODE_LETTERS[b % CODE_LETTERS.length]).join('');
}
// "mois-7k4 qpx" and "7K4QPX" are the same code
const cleanCode = (raw: unknown) => String(raw ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '').replace(/^MOIS/, '');
const inviteLink = (origin: unknown, token: string) => `${String(origin ?? '').replace(/\/$/, '')}/invite?t=${token}`;

async function issue(row: Record<string, unknown>, origin: unknown) {
  const token = newToken();
  const code = newCode();
  const { data, error } = await admin.from('user_invitations').insert({
    ...row,
    token_hash: await sha256(token),
    code_hash: await sha256(code),
    expires_at: new Date(Date.now() + INVITE_HOURS * 3600_000).toISOString(),
  }).select('id, expires_at').single();
  if (error) throw error;
  // shown once: only the hashes are kept
  return { id: data.id, expires_at: data.expires_at, code: `MOIS-${code}`, link: inviteLink(origin, token) };
}

async function createInvitation(caller: Caller, body: Record<string, unknown>) {
  const firstName = String(body.first_name ?? '').trim();
  const lastName = String(body.last_name ?? '').trim();
  const roleId = String(body.role_id ?? '');
  const branchId = body.branch_id ? String(body.branch_id) : null;
  const warehouseId = body.warehouse_id ? String(body.warehouse_id) : null;
  if (!firstName) throw new HttpError(400, 'Enter their name.');
  if (!roleId) throw new HttpError(400, 'Choose a role.');

  const { data: role } = await admin.from('roles').select('id, name').eq('id', roleId).eq('organization_id', caller.orgId).maybeSingle();
  if (!role) throw new HttpError(400, 'That role does not exist in your organization.');
  if (!caller.isOwner) {
    if (!branchId || !caller.managedBranches.has(branchId)) throw new HttpError(403, 'You can only invite people to your own branch.');
    if (!BM_MAY_INVITE.has(role.name)) throw new HttpError(403, 'Only the Technical admin can invite someone to this role.');
  }
  if (branchId) {
    const { data } = await admin.from('branches').select('id').eq('id', branchId).eq('organization_id', caller.orgId).maybeSingle();
    if (!data) throw new HttpError(400, 'That branch does not exist in your organization.');
  }
  if (warehouseId) {
    let q = admin.from('warehouses').select('id').eq('id', warehouseId).eq('organization_id', caller.orgId);
    if (branchId) q = q.eq('branch_id', branchId);
    const { data } = await q.maybeSingle();
    if (!data) throw new HttpError(400, 'That store does not exist in the selected branch.');
  }
  return await issue({
    organization_id: caller.orgId, kind: 'invite', first_name: firstName, last_name: lastName,
    role_id: roleId, branch_id: branchId, warehouse_id: warehouseId, created_by: caller.userId,
  }, body.origin);
}

/** The Technical admin, or the Branch Manager of a branch the invitation or person belongs to */
function mayManageInBranch(caller: Caller, branchId: string | null) {
  return caller.isOwner || (!!branchId && caller.managedBranches.has(branchId));
}

async function cancelInvitation(caller: Caller, body: Record<string, unknown>) {
  const { data: inv } = await admin.from('user_invitations').select('id, branch_id, status')
    .eq('id', String(body.id ?? '')).eq('organization_id', caller.orgId).maybeSingle();
  if (!inv) throw new HttpError(404, 'Invitation not found.');
  if (!mayManageInBranch(caller, inv.branch_id)) throw new HttpError(403, 'You do not have permission to do this.');
  if (inv.status !== 'waiting') throw new HttpError(409, 'This invitation has already been used or cancelled.');
  const { error } = await admin.from('user_invitations').update({ status: 'cancelled' }).eq('id', inv.id).eq('status', 'waiting');
  if (error) throw error;
  return { id: inv.id };
}

async function createReset(caller: Caller, body: Record<string, unknown>) {
  const userId = String(body.user_id ?? '');
  const { data: target } = await admin.from('profiles').select('id, first_name, last_name, username')
    .eq('id', userId).eq('organization_id', caller.orgId).maybeSingle();
  if (!target) throw new HttpError(404, 'User not found in your organization.');
  if (!target.username) throw new HttpError(400, 'This person signs in by email and can reset their own password.');
  const { data: grants } = await admin.from('user_roles').select('branch_id, role:roles(name)').eq('user_id', userId).eq('organization_id', caller.orgId);
  // deno-lint-ignore no-explicit-any
  const rows = (grants ?? []) as any[];
  const branchId = rows.find(g => g.branch_id && caller.managedBranches.has(g.branch_id))?.branch_id ?? rows.find(g => g.branch_id)?.branch_id ?? null;
  if (!caller.isOwner) {
    if (!branchId || !caller.managedBranches.has(branchId)) throw new HttpError(403, 'You can only do this for people at your own branch.');
    if (rows.some(g => !BM_MAY_INVITE.has(g.role?.name))) throw new HttpError(403, 'Only the Technical admin can do this for this person.');
  }
  // an earlier reset link stops working
  const { error: oldErr } = await admin.from('user_invitations').update({ status: 'cancelled' })
    .eq('target_user_id', userId).eq('kind', 'reset').eq('status', 'waiting');
  if (oldErr) throw oldErr;
  return await issue({
    organization_id: caller.orgId, kind: 'reset', first_name: target.first_name ?? '', last_name: target.last_name ?? '',
    target_user_id: userId, branch_id: branchId, created_by: caller.userId,
  }, body.origin);
}

/** Slows down guessing codes: a source with too many wrong tries waits */
async function requireNotBlocked(source: string) {
  const since = new Date(Date.now() - WRONG_WINDOW_MINUTES * 60_000).toISOString();
  const { count, error } = await admin.from('invitation_attempts').select('id', { count: 'exact', head: true }).eq('source', source).gte('created_at', since);
  if (error) throw error;
  if ((count ?? 0) >= MAX_WRONG) throw new HttpError(429, 'Too many tries. Please wait a few minutes.');
}

/** The waiting invitation a link or code belongs to. Every wrong or old one reads the same */
async function findInvitation(req: Request, body: Record<string, unknown>) {
  const source = await sha256(req.headers.get('x-forwarded-for')?.split(',')[0].trim() || 'unknown');
  await requireNotBlocked(source);
  const code = cleanCode(body.code);
  const hash = body.token ? await sha256(String(body.token)) : code ? await sha256(code) : null;
  const column = body.token ? 'token_hash' : 'code_hash';
  const { data } = hash
    ? await admin.from('user_invitations').select('*').eq(column, hash).eq('status', 'waiting').gt('expires_at', new Date().toISOString()).maybeSingle()
    : { data: null };
  if (!data) {
    await admin.from('invitation_attempts').insert({ source });
    throw new HttpError(404, 'This invitation has expired or isn\'t valid. Ask for a new one.');
  }
  return data;
}

async function invitationCheck(req: Request, body: Record<string, unknown>) {
  const inv = await findInvitation(req, body);
  const [role, branch, target] = await Promise.all([
    inv.role_id ? admin.from('roles').select('name').eq('id', inv.role_id).maybeSingle() : Promise.resolve({ data: null }),
    inv.branch_id ? admin.from('branches').select('name').eq('id', inv.branch_id).maybeSingle() : Promise.resolve({ data: null }),
    inv.target_user_id ? admin.from('profiles').select('username').eq('id', inv.target_user_id).maybeSingle() : Promise.resolve({ data: null }),
  ]);
  // no company name: the rule for sign-in screens
  return { kind: inv.kind, first_name: inv.first_name, role: role.data?.name ?? null, branch: branch.data?.name ?? null, username: target.data?.username ?? null };
}

async function usernameTaken(username: string) {
  const { data, error } = await admin.from('profiles').select('id').eq('username', username).maybeSingle();
  if (error) throw error;
  return !!data;
}

async function usernameAvailable(req: Request, body: Record<string, unknown>) {
  await findInvitation(req, body);
  const username = String(body.username ?? '').trim().toLowerCase();
  if (!USERNAME_RE.test(username)) return { available: false, reason: 'Use 3 to 30 letters or numbers; . _ and - are allowed inside.' };
  return { available: !(await usernameTaken(username)) };
}

async function invitationClaim(req: Request, body: Record<string, unknown>) {
  const inv = await findInvitation(req, body);
  const password = String(body.password ?? '');
  if (password.length < MIN_PASSWORD) throw new HttpError(400, `Use at least ${MIN_PASSWORD} characters for your password.`);

  // one use: whoever takes it first; given back if anything below fails
  const { data: taken, error: takeErr } = await admin.from('user_invitations')
    .update({ status: 'claimed', claimed_at: new Date().toISOString() }).eq('id', inv.id).eq('status', 'waiting').select('id');
  if (takeErr) throw takeErr;
  if (!taken?.length) throw new HttpError(409, 'This invitation has already been used.');
  const giveBack = () => admin.from('user_invitations').update({ status: 'waiting', claimed_at: null }).eq('id', inv.id);

  try {
    if (inv.kind === 'reset') {
      const { error } = await admin.auth.admin.updateUserById(inv.target_user_id, { password });
      if (error) throw error;
      await admin.from('user_invitations').update({ claimed_by: inv.target_user_id }).eq('id', inv.id);
      const { data: p } = await admin.from('profiles').select('username').eq('id', inv.target_user_id).maybeSingle();
      return { sign_in: p?.username ?? null };
    }

    const method = body.method;
    let email: string; let username: string | null = null;
    if (method === 'username') {
      username = String(body.username ?? '').trim().toLowerCase();
      if (!USERNAME_RE.test(username)) throw new HttpError(400, 'Use 3 to 30 letters or numbers; . _ and - are allowed inside.');
      if (await usernameTaken(username)) throw new HttpError(409, 'That username is taken. Try another.');
      email = `${username}@${HIDDEN_EMAIL_DOMAIN}`;
    } else if (method === 'email') {
      email = String(body.email ?? '').trim().toLowerCase();
      if (!EMAIL_RE.test(email)) throw new HttpError(400, 'Enter a valid email address.');
      const { data: existing } = await admin.from('profiles').select('id').ilike('email', email).maybeSingle();
      if (existing) throw new HttpError(409, 'This email can\'t be used. Ask whoever invited you.');
    } else {
      throw new HttpError(400, 'Choose email or username.');
    }

    const { data: made, error: mErr } = await admin.auth.admin.createUser({
      email, password, email_confirm: true,
      user_metadata: { first_name: inv.first_name, last_name: inv.last_name },
    });
    if (mErr || !made.user) {
      console.error('createUser failed', mErr);
      throw new HttpError(502, 'We couldn\'t create your account. Please try again.');
    }
    const userId = made.user.id;
    const { error: pErr } = await admin.from('profiles').update({
      organization_id: inv.organization_id, status: 'active', username,
      first_name: inv.first_name, last_name: inv.last_name,
    }).eq('id', userId);
    if (pErr) throw pErr;
    const { error: urErr } = await admin.from('user_roles').insert({
      user_id: userId, role_id: inv.role_id, organization_id: inv.organization_id,
      branch_id: inv.branch_id, warehouse_id: inv.warehouse_id, created_by: inv.created_by,
    });
    if (urErr) throw urErr;
    await admin.from('user_invitations').update({ claimed_by: userId }).eq('id', inv.id);
    return { sign_in: username ?? email };
  } catch (e) {
    await giveBack();
    throw e;
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json(405, { error: 'Method not allowed.' });

  try {
    const body = await req.json().catch(() => ({}));
    // holding a link or code, not signed in yet
    switch (body.action) {
      case 'invitation_check':   return json(200, await invitationCheck(req, body));
      case 'username_available': return json(200, await usernameAvailable(req, body));
      case 'invitation_claim':   return json(200, await invitationClaim(req, body));
    }
    const caller = await getCaller(req);
    switch (body.action) {
      case 'create_invitation': return json(200, await createInvitation(caller, body));
      case 'cancel_invitation': return json(200, await cancelInvitation(caller, body));
      case 'create_reset':      return json(200, await createReset(caller, body));
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
