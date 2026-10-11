/**
 * MOIS platform brand for the pre-login screens. MOIS is a SwahziTech
 * product; the tenant is unknown until the user signs in, so these screens
 * never show a company name (AGENTS.md §1). The tenant's name appears in the
 * app shell after login, read from the organizations table.
 */
export function MoisMark({ size = 40 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 40 40" aria-hidden="true" className="mois-mark">
      <rect width="40" height="40" rx="6" fill="var(--color-khaki)" />
      <rect x="11" y="11" width="6" height="6" fill="var(--color-coffee)" />
      <rect x="22" y="22" width="6" height="6" fill="var(--color-coffee)" />
    </svg>
  );
}

export default function AuthBrand() {
  return (
    <div className="auth-logo">
      <MoisMark />
      <span className="auth-logo-name">MOIS</span>
    </div>
  );
}
