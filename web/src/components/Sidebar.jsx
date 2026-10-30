import {
  LayoutDashboard, Package, Layers, DollarSign,
  Building2, Users, Settings, LogOut, LayoutGrid, Flag, Boxes, ArrowLeftRight, ShoppingCart, Factory, BookOpen,
  Calculator, Receipt, Contact, Wallet, HardHat, FileText, BarChart3, Landmark, CalendarClock, CalendarCheck, Files,
} from 'lucide-react';
import { useEffect, useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { roleLabel as labelOf } from '../lib/manageUsers';
import ThemeToggle from './ThemeToggle';
import AlertsBell from './AlertsBell';
import { primaryRole, resolveMenu } from '../lib/menu';
import { ChevronRight } from 'lucide-react';

/*
 * The sidebar, 2026-10-30: 9 sections of up to 3 pages (the agreed layout).
 * An entry with `group` stands for several pages shown as tabs under the
 * page heading (PageShell); an entry with `tabs` opens one page on those of
 * its tabs (?tab=). Statements, Documents and Print lists come later.
 */
export const NAV = [
  {
    section: 'Home',
    items: [
      { label: 'Dashboard',     to: '/',          icon: LayoutDashboard },
      // the day's report, written from MOIS or a written one checked against it (1f)
      { label: 'Daily report',  to: '/daily-report', icon: FileText, perm: 'production.view' },
      // changes waiting for an admin (033) and flags to review (yield band)
      { label: 'Review queue',  to: '/approvals', icon: Flag, badge: 'approvals', group: [
        { label: 'Approvals', to: '/approvals', perm: 'inventory.view' },
        { label: 'Reviews',   to: '/review',    perm: 'products.view' },
      ] },
    ],
  },
  {
    section: 'Master Data',
    items: [
      { label: 'Materials',     to: '/materials', icon: Layers,     perm: 'materials.view' },
      { label: 'Products',      to: '/products',  icon: Package, group: [
        { label: 'Products',      to: '/products',   perm: 'products.view' },
        { label: 'Categories',    to: '/categories', perm: 'products.view' },
        { label: 'Colours',       to: '/colours',    perm: 'products.view' },
        { label: 'Recipe / BOM',  to: '/recipes',    perm: 'products.view' },
      ] },
      { label: 'Pricing',       to: '/pricing',   icon: DollarSign, perm: 'products.view'  },
    ],
  },
  {
    section: 'Inventory & Procurement',
    items: [
      { label: 'Stock',         to: '/stock',     icon: Boxes,          perm: 'inventory.view' },
      { label: 'Movements',     to: '/movements', icon: ArrowLeftRight, perm: 'inventory.view' },
      { label: 'Procurement',   to: '/purchases', icon: ShoppingCart, group: [
        { label: 'Purchases', to: '/purchases', perm: 'procurement.view' },
        { label: 'Suppliers', to: '/suppliers', perm: 'materials.view' },
      ] },
    ],
  },
  {
    section: 'Production',
    items: [
      // batches, curing and quality release (migration 042)
      { label: 'Production',    to: '/production', icon: Factory,       perm: 'production.view' },
      // every confirmed production day, by period and stage (2026-10-21)
      { label: 'Job Costing',   to: '/production/ledger', icon: BookOpen, perm: 'production.view' },
      { label: 'Planner',       to: '/production?tab=planner', tabs: ['planner'], icon: CalendarClock, perm: 'production.view' },
    ],
  },
  {
    section: 'Sales',
    items: [
      // quotations → orders → invoices, payments; customers (1e, migration 064)
      { label: 'Sales',         to: '/sales', icon: Receipt, perm: 'sales.view' },
      { label: 'Customers',     to: '/customers', icon: Contact, perm: 'sales.view' },
      { label: 'Invoices',      to: '/sales?tab=list', tabs: ['list'], icon: Files, perm: 'sales.view' },
    ],
  },
  {
    section: 'Finance & Accounting',
    items: [
      // cost, price without VAT, margin, finished stock at cost (1e, migration 058) — managers
      { label: 'Costing',       to: '/costing', icon: Calculator, perm: 'products.manage' },
      // money in and out by account (094); Imprest = the branch's weekly cash (078)
      { label: 'Cash flow',     to: '/cash-flow', icon: Landmark, group: [
        { label: 'Cash flow', to: '/cash-flow',   perm: 'finance.view' },
        { label: 'Imprest',   to: '/weekly-cash', perm: 'cash.request' },
      ] },
    ],
  },
  {
    section: 'HR',
    items: [
      // employees and casual labourers, attendance, pay (Staff (HR), 071/086–091) — one page, three entries
      { label: 'Personnel',     to: '/staff', tabs: ['', 'employed', 'casual', 'teams'], icon: HardHat, perm: 'staff.view' },
      { label: 'Attendance',    to: '/staff?tab=attendance', tabs: ['attendance'], icon: CalendarCheck, perm: 'staff.view' },
      { label: 'Payroll',       to: '/staff?tab=pay', tabs: ['pay', 'advances', 'returns'], icon: Wallet, perm: 'staff.view' },
    ],
  },
  {
    section: 'Document Center',
    items: [
      // production, sales, spending, materials, profit, branches for a date range (PRD 4.15) — managers
      { label: 'Reports',       to: '/reports', icon: BarChart3, perm: 'products.manage' },
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

const NAV_ITEMS = NAV.flatMap(s => s.items);
const pathOf = to => to.split('?')[0];
/** may this person open the entry (any page of a group) */
export const canSee = (item, can) => (item.group ? item.group.some(g => !g.perm || can(g.perm)) : !item.perm || can(item.perm));
/** where the entry goes: a group's first page this person may open */
export const hrefOf = (item, can) => (item.group ? (item.group.find(g => !g.perm || can(g.perm))?.to ?? item.to) : item.to);
/** is the entry the page open now (a group's pages; a page's tabs split between entries) */
export function navActive(item, loc) {
  if (item.group) return item.group.some(g => loc.pathname === g.to);
  const path = pathOf(item.to);
  if (loc.pathname !== path) return false;
  const cur = new URLSearchParams(loc.search).get('tab') || '';
  if (item.tabs) return item.tabs.includes(cur);
  return !NAV_ITEMS.some(o => o !== item && !o.group && pathOf(o.to) === path && o.tabs?.includes(cur));
}
/** the group the open page belongs to, for the tabs under its heading */
export const groupOf = pathname => NAV_ITEMS.find(i => i.group?.some(g => g.to === pathname)) ?? null;

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

  // the layout for this person's role (098), else the current sidebar; only the pages they may open
  const [layouts, setLayouts] = useState({});
  useEffect(() => {
    if (!session) return;
    supabase.from('menu_layouts').select('role_name, layout').then(({ data, error }) => {
      if (!error) setLayouts(Object.fromEntries((data || []).map(x => [x.role_name, x.layout])));
    });
    const reload = () => supabase.from('menu_layouts').select('role_name, layout').then(({ data, error }) => {
      if (!error) setLayouts(Object.fromEntries((data || []).map(x => [x.role_name, x.layout])));
    });
    window.addEventListener('mois:menu-changed', reload);
    return () => window.removeEventListener('mois:menu-changed', reload);
  }, [session]);
  const role = primaryRole(userRoles);
  const sections = resolveMenu(NAV, layouts[role])
    .map(section => ({ ...section, items: section.items.filter(item => canSee(item, can)) }))
    .filter(section => section.items.length > 0);
  // a folded section opens on a click (and when one of its pages is open)
  const [unfolded, setUnfolded] = useState({});
  const isOpen = sec => !sec.folded || unfolded[sec.title] || sec.items.some(i => navActive(i, location));

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
        <div className="sidebar-logo-toggle"><AlertsBell /><ThemeToggle /></div>
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
        {sections.map((section, si) => (
          <div key={`${section.title}|${si}`} className="sidebar-section">
            {section.title && (section.folded
              ? <button type="button" className="sidebar-section-label sidebar-fold" aria-expanded={isOpen(section)} onClick={() => setUnfolded(u => ({ ...u, [section.title]: !isOpen(section) }))}>
                  <ChevronRight size={12} className={isOpen(section) ? 'is-open' : ''} />{section.title}</button>
              : <div className="sidebar-section-label">{section.title}</div>)}
            {isOpen(section) && section.items.map(item => (
              <Link
                key={item.to}
                id={`nav-${item.to === '/' ? 'dashboard' : item.to.slice(1).replace(/[^a-z0-9]+/gi, '-')}`}
                to={hrefOf(item, can)}
                title={item.label}
                aria-current={navActive(item, location) ? 'page' : undefined}
                className={`sidebar-item${navActive(item, location) ? ' active' : ''}`}
              >
                <item.icon size={16} strokeWidth={1.8} />
                <span>{item.label}</span>
                {item.badge === 'approvals' && pending > 0 && (
                  <b className="sidebar-badge" aria-label={`${pending} pending`}>{pending > 99 ? '99+' : pending}</b>
                )}
              </Link>
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
