-- ============================================================
-- 042 — Production batches, curing and quality release (1d)
--
-- Spec from SwahziTech with Stumarcot's answers (2026-10-18):
--   * A batch is ONE mix/session: one product, one colour, cast together.
--     A branch has many batches a day (4 bags of red, then 6 of grey…).
--   * Materials are hybrid: what is practical to count (cement bags) is
--     entered as actual; the rest starts from the recipe (written per bag
--     of cement) × bags. Both are issued from the raw-materials store.
--     production_material_variance sets that use against later stock
--     counts, per material, to show variance as data builds up.
--   * Cast pieces go into the branch's Curing store (type 'wip') — stock
--     that is NOT sellable — for the organization's curing period
--     (default 14 days; ASSUMPTION: one org-wide period, not per product).
--   * Quality release: every cast piece passes or is rejected with a
--     reason from the organization's list (Broken, Cracked, Colour wrong,
--     Size wrong). Passed pieces move into Finished Goods.
--   * The yield per bag is a ± band for quality control (AGENTS.md §3):
--     a batch outside it is flagged for review, never corrected.
--   * Secretary and branch manager record the whole batch
--     (production.create / production.complete at the branch); the
--     storekeeper can issue a batch's materials (inventory.issue at the
--     store) but not record batches.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Ledger: production entries, linked to their batch
-- ------------------------------------------------------------
ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_movement_type_check;
ALTER TABLE public.inventory_movements ADD CONSTRAINT inventory_movements_movement_type_check
  CHECK (movement_type IN ('opening_balance', 'receipt', 'issue', 'transfer', 'adjustment', 'count', 'reversal', 'reclassification',
                           'production_use', 'production_output', 'curing_release'));
ALTER TABLE public.inventory_transactions DROP CONSTRAINT inventory_transactions_transaction_type_check;
ALTER TABLE public.inventory_transactions ADD CONSTRAINT inventory_transactions_transaction_type_check
  CHECK (transaction_type IN ('opening_balance', 'receipt', 'issue', 'transfer_out', 'transfer_in', 'adjustment', 'count', 'reversal', 'reclassification',
                              'production_use', 'production_output', 'curing_out', 'curing_in'));

-- Every branch gets a Curing store (type 'wip') if it has none: stock there is cast but not yet sellable
INSERT INTO public.warehouses (organization_id, branch_id, name, type)
SELECT b.organization_id, b.id, 'Curing Store', 'wip'
FROM public.branches b
WHERE NOT EXISTS (SELECT 1 FROM public.warehouses w WHERE w.branch_id = b.id AND w.type = 'wip');

-- Curing period (days), one for the organization
ALTER TABLE public.organizations ADD COLUMN curing_days int NOT NULL DEFAULT 14 CHECK (curing_days BETWEEN 0 AND 365);
COMMENT ON COLUMN public.organizations.curing_days
  IS 'Days a cast batch cures before its quality release (042). One period for every product — not yet per product.';


