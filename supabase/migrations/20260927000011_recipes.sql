-- ============================================================
-- Migration 011: Recipes (Versions, Items, Product Links)
--
-- KEY DESIGN RULE (AGENTS.md §3):
--   Recipes are SHARED PER CATEGORY + COLOR, not per individual mold/product.
--   All Floor Tile molds of the same color share one recipe version.
--   recipe_versions.category_id + color_label is the key.
--   recipe_version_products links which specific products use that recipe.
--
-- Historical immutability rule:
--   Once a batch references a recipe_version, that version must not be
--   modified — create a new version instead (status → 'archived' on old).
-- ============================================================

-- ----------------------------------------------------------------
-- recipe_versions: one row per category × color combination
-- ----------------------------------------------------------------
CREATE TABLE public.recipe_versions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  category_id     uuid NOT NULL REFERENCES public.product_categories(id) ON DELETE RESTRICT,
  color_label     text NOT NULL,    -- 'White', 'Red', 'Grey', 'Black', or 'Plain' for no-color
  version_number  int NOT NULL DEFAULT 1,
  effective_date  date NOT NULL DEFAULT CURRENT_DATE,
  status          text NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'archived')),
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  -- Only one active version per category+color at a time
  UNIQUE (organization_id, category_id, color_label, version_number)
);

CREATE INDEX idx_recipe_versions_org      ON public.recipe_versions(organization_id);
CREATE INDEX idx_recipe_versions_category ON public.recipe_versions(category_id);

CREATE TRIGGER trg_recipe_versions_updated_at
  BEFORE UPDATE ON public.recipe_versions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.recipe_versions ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.recipe_versions
  IS 'One recipe version per category+color. Shared by all products in that category+color. Never mutate a version referenced by a production batch.';

-- ----------------------------------------------------------------
-- recipe_items: materials + quantities in a recipe version
-- ----------------------------------------------------------------
CREATE TABLE public.recipe_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipe_version_id uuid NOT NULL REFERENCES public.recipe_versions(id) ON DELETE CASCADE,
  material_id       uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
  quantity          numeric NOT NULL CHECK (quantity >= 0),
  unit_id           uuid REFERENCES public.units(id) ON DELETE SET NULL,
  -- null quantity is allowed for materials whose amount is not yet confirmed
  -- (e.g. rangi/pigment for White = 0, recorded as null in source data)
  quantity_confirmed boolean NOT NULL DEFAULT true,
  notes             text,
  UNIQUE (recipe_version_id, material_id)
);

CREATE INDEX idx_recipe_items_version ON public.recipe_items(recipe_version_id);

ALTER TABLE public.recipe_items ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.recipe_items
  IS 'Material quantities per recipe version. quantity=0 means none used (e.g. no pigment for white).';

-- ----------------------------------------------------------------
-- recipe_version_products: which specific products use a given recipe version
-- (Many-to-many — many products per recipe version)
-- ----------------------------------------------------------------
CREATE TABLE public.recipe_version_products (
  recipe_version_id uuid NOT NULL REFERENCES public.recipe_versions(id) ON DELETE CASCADE,
  product_id        uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  PRIMARY KEY (recipe_version_id, product_id)
);

CREATE INDEX idx_rvp_product  ON public.recipe_version_products(product_id);
CREATE INDEX idx_rvp_version  ON public.recipe_version_products(recipe_version_id);

ALTER TABLE public.recipe_version_products ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.recipe_version_products
  IS 'Links products to their shared recipe version. Preserves the shared-ratio-per-category-and-color rule.';
