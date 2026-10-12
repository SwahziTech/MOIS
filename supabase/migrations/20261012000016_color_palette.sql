-- ============================================================
-- Migration 016: Per-organization colour palette
--
-- Before: colour names were loose text in five places with no shared
--   source, and they disagreed ('White/OffWhite' vs 'White' vs 'OffWhite'):
--     product_categories.color_columns        (jsonb array of names)
--     recipe_versions.color_label             (also reused for press-mix labels)
--     category_color_pricing_rules.base_color (DEFAULT 'OffWhite')
--     category_color_pricing_rules.color_prices (jsonb, colour names as keys)
--     product_branch_pricing.color
-- After: one org-scoped `color_palette` table; every location references
--   it by id. No colour is built into the schema.
--
-- Existing text is mapped to ONE canonical name per real colour:
--   'White', 'OffWhite', 'White/OffWhite'  →  'White'
--   (product_master.json's global_color_palette declares these the same
--   colour; the tenant confirmed 'White' as their name for it, 2026-10-12).
-- All other names are kept exactly as written.
-- ============================================================

-- One-time mapping of legacy text → canonical palette name
CREATE FUNCTION pg_temp.canon_color(name text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN trim(name) IN ('White', 'OffWhite', 'White/OffWhite') THEN 'White'
              ELSE trim(name) END
$$;


-- ------------------------------------------------------------
-- 1. The palette
-- ------------------------------------------------------------
CREATE TABLE public.color_palette (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name            text NOT NULL CHECK (trim(name) <> ''),
  display_order   int  NOT NULL DEFAULT 0,
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);

CREATE INDEX idx_color_palette_org ON public.color_palette(organization_id);

CREATE TRIGGER trg_color_palette_updated_at
  BEFORE UPDATE ON public.color_palette
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.color_palette ENABLE ROW LEVEL SECURITY;

CREATE POLICY "color_palette: read own org"
  ON public.color_palette FOR SELECT
  USING (organization_id = public.get_my_org_id());

CREATE POLICY "color_palette: owner can manage"
  ON public.color_palette FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id() AND public.is_org_owner());

COMMENT ON TABLE public.color_palette
  IS 'Per-org colour palette. Every colour reference in MOIS points here; none is hardcoded.';

-- Fill it from every existing colour name, ordered by first appearance in
-- the categories' colour columns.
INSERT INTO public.color_palette (organization_id, name, display_order)
SELECT organization_id, name, min(ord)::int
FROM (
  SELECT pc.organization_id, pg_temp.canon_color(c.value) AS name, c.ord
  FROM public.product_categories pc,
       jsonb_array_elements_text(pc.color_columns) WITH ORDINALITY AS c(value, ord)
  WHERE jsonb_typeof(pc.color_columns) = 'array'
  UNION ALL
  SELECT organization_id, pg_temp.canon_color(base_color), 100 FROM public.category_color_pricing_rules
  UNION ALL
  SELECT r.organization_id, pg_temp.canon_color(k), 100
  FROM public.category_color_pricing_rules r, jsonb_object_keys(r.color_prices) AS k
  UNION ALL
  SELECT organization_id, pg_temp.canon_color(color), 100
  FROM public.product_branch_pricing WHERE color IS NOT NULL
) names
GROUP BY organization_id, name;


-- ------------------------------------------------------------
-- 2. Colour references must stay inside the organization
--    (TG_ARGV[0] = the colour column to check)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_color_org()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  color uuid;
BEGIN
  EXECUTE format('SELECT ($1).%I', TG_ARGV[0]) USING NEW INTO color;
  IF color IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.color_palette WHERE id = color AND organization_id = NEW.organization_id) THEN
    RAISE EXCEPTION 'Colour does not belong to this organization' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;


-- ------------------------------------------------------------
-- 3. product_categories.color_columns → product_category_colors
-- ------------------------------------------------------------
CREATE TABLE public.product_category_colors (
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  category_id     uuid NOT NULL REFERENCES public.product_categories(id) ON DELETE CASCADE,
  color_id        uuid NOT NULL REFERENCES public.color_palette(id) ON DELETE RESTRICT,
  display_order   int  NOT NULL DEFAULT 0,
  PRIMARY KEY (category_id, color_id)
);

