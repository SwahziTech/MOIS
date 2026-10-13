import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import { supabase } from '../lib/supabase';

const AuthContext = createContext(null);

const EMPTY_SET = new Set();

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

  const loadProfile = useCallback(async (userId) => {
    loadedFor.current = userId;
    setProfileReady(false);

    const { data: profileData, error: profileErr } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', userId)
      .maybeSingle();
    if (profileErr) console.error('profile load failed', profileErr);
    if (loadedFor.current !== userId) return; // signed out / switched meanwhile

    let org = null;
    let roles = [];
    if (profileData?.organization_id) {
      const [orgRes, rolesRes] = await Promise.all([
        supabase
          .from('organizations')
          .select('id, name, legal_name, logo_url, brand_config, status, currency_code, timezone')
          .eq('id', profileData.organization_id)
          .maybeSingle(),
        supabase
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
          .eq('organization_id', profileData.organization_id),
      ]);
      if (orgRes.error)   console.error('organization load failed', orgRes.error);
      if (rolesRes.error) console.error('roles load failed', rolesRes.error);
      org   = orgRes.data || null;
      roles = rolesRes.data || [];
    }
    if (loadedFor.current !== userId) return;

    // Flatten permissions into Sets: all grants, and org-wide grants only
    // (master-data writes require an org-wide grant — has_permission(), 018)
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

  useEffect(() => {
    // onAuthStateChange fires INITIAL_SESSION on subscribe, so no separate
    // getSession() call is needed (that caused every profile to load twice).
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event, nextSession) => {
      setSession(nextSession);
      if (event === 'PASSWORD_RECOVERY') setRecovering(true);

      const userId = nextSession?.user?.id ?? null;
      if (!userId) {
        loadedFor.current = null;
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
    return supabase.auth.signInWithPassword({ email, password });
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
