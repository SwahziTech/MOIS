-- ============================================================
-- Migration 009: Product Branch Pricing
--
-- Preserves the price_list_structured.json structure:
--   - National price list with genuine per-branch differences
--   - Most products share one price across all 3 branches
--   - Some genuinely differ (e.g. culverts in Mwanza cost more)
--   - color = null for plain/no-color products (PCS-based)
--   - canonical_match=null rows in source have no pricing row here
-- ============================================================

CREATE TABLE public.product_branch_pricing (
  id                              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id                 uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  product_id                      uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  branch_id                       uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  color                           text,         -- null for plain/no-color products
  -- Per-unit pricing (piece price for PCS products)
  price_per_unit_exclusive        numeric,      -- ex-VAT price per piece
  vat_per_unit                    numeric,      -- VAT per piece
  price_per_unit_inclusive        numeric,      -- inc-VAT price per piece
  -- SQM pricing (for SQM-stocked products: tiles, paving)
  price_per_sqm_inclusive         numeric,      -- inc-VAT per SQM
  pcs_per_sqm_at_pricing          int,          -- how many pcs/sqm this price is based on
  -- Metadata from source
  is_available                    boolean NOT NULL DEFAULT true,
  price_consistent_across_branches boolean NOT NULL DEFAULT true,
  source_item_no                  int,          -- item # in original price list
  raw_notes                       text,         -- any notes from the original price list
  created_at                      timestamptz NOT NULL DEFAULT now(),
  updated_at                      timestamptz NOT NULL DEFAULT now(),
  -- One pricing row per product × branch × color
  UNIQUE (product_id, branch_id, color)
);

CREATE INDEX idx_pricing_org     ON public.product_branch_pricing(organization_id);
CREATE INDEX idx_pricing_product ON public.product_branch_pricing(product_id);
CREATE INDEX idx_pricing_branch  ON public.product_branch_pricing(branch_id);

CREATE TRIGGER trg_pricing_updated_at
  BEFORE UPDATE ON public.product_branch_pricing
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.product_branch_pricing ENABLE ROW LEVEL SECURITY;

-- Color pricing rules per category × branch (delta over base color, or absolute)
-- This stores the category-level color surcharge rules from price_list_structured.json
CREATE TABLE public.category_color_pricing_rules (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  category_id     uuid NOT NULL REFERENCES public.product_categories(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  base_color      text NOT NULL DEFAULT 'OffWhite',
  pricing_type    text NOT NULL
                    CHECK (pricing_type IN ('delta_per_sqmt_over_offwhite', 'absolute_price_per_sqmt')),
  -- color → surcharge/price map stored as jsonb: { "Red": 3000, "Grey": 3000 }
  color_prices    jsonb NOT NULL DEFAULT '{}',
  raw_notes       jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (category_id, branch_id)
);

CREATE INDEX idx_color_rules_org ON public.category_color_pricing_rules(organization_id);

ALTER TABLE public.category_color_pricing_rules ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.product_branch_pricing
  IS 'Per-product × per-branch × per-color pricing. Preserves genuine branch price differences from price_list_structured.json.';
COMMENT ON TABLE public.category_color_pricing_rules
  IS 'Category-level color surcharge rules (e.g. Red/Grey = +3000 TZS/SQM over OffWhite).';
