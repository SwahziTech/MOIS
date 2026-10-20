-- ============================================================
-- 043 — A batch's several products, weighted yield, day save (1d)
--
-- Decided with SwahziTech (2026-10-20), from the batch-logging engine
-- they showed:
--   * One mix can be cast into its main product AND leftover products —
--     by default only products of the same recipe (category + colour).
--     The branch manager can allow other products for one batch only.
--   * The yield check is weighted: each product's pieces ÷ its own yield
--     per bag, added up, is the cement the output "should" have taken.
--     Bags actually used outside that band (from each product's ±
--     tolerance) is flagged for review, never corrected (AGENTS.md §3).
--   * Materials are checked against the store as soon as the bags are
--     known: recipe × bags, and anything short is named. Production
--     does not go ahead on short stock — the branch manager reviews the
--     stock first (a receipt, a count).
--   * A day's batches are saved together, all or nothing.
--   * Material categories can be kept out of recipes and batches (e.g.
--     mould oil: used in production, not a mix ingredient).
-- No batches existed when this was written (042 had just gone live).
-- ============================================================

ALTER TABLE public.material_categories ADD COLUMN used_in_recipes boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN public.material_categories.used_in_recipes
  IS 'false = not a mix ingredient (e.g. mould oil): not offered in recipes, not shown in batch materials.';

-- ------------------------------------------------------------
-- 1. Products cast from a batch
-- ------------------------------------------------------------
CREATE TABLE public.production_batch_outputs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  batch_id        uuid NOT NULL REFERENCES public.production_batches(id) ON DELETE RESTRICT,
  product_id      uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  color_id        uuid REFERENCES public.color_palette(id) ON DELETE RESTRICT,
  is_primary      boolean NOT NULL DEFAULT false,
  pieces_cast     int NOT NULL CHECK (pieces_cast >= 0),
  yield_per_bag   numeric,     -- the product's average yield per bag at the time (NULL: none set)
  yield_tolerance numeric,
  pieces_passed   int CHECK (pieces_passed >= 0),
  UNIQUE (batch_id, product_id)
);
CREATE UNIQUE INDEX uq_batch_outputs_primary ON public.production_batch_outputs (batch_id) WHERE is_primary;
CREATE TRIGGER trg_production_batch_outputs_audit AFTER INSERT OR UPDATE OR DELETE ON public.production_batch_outputs
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('production_batch_output', 'id');
ALTER TABLE public.production_batch_outputs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "production_batch_outputs: read own org" ON public.production_batch_outputs FOR SELECT USING (organization_id = public.get_my_org_id());

-- The batch keeps its main product and the totals; the pieces band becomes a band in bags
ALTER TABLE public.production_batches DROP COLUMN yield_min, DROP COLUMN yield_max, DROP COLUMN pieces_passed;
ALTER TABLE public.production_batches
  ADD COLUMN theoretical_bags numeric,   -- Σ pieces ÷ yield per bag (NULL when a product has no yield set)
  ADD COLUMN bags_min numeric,           -- Σ pieces ÷ (average + tolerance)
  ADD COLUMN bags_max numeric,           -- Σ pieces ÷ (average − tolerance)
  ADD COLUMN other_products_allowed_by uuid REFERENCES auth.users(id);   -- the branch manager who allowed other products, this batch only
COMMENT ON COLUMN public.production_batches.pieces_cast IS 'All pieces cast from the mix (its products together).';
COMMENT ON COLUMN public.production_batches.product_id IS 'The main product; leftovers are in production_batch_outputs.';

-- Rejects belong to one product of the batch
DROP TABLE public.production_batch_rejects;
CREATE TABLE public.production_batch_rejects (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  batch_id        uuid NOT NULL REFERENCES public.production_batches(id) ON DELETE RESTRICT,
  output_id       uuid NOT NULL REFERENCES public.production_batch_outputs(id) ON DELETE RESTRICT,
  reason_id       uuid NOT NULL REFERENCES public.reject_reasons(id) ON DELETE RESTRICT,
  pieces          int NOT NULL CHECK (pieces > 0),
  UNIQUE (output_id, reason_id)
);
CREATE TRIGGER trg_production_batch_rejects_audit AFTER INSERT OR UPDATE OR DELETE ON public.production_batch_rejects
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('production_batch_reject', 'id');
ALTER TABLE public.production_batch_rejects ENABLE ROW LEVEL SECURITY;
CREATE POLICY "production_batch_rejects: read own org" ON public.production_batch_rejects FOR SELECT USING (organization_id = public.get_my_org_id());