-- ------------------------------------------------------------
-- 2. Reject reasons (a list per organization, like expense categories)
-- ------------------------------------------------------------
CREATE TABLE public.reject_reasons (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name            text NOT NULL CHECK (btrim(name) <> ''),
  display_order   int  NOT NULL DEFAULT 0,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_reject_reasons_name ON public.reject_reasons (organization_id, public.normalize_name(name));
CREATE TRIGGER trg_reject_reasons_updated_at BEFORE UPDATE ON public.reject_reasons
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_reject_reasons_audit AFTER INSERT OR UPDATE OR DELETE ON public.reject_reasons
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('reject_reason', 'id');
CREATE TRIGGER trg_reject_reasons_no_delete BEFORE DELETE ON public.reject_reasons
  FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('reject reason');
ALTER TABLE public.reject_reasons ENABLE ROW LEVEL SECURITY;
CREATE POLICY "reject_reasons: read own org" ON public.reject_reasons FOR SELECT
  USING (organization_id = public.get_my_org_id());
CREATE POLICY "reject_reasons: org admins add" ON public.reject_reasons FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'));
CREATE POLICY "reject_reasons: org admins change" ON public.reject_reasons FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'));

INSERT INTO public.reject_reasons (organization_id, name, display_order)
SELECT o.id, r.name, r.ord
FROM public.organizations o
CROSS JOIN (VALUES ('Broken', 1), ('Cracked', 2), ('Colour wrong', 3), ('Size wrong', 4)) AS r(name, ord)
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- 3. Batches
-- ------------------------------------------------------------
CREATE TABLE public.production_batches (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id      uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id            uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  batch_date           date NOT NULL,
  product_id           uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  color_id             uuid REFERENCES public.color_palette(id) ON DELETE RESTRICT,
  recipe_version_id    uuid NOT NULL REFERENCES public.recipe_versions(id) ON DELETE RESTRICT,   -- the version used, kept for good
  raw_warehouse_id     uuid NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  curing_warehouse_id  uuid NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  cement_bags          numeric NOT NULL CHECK (cement_bags > 0),     -- counted: the batch's size (recipes are per bag)
  pieces_cast          int NOT NULL CHECK (pieces_cast >= 0),
  yield_min            numeric,     -- the band at the time: bags × (average − tolerance)
  yield_max            numeric,
  curing_until         date NOT NULL,
  status               text NOT NULL DEFAULT 'curing' CHECK (status IN ('curing', 'released', 'void')),
  materials_movement_id uuid REFERENCES public.inventory_movements(id),   -- NULL until the materials are issued
  output_movement_id   uuid REFERENCES public.inventory_movements(id),
  release_movement_id  uuid REFERENCES public.inventory_movements(id),
  fg_warehouse_id      uuid REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  released_on          date,
  pieces_passed        int CHECK (pieces_passed >= 0),
  release_note         text,
  notes                text,
  void_reason          text,
  created_by           uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CHECK ((status = 'released') = (released_on IS NOT NULL)),
  CHECK ((status = 'void') = (void_reason IS NOT NULL))
);
CREATE INDEX idx_production_batches_branch_date ON public.production_batches (organization_id, branch_id, batch_date DESC);

CREATE TABLE public.production_batch_materials (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  batch_id        uuid NOT NULL REFERENCES public.production_batches(id) ON DELETE RESTRICT,
  material_id     uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
  quantity        numeric NOT NULL CHECK (quantity >= 0),    -- as entered, in unit_id
  unit_id         uuid NOT NULL REFERENCES public.units(id),
  stock_quantity  numeric NOT NULL CHECK (stock_quantity >= 0),   -- in the material's stock unit
  standard_quantity numeric,                                  -- recipe × bags, in unit_id (NULL: not in the recipe)
  source          text NOT NULL CHECK (source IN ('counted', 'recipe')),   -- counted for real, or taken from the recipe
  UNIQUE (batch_id, material_id)
);

CREATE TABLE public.production_batch_rejects (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  batch_id        uuid NOT NULL REFERENCES public.production_batches(id) ON DELETE RESTRICT,
  reason_id       uuid NOT NULL REFERENCES public.reject_reasons(id) ON DELETE RESTRICT,
  pieces          int NOT NULL CHECK (pieces > 0),
  UNIQUE (batch_id, reason_id)
);

ALTER TABLE public.inventory_movements ADD COLUMN production_batch_id uuid REFERENCES public.production_batches(id);
CREATE INDEX idx_movements_production_batch ON public.inventory_movements (production_batch_id) WHERE production_batch_id IS NOT NULL;

CREATE TRIGGER trg_production_batches_updated_at BEFORE UPDATE ON public.production_batches
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_production_batches_audit AFTER INSERT OR UPDATE OR DELETE ON public.production_batches
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('production_batch', 'id');
CREATE TRIGGER trg_production_batches_no_delete BEFORE DELETE ON public.production_batches
  FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('production batch');
CREATE TRIGGER trg_production_batch_materials_audit AFTER INSERT OR UPDATE OR DELETE ON public.production_batch_materials
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('production_batch_material', 'id');
CREATE TRIGGER trg_production_batch_rejects_audit AFTER INSERT OR UPDATE OR DELETE ON public.production_batch_rejects
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('production_batch_reject', 'id');

-- Read across the organization; written only through the functions below
ALTER TABLE public.production_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.production_batch_materials ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.production_batch_rejects ENABLE ROW LEVEL SECURITY;
CREATE POLICY "production_batches: read own org" ON public.production_batches FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "production_batch_materials: read own org" ON public.production_batch_materials FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "production_batch_rejects: read own org" ON public.production_batch_rejects FOR SELECT USING (organization_id = public.get_my_org_id());


-- ------------------------------------------------------------
-- 4. Who records production
-- ------------------------------------------------------------
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p
  ON p.code IN ('production.view', 'production.create', 'production.execute', 'production.complete')
WHERE r.name IN ('secretary', 'branch_manager') AND r.is_system_role
ON CONFLICT DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code = 'production.view'
WHERE r.name = 'storekeeper' AND r.is_system_role
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- 5. Helpers
-- ------------------------------------------------------------
-- Pieces → the product's stock unit: m² products (stock unit SQM, AGENTS.md §3) by their pieces per m²
CREATE OR REPLACE FUNCTION public.production_stock_qty(p_product uuid, p_pieces numeric)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  sym text;
  pcs numeric;
  nm  text;
BEGIN
  SELECT u.symbol, p.canonical_name INTO sym, nm FROM public.products p JOIN public.units u ON u.id = p.unit_id WHERE p.id = p_product;
  IF upper(sym) NOT IN ('SQM', 'M2', 'M²') THEN RETURN p_pieces; END IF;
  SELECT s.pcs_per_sqm INTO pcs FROM public.product_specs s WHERE s.product_id = p_product;
  IF pcs IS NULL OR pcs <= 0 THEN
    RAISE EXCEPTION '%: set its pieces per m² first (Products) — stock is counted in m²', nm USING ERRCODE = '23514';
  END IF;
  RETURN p_pieces / pcs;
END;
$$;

-- One ledger line written the way post_inventory_movement() writes it (lock, date checks, no negative stock)
CREATE OR REPLACE FUNCTION public.production_ledger_line(p_movement uuid, p_type text, p_wh public.warehouses,
  p_mat uuid, p_pro uuid, p_col uuid, p_delta numeric, p_unit uuid, p_entered numeric, p_entered_unit uuid, p_date date, p_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  label text := (SELECT b.name FROM public.branches b WHERE b.id = p_wh.branch_id) || ' — ' || p_wh.name;
BEGIN
  PERFORM public.inventory_lock_item(p_wh.id, p_mat, p_pro, p_col);
  PERFORM public.inventory_check_after_opening(p_wh.id, p_mat, p_pro, p_col, p_date, p_name, label);
  PERFORM public.inventory_check_outflow(p_wh.id, p_mat, p_pro, p_col, p_date, p_delta, p_name, label);
  INSERT INTO public.inventory_transactions
    (organization_id, movement_id, transaction_type, branch_id, warehouse_id, material_id, product_id, color_id,
     quantity, stock_unit_id, entered_quantity, entered_unit_id, transaction_date, created_by)
  VALUES (p_wh.organization_id, p_movement, p_type, p_wh.branch_id, p_wh.id, p_mat, p_pro, p_col,
          p_delta, p_unit, p_entered, p_entered_unit, p_date, auth.uid());
END;
$$;

-- Post a batch's materials out of its raw-materials store
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
BEGIN
  SELECT * INTO b FROM public.production_batches WHERE id = p_batch FOR UPDATE;
  SELECT * INTO wh FROM public.warehouses WHERE id = b.raw_warehouse_id;
  INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, created_by, production_batch_id)
  VALUES (b.organization_id, 'production_use', b.branch_id, wh.id, b.batch_date, 'Production batch', auth.uid(), b.id)
  RETURNING id INTO mv;
  FOR m IN SELECT bm.*, mt.name, mt.stock_unit_id FROM public.production_batch_materials bm JOIN public.materials mt ON mt.id = bm.material_id
           WHERE bm.batch_id = b.id AND bm.stock_quantity > 0 LOOP
    PERFORM public.production_ledger_line(mv, 'production_use', wh, m.material_id, NULL, NULL, -m.stock_quantity,
      m.stock_unit_id, m.quantity, m.unit_id, b.batch_date, m.name);
  END LOOP;
  UPDATE public.production_batches SET materials_movement_id = mv WHERE id = b.id;
  RETURN mv;
END;
$$;


-- ------------------------------------------------------------
-- 6. Record a batch
-- ------------------------------------------------------------
-- p: { batch_date, product_id, color_id?, recipe_version_id?, raw_warehouse_id, curing_warehouse_id,
--      cement_bags, pieces_cast, notes?, issue_materials (default true),
--      materials: [{ material_id, quantity, unit_id, source: 'counted' | 'recipe' }] }
CREATE OR REPLACE FUNCTION public.record_production_batch(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org    uuid := public.get_my_org_id();
  today  date;
  bdate  date;
  raw    public.warehouses;
  cur    public.warehouses;
  prod   public.products;
  col    uuid := nullif(p->>'color_id', '')::uuid;
  rv     uuid := nullif(p->>'recipe_version_id', '')::uuid;
  bags   numeric := nullif(p->>'cement_bags', '')::numeric;
  pieces int := nullif(p->>'pieces_cast', '')::int;
  band   record;
  bid    uuid;
  mv     uuid;
  l      jsonb;
  mat    public.materials;
  factor numeric;
  std    numeric;
  pname  text;
  sqty   numeric;
BEGIN
  IF org IS NULL OR auth.uid() IS NULL THEN RAISE EXCEPTION 'Not signed in to an organization' USING ERRCODE = '42501'; END IF;
  today := public.org_today(org);
  bdate := coalesce(nullif(p->>'batch_date', '')::date, today);
  IF bdate > today THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;

  SELECT * INTO raw FROM public.warehouses WHERE id = nullif(p->>'raw_warehouse_id', '')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND OR raw.type NOT IN ('raw_materials', 'general') THEN RAISE EXCEPTION 'Choose the store the materials come from' USING ERRCODE = '23514'; END IF;
  SELECT * INTO cur FROM public.warehouses WHERE id = nullif(p->>'curing_warehouse_id', '')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND OR cur.type <> 'wip' OR cur.branch_id <> raw.branch_id THEN
    RAISE EXCEPTION 'Choose the branch''s curing store' USING ERRCODE = '23514';
  END IF;
  IF NOT public.has_permission_at('production.create', raw.branch_id, NULL) THEN
    RAISE EXCEPTION 'You can''t record production at this branch' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO prod FROM public.products WHERE id = nullif(p->>'product_id', '')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'Choose the product' USING ERRCODE = '23514'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.branch_products WHERE branch_id = raw.branch_id AND product_id = prod.id AND status = 'active') THEN
    RAISE EXCEPTION '% isn''t in this branch''s product list — add it there first', prod.canonical_name USING ERRCODE = '23514';
  END IF;
  pname := prod.canonical_name;
  IF EXISTS (SELECT 1 FROM public.product_category_colors WHERE category_id = prod.category_id) THEN
    IF col IS NULL OR NOT EXISTS (SELECT 1 FROM public.product_category_colors WHERE category_id = prod.category_id AND color_id = col) THEN
      RAISE EXCEPTION '%: choose one of its colours', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    pname := pname || ' ' || (SELECT name FROM public.color_palette WHERE id = col);
  ELSIF col IS NOT NULL THEN
    RAISE EXCEPTION '%: its category has no colours', prod.canonical_name USING ERRCODE = '23514';
  END IF;

  -- The branch's active recipe for the product's category + colour (kept on the batch for good)
  IF rv IS NULL THEN
    SELECT v.id INTO rv FROM public.recipe_versions v
    WHERE v.branch_id = raw.branch_id AND v.category_id = prod.category_id AND v.color_id IS NOT DISTINCT FROM col AND v.status = 'active'
    ORDER BY EXISTS (SELECT 1 FROM public.recipe_version_products x WHERE x.recipe_version_id = v.id AND x.product_id = prod.id) DESC,
             v.effective_date DESC NULLS LAST, v.version_number DESC
    LIMIT 1;
    IF rv IS NULL THEN
      RAISE EXCEPTION 'No active recipe for % at this branch — add one under Recipes', pname USING ERRCODE = '23514';
    END IF;
  ELSIF NOT EXISTS (SELECT 1 FROM public.recipe_versions v WHERE v.id = rv AND v.branch_id = raw.branch_id
                    AND v.category_id = prod.category_id AND v.color_id IS NOT DISTINCT FROM col AND v.status = 'active') THEN
    RAISE EXCEPTION 'That recipe isn''t an active one for % at this branch', pname USING ERRCODE = '23514';
  END IF;

  IF bags IS NULL OR bags <= 0 THEN RAISE EXCEPTION 'Enter the bags of cement used' USING ERRCODE = '23514'; END IF;
  IF pieces IS NULL OR pieces < 0 THEN RAISE EXCEPTION 'Enter the pieces cast' USING ERRCODE = '23514'; END IF;

  SELECT * INTO band FROM public.product_yield_band(prod.id, raw.branch_id);

  INSERT INTO public.production_batches (organization_id, branch_id, batch_date, product_id, color_id, recipe_version_id,
    raw_warehouse_id, curing_warehouse_id, cement_bags, pieces_cast, yield_min, yield_max, curing_until, notes, created_by)
  VALUES (org, raw.branch_id, bdate, prod.id, col, rv, raw.id, cur.id, bags, pieces,
          CASE WHEN band.yield_min IS NOT NULL THEN bags * band.yield_min END,
          CASE WHEN band.yield_max IS NOT NULL THEN bags * band.yield_max END,
          bdate + (SELECT curing_days FROM public.organizations WHERE id = org),
          nullif(btrim(p->>'notes'), ''), auth.uid())
  RETURNING id INTO bid;

  -- Materials: counted where practical, the recipe × bags elsewhere
  FOR l IN SELECT * FROM jsonb_array_elements(coalesce(p->'materials', '[]'::jsonb)) LOOP
    SELECT * INTO mat FROM public.materials WHERE id = nullif(l->>'material_id', '')::uuid AND organization_id = org AND status = 'active'
      AND (branch_id IS NULL OR branch_id = raw.branch_id);
    IF NOT FOUND THEN RAISE EXCEPTION 'Material not found, inactive or not used at this branch' USING ERRCODE = '23514'; END IF;
    IF mat.stock_unit_id IS NULL THEN RAISE EXCEPTION '%: set its stock unit under Materials first', mat.name USING ERRCODE = '23514'; END IF;
    IF coalesce(l->>'source', '') NOT IN ('counted', 'recipe') THEN RAISE EXCEPTION 'Say whether % was counted or taken from the recipe', mat.name USING ERRCODE = '23514'; END IF;
    IF nullif(l->>'quantity', '')::numeric IS NULL OR (l->>'quantity')::numeric < 0 THEN
      RAISE EXCEPTION '%: enter a quantity of zero or more', mat.name USING ERRCODE = '23514';
    END IF;
    IF (l->>'unit_id')::uuid = mat.stock_unit_id THEN factor := 1;
    ELSE
      SELECT factor_to_stock_unit INTO factor FROM public.material_unit_conversions WHERE material_id = mat.id AND unit_id = (l->>'unit_id')::uuid;
      IF NOT FOUND THEN RAISE EXCEPTION '%: use its stock unit or one of its listed units', mat.name USING ERRCODE = '23514'; END IF;
    END IF;
    SELECT ri.quantity * bags INTO std FROM public.recipe_items ri WHERE ri.recipe_version_id = rv AND ri.material_id = mat.id AND ri.unit_id = (l->>'unit_id')::uuid;
    INSERT INTO public.production_batch_materials (organization_id, batch_id, material_id, quantity, unit_id, stock_quantity, standard_quantity, source)
    VALUES (org, bid, mat.id, (l->>'quantity')::numeric, (l->>'unit_id')::uuid, (l->>'quantity')::numeric * factor, std, l->>'source');
  END LOOP;

  -- Cast pieces into curing (not sellable yet)
  IF pieces > 0 THEN
    sqty := public.production_stock_qty(prod.id, pieces);
    INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, created_by, production_batch_id)
    VALUES (org, 'production_output', cur.branch_id, cur.id, bdate, 'Production batch — curing', auth.uid(), bid)
    RETURNING id INTO mv;
    PERFORM public.production_ledger_line(mv, 'production_output', cur, NULL, prod.id, col, sqty, prod.unit_id, sqty, prod.unit_id, bdate, pname);
    UPDATE public.production_batches SET output_movement_id = mv WHERE id = bid;
  END IF;

  -- Materials out of the store now, or left for the storekeeper to issue
  IF coalesce((p->>'issue_materials')::boolean, true) AND EXISTS (SELECT 1 FROM public.production_batch_materials WHERE batch_id = bid) THEN
    PERFORM public.production_post_materials(bid);
  END IF;

  -- Outside the yield band: flagged for review, never corrected (AGENTS.md §3)
  IF band.yield_min IS NOT NULL AND (pieces < bags * band.yield_min OR pieces > bags * band.yield_max) THEN
    INSERT INTO public.review_flags (organization_id, entity_type, entity_id, reason_code, reason, created_by)
    VALUES (org, 'production_batch', bid::text, 'yield_out_of_band',
      format('%s pieces of %s from %s bags on %s — expected %s to %s (%s ± %s per bag). Check the mix, the count or the materials.',
             pieces, pname, bags, bdate, round(bags * band.yield_min), round(bags * band.yield_max),
             band.average_yield_per_bag, band.yield_tolerance), auth.uid());
  END IF;
  RETURN bid;
