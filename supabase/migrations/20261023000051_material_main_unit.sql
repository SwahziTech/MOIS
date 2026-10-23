-- ============================================================
-- 051 — A material's main unit (1d)
--
-- SwahziTech, 2026-10-23: stock is counted and shown in the unit the
-- factory thinks in — Dawa in barrels (pipa), Rangi in 25 kg bags — while
-- the ledger keeps its stock unit (L, kg) and recipes keep theirs (per bag
-- of cement). materials.main_unit_id is that counting/display unit: the
-- stock unit itself or one of the material's unit conversions. NULL = the
-- stock unit. Nothing already recorded changes.
-- ============================================================

ALTER TABLE public.materials ADD COLUMN main_unit_id uuid REFERENCES public.units(id) ON DELETE RESTRICT;
COMMENT ON COLUMN public.materials.main_unit_id
  IS 'The unit stock is counted and shown in (051): the stock unit or one with a conversion; NULL = the stock unit.';

CREATE FUNCTION public.check_material_main_unit()
RETURNS trigger LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  IF NEW.main_unit_id IS NOT NULL AND NEW.main_unit_id IS DISTINCT FROM NEW.stock_unit_id
     AND NOT EXISTS (SELECT 1 FROM public.material_unit_conversions WHERE material_id = NEW.id AND unit_id = NEW.main_unit_id) THEN
    RAISE EXCEPTION '%: the main unit must be its stock unit or one of its conversions', NEW.name USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_materials_main_unit BEFORE INSERT OR UPDATE OF main_unit_id, stock_unit_id ON public.materials
  FOR EACH ROW EXECUTE FUNCTION public.check_material_main_unit();

-- a conversion in use as a main unit can't be removed
CREATE FUNCTION public.check_main_unit_conversion_kept()
RETURNS trigger LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.materials WHERE id = OLD.material_id AND main_unit_id = OLD.unit_id) THEN
    RAISE EXCEPTION 'This unit is the material''s main unit — choose another main unit first' USING ERRCODE = '23514';
  END IF;
  RETURN OLD;
END;
$$;
CREATE TRIGGER trg_muc_main_unit BEFORE DELETE ON public.material_unit_conversions
  FOR EACH ROW EXECUTE FUNCTION public.check_main_unit_conversion_kept();
