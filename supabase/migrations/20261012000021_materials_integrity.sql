-- ============================================================
-- 021 — Materials integrity for in-app editing (build-plan 1a.1 step 6)
--
-- 019 checks units when a source or conversion is written, but nothing
-- stopped a later edit from pulling the ground out from under them:
--
--   1. A unit conversion cannot be removed (or re-pointed to another unit)
--      while a branch source buys in that unit or a recipe (any version,
--      archived ones included — they are history) measures in it.
--   2. A material's stock unit is set once: it can be filled in when empty
--      (e.g. steel, awaiting the tenant) or changed while nothing depends on
--      it, but not after conversions, sources or recipe lines exist — those
--      are all expressed relative to it.
--   3. A material used by an ACTIVE recipe cannot be deactivated; change the
--      recipe first (a new version without it).
--
-- These are business rules, so they apply to every writer (app, scripts).
-- ============================================================


-- 1. Conversions in use
CREATE OR REPLACE FUNCTION public.guard_conversion_in_use()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.material_id = OLD.material_id AND NEW.unit_id = OLD.unit_id THEN
    RETURN NEW;   -- factor / notes only
  END IF;
  IF EXISTS (SELECT 1 FROM public.material_branch_sources
             WHERE material_id = OLD.material_id AND purchase_unit_id = OLD.unit_id)
  OR EXISTS (SELECT 1 FROM public.recipe_items
             WHERE material_id = OLD.material_id AND unit_id = OLD.unit_id) THEN
    RAISE EXCEPTION 'This unit is used by a branch source or a recipe of this material, so its conversion must stay'
      USING ERRCODE = '23514';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER trg_muc_in_use
  BEFORE UPDATE OR DELETE ON public.material_unit_conversions
  FOR EACH ROW EXECUTE FUNCTION public.guard_conversion_in_use();


-- 2 + 3. Stock unit and deactivation
CREATE OR REPLACE FUNCTION public.guard_material_changes()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF OLD.stock_unit_id IS NOT NULL AND NEW.stock_unit_id IS DISTINCT FROM OLD.stock_unit_id
     AND (EXISTS (SELECT 1 FROM public.material_unit_conversions WHERE material_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.material_branch_sources WHERE material_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.recipe_items WHERE material_id = OLD.id)) THEN
    RAISE EXCEPTION 'The stock unit can''t change once conversions, sources or recipes use this material'
      USING ERRCODE = '23514';
  END IF;

  IF OLD.status = 'active' AND NEW.status = 'inactive'
     AND EXISTS (SELECT 1 FROM public.recipe_items ri
                 JOIN public.recipe_versions rv ON rv.id = ri.recipe_version_id
                 WHERE ri.material_id = OLD.id AND rv.status = 'active') THEN
    RAISE EXCEPTION 'An active recipe uses this material — save the recipe without it first'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_materials_guard
  BEFORE UPDATE OF stock_unit_id, status ON public.materials
  FOR EACH ROW EXECUTE FUNCTION public.guard_material_changes();
