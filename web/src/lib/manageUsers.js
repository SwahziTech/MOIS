import { supabase } from './supabase';

/**
 * Calls the manage-users Edge Function (invite, activate/deactivate).
 * Those actions need the service-role key, so they run server-side.
 * Throws an Error whose message is safe to show to the user.
 */
export async function manageUsers(body) {
  const { data, error } = await supabase.functions.invoke('manage-users', { body });
  if (error) {
    let message = 'Something went wrong. Please try again.';
    try {
      const payload = await error.context?.json();
      if (payload?.error) message = payload.error; // function returns user-facing messages only
    } catch { /* non-JSON response */ }
    console.error('manage-users failed', error);
    throw new Error(message);
  }
  return data;
}

// Display names where the stored role name isn't the label (migration 034:
// the system role 'owner' is the Technical admin)
const ROLE_LABELS = { owner: 'Technical admin' };

/** 'branch_manager' → 'Branch manager'; 'owner' → 'Technical admin' */
export function roleLabel(name) {
  if (!name) return '';
  if (ROLE_LABELS[name]) return ROLE_LABELS[name];
  const s = name.replace(/_/g, ' ');
  return s.charAt(0).toUpperCase() + s.slice(1);
}
