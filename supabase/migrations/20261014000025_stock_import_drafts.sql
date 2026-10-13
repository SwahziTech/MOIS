-- ============================================================
-- 025 — Saved stock-import drafts (1b)
--
-- Resolving a stock sheet (which product, colour, unit, date per line) can
-- take a while and involve more than one person. A draft keeps the file
-- and every choice made so far, so the work survives closing the tab and
-- can be reviewed before anything posts. A draft never touches stock:
-- posting still goes only through post_inventory_batch().
--
-- Who: anyone who can post opening balances somewhere
-- (inventory.adjust at any scope). Drafts are discarded, never deleted.
-- ============================================================

CREATE OR REPLACE FUNCTION public.has_permission_anywhere(code text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles ur
    JOIN public.roles r             ON r.id = ur.role_id
    JOIN public.role_permissions rp ON rp.role_id = r.id
    JOIN public.permissions p       ON p.id = rp.permission_id
    WHERE ur.user_id = auth.uid()
      AND ur.organization_id = public.get_my_org_id()
      AND r.organization_id = ur.organization_id
      AND p.code = has_permission_anywhere.code
  )
$$;

COMMENT ON FUNCTION public.has_permission_anywhere(text)
  IS 'True if the caller holds this permission at any scope (org-wide, a branch, or a warehouse).';

CREATE TABLE public.stock_import_drafts (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id     uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  file_name           text,
  file_text           text NOT NULL,
  warehouse_id        uuid REFERENCES public.warehouses(id),
  as_of_date          date,
  table_choices       jsonb NOT NULL DEFAULT '{}',   -- table index → { categoryId, unitId }
  line_choices        jsonb NOT NULL DEFAULT '{}',   -- line id → { productId, colorId, unitId, qty, date, skip, noConvert }
  status              text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'posted', 'discarded')),
  posted_movement_ids uuid[],
  created_by          uuid NOT NULL REFERENCES auth.users(id),
  updated_by          uuid REFERENCES auth.users(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CHECK ((status = 'posted') = (posted_movement_ids IS NOT NULL))
);

CREATE INDEX idx_stock_import_drafts_org ON public.stock_import_drafts(organization_id, status, updated_at DESC);

CREATE TRIGGER trg_stock_import_drafts_updated_at
  BEFORE UPDATE ON public.stock_import_drafts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_stock_import_drafts_wh_org
  BEFORE INSERT OR UPDATE ON public.stock_import_drafts
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('warehouses', 'warehouse_id');
CREATE TRIGGER trg_stock_import_drafts_no_delete
  BEFORE DELETE ON public.stock_import_drafts
  FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('stock_import_draft');

-- A posted draft is a record of what was imported: frozen
CREATE OR REPLACE FUNCTION public.freeze_posted_import_draft()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF OLD.status = 'posted' THEN
    RAISE EXCEPTION 'This import has been posted and can''t be changed' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_stock_import_drafts_frozen
  BEFORE UPDATE ON public.stock_import_drafts
  FOR EACH ROW EXECUTE FUNCTION public.freeze_posted_import_draft();

ALTER TABLE public.stock_import_drafts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "import_drafts: importers read" ON public.stock_import_drafts FOR SELECT
  USING (organization_id = public.get_my_org_id() AND public.has_permission_anywhere('inventory.adjust'));
CREATE POLICY "import_drafts: importers create" ON public.stock_import_drafts FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_anywhere('inventory.adjust')
              AND created_by = auth.uid());
CREATE POLICY "import_drafts: importers update" ON public.stock_import_drafts FOR UPDATE
  USING      (organization_id = public.get_my_org_id() AND public.has_permission_anywhere('inventory.adjust'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_anywhere('inventory.adjust'));

COMMENT ON TABLE public.stock_import_drafts
  IS 'Stock-sheet imports in progress (file + every resolution), and the record of posted ones. Never writes stock.';
