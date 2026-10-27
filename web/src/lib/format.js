/**
 * Money in the organization's own currency (organizations.currency_code).
 * Without a currency set, shows the plain number rather than guessing one.
 */
// the way a currency is written where it is used (2026-10-26): Tanzania writes "Tsh 10,000" (or "10,000 TZS")
const LOCAL_SYMBOL = { TZS: 'Tsh' };

export function formatMoney(value, currencyCode) {
  if (value == null) return '—';
  if (!currencyCode) return new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(value);
  if (LOCAL_SYMBOL[currencyCode]) {
    const n = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 }).format(Math.abs(value));
    return `${value < 0 ? '−' : ''}${LOCAL_SYMBOL[currencyCode]} ${n}`;
  }
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: currencyCode,
    currencyDisplay: 'code',
    maximumFractionDigits: 0,
  }).format(value);
}

/**
 * The browser's IANA time zone (e.g. 'Africa/Dar_es_Salaam'), or null.
 * Use it ONLY as the one-time default when an organization is created
 * (organizations.timezone) — never as a per-user "today": the ledger's date
 * boundary is the organization's setting, so everyone at a store agrees on
 * what day it is (migration 023).
 */
export function browserTimeZone() {
  try { return Intl.DateTimeFormat().resolvedOptions().timeZone || null; }
  catch { return null; }
}

/** A plain amount for a table whose header carries the currency, e.g. "Amount (TZS)" */
export function formatAmount(value) {
  if (value == null) return '—';
  return new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 }).format(value);
}

/** Money in short, for the note under a summary figure (2026-10-27): "Tsh 29.3M", "Tsh 845K" */
export function formatMoneyShort(value, currencyCode) {
  if (value == null) return '—';
  const a = Math.abs(value);
  const n = a >= 1e9 ? `${(a / 1e9).toFixed(1)}B` : a >= 1e6 ? `${(a / 1e6).toFixed(1)}M` : a >= 1e4 ? `${Math.round(a / 1e3)}K` : new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 }).format(a);
  return `${value < 0 ? '−' : ''}${LOCAL_SYMBOL[currencyCode] ?? currencyCode ?? ''} ${n.replace('.0', '')}`.trim();
}