END;
$$;

-- The storekeeper (or the recorder) issues a batch's materials later
CREATE OR REPLACE FUNCTION public.issue_production_materials(p_batch uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  b public.production_batches;
BEGIN
  SELECT * INTO b FROM public.production_batches WHERE id = p_batch AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND OR b.status = 'void' THEN RAISE EXCEPTION 'Batch not found' USING ERRCODE = '23514'; END IF;
  IF b.materials_movement_id IS NOT NULL THEN RAISE EXCEPTION 'This batch''s materials were already issued' USING ERRCODE = '23514'; END IF;
  IF NOT (public.has_permission_at('inventory.issue', b.branch_id, b.raw_warehouse_id)
          OR public.has_permission_at('production.create', b.branch_id, NULL)) THEN
    RAISE EXCEPTION 'You can''t issue materials from this store' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.production_batch_materials WHERE batch_id = b.id AND stock_quantity > 0) THEN
    RAISE EXCEPTION 'This batch has no materials to issue' USING ERRCODE = '23514';
  END IF;
  RETURN public.production_post_materials(b.id);
END;
$$;


-- ------------------------------------------------------------
-- 7. Quality release after curing
-- ------------------------------------------------------------
-- p: { fg_warehouse_id, release_date?, pieces_passed, rejects: [{ reason_id, pieces }], note? (required before curing ends) }
CREATE OR REPLACE FUNCTION public.release_production_batch(p_batch uuid, p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org     uuid := public.get_my_org_id();
  b       public.production_batches;
  prod    public.products;
  cur     public.warehouses;
  fg      public.warehouses;
  rdate   date;
  passed  int := nullif(p->>'pieces_passed', '')::int;
  rejected int := 0;
  r       jsonb;
  mv      uuid;
  pname   text;
BEGIN
  SELECT * INTO b FROM public.production_batches WHERE id = p_batch AND organization_id = org FOR UPDATE;
  IF NOT FOUND OR b.status <> 'curing' THEN RAISE EXCEPTION 'Batch not found or not curing' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('production.complete', b.branch_id, NULL) THEN
    RAISE EXCEPTION 'You can''t release production at this branch' USING ERRCODE = '42501';
  END IF;
  rdate := coalesce(nullif(p->>'release_date', '')::date, public.org_today(org));
  IF rdate < b.batch_date OR rdate > public.org_today(org) THEN RAISE EXCEPTION 'Release date must be between the batch date and today' USING ERRCODE = '23514'; END IF;
  IF rdate < b.curing_until AND nullif(btrim(p->>'note'), '') IS NULL THEN
    RAISE EXCEPTION 'Curing runs until % — say why it is released early', b.curing_until USING ERRCODE = '23514';
  END IF;
  SELECT * INTO fg FROM public.warehouses WHERE id = nullif(p->>'fg_warehouse_id', '')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND OR fg.type <> 'finished_goods' OR fg.branch_id <> b.branch_id THEN
    RAISE EXCEPTION 'Choose the branch''s finished-goods store' USING ERRCODE = '23514';
  END IF;
  IF passed IS NULL OR passed < 0 THEN RAISE EXCEPTION 'Enter the pieces that passed' USING ERRCODE = '23514'; END IF;

  FOR r IN SELECT * FROM jsonb_array_elements(coalesce(p->'rejects', '[]'::jsonb)) LOOP
    IF NOT EXISTS (SELECT 1 FROM public.reject_reasons WHERE id = nullif(r->>'reason_id', '')::uuid AND organization_id = org) THEN
      RAISE EXCEPTION 'Choose a reject reason from the list' USING ERRCODE = '23514';
    END IF;
    IF nullif(r->>'pieces', '')::int IS NULL OR (r->>'pieces')::int <= 0 THEN RAISE EXCEPTION 'Rejected pieces must be above zero' USING ERRCODE = '23514'; END IF;
    INSERT INTO public.production_batch_rejects (organization_id, batch_id, reason_id, pieces) VALUES (org, b.id, (r->>'reason_id')::uuid, (r->>'pieces')::int);
    rejected := rejected + (r->>'pieces')::int;
  END LOOP;
  IF passed + rejected <> b.pieces_cast THEN
    RAISE EXCEPTION 'Passed (%) and rejected (%) must add up to the % pieces cast', passed, rejected, b.pieces_cast USING ERRCODE = '23514';
  END IF;

  SELECT * INTO prod FROM public.products WHERE id = b.product_id;
  SELECT * INTO cur FROM public.warehouses WHERE id = b.curing_warehouse_id;
  pname := prod.canonical_name || coalesce(' ' || (SELECT name FROM public.color_palette WHERE id = b.color_id), '');
  IF b.pieces_cast > 0 THEN
    INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, notes, created_by, production_batch_id)
    VALUES (org, 'curing_release', b.branch_id, cur.id, rdate, 'Quality release', nullif(btrim(p->>'note'), ''), auth.uid(), b.id)
    RETURNING id INTO mv;
    PERFORM public.production_ledger_line(mv, 'curing_out', cur, NULL, prod.id, b.color_id,
      -public.production_stock_qty(prod.id, b.pieces_cast), prod.unit_id, public.production_stock_qty(prod.id, b.pieces_cast), prod.unit_id, rdate, pname);
    IF passed > 0 THEN
      PERFORM public.production_ledger_line(mv, 'curing_in', fg, NULL, prod.id, b.color_id,
        public.production_stock_qty(prod.id, passed), prod.unit_id, public.production_stock_qty(prod.id, passed), prod.unit_id, rdate, pname);
    END IF;
  END IF;

  UPDATE public.production_batches SET status = 'released', released_on = rdate, pieces_passed = passed, fg_warehouse_id = fg.id,
         release_movement_id = mv, release_note = nullif(btrim(p->>'note'), '')
  WHERE id = b.id;
  RETURN mv;
