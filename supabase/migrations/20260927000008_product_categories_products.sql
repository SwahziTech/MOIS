-- ============================================================
-- Migration 008: Product Categories & Products
--
-- Key rules from AGENTS.md and product_master.json:
--   - display_format: 'colored' (one qty col per color) | 'plain' (single qty col)
--   - stock_unit: 'SQM' for tiles/paving | 'PCS' for everything else
--   - pcs_per_sqm is the MOLD property (coverage), NOT the recipe yield
--   - wastani_per_bag is the RECIPE yield (pieces per 50kg cement bag)
-- ============================================================

-- ----------------------------------------------------------------
-- product_categories
-- ----------------------------------------------------------------
CREATE TABLE public.product_categories (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  category_id_ref text NOT NULL,   -- slug from product_master.json, e.g. 'floor_tiles'
  name            text NOT NULL,
  display_format  text NOT NULL CHECK (display_format IN ('colored', 'plain')),
  stock_unit      text NOT NULL CHECK (stock_unit IN ('SQM', 'PCS')),
  color_columns   jsonb,           -- array of color names when display_format='colored'
  sort_order      int NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, category_id_ref)
);

CREATE INDEX idx_product_categories_org ON public.product_categories(organization_id);

CREATE TRIGGER trg_product_categories_updated_at
  BEFORE UPDATE ON public.product_categories
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.product_categories ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------
-- products
-- ----------------------------------------------------------------
CREATE TABLE public.products (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  category_id     uuid NOT NULL REFERENCES public.product_categories(id) ON DELETE RESTRICT,
  product_id_ref  text NOT NULL,   -- from product_master.json, e.g. 'floor_tiles_04'
  canonical_name  text NOT NULL,
  size_cm         text,            -- null where not recorded in source data
  -- SQM coverage (mold property, NOT recipe yield — never conflate)
  pcs_per_sqm     numeric,         -- null where not recorded; do NOT guess
  -- Recipe yield (per bag of cement — recipe/ratio property, NOT mold)
  wastani_per_bag numeric,         -- null where not recorded; do NOT guess
  status          text NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'inactive')),
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, product_id_ref)
);

CREATE INDEX idx_products_org      ON public.products(organization_id);
CREATE INDEX idx_products_category ON public.products(category_id);

CREATE TRIGGER trg_products_updated_at
  BEFORE UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

COMMENT ON COLUMN public.products.pcs_per_sqm
  IS 'Pieces to cover 1 SQM — property of the mold physical size. Distinct from wastani_per_bag.';
COMMENT ON COLUMN public.products.wastani_per_bag
  IS 'Avg pieces per 50kg cement bag — property of the recipe/mix ratio. Distinct from pcs_per_sqm.';
