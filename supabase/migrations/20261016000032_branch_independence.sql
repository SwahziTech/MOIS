-- ============================================================
-- 032 — Branches run independently (1b)
--
-- Follows 031. Decided with SwahziTech (2026-10-16):
--   1. A branch's catalogue is adjusted as things change — the branch
--      manager adds a product when it starts being made and removes it
--      when it stops. No review flags for someone else to close: stock
--      arriving for an uncarried product still joins the catalogue (031),
--      but no longer raises a flag.
--   2. A branch can define its own material (a local input only it uses):
--      materials.branch_id, NULL = shared by every branch. A branch's own
--      material is edited by that branch and used only there (recipes,
--      stock), until an org admin makes it shared.
--   Branch managers get materials.manage through their branch-scoped grant,
--   so has_permission() (org-wide) — shared materials, suppliers — is
--   unaffected.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Stock outside a branch's catalogue: join it, no flag
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_stock_product_carried()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  prod text;
  br   text;
BEGIN
  IF NEW.product_id IS NULL OR NEW.quantity <= 0
     OR EXISTS (SELECT 1 FROM public.branch_products WHERE branch_id = NEW.branch_id AND product_id = NEW.product_id) THEN
    RETURN NEW;
  END IF;

  -- Receipts and adjustments of a product the branch doesn't carry are
  -- refused (likely a wrong pick) — the branch adds it to its list first
  IF NEW.transaction_type IN ('receipt', 'adjustment') THEN
    SELECT canonical_name INTO prod FROM public.products WHERE id = NEW.product_id;
    SELECT name INTO br FROM public.branches WHERE id = NEW.branch_id;
    RAISE EXCEPTION '% isn''t in %''s product list — add it there first', prod, br USING ERRCODE = '23514';
  END IF;

  -- Stock physically there (opening balance, count, transfer in,
  -- reclassification, reversal): the branch carries it now
  INSERT INTO public.branch_products (organization_id, branch_id, product_id, source, created_by, notes)
  VALUES (NEW.organization_id, NEW.branch_id, NEW.product_id, 'stock', auth.uid(),
          'Added when ' || replace(NEW.transaction_type, '_', ' ') || ' stock was recorded');
  RETURN NEW;
END;
$$;


-- ------------------------------------------------------------
-- 2. A branch's own materials
-- ------------------------------------------------------------
ALTER TABLE public.materials
  ADD COLUMN branch_id uuid REFERENCES public.branches(id) ON DELETE RESTRICT;

COMMENT ON COLUMN public.materials.branch_id
  IS 'NULL = shared by every branch. Otherwise the branch that defined it: only that branch edits it and uses it (recipes, stock) until an org admin makes it shared.';

CREATE INDEX idx_materials_branch ON public.materials(branch_id);
CREATE TRIGGER trg_materials_branch_org BEFORE INSERT OR UPDATE ON public.materials
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('branches', 'branch_id');

-- A material can become shared, never move to (another) branch: other
-- branches may already be using a shared one
CREATE OR REPLACE FUNCTION public.check_material_branch_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.branch_id IS NOT NULL AND NEW.branch_id IS DISTINCT FROM OLD.branch_id THEN
    RAISE EXCEPTION 'A material can be made shared, but not moved to a branch' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_materials_branch_change BEFORE UPDATE OF branch_id ON public.materials
  FOR EACH ROW EXECUTE FUNCTION public.check_material_branch_change();

-- Writes: shared materials need an org-wide grant (as before); a branch's
-- own materials need the permission at that branch
DROP POLICY "materials: admins can manage" ON public.materials;
CREATE POLICY "materials: shared by org admins, own by the branch" ON public.materials FOR ALL
  USING      (organization_id = public.get_my_org_id()
              AND CASE WHEN branch_id IS NULL THEN public.has_permission('materials.manage')
                       ELSE public.has_permission_at('materials.manage', branch_id, NULL) END)
  WITH CHECK (organization_id = public.get_my_org_id()
              AND CASE WHEN branch_id IS NULL THEN public.has_permission('materials.manage')
                       ELSE public.has_permission_at('materials.manage', branch_id, NULL) END);

DROP POLICY "muc: admins can manage" ON public.material_unit_conversions;
CREATE POLICY "muc: whoever manages the material" ON public.material_unit_conversions FOR ALL
  USING (organization_id = public.get_my_org_id() AND EXISTS (
           SELECT 1 FROM public.materials m WHERE m.id = material_id
             AND CASE WHEN m.branch_id IS NULL THEN public.has_permission('materials.manage')
                      ELSE public.has_permission_at('materials.manage', m.branch_id, NULL) END))
  WITH CHECK (organization_id = public.get_my_org_id() AND EXISTS (
           SELECT 1 FROM public.materials m WHERE m.id = material_id
             AND CASE WHEN m.branch_id IS NULL THEN public.has_permission('materials.manage')
                      ELSE public.has_permission_at('materials.manage', m.branch_id, NULL) END));

-- A branch's own material is used only in that branch: its recipes...
CREATE OR REPLACE FUNCTION public.check_recipe_material_branch()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE mat public.materials; br text;
BEGIN
  SELECT * INTO mat FROM public.materials WHERE id = NEW.material_id;
  IF mat.branch_id IS NOT NULL AND mat.branch_id IS DISTINCT FROM
       (SELECT branch_id FROM public.recipe_versions WHERE id = NEW.recipe_version_id) THEN
    SELECT name INTO br FROM public.branches WHERE id = mat.branch_id;
    RAISE EXCEPTION '% is %''s own material — make it shared before other branches use it', mat.name, br
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_recipe_items_material_branch BEFORE INSERT OR UPDATE ON public.recipe_items
  FOR EACH ROW EXECUTE FUNCTION public.check_recipe_material_branch();

-- ...and its stores
CREATE OR REPLACE FUNCTION public.check_stock_material_branch()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE mat public.materials; br text;
BEGIN
  IF NEW.material_id IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO mat FROM public.materials WHERE id = NEW.material_id;
  IF mat.branch_id IS NOT NULL AND mat.branch_id IS DISTINCT FROM NEW.branch_id THEN
    SELECT name INTO br FROM public.branches WHERE id = mat.branch_id;
    RAISE EXCEPTION '% is %''s own material — make it shared before other branches stock it', mat.name, br
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_inventory_material_branch BEFORE INSERT ON public.inventory_transactions
  FOR EACH ROW EXECUTE FUNCTION public.check_stock_material_branch();


-- ------------------------------------------------------------
-- 3. Branch managers: their own branch's materials
-- ------------------------------------------------------------
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM public.roles r, public.permissions p
WHERE r.name = 'branch_manager' AND r.is_system_role AND p.code = 'materials.manage'
ON CONFLICT DO NOTHING;