END;
$$;


-- ------------------------------------------------------------
-- 8. Void a batch entered wrongly (before release) — org admins
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.void_production_batch(p_batch uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  b public.production_batches;
BEGIN
  SELECT * INTO b FROM public.production_batches WHERE id = p_batch AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND OR b.status <> 'curing' THEN RAISE EXCEPTION 'Only a batch still curing can be voided' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission('inventory.adjust') THEN
    RAISE EXCEPTION 'Voiding a batch is a stock correction — an org admin does it' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN RAISE EXCEPTION 'Give a reason' USING ERRCODE = '23514'; END IF;
  IF b.output_movement_id IS NOT NULL THEN PERFORM public.reverse_inventory_movement(b.output_movement_id, 'Batch voided: ' || btrim(p_reason)); END IF;
  IF b.materials_movement_id IS NOT NULL THEN PERFORM public.reverse_inventory_movement(b.materials_movement_id, 'Batch voided: ' || btrim(p_reason)); END IF;
  UPDATE public.production_batches SET status = 'void', void_reason = btrim(p_reason) WHERE id = b.id;
  UPDATE public.review_flags SET status = 'dismissed', resolved_at = now(), resolved_by = auth.uid(), resolution_note = 'Batch voided'
  WHERE entity_type = 'production_batch' AND entity_id = b.id::text AND status = 'open';
END;
$$;


-- ------------------------------------------------------------
-- 9. Material variance: production use set against stock counts
-- ------------------------------------------------------------
-- Per branch and material: what batches used (counted / taken from the
-- recipe) and what stock counts corrected since the first batch. Counts
-- that keep removing stock mean the recipe figures understate real use.
CREATE VIEW public.production_material_variance
WITH (security_invoker = true) AS
SELECT b.organization_id, b.branch_id, bm.material_id,
       min(b.batch_date) AS first_batch,
       count(DISTINCT b.id) AS batches,
       sum(bm.stock_quantity) FILTER (WHERE bm.source = 'counted') AS counted_use,
       sum(bm.stock_quantity) FILTER (WHERE bm.source = 'recipe') AS recipe_use,
       (SELECT coalesce(sum(t.quantity), 0) FROM public.inventory_transactions t
        WHERE t.branch_id = b.branch_id AND t.material_id = bm.material_id AND t.transaction_type = 'count'
          AND t.transaction_date >= min(b.batch_date)) AS count_corrections,
       (SELECT max(t.transaction_date) FROM public.inventory_transactions t
        WHERE t.branch_id = b.branch_id AND t.material_id = bm.material_id AND t.transaction_type = 'count'
          AND t.transaction_date >= min(b.batch_date)) AS last_count
FROM public.production_batches b
JOIN public.production_batch_materials bm ON bm.batch_id = b.id
WHERE b.status <> 'void' AND b.materials_movement_id IS NOT NULL
GROUP BY b.organization_id, b.branch_id, bm.material_id;

REVOKE ALL ON FUNCTION public.production_stock_qty(uuid, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.production_ledger_line(uuid, text, public.warehouses, uuid, uuid, uuid, numeric, uuid, numeric, uuid, date, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.production_post_materials(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_production_batch(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.issue_production_materials(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.release_production_batch(uuid, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.void_production_batch(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_production_batch(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.issue_production_materials(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.release_production_batch(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.void_production_batch(uuid, text) TO authenticated;