CREATE INDEX idx_pcc_org ON public.product_category_colors(organization_id);

ALTER TABLE public.product_category_colors ENABLE ROW LEVEL SECURITY;

CREATE POLICY "pcc: read own org"
  ON public.product_category_colors FOR SELECT
  USING (organization_id = public.get_my_org_id());

CREATE POLICY "pcc: owner can manage"
  ON public.product_category_colors FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id() AND public.is_org_owner());

CREATE TRIGGER trg_pcc_color_org
  BEFORE INSERT OR UPDATE ON public.product_category_colors
  FOR EACH ROW EXECUTE FUNCTION public.check_color_org('color_id');

COMMENT ON TABLE public.product_category_colors
  IS 'Colours a category is made/stocked in (was product_categories.color_columns).';

INSERT INTO public.product_category_colors (organization_id, category_id, color_id, display_order)
SELECT pc.organization_id, pc.id, cp.id, min(c.ord)::int
FROM public.product_categories pc,
     jsonb_array_elements_text(pc.color_columns) WITH ORDINALITY AS c(value, ord)
JOIN public.color_palette cp ON cp.name = pg_temp.canon_color(c.value)
WHERE jsonb_typeof(pc.color_columns) = 'array'
  AND cp.organization_id = pc.organization_id
GROUP BY pc.organization_id, pc.id, cp.id;

ALTER TABLE public.product_categories DROP COLUMN color_columns;


-- ------------------------------------------------------------
-- 4. recipe_versions: color_label → color_id (colour recipes) or
--    variant_label (anything else, e.g. 'Standard', press-mix labels).
--    Exactly one of the two is set.
-- ------------------------------------------------------------
ALTER TABLE public.recipe_versions RENAME COLUMN color_label TO variant_label;
ALTER TABLE public.recipe_versions ALTER COLUMN variant_label DROP NOT NULL;
ALTER TABLE public.recipe_versions
  ADD COLUMN color_id uuid REFERENCES public.color_palette(id) ON DELETE RESTRICT;

-- A label is a colour only if it is one of its category's colours
UPDATE public.recipe_versions rv
SET color_id = pcc.color_id, variant_label = NULL
FROM public.product_category_colors pcc
JOIN public.color_palette cp ON cp.id = pcc.color_id
WHERE pcc.category_id = rv.category_id
  AND cp.name = pg_temp.canon_color(rv.variant_label);

ALTER TABLE public.recipe_versions
  ADD CONSTRAINT recipe_versions_color_xor_variant
  CHECK (num_nonnulls(color_id, variant_label) = 1);

-- Replace the old (org, category, color_label, version) unique key
DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.recipe_versions'::regclass AND contype = 'u'
  LOOP
    EXECUTE format('ALTER TABLE public.recipe_versions DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;

ALTER TABLE public.recipe_versions
  ADD CONSTRAINT recipe_versions_unique
  UNIQUE NULLS NOT DISTINCT (organization_id, category_id, color_id, variant_label, version_number);

CREATE TRIGGER trg_recipe_versions_color_org
  BEFORE INSERT OR UPDATE ON public.recipe_versions
  FOR EACH ROW EXECUTE FUNCTION public.check_color_org('color_id');

COMMENT ON COLUMN public.recipe_versions.variant_label
  IS 'Label for non-colour recipe variants (e.g. Standard, a press-mix). NULL when color_id is set.';


-- ------------------------------------------------------------
-- 5. category_color_pricing_rules
--    base_color text (DEFAULT 'OffWhite') → base_color_id, no default
--    color_prices jsonb → category_color_price_items rows
--    pricing_type 'delta_per_sqmt_over_offwhite' → 'delta_over_base_color'
-- ------------------------------------------------------------
ALTER TABLE public.category_color_pricing_rules
  ADD COLUMN base_color_id uuid REFERENCES public.color_palette(id) ON DELETE RESTRICT;

UPDATE public.category_color_pricing_rules r
SET base_color_id = cp.id
FROM public.color_palette cp
WHERE cp.organization_id = r.organization_id
  AND cp.name = pg_temp.canon_color(r.base_color);

ALTER TABLE public.category_color_pricing_rules ALTER COLUMN base_color_id SET NOT NULL;

CREATE TRIGGER trg_color_rules_color_org
  BEFORE INSERT OR UPDATE ON public.category_color_pricing_rules
  FOR EACH ROW EXECUTE FUNCTION public.check_color_org('base_color_id');

CREATE TABLE public.category_color_price_items (
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  rule_id         uuid NOT NULL REFERENCES public.category_color_pricing_rules(id) ON DELETE CASCADE,
  color_id        uuid NOT NULL REFERENCES public.color_palette(id) ON DELETE RESTRICT,
  amount          numeric NOT NULL,
  PRIMARY KEY (rule_id, color_id)
);

CREATE INDEX idx_ccpi_org ON public.category_color_price_items(organization_id);

ALTER TABLE public.category_color_price_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ccpi: read own org"
  ON public.category_color_price_items FOR SELECT
  USING (organization_id = public.get_my_org_id());

CREATE POLICY "ccpi: owner can manage"
  ON public.category_color_price_items FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id() AND public.is_org_owner());