-- ------------------------------------------------------------
-- 2. Record a batch
-- ------------------------------------------------------------
-- p: { batch_date, raw_warehouse_id, curing_warehouse_id, color_id?, recipe_version_id?, cement_bags,
--      outputs: [{ product_id, pieces, primary? }]  — the first (or the one marked primary) is the main product,
--      allow_other_products? (branch manager only, this batch), notes?, issue_materials (default true),
--      materials: [{ material_id, quantity, unit_id, source: 'counted' | 'recipe' }] }
DROP FUNCTION public.record_production_batch(jsonb);
CREATE FUNCTION public.record_production_batch(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org     uuid := public.get_my_org_id();
  today   date;
  bdate   date;
  raw     public.warehouses;
  cur     public.warehouses;
  main    public.products;
  prod    public.products;
  col     uuid := nullif(p->>'color_id', '')::uuid;
  rv      uuid := nullif(p->>'recipe_version_id', '')::uuid;
  bags    numeric := nullif(p->>'cement_bags', '')::numeric;
  others  boolean := coalesce((p->>'allow_other_products')::boolean, false);
  outs    jsonb;
  o       jsonb;
  band    record;
  bid     uuid;
  mv      uuid;
  l       jsonb;
  mat     public.materials;
  factor  numeric;
  std     numeric;
  bal     numeric;
  short   text := '';
  pname   text;
  total   int := 0;
  eq      numeric := 0;
  bmin    numeric := 0;
  bmax    numeric := 0;
  banded  boolean := true;
  seen    uuid[] := '{}';
  n       int := 0;
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
  IF others AND NOT public.has_permission_at('products.manage', raw.branch_id, NULL) THEN
    RAISE EXCEPTION 'Only the branch manager can allow other products in a batch' USING ERRCODE = '42501';
  END IF;
  IF bags IS NULL OR bags <= 0 THEN RAISE EXCEPTION 'Enter the bags of cement used' USING ERRCODE = '23514'; END IF;

  -- The main product first
  outs := coalesce(p->'outputs', '[]'::jsonb);
  IF jsonb_array_length(outs) = 0 THEN RAISE EXCEPTION 'Enter the product cast and its pieces' USING ERRCODE = '23514'; END IF;
  SELECT coalesce((SELECT x FROM jsonb_array_elements(outs) x WHERE (x->>'primary')::boolean LIMIT 1), outs->0) INTO o;
  SELECT * INTO main FROM public.products WHERE id = nullif(o->>'product_id', '')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'Choose the product' USING ERRCODE = '23514'; END IF;
  IF EXISTS (SELECT 1 FROM public.product_category_colors WHERE category_id = main.category_id) THEN
    IF col IS NULL OR NOT EXISTS (SELECT 1 FROM public.product_category_colors WHERE category_id = main.category_id AND color_id = col) THEN
      RAISE EXCEPTION '%: choose one of its colours', main.canonical_name USING ERRCODE = '23514';
    END IF;
  ELSIF col IS NOT NULL THEN
    RAISE EXCEPTION '%: its category has no colours', main.canonical_name USING ERRCODE = '23514';
  END IF;

  -- The branch's active recipe for the main product's category + colour (kept for good)
  IF rv IS NULL THEN
    SELECT v.id INTO rv FROM public.recipe_versions v
    WHERE v.branch_id = raw.branch_id AND v.category_id = main.category_id AND v.color_id IS NOT DISTINCT FROM col AND v.status = 'active'
    ORDER BY EXISTS (SELECT 1 FROM public.recipe_version_products x WHERE x.recipe_version_id = v.id AND x.product_id = main.id) DESC,
             v.effective_date DESC NULLS LAST, v.version_number DESC
    LIMIT 1;
    IF rv IS NULL THEN
      RAISE EXCEPTION 'No active recipe for % % at this branch — add one under Recipes', main.canonical_name,
        coalesce((SELECT name FROM public.color_palette WHERE id = col), '') USING ERRCODE = '23514';
    END IF;
  ELSIF NOT EXISTS (SELECT 1 FROM public.recipe_versions v WHERE v.id = rv AND v.branch_id = raw.branch_id
                    AND v.category_id = main.category_id AND v.color_id IS NOT DISTINCT FROM col AND v.status = 'active') THEN
    RAISE EXCEPTION 'That recipe isn''t an active one for % at this branch', main.canonical_name USING ERRCODE = '23514';
  END IF;

  -- Materials: anything short is named, and nothing is recorded (the branch manager reviews the stock)
  FOR l IN SELECT * FROM jsonb_array_elements(coalesce(p->'materials', '[]'::jsonb)) LOOP
    SELECT * INTO mat FROM public.materials WHERE id = nullif(l->>'material_id', '')::uuid AND organization_id = org AND status = 'active'
      AND (branch_id IS NULL OR branch_id = raw.branch_id);
    IF NOT FOUND THEN RAISE EXCEPTION 'Material not found, inactive or not used at this branch' USING ERRCODE = '23514'; END IF;
    IF mat.stock_unit_id IS NULL THEN RAISE EXCEPTION '%: set its stock unit under Materials first', mat.name USING ERRCODE = '23514'; END IF;
    IF (l->>'unit_id')::uuid = mat.stock_unit_id THEN factor := 1;
    ELSE
      SELECT factor_to_stock_unit INTO factor FROM public.material_unit_conversions WHERE material_id = mat.id AND unit_id = (l->>'unit_id')::uuid;
      IF NOT FOUND THEN RAISE EXCEPTION '%: use its stock unit or one of its listed units', mat.name USING ERRCODE = '23514'; END IF;
    END IF;
    IF nullif(l->>'quantity', '')::numeric IS NULL OR (l->>'quantity')::numeric < 0 THEN
      RAISE EXCEPTION '%: enter a quantity of zero or more', mat.name USING ERRCODE = '23514';
    END IF;
    bal := public.inventory_balance_as_of(raw.id, mat.id, NULL, NULL, bdate);
    IF (l->>'quantity')::numeric * factor > bal + 1e-9 THEN
      short := short || format('%s%s needs %s %s, only %s %s in stock', CASE WHEN short = '' THEN '' ELSE '; ' END, mat.name,
        trim_scale(round((l->>'quantity')::numeric * factor, 4)), (SELECT u.symbol FROM public.units u WHERE u.id = mat.stock_unit_id),
        trim_scale(round(bal, 4)), (SELECT u.symbol FROM public.units u WHERE u.id = mat.stock_unit_id));
    END IF;
  END LOOP;
  IF short <> '' THEN
    RAISE EXCEPTION 'Not enough in % — %. The branch manager should check the stock (a receipt or a count) before this batch is recorded.',
      raw.name, short USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.production_batches (organization_id, branch_id, batch_date, product_id, color_id, recipe_version_id,
    raw_warehouse_id, curing_warehouse_id, cement_bags, pieces_cast, curing_until, notes, created_by,
    other_products_allowed_by)
  VALUES (org, raw.branch_id, bdate, main.id, col, rv, raw.id, cur.id, bags, 0,
          bdate + (SELECT curing_days FROM public.organizations WHERE id = org),
          nullif(btrim(p->>'notes'), ''), auth.uid(), CASE WHEN others THEN auth.uid() END)
  RETURNING id INTO bid;

  -- Products cast: same recipe (category + colour) as the main one, unless allowed for this batch
  FOR o IN SELECT * FROM jsonb_array_elements(outs) LOOP
    n := n + 1;
    SELECT * INTO prod FROM public.products WHERE id = nullif(o->>'product_id', '')::uuid AND organization_id = org AND status = 'active';
    IF NOT FOUND THEN RAISE EXCEPTION 'Choose each product cast' USING ERRCODE = '23514'; END IF;
    IF prod.id = ANY (seen) THEN RAISE EXCEPTION '% appears twice — add its pieces together', prod.canonical_name USING ERRCODE = '23514'; END IF;
    seen := seen || prod.id;
    IF NOT EXISTS (SELECT 1 FROM public.branch_products WHERE branch_id = raw.branch_id AND product_id = prod.id AND status = 'active') THEN
      RAISE EXCEPTION '% isn''t in this branch''s product list — add it there first', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    IF prod.category_id <> main.category_id AND NOT others THEN
      RAISE EXCEPTION '% is a different product family from % — only the same recipe can share a mix (the branch manager can allow it for one batch)',
        prod.canonical_name, main.canonical_name USING ERRCODE = '23514';
    END IF;
    -- the mix's colour must be one this product comes in (or none, for a plain category)
    IF EXISTS (SELECT 1 FROM public.product_category_colors WHERE category_id = prod.category_id) THEN
      IF col IS NULL OR NOT EXISTS (SELECT 1 FROM public.product_category_colors WHERE category_id = prod.category_id AND color_id = col) THEN
        RAISE EXCEPTION '% doesn''t come in this colour', prod.canonical_name USING ERRCODE = '23514';
      END IF;
    ELSIF col IS NOT NULL AND NOT others THEN
      RAISE EXCEPTION '% has no colours', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    IF nullif(o->>'pieces', '')::int IS NULL OR (o->>'pieces')::int < 0 THEN
      RAISE EXCEPTION '%: enter the pieces cast', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    SELECT * INTO band FROM public.product_yield_band(prod.id, raw.branch_id);
    INSERT INTO public.production_batch_outputs (organization_id, batch_id, product_id, color_id, is_primary, pieces_cast, yield_per_bag, yield_tolerance)
    VALUES (org, bid, prod.id, CASE WHEN EXISTS (SELECT 1 FROM public.product_category_colors WHERE category_id = prod.category_id) THEN col END,
            prod.id = main.id, (o->>'pieces')::int, band.average_yield_per_bag, band.yield_tolerance);
    total := total + (o->>'pieces')::int;
    IF band.average_yield_per_bag IS NULL OR band.average_yield_per_bag <= 0 THEN banded := false;
    ELSE
      eq := eq + (o->>'pieces')::int / band.average_yield_per_bag;
      bmin := bmin + (o->>'pieces')::int / band.yield_max;
      bmax := bmax + CASE WHEN band.yield_min > 0 THEN (o->>'pieces')::int / band.yield_min ELSE 'Infinity'::numeric END;
    END IF;
  END LOOP;
  IF total = 0 THEN RAISE EXCEPTION 'Enter the pieces cast' USING ERRCODE = '23514'; END IF;
  UPDATE public.production_batches SET pieces_cast = total,
         theoretical_bags = CASE WHEN banded THEN eq END, bags_min = CASE WHEN banded THEN bmin END,
         bags_max = CASE WHEN banded AND bmax <> 'Infinity'::numeric THEN bmax END
  WHERE id = bid;

  -- Materials row by row (as 042)
  FOR l IN SELECT * FROM jsonb_array_elements(coalesce(p->'materials', '[]'::jsonb)) LOOP
    SELECT * INTO mat FROM public.materials WHERE id = (l->>'material_id')::uuid;
    IF coalesce(l->>'source', '') NOT IN ('counted', 'recipe') THEN RAISE EXCEPTION 'Say whether % was counted or taken from the recipe', mat.name USING ERRCODE = '23514'; END IF;
    IF (l->>'unit_id')::uuid = mat.stock_unit_id THEN factor := 1;
    ELSE SELECT factor_to_stock_unit INTO factor FROM public.material_unit_conversions WHERE material_id = mat.id AND unit_id = (l->>'unit_id')::uuid;
    END IF;
    SELECT ri.quantity * bags INTO std FROM public.recipe_items ri WHERE ri.recipe_version_id = rv AND ri.material_id = mat.id AND ri.unit_id = (l->>'unit_id')::uuid;
    INSERT INTO public.production_batch_materials (organization_id, batch_id, material_id, quantity, unit_id, stock_quantity, standard_quantity, source)
    VALUES (org, bid, mat.id, (l->>'quantity')::numeric, (l->>'unit_id')::uuid, (l->>'quantity')::numeric * factor, std, l->>'source');
  END LOOP;

  -- All products into curing, one line each (not sellable yet)
  INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, created_by, production_batch_id)
  VALUES (org, 'production_output', cur.branch_id, cur.id, bdate, 'Production batch — curing', auth.uid(), bid)
  RETURNING id INTO mv;
  PERFORM public.production_post_outputs(bid, mv, bdate);
  UPDATE public.production_batches SET output_movement_id = mv WHERE id = bid;

  IF coalesce((p->>'issue_materials')::boolean, true) AND EXISTS (SELECT 1 FROM public.production_batch_materials WHERE batch_id = bid) THEN
    PERFORM public.production_post_materials(bid);
  END IF;

  -- Bags used outside the band the output implies: flagged, never corrected
  IF banded AND (bags < bmin OR (bmax <> 'Infinity'::numeric AND bags > bmax)) THEN
    SELECT string_agg(format('%s × %s', x.pieces_cast, pr.canonical_name), ' + ') INTO pname
    FROM public.production_batch_outputs x JOIN public.products pr ON pr.id = x.product_id WHERE x.batch_id = bid;
    INSERT INTO public.review_flags (organization_id, entity_type, entity_id, reason_code, reason, created_by)
    VALUES (org, 'production_batch', bid::text, 'yield_out_of_band',
      format('%s pieces (%s) on %s used %s bags — the products'' yields give %s bags (%s to %s with the tolerance). Check the mix, the count or the materials.',
             total, pname, bdate, bags, round(eq, 2), round(bmin, 2), CASE WHEN bmax = 'Infinity'::numeric THEN '—' ELSE round(bmax, 2)::text END),
      auth.uid());
  END IF;
  RETURN bid;
