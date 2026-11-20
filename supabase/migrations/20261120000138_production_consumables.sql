-- ============================================================
-- 138 — Consumables per bag (mafuta, sabuni): out of the store with each batch
--
-- SwahziTech, 2026-11-20 (the user, after reviewing an old job card):
-- mould oil and soap are not part of a product's mix, so they stay out of
-- the recipes. They are set per branch in Costing (an amount per bag of
-- cement, for the categories that use them, switched on once their stock is
-- in). Every batch of those categories then takes bags × amount out of the
-- batch's raw-materials store together with its recipe materials, and their
-- cost (oldest stock first) is part of the batch's material cost.
--
--   1. production_consumables — branch, material, unit, amount a bag,
--      categories, active / off.
--   2. production_batch_materials.source may be 'consumable'.
--   3. production_post_materials() adds the consumables before posting
--      (batches already recorded are not touched).
-- ============================================================

CREATE TABLE public.production_consumables (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id        uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  material_id      uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
  unit_id          uuid NOT NULL REFERENCES public.units(id),
  quantity_per_bag numeric NOT NULL CHECK (quantity_per_bag > 0),
  category_ids     uuid[] NOT NULL DEFAULT '{}',
  status           text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (branch_id, material_id)
);
CREATE INDEX idx_production_consumables_branch ON public.production_consumables (organization_id, branch_id);
CREATE TRIGGER trg_production_consumables_updated_at BEFORE UPDATE ON public.production_consumables
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_production_consumables_audit AFTER INSERT OR UPDATE OR DELETE ON public.production_consumables
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('production_consumable', 'id');
COMMENT ON TABLE public.production_consumables
  IS 'Per branch: a material production uses a fixed amount of per bag of cement (mould oil, soap) for some categories — not in the recipes; taken out with each batch (138).';

-- the material, unit and categories must be this company's; the unit one the material is counted in
CREATE FUNCTION public.check_production_consumable()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE mat public.materials;
BEGIN
  SELECT * INTO mat FROM public.materials WHERE id = NEW.material_id;
  IF NOT FOUND OR mat.organization_id <> NEW.organization_id
     OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = NEW.branch_id AND organization_id = NEW.organization_id) THEN
    RAISE EXCEPTION 'Material not found' USING ERRCODE = '23514';
  END IF;
  IF NEW.unit_id <> mat.stock_unit_id
     AND NOT EXISTS (SELECT 1 FROM public.material_unit_conversions WHERE material_id = mat.id AND unit_id = NEW.unit_id) THEN
    RAISE EXCEPTION '% isn''t counted in that unit', mat.name USING ERRCODE = '23514';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(NEW.category_ids) c
              WHERE NOT EXISTS (SELECT 1 FROM public.product_categories pc WHERE pc.id = c AND pc.organization_id = NEW.organization_id)) THEN
    RAISE EXCEPTION 'Category not found' USING ERRCODE = '23514';
  END IF;
  NEW.quantity_per_bag := round(NEW.quantity_per_bag, 3);   -- quantities to 3 decimals (whole amounts rule)
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_production_consumables_check BEFORE INSERT OR UPDATE ON public.production_consumables
  FOR EACH ROW EXECUTE FUNCTION public.check_production_consumable();

ALTER TABLE public.production_consumables ENABLE ROW LEVEL SECURITY;
CREATE POLICY "production_consumables: read in company" ON public.production_consumables FOR SELECT
  USING (organization_id = public.get_my_org_id());
CREATE POLICY "production_consumables: managers change" ON public.production_consumables FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission_at('products.manage', branch_id, NULL))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_at('products.manage', branch_id, NULL));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.production_consumables TO authenticated;

-- 2. a batch line may be a consumable
ALTER TABLE public.production_batch_materials DROP CONSTRAINT production_batch_materials_source_check;
ALTER TABLE public.production_batch_materials ADD CONSTRAINT production_batch_materials_source_check
  CHECK (source IN ('counted', 'recipe', 'consumable'));

-- 3. posting a batch's materials: its consumables first (055's function, the insert added)
CREATE OR REPLACE FUNCTION public.production_post_materials(p_batch uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  b    public.production_batches;
  wh   public.warehouses;
  mv   uuid;
  m    record;
  cat  uuid;
  par  uuid;
BEGIN
  SELECT * INTO b FROM public.production_batches WHERE id = p_batch FOR UPDATE;
  SELECT * INTO wh FROM public.warehouses WHERE id = b.raw_warehouse_id;

  -- consumables of the batch's category (or its group) at this branch: bags × amount a bag (138)
  SELECT rv.category_id, pc.parent_category_id INTO cat, par
    FROM public.recipe_versions rv JOIN public.product_categories pc ON pc.id = rv.category_id
   WHERE rv.id = b.recipe_version_id;
  INSERT INTO public.production_batch_materials (organization_id, batch_id, material_id, quantity, unit_id, stock_quantity, standard_quantity, source)
  SELECT b.organization_id, b.id, c.material_id, round(c.quantity_per_bag * b.cement_bags, 3), c.unit_id,
         round(c.quantity_per_bag * b.cement_bags, 3)
           * CASE WHEN c.unit_id = mt.stock_unit_id THEN 1
                  ELSE (SELECT factor_to_stock_unit FROM public.material_unit_conversions WHERE material_id = mt.id AND unit_id = c.unit_id) END,
         round(c.quantity_per_bag * b.cement_bags, 3), 'consumable'
    FROM public.production_consumables c JOIN public.materials mt ON mt.id = c.material_id
   WHERE c.organization_id = b.organization_id AND c.branch_id = b.branch_id AND c.status = 'active'
     AND (cat = ANY (c.category_ids) OR par = ANY (c.category_ids))
  ON CONFLICT (batch_id, material_id) DO NOTHING;   -- a material already on the batch stays as entered

  INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, created_by, production_batch_id)
  VALUES (b.organization_id, 'production_use', b.branch_id, wh.id, b.batch_date, 'Production batch', auth.uid(), b.id)
  RETURNING id INTO mv;
  FOR m IN SELECT bm.*, mt.name, mt.stock_unit_id FROM public.production_batch_materials bm JOIN public.materials mt ON mt.id = bm.material_id
           WHERE bm.batch_id = b.id AND bm.stock_quantity > 0 LOOP
    PERFORM public.production_ledger_line(mv, 'production_use', wh, m.material_id, NULL, NULL, -m.stock_quantity,
      m.stock_unit_id, m.quantity, m.unit_id, b.batch_date, m.name);
  END LOOP;
  UPDATE public.production_batches SET materials_movement_id = mv WHERE id = b.id;
  PERFORM public.production_cost_batch(b.id);   -- 055
  RETURN mv;
END;
$$;
REVOKE ALL ON FUNCTION public.production_post_materials(uuid) FROM PUBLIC, anon, authenticated;