CREATE TRIGGER trg_ccpi_color_org
  BEFORE INSERT OR UPDATE ON public.category_color_price_items
  FOR EACH ROW EXECUTE FUNCTION public.check_color_org('color_id');

COMMENT ON TABLE public.category_color_price_items
  IS 'Price for each non-base colour under a category colour-pricing rule (was color_prices jsonb).';

INSERT INTO public.category_color_price_items (organization_id, rule_id, color_id, amount)
SELECT r.organization_id, r.id, cp.id, (kv.value)::numeric
FROM public.category_color_pricing_rules r,
     jsonb_each_text(r.color_prices) AS kv(key, value)
JOIN public.color_palette cp ON cp.name = pg_temp.canon_color(kv.key)
WHERE cp.organization_id = r.organization_id;

ALTER TABLE public.category_color_pricing_rules DROP COLUMN base_color;
ALTER TABLE public.category_color_pricing_rules DROP COLUMN color_prices;

ALTER TABLE public.category_color_pricing_rules
  DROP CONSTRAINT category_color_pricing_rules_pricing_type_check;
UPDATE public.category_color_pricing_rules
  SET pricing_type = 'delta_over_base_color'
  WHERE pricing_type = 'delta_per_sqmt_over_offwhite';
ALTER TABLE public.category_color_pricing_rules
  ADD CONSTRAINT category_color_pricing_rules_pricing_type_check
  CHECK (pricing_type IN ('delta_over_base_color', 'absolute_price_per_sqmt'));


-- ------------------------------------------------------------
-- 6. product_branch_pricing.color → color_id (NULL = base price)
-- ------------------------------------------------------------
ALTER TABLE public.product_branch_pricing
  ADD COLUMN color_id uuid REFERENCES public.color_palette(id) ON DELETE RESTRICT;

UPDATE public.product_branch_pricing pbp
SET color_id = cp.id
FROM public.color_palette cp
WHERE pbp.color IS NOT NULL
  AND cp.organization_id = pbp.organization_id
  AND cp.name = pg_temp.canon_color(pbp.color);

ALTER TABLE public.product_branch_pricing DROP CONSTRAINT product_branch_pricing_unique;
ALTER TABLE public.product_branch_pricing DROP COLUMN color;
ALTER TABLE public.product_branch_pricing
  ADD CONSTRAINT product_branch_pricing_unique
  UNIQUE NULLS NOT DISTINCT (product_id, branch_id, color_id);

CREATE TRIGGER trg_pricing_color_org
  BEFORE INSERT OR UPDATE ON public.product_branch_pricing
  FOR EACH ROW EXECUTE FUNCTION public.check_color_org('color_id');

COMMENT ON COLUMN public.product_branch_pricing.color_id
  IS 'NULL = base price (the category''s base colour, or the only colour for plain categories).';
