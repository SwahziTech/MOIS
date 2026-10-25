import {
  LayoutDashboard, Package, Layers, ScrollText, DollarSign,
  Building2, Users, Settings, LogOut, LayoutGrid, FolderTree, Palette, Flag, Truck, Boxes, ArrowLeftRight, CheckSquare, ShoppingCart, Factory, BookOpen,
  Calculator,
} from 'lucide-react';
import { useEffect, useState } from 'react';
import { NavLink, useLocation, useNavigate } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { roleLabel as labelOf } from '../lib/manageUsers';
import ThemeToggle from './ThemeToggle';

/*
 * Navigation tabs. An item with `perm` is shown only to users holding that
 * permission (AGENTS.md §7: users see only the modules they're authorized
 * for). This is UX only — Supabase RLS remains the security boundary.
 * Codes must exist in public.permissions (migration 006).
 */
const NAV = [
  {
    section: 'Overview',
    items: [
      { label: 'Dashboard',     to: '/',          icon: LayoutDashboard },
      // price changes and stock corrections waiting for an admin (migration 033)
      { label: 'Approvals',     to: '/approvals', icon: CheckSquare, perm: 'inventory.view', badge: 'approvals' },
    ],
  },
  {
    section: 'Master Data',
    items: [
      { label: 'Products',      to: '/products',  icon: Package,    perm: 'products.view'  },
      { label: 'Categories',    to: '/categories', icon: FolderTree, perm: 'products.view' },
      { label: 'Colours',       to: '/colours',  icon: Palette,    perm: 'products.view' },
      { label: 'Materials',     to: '/materials', icon: Layers,     perm: 'materials.view' },
      { label: 'Suppliers',     to: '/suppliers', icon: Truck,     perm: 'materials.view' },
      { label: 'Recipes / BOM', to: '/recipes',   icon: ScrollText, perm: 'products.view'  },
      { label: 'Pricing',       to: '/pricing',   icon: DollarSign, perm: 'products.view'  },
      { label: 'Review queue',  to: '/review',   icon: Flag,       perm: 'products.view' },
    ],
  },
  {
    section: 'Inventory',
    items: [
      { label: 'Stock',         to: '/stock',     icon: Boxes,          perm: 'inventory.view' },
      { label: 'Movements',     to: '/movements', icon: ArrowLeftRight, perm: 'inventory.view' },
      { label: 'Purchases',     to: '/purchases', icon: ShoppingCart,   perm: 'procurement.view' },
    ],
  },
  {
    section: 'Production',
    items: [
      // batches, curing and quality release (migration 042)
      { label: 'Production',    to: '/production', icon: Factory,       perm: 'production.view' },
      // every confirmed production day, by period and stage (2026-10-21)
      { label: 'Production ledger', to: '/production/ledger', icon: BookOpen, perm: 'production.view' },
    ],
  },
  {
    section: 'Sales & Costing',
    items: [
      // cost, price without VAT, margin, finished stock at cost (1e, migration 058)
      { label: 'Costing', to: '/costing', icon: Calculator, perm: 'products.manage' },
    ],
  },
  {
    section: 'Organization',
    items: [
      { label: 'Branches',      to: '/branches',  icon: Building2,  perm: 'branches.manage' },
      { label: 'Users',         to: '/users',     icon: Users,      perm: 'users.invite'    },
      { label: 'Settings',      to: '/settings',  icon: Settings },
    ],
  },
];

