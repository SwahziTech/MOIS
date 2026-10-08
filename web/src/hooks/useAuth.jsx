import { createContext, useContext, useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [session,  setSession]  = useState(undefined); // undefined = loading
  const [profile,  setProfile]  = useState(null);
  const [userRoles, setUserRoles] = useState([]);
  const [permissions, setPermissions] = useState(new Set());

  useEffect(() => {
    // Get current session
    supabase.auth.getSession().then(({ data: { session } }) => {
      setSession(session);
      if (session) loadProfile(session.user.id);
    });

    // Listen for auth changes
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session);
      if (session) {
        loadProfile(session.user.id);
      } else {
        setProfile(null);
        setUserRoles([]);
        setPermissions(new Set());
      }
    });

    return () => subscription.unsubscribe();
  }, []);

  async function loadProfile(userId) {
    const { data: profileData } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', userId)
      .single();
    setProfile(profileData);

    if (!profileData?.organization_id) return;

    // Load user roles
    const { data: rolesData } = await supabase
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
      .eq('organization_id', profileData.organization_id);

    setUserRoles(rolesData || []);

    // Flatten permissions into a Set
    const permSet = new Set();
    for (const ur of rolesData || []) {
      for (const rp of ur.role?.role_permissions || []) {
        if (rp.permission?.code) permSet.add(rp.permission.code);
      }
    }
    setPermissions(permSet);
  }

  async function signIn(email, password) {
    return supabase.auth.signInWithPassword({ email, password });
  }

  async function signUp(email, password, meta = {}) {
    return supabase.auth.signUp({ email, password, options: { data: meta } });
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

  const value = {
    session,
    profile,
    userRoles,
    permissions,
    loading: session === undefined,
    isAuthenticated: !!session,
    can,
    hasRole,
    signIn,
    signUp,
    signOut,
    resetPassword,
    loadProfile,
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}
