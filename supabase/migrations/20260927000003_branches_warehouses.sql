-- ============================================================
-- Migration 003: Branches & Warehouses
-- ============================================================

-- Branches: physical factory/office locations within an organization
CREATE TABLE public.branches (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name            text NOT NULL,
  location        text,
  contact_info    jsonb NOT NULL DEFAULT '{}',  -- phone, email, address, etc.
  status          text NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'inactive')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid,           -- FK to auth.users — added after profiles exist
  updated_by      uuid
);

CREATE INDEX idx_branches_org ON public.branches(organization_id);

CREATE TRIGGER trg_branches_updated_at
  BEFORE UPDATE ON public.branches
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.branches
  IS 'Physical branch/factory locations. A user may be scoped to one or more branches.';

-- ----------------------------------------------------------------
-- Warehouses: inventory storage locations within a branch
-- ----------------------------------------------------------------
CREATE TABLE public.warehouses (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  name            text NOT NULL,
  type            text NOT NULL DEFAULT 'general'
                    CHECK (type IN ('raw_materials', 'finished_goods', 'wip', 'general')),
  status          text NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'inactive')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid,
  updated_by      uuid
);

CREATE INDEX idx_warehouses_org ON public.warehouses(organization_id);
CREATE INDEX idx_warehouses_branch ON public.warehouses(branch_id);

CREATE TRIGGER trg_warehouses_updated_at
  BEFORE UPDATE ON public.warehouses
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.warehouses ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.warehouses
  IS 'Inventory storage locations within a branch. Type distinguishes raw/WIP/finished/general.';
