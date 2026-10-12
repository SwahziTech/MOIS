-- ============================================================
-- Migration 015: Stock unit per PRODUCT, from the per-org units table
--
-- Before: product_categories.stock_unit text CHECK IN ('SQM','PCS') —
--   only two units could ever exist, set per category, and not linked to
--   the per-org `units` table.
-- After:
--   - products.unit_id      → units(id), required. AGENTS.md §3: the stock
--                             unit is fixed per product.
--   - product_categories.default_unit_id → units(id), optional SUGGESTION
--                             for new products in the category; constrains
--                             nothing.
--   - product_categories.stock_unit (and its CHECK) dropped.
--   - units must belong to the same organization as the row using them.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Every org that uses a stock_unit value must have that unit in its
--    own `units` table. Stumarcot already has SQM and PCS; this only adds
--    rows for orgs missing one (e.g. the isolation-test org).
-- ------------------------------------------------------------
INSERT INTO public.units (organization_id, symbol, name)
SELECT DISTINCT pc.organization_id, pc.stock_unit,
       CASE pc.stock_unit WHEN 'SQM' THEN 'Square Metre' WHEN 'PCS' THEN 'Pieces' END
FROM public.product_categories pc
WHERE NOT EXISTS (
  SELECT 1 FROM public.units u
  WHERE u.organization_id = pc.organization_id AND u.symbol = pc.stock_unit
);


-- ------------------------------------------------------------
-- 2. New columns, backfilled from the category's old stock_unit
-- ------------------------------------------------------------
ALTER TABLE public.product_categories
  ADD COLUMN default_unit_id uuid REFERENCES public.units(id) ON DELETE SET NULL;

ALTER TABLE public.products
  ADD COLUMN unit_id uuid REFERENCES public.units(id) ON DELETE RESTRICT;

UPDATE public.product_categories pc
SET default_unit_id = u.id
FROM public.units u
WHERE u.organization_id = pc.organization_id
  AND u.symbol = pc.stock_unit;

UPDATE public.products p
SET unit_id = pc.default_unit_id
FROM public.product_categories pc
WHERE pc.id = p.category_id;

-- Every product now has a unit; require it from here on
ALTER TABLE public.products ALTER COLUMN unit_id SET NOT NULL;

CREATE INDEX idx_products_unit ON public.products(unit_id);

COMMENT ON COLUMN public.products.unit_id
  IS 'Stock unit for this product (per-org units table). Fixed per product — AGENTS.md §3.';
COMMENT ON COLUMN public.product_categories.default_unit_id
  IS 'Suggested unit for NEW products in this category. Does not constrain existing products.';


-- ------------------------------------------------------------
-- 3. Drop the hardcoded column (and with it the SQM/PCS CHECK)
-- ------------------------------------------------------------
ALTER TABLE public.product_categories DROP COLUMN stock_unit;


-- ------------------------------------------------------------
-- 4. A unit must belong to the same organization as the row using it
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_unit_org()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  unit uuid;
BEGIN
  -- Separate assignments: a field reference is only resolved when executed
  IF TG_TABLE_NAME = 'product_categories' THEN
    unit := NEW.default_unit_id;
  ELSE
    unit := NEW.unit_id;
  END IF;

  IF unit IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.units WHERE id = unit AND organization_id = NEW.organization_id) THEN
    RAISE EXCEPTION 'Unit does not belong to this organization' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_products_unit_org
  BEFORE INSERT OR UPDATE OF unit_id, organization_id ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.check_unit_org();

CREATE TRIGGER trg_product_categories_unit_org
  BEFORE INSERT OR UPDATE OF default_unit_id, organization_id ON public.product_categories
  FOR EACH ROW EXECUTE FUNCTION public.check_unit_org();
