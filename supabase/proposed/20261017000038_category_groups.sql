-- ============================================================
-- 038 — Category groups: a parent with subcategories (1c)
--         PROPOSED — not applied. Dry-run on a live snapshot first.
--
-- Decided with SwahziTech (2026-10-17): Stumarcot's "Paving Blocks Vibro"
-- and "Press Machine Paving" are subcategories ("Vibro", "Press") of one
-- category, "Paving Blocks". Generic: any organization can group
-- categories one level deep.
--
-- A group (a parent) is only a heading: products, recipes, colours,
-- colour pricing and size specs stay on the subcategories, so nothing that
-- points at today's categories moves — no product is reassigned,
-- orphaned or duplicated. Rules:
--   * one level only: a subcategory can't have subcategories, and a group
--     can't itself be inside a group;
--   * a group holds no products, colours, recipes, colour pricing or size
--     specs (it would be ambiguous which subcategory they belong to) —
--     so a category already holding any of these can't become a group.
-- The tenant's data change (new group, renames, old names kept as import
-- decisions) is a separate one-off script.
-- ============================================================

ALTER TABLE public.product_categories
  ADD COLUMN parent_category_id uuid REFERENCES public.product_categories(id) ON DELETE RESTRICT;
COMMENT ON COLUMN public.product_categories.parent_category_id
  IS 'The group this category sits under (one level). A group holds no products, colours, recipes or prices itself.';
CREATE INDEX idx_product_categories_parent ON public.product_categories(parent_category_id);

CREATE TRIGGER trg_product_categories_parent_org BEFORE INSERT OR UPDATE ON public.product_categories
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('product_categories', 'parent_category_id');

-- True when the category is a group (something sits under it)
CREATE OR REPLACE FUNCTION public.is_category_group(p_category_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.product_categories WHERE parent_category_id = p_category_id)
$$;

-- One level, and a group stays empty
CREATE OR REPLACE FUNCTION public.check_category_parent()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE p public.product_categories;
BEGIN
  IF NEW.parent_category_id IS NULL THEN RETURN NEW; END IF;
  IF NEW.parent_category_id = NEW.id THEN
    RAISE EXCEPTION 'A category can''t be its own group' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO p FROM public.product_categories WHERE id = NEW.parent_category_id;
  IF p.parent_category_id IS NOT NULL THEN
    RAISE EXCEPTION '% is itself under a group — groups go one level deep', p.name USING ERRCODE = '23514';
  END IF;
  IF public.is_category_group(NEW.id) THEN
    RAISE EXCEPTION '% has categories under it, so it can''t go under another', NEW.name USING ERRCODE = '23514';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products WHERE category_id = p.id)
     OR EXISTS (SELECT 1 FROM public.product_category_colors WHERE category_id = p.id)
     OR EXISTS (SELECT 1 FROM public.recipe_versions WHERE category_id = p.id)
     OR EXISTS (SELECT 1 FROM public.category_color_pricing_rules WHERE category_id = p.id)
     OR EXISTS (SELECT 1 FROM public.product_size_specs WHERE category_id = p.id) THEN
    RAISE EXCEPTION '% has products, colours, recipes or prices of its own, so it can''t become a group', p.name
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_product_categories_parent BEFORE INSERT OR UPDATE OF parent_category_id ON public.product_categories
  FOR EACH ROW EXECUTE FUNCTION public.check_category_parent();

-- Nothing is put on a group itself
CREATE OR REPLACE FUNCTION public.check_not_category_group()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.is_category_group(NEW.category_id) THEN
    RAISE EXCEPTION 'That category is a group — choose one of the categories under it' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_products_not_group BEFORE INSERT OR UPDATE OF category_id ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.check_not_category_group();
CREATE TRIGGER trg_pcc_not_group BEFORE INSERT OR UPDATE OF category_id ON public.product_category_colors
  FOR EACH ROW EXECUTE FUNCTION public.check_not_category_group();
CREATE TRIGGER trg_recipe_versions_not_group BEFORE INSERT ON public.recipe_versions
  FOR EACH ROW EXECUTE FUNCTION public.check_not_category_group();
CREATE TRIGGER trg_color_rules_not_group BEFORE INSERT OR UPDATE OF category_id ON public.category_color_pricing_rules
  FOR EACH ROW EXECUTE FUNCTION public.check_not_category_group();
CREATE TRIGGER trg_size_specs_not_group BEFORE INSERT OR UPDATE OF category_id ON public.product_size_specs
  FOR EACH ROW EXECUTE FUNCTION public.check_not_category_group();