END;
$$;

-- One curing line per product cast
CREATE OR REPLACE FUNCTION public.production_post_outputs(p_batch uuid, p_movement uuid, p_date date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cur  public.warehouses;
  x    record;
  q    numeric;
BEGIN
  SELECT w.* INTO cur FROM public.warehouses w JOIN public.production_batches b ON b.curing_warehouse_id = w.id WHERE b.id = p_batch;
  FOR x IN SELECT o.*, pr.unit_id, pr.canonical_name || coalesce(' ' || cp.name, '') AS name
           FROM public.production_batch_outputs o JOIN public.products pr ON pr.id = o.product_id
           LEFT JOIN public.color_palette cp ON cp.id = o.color_id
           WHERE o.batch_id = p_batch AND o.pieces_cast > 0 LOOP
    q := public.production_stock_qty(x.product_id, x.pieces_cast);
    PERFORM public.production_ledger_line(p_movement, 'production_output', cur, NULL, x.product_id, x.color_id, q, x.unit_id, q, x.unit_id, p_date, x.name);
  END LOOP;
END;
$$;

-- A day's batches together: all saved, or none (the failing one is named)
CREATE OR REPLACE FUNCTION public.record_production_batches(p jsonb)
RETURNS uuid[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  b    jsonb;
  ids  uuid[] := '{}';
  i    int := 0;
  msg  text;
  st   text;
BEGIN
  IF jsonb_typeof(p->'batches') <> 'array' OR jsonb_array_length(p->'batches') = 0 THEN
    RAISE EXCEPTION 'Add at least one batch' USING ERRCODE = '23514';
  END IF;
  FOR b IN SELECT * FROM jsonb_array_elements(p->'batches') LOOP
    i := i + 1;
    BEGIN
      ids := ids || public.record_production_batch(b);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT, st = RETURNED_SQLSTATE;
      RAISE EXCEPTION 'Batch %: %', i, msg USING ERRCODE = st;
    END;
  END LOOP;
  RETURN ids;
END;
$$;


-- ------------------------------------------------------------
-- 3. Quality release, product by product
-- ------------------------------------------------------------
-- p: { fg_warehouse_id, release_date?, note? (required before curing ends),
--      outputs: [{ output_id, pieces_passed, rejects: [{ reason_id, pieces }] }] — every product of the batch }
CREATE OR REPLACE FUNCTION public.release_production_batch(p_batch uuid, p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org     uuid := public.get_my_org_id();
  b       public.production_batches;
  cur     public.warehouses;
  fg      public.warehouses;
  rdate   date;
  x       record;
  e       jsonb;
  r       jsonb;
  passed  int;
  rejected int;
  mv      uuid;
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
  SELECT * INTO cur FROM public.warehouses WHERE id = b.curing_warehouse_id;

  INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, notes, created_by, production_batch_id)
  VALUES (org, 'curing_release', b.branch_id, cur.id, rdate, 'Quality release', nullif(btrim(p->>'note'), ''), auth.uid(), b.id)
  RETURNING id INTO mv;

  FOR x IN SELECT o.*, pr.unit_id, pr.canonical_name || coalesce(' ' || cp.name, '') AS name
           FROM public.production_batch_outputs o JOIN public.products pr ON pr.id = o.product_id
           LEFT JOIN public.color_palette cp ON cp.id = o.color_id
           WHERE o.batch_id = b.id ORDER BY o.is_primary DESC, pr.canonical_name LOOP
    SELECT y INTO e FROM jsonb_array_elements(coalesce(p->'outputs', '[]'::jsonb)) y WHERE y->>'output_id' = x.id::text;
    IF e IS NULL THEN RAISE EXCEPTION '%: enter its passed and rejected pieces', x.name USING ERRCODE = '23514'; END IF;
    passed := nullif(e->>'pieces_passed', '')::int;
    IF passed IS NULL OR passed < 0 THEN RAISE EXCEPTION '%: enter the pieces that passed', x.name USING ERRCODE = '23514'; END IF;
    rejected := 0;
    FOR r IN SELECT * FROM jsonb_array_elements(coalesce(e->'rejects', '[]'::jsonb)) LOOP
      IF NOT EXISTS (SELECT 1 FROM public.reject_reasons WHERE id = nullif(r->>'reason_id', '')::uuid AND organization_id = org) THEN
        RAISE EXCEPTION 'Choose a reject reason from the list' USING ERRCODE = '23514';
      END IF;
      IF nullif(r->>'pieces', '')::int IS NULL OR (r->>'pieces')::int <= 0 THEN RAISE EXCEPTION 'Rejected pieces must be above zero' USING ERRCODE = '23514'; END IF;
      INSERT INTO public.production_batch_rejects (organization_id, batch_id, output_id, reason_id, pieces)
      VALUES (org, b.id, x.id, (r->>'reason_id')::uuid, (r->>'pieces')::int);
      rejected := rejected + (r->>'pieces')::int;
    END LOOP;
    IF passed + rejected <> x.pieces_cast THEN
      RAISE EXCEPTION '%: passed (%) and rejected (%) must add up to the % pieces cast', x.name, passed, rejected, x.pieces_cast USING ERRCODE = '23514';
    END IF;
    UPDATE public.production_batch_outputs SET pieces_passed = passed WHERE id = x.id;
    IF x.pieces_cast > 0 THEN
      PERFORM public.production_ledger_line(mv, 'curing_out', cur, NULL, x.product_id, x.color_id,
        -public.production_stock_qty(x.product_id, x.pieces_cast), x.unit_id, public.production_stock_qty(x.product_id, x.pieces_cast), x.unit_id, rdate, x.name);
    END IF;
    IF passed > 0 THEN
      PERFORM public.production_ledger_line(mv, 'curing_in', fg, NULL, x.product_id, x.color_id,
        public.production_stock_qty(x.product_id, passed), x.unit_id, public.production_stock_qty(x.product_id, passed), x.unit_id, rdate, x.name);
    END IF;
  END LOOP;

  UPDATE public.production_batches SET status = 'released', released_on = rdate, fg_warehouse_id = fg.id,
         release_movement_id = mv, release_note = nullif(btrim(p->>'note'), '')
  WHERE id = b.id;
  RETURN mv;
END;
$$;

REVOKE ALL ON FUNCTION public.production_post_outputs(uuid, uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_production_batch(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.record_production_batches(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_production_batch(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_production_batches(jsonb) TO authenticated;
