/*
 * Email or username sign-in (migration 100, 2026-10-31). Supabase Auth needs an
 * email, so a username account has a hidden address nobody sees or receives
 * mail at. Same domain as the manage-users function.
 */
const HIDDEN_EMAIL_DOMAIN = 'users.mois.invalid';

/** What was typed in the sign-in box → the address Supabase Auth knows */
export const toAuthEmail = typed => {
  const t = String(typed ?? '').trim();
  return t.includes('@') ? t : `${t.toLowerCase()}@${HIDDEN_EMAIL_DOMAIN}`;
};

export const isHiddenEmail = email => String(email ?? '').endsWith(`@${HIDDEN_EMAIL_DOMAIN}`);