export default function Sidebar() {
  const { profile, session, organization, userRoles, can, signOut } = useAuth();
  const { branchId, setBranchId, branches, allowAll } = useBranch();
  const navigate = useNavigate();
  const location = useLocation();
  const pending = usePendingApprovals(branchId, location.pathname, !!session);
  // Hidden to icons until pointed at (2026-10-20); on touch screens the logo opens it, and it closes on navigating
  const [open, setOpen] = useState(false);
  useEffect(() => { setOpen(false); }, [location.pathname]);

  const fullName =
    [profile?.first_name, profile?.last_name].filter(Boolean).join(' ') ||
    session?.user?.email?.split('@')[0] ||
    'User';

  const initials = fullName
    .split(/\s+/)
    .map(w => w[0])
    .join('')
    .slice(0, 2)
    .toUpperCase();

  const roleLabel = [...new Set(userRoles.map(ur => ur.role?.name).filter(Boolean))]
    .map(labelOf)
    .join(', ');

  const sections = NAV
    .map(section => ({ ...section, items: section.items.filter(item => !item.perm || can(item.perm)) }))
    .filter(section => section.items.length > 0);

  async function handleSignOut() {
    await signOut();
    navigate('/login');
  }

  return (
    <aside className={`sidebar${open ? ' is-open' : ''}`} onMouseLeave={() => setOpen(false)}>
      {/* Logo / Org header */}
      <div className="sidebar-logo">
        <button type="button" className="sidebar-logo-mark" aria-label={open ? 'Close menu' : 'Open menu'} aria-expanded={open} onClick={() => setOpen(o => !o)}>
          <LayoutGrid size={15} strokeWidth={2.2} />
        </button>
        <div className="sidebar-logo-text">
          <span className="sidebar-org-name" title={organization?.legal_name || organization?.name}>
            {organization?.name || 'Organization'}
          </span>
          <span className="sidebar-system-label">MOIS Platform</span>
        </div>
        {/* light / dark mode — every page used to carry it in a top bar */}
        <div className="sidebar-logo-toggle"><ThemeToggle /></div>
      </div>

      {/* Branch the screens are looking at */}
      {branches.length > 0 && (
        <div className="sidebar-branch">
          <label className="sidebar-section-label" htmlFor="sidebar-branch">Branch</label>
          <select id="sidebar-branch" className="form-input sidebar-branch-select" value={branchId}
            disabled={!allowAll && branches.length === 1} onChange={e => setBranchId(e.target.value)}>
            {allowAll && <option value="">All branches</option>}
            {branches.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}
          </select>
        </div>
      )}

      {/* Navigation */}
      <nav className="sidebar-nav" aria-label="Main navigation">
        {sections.map(section => (
          <div key={section.section} className="sidebar-section">
            <div className="sidebar-section-label">{section.section}</div>
            {section.items.map(item => (
              <NavLink
                key={item.to}
                id={`nav-${item.to === '/' ? 'dashboard' : item.to.slice(1)}`}
                to={item.to}
                end={item.to === '/' || item.to === '/production'}
                title={item.label}
                className={({ isActive }) => `sidebar-item${isActive ? ' active' : ''}`}
              >
                <item.icon size={16} strokeWidth={1.8} />
                <span>{item.label}</span>
                {item.badge === 'approvals' && pending > 0 && (
                  <b className="sidebar-badge" aria-label={`${pending} pending`}>{pending > 99 ? '99+' : pending}</b>
                )}
              </NavLink>
            ))}
          </div>
        ))}
      </nav>

      {/* User footer */}
      <div className="sidebar-footer">
        <div className="sidebar-user">
          <div className="sidebar-avatar">{initials}</div>
          <div className="sidebar-user-info">
            <div className="sidebar-user-name truncate">{fullName}</div>
            {roleLabel && <div className="sidebar-user-role truncate">{roleLabel}</div>}
          </div>
        </div>
        <button id="sidebar-signout" type="button" className="sidebar-signout" onClick={handleSignOut}>
          <LogOut size={13} />
          <span>Sign out</span>
        </button>
      </div>
    </aside>
  );
}

/**
 * How many changes wait in the Approvals queue (033) for the branch picked
 * in the sidebar (all on "All branches"). Re-counted on every page change,
 * every minute, and when the Approvals page decides one.
 */
function usePendingApprovals(branchId, path, signedIn) {
  const [count, setCount] = useState(0);
  useEffect(() => {
    if (!signedIn) return undefined;
    let live = true;
    const load = async () => {
      let q = supabase.from('pending_changes').select('id', { count: 'exact', head: true }).eq('status', 'pending');
      if (branchId) q = q.eq('branch_id', branchId);
      const { count: n, error } = await q;
      if (live && !error) setCount(n ?? 0);
    };
    load();
    const timer = setInterval(load, 60000);
    window.addEventListener('mois:approvals-changed', load);
    return () => { live = false; clearInterval(timer); window.removeEventListener('mois:approvals-changed', load); };
  }, [branchId, path, signedIn]);
  return count;
}
