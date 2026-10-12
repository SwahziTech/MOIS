-- ============================================================
-- Migration 019: Materials as master data (Phase 1a.1)
--
-- Global (same in every branch — the production flow does not vary):
--   material_categories            per-org, open-ended (like color_palette)
--   materials.category_id          → material_categories
--   materials.stock_unit_id        unit stock is tracked in (was unit_id)
--   materials.material_id_ref      stable reference used by source files
--   material_unit_conversions      any other unit → stock unit
--                                  (e.g. 1 Cbm = 0.05 Trip/Truck,
--                                   1 bucket = 0.0004 Trip/Truck)
-- Per branch (sourcing varies by branch — mirrors product_branch_pricing):
--   material_branch_sources        where a branch buys a material, in
--                                  which purchase unit; several per branch,
--                                  one marked primary
--
-- NOT stored here: quantity on hand or purchase price. Both are derived
-- from transactions in 1b's materials ledger (AGENTS.md §5), per branch.
-- ============================================================


-- Generic: the row referenced by column TG_ARGV[1] of table TG_ARGV[0]
-- must belong to the same organization as NEW.
CREATE OR REPLACE FUNCTION public.check_ref_org()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ref uuid;
  ok  boolean;
BEGIN
  EXECUTE format('SELECT ($1).%I', TG_ARGV[1]) USING NEW INTO ref;
  IF ref IS NULL THEN RETURN NEW; END IF;
  EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I WHERE id = $1 AND organization_id = $2)', TG_ARGV[0])
    USING ref, NEW.organization_id INTO ok;
  IF NOT ok THEN
    RAISE EXCEPTION '% does not belong to this organization', TG_ARGV[1] USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;


-- ------------------------------------------------------------
-- 1. Material categories
-- ------------------------------------------------------------
CREATE TABLE public.material_categories (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name            text NOT NULL CHECK (trim(name) <> ''),
  display_order   int  NOT NULL DEFAULT 0,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);

CREATE INDEX idx_material_categories_org ON public.material_categories(organization_id);
CREATE TRIGGER trg_material_categories_updated_at
  BEFORE UPDATE ON public.material_categories
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- ------------------------------------------------------------
-- 2. Materials: category, stock unit, stable reference
-- ------------------------------------------------------------
ALTER TABLE public.materials RENAME COLUMN unit_id TO stock_unit_id;
ALTER TABLE public.materials
  ADD COLUMN material_id_ref text,
  ADD COLUMN category_id uuid REFERENCES public.material_categories(id) ON DELETE RESTRICT,
  ADD CONSTRAINT materials_org_ref_unique UNIQUE (organization_id, material_id_ref);

COMMENT ON COLUMN public.materials.stock_unit_id
  IS 'Unit stock is tracked in (inventory unit). NULL = not specified yet (needs review).';

CREATE TRIGGER trg_materials_unit_org
  BEFORE INSERT OR UPDATE OF stock_unit_id, organization_id ON public.materials
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('units', 'stock_unit_id');
CREATE TRIGGER trg_materials_category_org
  BEFORE INSERT OR UPDATE OF category_id, organization_id ON public.materials
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('material_categories', 'category_id');


-- ------------------------------------------------------------
-- 3. Unit conversions (to the material's stock unit)
-- ------------------------------------------------------------
CREATE TABLE public.material_unit_conversions (
  organization_id      uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  material_id          uuid NOT NULL REFERENCES public.materials(id) ON DELETE CASCADE,
  unit_id              uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  factor_to_stock_unit numeric NOT NULL CHECK (factor_to_stock_unit > 0),
  notes                text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (material_id, unit_id)
);

COMMENT ON TABLE public.material_unit_conversions
  IS '1 <unit> = factor_to_stock_unit × the material''s stock unit. The stock unit itself is implicit (factor 1).';

CREATE INDEX idx_muc_org ON public.material_unit_conversions(organization_id);
CREATE TRIGGER trg_muc_updated_at
  BEFORE UPDATE ON public.material_unit_conversions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_muc_material_org
  BEFORE INSERT OR UPDATE ON public.material_unit_conversions
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('materials', 'material_id');
CREATE TRIGGER trg_muc_unit_org
  BEFORE INSERT OR UPDATE ON public.material_unit_conversions
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('units', 'unit_id');

CREATE OR REPLACE FUNCTION public.check_conversion_unit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.materials WHERE id = NEW.material_id AND stock_unit_id = NEW.unit_id) THEN
    RAISE EXCEPTION 'A conversion to the material''s own stock unit is implicit (factor 1)' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_muc_not_stock_unit
  BEFORE INSERT OR UPDATE ON public.material_unit_conversions
  FOR EACH ROW EXECUTE FUNCTION public.check_conversion_unit();


