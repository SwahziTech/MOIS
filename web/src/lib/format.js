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

/**
 * THE date format, everywhere (user rule, 2026-10-30): "Fri, 30 Oct 2026".
 * Takes a 'YYYY-MM-DD' or a timestamp; empty stays null so `?? '—'` works.
 */
export function dateText(v, timeZone = 'UTC') {
  if (v == null || v === '') return null;
  const s = String(v);
  const day = /^\d{4}-\d{2}-\d{2}$/.test(s);
  const d = new Date(day ? `${s}T00:00:00Z` : s);
  if (Number.isNaN(d.getTime())) return s;
  return d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric', timeZone: day ? 'UTC' : timeZone || undefined }).replace('Sept', 'Sep');
}

/** A moment: "Fri, 30 Oct 2026, 14:53" (pass the organization's time zone) */
export function dateTimeText(v, timeZone) {
  if (v == null || v === '') return null;
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) return String(v);
  const tz = timeZone || undefined;
  return `${dateText(v, tz)}, ${d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: tz })}`;
}

/** Dates inside text written elsewhere (database messages, saved summaries) */
export const datesInText = (s, format = dateText) => (s == null ? s : String(s).replace(/\b\d{4}-\d{2}-\d{2}\b/g, m => format(m)));

/** Inside a table: the date without the day, "30 Oct 2026" (user rule, 2026-10-30) */
export const tableDate = (v, timeZone) => dateText(v, timeZone)?.replace(/^\p{L}+,\s*/u, '') ?? null;

/** Inside a table: a moment without the day, "30 Oct 2026, 14:53" */
export const tableDateTime = (v, timeZone) => dateTimeText(v, timeZone)?.replace(/^\p{L}+,\s*/u, '') ?? null;
