-- ============================================================
-- Migration 010: Materials
-- Raw materials used in recipes. NOT suppliers (Phase 1b).
-- Seeded from the 'material' fields in ratios_and_molds.json.
-- ============================================================

CREATE TABLE public.materials (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name            text NOT NULL,       -- 'Cement', 'Mchanga (Sand)', 'Chipping', etc.
  code            text,                -- short reference code
  unit_id         uuid REFERENCES public.units(id) ON DELETE SET NULL,
  reorder_level   numeric,             -- Phase 1b: used for low-stock alerts
  status          text NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'inactive')),
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);

CREATE INDEX idx_materials_org ON public.materials(organization_id);

CREATE TRIGGER trg_materials_updated_at
  BEFORE UPDATE ON public.materials
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.materials ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.materials
  IS 'Raw materials used in production. Supplier relationships added in Phase 1b.';
