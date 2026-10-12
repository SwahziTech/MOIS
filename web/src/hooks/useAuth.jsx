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
          .select('id, name, legal_name, logo_url, brand_config, status, currency_code')
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

    // Flatten permissions into a Set
    const permSet = new Set();
    for (const ur of roles) {
      for (const rp of ur.role?.role_permissions || []) {
        if (rp.permission?.code) permSet.add(rp.permission.code);
      }
    }

    setProfile(profileData || null);
    setOrganization(org);
    setUserRoles(roles);
    setPermissions(permSet);
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

  function can(permCode) {
    return permissions.has(permCode);
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
