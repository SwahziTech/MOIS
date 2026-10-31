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

/**
 * Holding an invitation, not signed in: an old session left in the browser must
 * not get in the way, so these go with the public key only. The message says
 * whether MOIS answered at all.
 */
export async function invitationCall(body) {
  const key = import.meta.env.VITE_SUPABASE_ANON_KEY;
  let res;
  try {
    res = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/manage-users`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: key, Authorization: `Bearer ${key}` },
      body: JSON.stringify(body),
    });
  } catch (e) {
    console.error('invitation call failed', e);
    throw new Error("We couldn't reach MOIS. Check your connection and try again.");
  }
  const payload = await res.json().catch(() => null);
  if (res.ok && payload) return payload;
  console.error('invitation call refused', res.status, payload);
  throw new Error(payload?.error || `Something went wrong (${res.status}). Please try again.`);
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
