/**
 * Money in the organization's own currency (organizations.currency_code).
 * Without a currency set, shows the plain number rather than guessing one.
 */
export function formatMoney(value, currencyCode) {
  if (value == null) return '—';
  if (!currencyCode) return new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(value);
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: currencyCode,
    currencyDisplay: 'code',
    maximumFractionDigits: 0,
  }).format(value);
}
