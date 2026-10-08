-- ============================================================
-- Migration 007: Units
-- Per-org lookup table for measurement units.
-- (cement bag, bucket/ndoo, litre, kg, SQM, PCS, etc.)
-- ============================================================

CREATE TABLE public.units (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name            text NOT NULL,    -- 'Cement Bag (50kg)', 'Bucket (10L/20kg)', 'Kilogram', etc.
  symbol          text NOT NULL,    -- 'bag', 'bucket', 'kg', 'L', 'SQM', 'PCS'
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, symbol)
);

CREATE INDEX idx_units_org ON public.units(organization_id);

ALTER TABLE public.units ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.units
  IS 'Measurement units per org. Seeded from ratios_and_molds.json ingredient units.';
