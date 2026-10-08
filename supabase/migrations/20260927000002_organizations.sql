-- ============================================================
-- Migration 002: Organizations
-- The top-level multi-tenant boundary. One row = one company.
-- No organization_id here — this IS the organization.
-- No RLS on this table; access controlled at app layer + platform admin.
-- ============================================================

CREATE TABLE public.organizations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,                        -- display name
  legal_name    text,                                 -- legal/registered name
  logo_url      text,
  brand_config  jsonb NOT NULL DEFAULT '{}',          -- colors, favicon, doc branding
  status        text NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active', 'suspended', 'inactive')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_organizations_updated_at
  BEFORE UPDATE ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Only authenticated users can read organizations they belong to.
-- The actual RLS policy referencing profiles is in migration 012
-- (after profiles table exists). Enable RLS now; policies come later.
ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.organizations
  IS 'Multi-tenant root. One row per manufacturing company (tenant).';
