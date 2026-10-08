import {
  LayoutDashboard, Package, Layers, ScrollText, DollarSign,
  Building2, Users, Settings, LogOut, LayoutGrid,
} from 'lucide-react';
import { NavLink, useNavigate } from 'react-router-dom';
import { useAuth } from '../hooks/useAuth';

/*
 * Navigation tabs. `perm` documents the permission each page relates to;
 * data access itself is enforced by Supabase RLS, so every tab is shown
 * (pages render an empty/error state if the user can't read the data).
 */
const NAV = [
  {
    section: 'Overview',
    items: [
      { label: 'Dashboard',     to: '/',          icon: LayoutDashboard },
    ],
  },
  {
    section: 'Master Data',
    items: [
      { label: 'Products',      to: '/products',  icon: Package,    perm: 'products.view'  },
      { label: 'Materials',     to: '/materials', icon: Layers,     perm: 'materials.view' },
      { label: 'Recipes / BOM', to: '/recipes',   icon: ScrollText, perm: 'recipes.view'   },
      { label: 'Pricing',       to: '/pricing',   icon: DollarSign, perm: 'pricing.view'   },
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
  const { profile, session, signOut } = useAuth();
  const navigate = useNavigate();

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

  async function handleSignOut() {
    await signOut();
    navigate('/login');
  }

  return (
    <aside className="sidebar">
      {/* Logo / Org header */}
      <div className="sidebar-logo">
        <div className="sidebar-logo-mark">
          <LayoutGrid size={15} strokeWidth={2.2} />
        </div>
        <div className="sidebar-logo-text">
          <span className="sidebar-org-name">Stumarcot Co Ltd</span>
          <span className="sidebar-system-label">MOIS Platform</span>
        </div>
      </div>

      {/* Navigation */}
      <nav className="sidebar-nav" aria-label="Main navigation">
        {NAV.map(section => (
          <div key={section.section} className="sidebar-section">
            <div className="sidebar-section-label">{section.section}</div>
            {section.items.map(item => (
              <NavLink
                key={item.to}
                id={`nav-${item.to === '/' ? 'dashboard' : item.to.slice(1)}`}
                to={item.to}
                end={item.to === '/'}
                className={({ isActive }) => `sidebar-item${isActive ? ' active' : ''}`}
              >
                <item.icon size={16} strokeWidth={1.8} />
                <span>{item.label}</span>
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
