import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import { supabase } from '../lib/supabase';
import { toAuthEmail } from '../lib/authId';

const AuthContext = createContext(null);

const EMPTY_SET = new Set();

// A dropped connection makes the browser wait ~20 s before failing (2026-11-19, the user: "the system loads longer"):
// give each sign-in read 8 s, then try again on a fresh connection — up to 4 tries
const isNetErr = e => !!e && !e.code && /abort|fetch|network|timed? ?out/i.test(`${e.name ?? ''} ${e.message ?? ''} ${e.details ?? ''}`);
async function patient(makeQuery) {
  let res;
  for (let i = 0; i < 4; i++) {
    res = await makeQuery().abortSignal(AbortSignal.timeout(8000));
    if (!isNetErr(res.error)) return res;
  }
  return res;
}

export function AuthProvider({ children }) {
  const [session,      setSession]      = useState(undefined); // undefined = resolving
  const [profile,      setProfile]      = useState(null);
  const [organization, setOrganization] = useState(null);
  const [userRoles,    setUserRoles]    = useState([]);
  const [permissions,  setPermissions]  = useState(EMPTY_SET);
  const [orgWidePermissions, setOrgWidePermissions] = useState(EMPTY_SET);
  const [profileReady, setProfileReady] = useState(false);
  const [recovering,   setRecovering]   = useState(false);
  const loadedFor = useRef(null); // user id whose profile is loaded / loading

  // who the person is, their company and roles, as last read — kept on this device so the app opens at once
  // (2026-11-27, the user: "the app itself loads forever"); refreshed from the server straight after, and the
  // database still checks every permission on every read and write
  const applied = useRef('');
  const applyAccess = useCallback((profileData, org, roles) => {
    // the same as already shown (the kept copy matched the server): leave it, so pages do not load again
    const key = JSON.stringify([profileData, org, roles]);
    if (key === applied.current) { setProfileReady(true); return; }
    applied.current = key;
    const permSet = new Set();
    const orgWideSet = new Set();
    for (const ur of roles) {
      const orgWide = !ur.branch_id && !ur.warehouse_id;
      for (const rp of ur.role?.role_permissions || []) {
        if (!rp.permission?.code) continue;
        permSet.add(rp.permission.code);
        if (orgWide) orgWideSet.add(rp.permission.code);
      }
    }
    setProfile(profileData || null);
    setOrganization(org);
    setUserRoles(roles);
    setPermissions(permSet);
    setOrgWidePermissions(orgWideSet);
    setProfileReady(true);
  }, []);

  const loadProfile = useCallback(async (userId) => {
    loadedFor.current = userId;
    let cached = null;
    try { cached = JSON.parse(localStorage.getItem(`mois.access.${userId}`) || 'null'); } catch { /* storage off */ }
    if (cached?.profile && cached.org) applyAccess(cached.profile, cached.org, cached.roles || []);
    else setProfileReady(false);

    const readProfile = () => patient(() => supabase.from('profiles').select('*').eq('id', userId).maybeSingle());
    let { data: profileData, error: profileErr } = await readProfile();
    // an expired sign-in (e.g. the tab sat closed overnight): renew it once; if that fails, back to the sign-in page —
    // never read it as "no organization" (2026-10-26)
    if (profileErr && (profileErr.code === 'PGRST303' || /JWT expired/i.test(profileErr.message ?? ''))) {
      const { error: refreshErr } = await supabase.auth.refreshSession();
      if (refreshErr) { await supabase.auth.signOut(); return; }
      ({ data: profileData, error: profileErr } = await readProfile());
    }
    if (profileErr) console.error('profile load failed', profileErr);
    if (loadedFor.current !== userId) return; // signed out / switched meanwhile

    let org = null;
    let roles = [];
    if (profileData?.organization_id) {
      const [orgRes, rolesRes] = await Promise.all([
        patient(() => supabase
          .from('organizations')
          .select('id, name, legal_name, logo_url, brand_config, status, currency_code, timezone, default_branch_id, yield_tolerance')
          .eq('id', profileData.organization_id)
          .maybeSingle()),
        patient(() => supabase
          .from('user_roles')
          .select(`
            id, branch_id, warehouse_id,
            role:roles(id, name, description,
              role_permissions(
                permission:permissions(code)
              )
            )
          `)
          .eq('user_id', userId)
          .eq('organization_id', profileData.organization_id)),
      ]);
      if (orgRes.error)   console.error('organization load failed', orgRes.error);
      if (rolesRes.error) console.error('roles load failed', rolesRes.error);
      org   = orgRes.data || null;
      roles = rolesRes.data || [];
    }
    if (loadedFor.current !== userId) return;
    // a failed read (no connection) keeps what was shown; a good one replaces it and is kept for next time
    if (profileErr && cached?.profile) return;

    // Flatten permissions into Sets: all grants, and org-wide grants only
    // (master-data writes require an org-wide grant — has_permission(), 018)
    applyAccess(profileData, org, roles);
    try {
      if (profileData && org) localStorage.setItem(`mois.access.${userId}`, JSON.stringify({ profile: profileData, org, roles }));
      else localStorage.removeItem(`mois.access.${userId}`);
    } catch { /* storage off */ }
  }, [applyAccess]);

  useEffect(() => {
    // onAuthStateChange fires INITIAL_SESSION on subscribe, so no separate
    // getSession() call is needed (that caused every profile to load twice).
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event, nextSession) => {
      setSession(nextSession);
      if (event === 'PASSWORD_RECOVERY') setRecovering(true);

      const userId = nextSession?.user?.id ?? null;
      if (!userId) {
        loadedFor.current = null;
        applied.current = '';
        setProfile(null);
        setOrganization(null);
        setUserRoles([]);
        setPermissions(EMPTY_SET);
        setOrgWidePermissions(EMPTY_SET);
        setProfileReady(false);
        return;
      }
      // Token refreshes re-fire this callback; only reload on a new user.
      // Deferred: Supabase calls awaited inside this callback can deadlock.
      if (loadedFor.current !== userId) setTimeout(() => loadProfile(userId), 0);
    });

    return () => subscription.unsubscribe();
  }, [loadProfile]);

  async function signIn(email, password) {
    return supabase.auth.signInWithPassword({ email: toAuthEmail(email), password });
  }

  async function signUp(email, password, meta = {}) {
    return supabase.auth.signUp({
      email,
      password,
      options: { data: meta, emailRedirectTo: window.location.origin },
    });
  }

  async function signInWithGoogle() {
    // Requires the Google provider enabled in Supabase (Auth → Providers)
    // and this origin in the allowed redirect URLs.
    return supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: window.location.origin },
    });
  }

  async function signOut() {
    // a shared office PC: the next person must not open on this person's details
    try { if (session?.user?.id) localStorage.removeItem(`mois.access.${session.user.id}`); } catch { /* storage off */ }
    return supabase.auth.signOut();
  }

  async function resetPassword(email) {
    return supabase.auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/reset-password`,
    });
  }

  /** Master-data administration: the permission via an org-wide role grant */
  function canManage(permCode) {
    return orgWidePermissions.has(permCode);
  }

  function can(permCode) {
    return permissions.has(permCode);
  }

  /**
   * Permission at a specific branch/warehouse: an org-wide, branch or
   * warehouse role grant (mirrors has_permission_at(), migration 022)
   */
  function canAt(permCode, branchId, warehouseId) {
    return userRoles.some(ur =>
      (ur.role?.role_permissions || []).some(rp => rp.permission?.code === permCode) &&
      ((!ur.branch_id && !ur.warehouse_id) ||
       (!ur.warehouse_id && ur.branch_id === branchId) ||
       (ur.warehouse_id && ur.warehouse_id === warehouseId)));
  }

  function hasRole(roleName) {
    return userRoles.some(ur => ur.role?.name === roleName);
  }

  const isAuthenticated = !!session;

  const value = {
    session,
    profile,
    organization,
    userRoles,
    permissions,
    // resolving the session, or signed in but profile/org/roles not loaded yet
    loading: session === undefined || (isAuthenticated && !profileReady),
    isAuthenticated,
    recovering,
    finishRecovery: () => setRecovering(false),
    can,
    canAt,
    canManage,
    hasRole,
    signIn,
    signInWithGoogle,
    signUp,
    signOut,
    resetPassword,
    reloadProfile: () => session?.user?.id && loadProfile(session.user.id),
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}