-- ------------------------------------------------------------
-- 4. Per-branch sources
-- ------------------------------------------------------------
CREATE TABLE public.material_branch_sources (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  material_id      uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
  branch_id        uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  source_name      text NOT NULL CHECK (trim(source_name) <> ''),  -- supplier/place; becomes a supplier link in 1b
  purchase_unit_id uuid REFERENCES public.units(id) ON DELETE RESTRICT,
  is_primary       boolean NOT NULL DEFAULT false,
  status           text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  notes            text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (material_id, branch_id, source_name)
);

-- At most one active primary source per material per branch
CREATE UNIQUE INDEX uq_mbs_primary
  ON public.material_branch_sources (material_id, branch_id)
  WHERE is_primary AND status = 'active';
CREATE INDEX idx_mbs_org ON public.material_branch_sources(organization_id);
CREATE INDEX idx_mbs_branch ON public.material_branch_sources(branch_id);

CREATE TRIGGER trg_mbs_updated_at
  BEFORE UPDATE ON public.material_branch_sources
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_mbs_material_org
  BEFORE INSERT OR UPDATE ON public.material_branch_sources
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('materials', 'material_id');
CREATE TRIGGER trg_mbs_branch_org
  BEFORE INSERT OR UPDATE ON public.material_branch_sources
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('branches', 'branch_id');
CREATE TRIGGER trg_mbs_unit_org
  BEFORE INSERT OR UPDATE ON public.material_branch_sources
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('units', 'purchase_unit_id');

-- Purchase unit must be the stock unit or one of the material's conversions
CREATE OR REPLACE FUNCTION public.check_purchase_unit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.purchase_unit_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.materials
                     WHERE id = NEW.material_id AND stock_unit_id = NEW.purchase_unit_id)
     AND NOT EXISTS (SELECT 1 FROM public.material_unit_conversions
                     WHERE material_id = NEW.material_id AND unit_id = NEW.purchase_unit_id) THEN
    RAISE EXCEPTION 'Purchase unit must be the material''s stock unit or one of its listed conversion units'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_mbs_purchase_unit
  BEFORE INSERT OR UPDATE ON public.material_branch_sources
  FOR EACH ROW EXECUTE FUNCTION public.check_purchase_unit();

COMMENT ON TABLE public.material_branch_sources
  IS 'Where each branch buys a material and in which unit. Per branch, like product_branch_pricing. Price is not stored here — it comes from 1b receiving transactions.';


-- ------------------------------------------------------------
-- 5. RLS: read own org; write with materials.manage
-- ------------------------------------------------------------
ALTER TABLE public.material_categories       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.material_unit_conversions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.material_branch_sources   ENABLE ROW LEVEL SECURITY;

CREATE POLICY "material_categories: read own org" ON public.material_categories FOR SELECT
  USING (organization_id = public.get_my_org_id());
CREATE POLICY "material_categories: admins can manage" ON public.material_categories FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('materials.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('materials.manage'));

CREATE POLICY "muc: read own org" ON public.material_unit_conversions FOR SELECT
  USING (organization_id = public.get_my_org_id());
CREATE POLICY "muc: admins can manage" ON public.material_unit_conversions FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('materials.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('materials.manage'));

CREATE POLICY "mbs: read own org" ON public.material_branch_sources FOR SELECT
  USING (organization_id = public.get_my_org_id());
CREATE POLICY "mbs: admins can manage" ON public.material_branch_sources FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('materials.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('materials.manage'));


-- ------------------------------------------------------------
-- 6. Audit + deactivate-only, same as every other master table
-- ------------------------------------------------------------
CREATE TRIGGER trg_material_categories_audit AFTER INSERT OR UPDATE OR DELETE ON public.material_categories
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('material_category', 'id');
CREATE TRIGGER trg_material_categories_no_delete BEFORE DELETE ON public.material_categories
  FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('material_category');

CREATE TRIGGER trg_muc_audit AFTER INSERT OR UPDATE OR DELETE ON public.material_unit_conversions
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('material_unit_conversion', 'material_id,unit_id');

CREATE TRIGGER trg_mbs_audit AFTER INSERT OR UPDATE OR DELETE ON public.material_branch_sources
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('material_source', 'id');
CREATE TRIGGER trg_mbs_no_delete BEFORE DELETE ON public.material_branch_sources
  FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('material_source');
