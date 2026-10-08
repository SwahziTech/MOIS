-- ============================================================
-- Migration 006: Roles, Permissions, Role-Permissions, User-Roles
-- ============================================================

-- ----------------------------------------------------------------
-- permissions: platform-defined capability codes.
-- Not per-org — these are the fixed MOIS permission vocabulary.
-- ----------------------------------------------------------------
CREATE TABLE public.permissions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,   -- e.g. 'inventory.view'
  description text NOT NULL,
  module      text NOT NULL,          -- 'inventory', 'production', 'sales', etc.
  created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.permissions
  IS 'Platform-defined permission codes. Not per-org. Seeded once by MOIS.';

-- Seed the Phase 1a permission set
INSERT INTO public.permissions (code, description, module) VALUES
  -- Org admin
  ('org.manage',            'Manage org settings, branding, config',      'org'),
  ('users.invite',          'Invite and manage users',                     'org'),
  ('users.manage',          'Activate/deactivate users, change roles',     'org'),
  ('branches.manage',       'Create and manage branches',                  'org'),
  ('warehouses.manage',     'Create and manage warehouses',                'org'),
  -- Master data
  ('products.view',         'View products and categories',                'master_data'),
  ('products.manage',       'Create and edit products, recipes',           'master_data'),
  ('materials.view',        'View materials',                              'master_data'),
  ('materials.manage',      'Create and edit materials',                   'master_data'),
  -- Inventory (Phase 1b — codes defined now, enforced when feature ships)
  ('inventory.view',        'View stock balances and inventory',           'inventory'),
  ('inventory.receive',     'Receive goods into stock',                    'inventory'),
  ('inventory.issue',       'Issue materials from stock',                  'inventory'),
  ('inventory.transfer',    'Transfer stock between warehouses/branches',  'inventory'),
  ('inventory.adjust',      'Adjust stock balances',                       'inventory'),
  ('inventory.count',       'Perform stock counts',                        'inventory'),
  -- Procurement (Phase 1c)
  ('procurement.view',      'View purchase requests and orders',           'procurement'),
  ('procurement.request',   'Create purchase requests',                    'procurement'),
  ('procurement.approve',   'Approve purchase requests',                   'procurement'),
  ('procurement.order',     'Create and manage purchase orders',           'procurement'),
  ('procurement.receive',   'Record goods received',                       'procurement'),
  -- Production (Phase 1d)
  ('production.view',       'View production orders and batches',          'production'),
  ('production.create',     'Create production orders',                    'production'),
  ('production.execute',    'Record production batches and consumption',   'production'),
  ('production.complete',   'Complete and close production orders',        'production'),
  -- Sales (Phase 1e)
  ('sales.view',            'View quotations and orders',                  'sales'),
  ('sales.create',          'Create quotations and orders',                'sales'),
  ('invoices.create',       'Create and send invoices',                    'sales'),
  ('payments.record',       'Record customer payments',                    'sales'),
  -- Reports
  ('reports.view',          'View operational reports',                    'reports'),
  ('reports.financial',     'View financial reports and costing',          'reports');

-- ----------------------------------------------------------------
-- roles: per-organization role definitions
-- ----------------------------------------------------------------
CREATE TABLE public.roles (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name            text NOT NULL,
  description     text,
  is_system_role  boolean NOT NULL DEFAULT false, -- seeded by MOIS, not deletable
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);

CREATE INDEX idx_roles_org ON public.roles(organization_id);

ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.roles
  IS 'Per-org roles. is_system_role=true rows are seeded by MOIS and should not be deleted.';

-- ----------------------------------------------------------------
-- role_permissions: maps roles to permission codes
-- ----------------------------------------------------------------
CREATE TABLE public.role_permissions (
  role_id       uuid NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  permission_id uuid NOT NULL REFERENCES public.permissions(id) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_id)
);

ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------
-- user_roles: maps users to roles, optionally scoped to branch/warehouse
-- ----------------------------------------------------------------
CREATE TABLE public.user_roles (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role_id         uuid NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid REFERENCES public.branches(id) ON DELETE CASCADE,    -- null = all branches
  warehouse_id    uuid REFERENCES public.warehouses(id) ON DELETE CASCADE,  -- null = all warehouses
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  UNIQUE (user_id, role_id, organization_id, branch_id, warehouse_id)
);

CREATE INDEX idx_user_roles_user ON public.user_roles(user_id);
CREATE INDEX idx_user_roles_org  ON public.user_roles(organization_id);

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.user_roles
  IS 'User ↔ Role assignments. branch_id/warehouse_id scope the assignment; null = org-wide.';

-- ----------------------------------------------------------------
-- is_org_owner(): defined HERE (after user_roles exists, not in migration 005)
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_org_owner()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles ur
    JOIN public.roles r ON r.id = ur.role_id
    WHERE ur.user_id = auth.uid()
      AND r.name = 'owner'
  )
$$;

COMMENT ON FUNCTION public.is_org_owner()
  IS 'True if current user has the owner role. Used to gate admin writes in RLS policies.';
