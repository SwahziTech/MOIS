/**
 * Platform brand for the pre-login screens. The tenant is unknown until the
 * user signs in, so these screens show MOIS — never a specific company
 * (AGENTS.md §1: no tenant identity in code).
 */
export default function AuthBrand() {
  return (
    <div className="auth-logo">
      <div className="auth-logo-mark">M</div>
      <div>
        <div className="auth-logo-name">MOIS</div>
        <div className="auth-logo-sub">Manufacturing Operating Intelligent System</div>
      </div>
    </div>
  );
}
