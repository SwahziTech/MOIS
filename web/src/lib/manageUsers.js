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

/** 'branch_manager' → 'Branch manager' */
export function roleLabel(name) {
  if (!name) return '';
  const s = name.replace(/_/g, ' ');
  return s.charAt(0).toUpperCase() + s.slice(1);
}
