-- ============================================================
-- 087 — Who worked is chosen on each batch (Staff (HR), 2026-10-28)
-- ============================================================
-- Teams change week to week, even day to day, so a team is no longer a fixed
-- list of people. The team stays as the batch's label; the people who worked
-- are ticked on each batch from the branch's staff (employees and casuals).
--
--   * production_batches.worker_ids now holds staff ids, always filled:
--     old team-member ids become their staff; a batch that took "the whole
--     team" gets the team's people as they were listed.
--   * production_people / production_presence: names (no pay) and that
--     day's attendance, for those who record production but can't see pay.
--   * add_production_person: a new labourer added from the batch becomes a
--     casual staff member (pay is set later in HR › Staff).
--   * record_production_batch: workers must be staff of the branch.
--
-- Team members (056) and staff.team_id are left in place, unused by the screens.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Past batches: workers as staff
-- ------------------------------------------------------------
UPDATE public.production_batches b
SET worker_ids = (SELECT array_agg(DISTINCT m.staff_id) FROM unnest(b.worker_ids) w
                  JOIN public.production_team_members m ON m.id = w WHERE m.staff_id IS NOT NULL)
WHERE b.worker_ids IS NOT NULL;
UPDATE public.production_batches b
SET worker_ids = (SELECT array_agg(DISTINCT m.staff_id) FROM public.production_team_members m
                  WHERE m.team_id = b.team_id AND m.status = 'active' AND m.staff_id IS NOT NULL)
WHERE b.worker_ids IS NULL AND b.team_id IS NOT NULL;
COMMENT ON COLUMN public.production_batches.worker_ids IS 'Staff who worked on the batch, ticked on each batch (087).';

-- ------------------------------------------------------------
-- 2. Names and attendance for production screens (no pay)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.production_people AS
SELECT s.id, s.organization_id, s.branch_id, s.full_name, s.kind, s.job_title, s.status
FROM public.staff s
WHERE s.organization_id = public.get_my_org_id();
COMMENT ON VIEW public.production_people IS 'Staff names for ticking who worked on a batch — no pay (087).';
GRANT SELECT ON public.production_people TO authenticated;

CREATE OR REPLACE VIEW public.production_presence AS
SELECT a.staff_id, a.branch_id, a.work_date, a.day_fraction
FROM public.staff_attendance a
WHERE a.organization_id = public.get_my_org_id();
COMMENT ON VIEW public.production_presence IS 'Who was marked at work on a day, to list them first on a batch (087).';
GRANT SELECT ON public.production_presence TO authenticated;

-- ------------------------------------------------------------
-- 3. A new labourer from the batch → a casual staff member
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_production_person(p_branch uuid, p_name text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  sid uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch AND organization_id = org)
     OR NOT (public.can_keep_production_lists(p_branch) OR public.has_permission_at('staff.manage', p_branch, NULL)) THEN
    RAISE EXCEPTION 'You can''t add people at this branch' USING ERRCODE = '42501';
  END IF;
  IF btrim(coalesce(p_name, '')) = '' THEN RAISE EXCEPTION 'Enter the person''s name' USING ERRCODE = '23514'; END IF;
  SELECT id INTO sid FROM public.staff WHERE branch_id = p_branch AND public.normalize_name(full_name) = public.normalize_name(p_name);
  IF sid IS NULL THEN
    INSERT INTO public.staff (organization_id, branch_id, full_name, kind)
    VALUES (org, p_branch, btrim(p_name), 'casual') RETURNING id INTO sid;
  END IF;
  RETURN sid;
END;
$$;
REVOKE ALL ON FUNCTION public.add_production_person(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_production_person(uuid, text) TO authenticated;

-- ------------------------------------------------------------
-- 4. Recording a batch: workers are staff of the branch
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_production_batch(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  ocol    uuid;          -- a product's own colour in the mix (047)
  oline   uuid;          -- the order line it counts towards (048)
  team    public.production_teams;   -- who made it (056)
  mach    public.machines;           -- what it was made on (056)
  workers uuid[];                    -- who worked: staff ticked on the batch (087)
  ol      record;
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

  -- Who made it and on what (056): both required
  SELECT * INTO team FROM public.production_teams WHERE id = nullif(p->>'team_id', '')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND OR team.branch_id <> raw.branch_id THEN RAISE EXCEPTION 'Choose the team that made this batch' USING ERRCODE = '23514'; END IF;
  SELECT * INTO mach FROM public.machines WHERE id = nullif(p->>'machine_id', '')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND OR mach.branch_id <> raw.branch_id THEN RAISE EXCEPTION 'Choose the machine this batch was made on' USING ERRCODE = '23514'; END IF;
  -- who worked (087): the branch's staff ticked on the batch — teams change day to day, so the
  -- people are chosen on each batch. Ids of old team members (a day still waiting in Approvals) are read as their staff.
  IF jsonb_typeof(p->'worker_ids') = 'array' THEN
    SELECT array_agg(DISTINCT coalesce(s.id, m.staff_id, x::uuid)) INTO workers
    FROM jsonb_array_elements_text(p->'worker_ids') x
    LEFT JOIN public.staff s ON s.id = x::uuid
    LEFT JOIN public.production_team_members m ON m.id = x::uuid;
    IF workers IS NULL THEN RAISE EXCEPTION 'Tick at least one person who worked on this batch' USING ERRCODE = '23514'; END IF;
    IF EXISTS (SELECT 1 FROM unnest(workers) w WHERE NOT EXISTS (
         SELECT 1 FROM public.staff s WHERE s.id = w AND s.organization_id = org AND s.branch_id = raw.branch_id)) THEN
      RAISE EXCEPTION 'Someone ticked isn''t on this branch''s staff' USING ERRCODE = '23514';
    END IF;
  ELSE
    -- none ticked (a day from before 087): the team's people as they were listed
    SELECT array_agg(DISTINCT m.staff_id) INTO workers FROM public.production_team_members m
    WHERE m.team_id = team.id AND m.status = 'active' AND m.staff_id IS NOT NULL;
  END IF;

  -- The main product first
  outs := coalesce(p->'outputs', '[]'::jsonb);
  IF jsonb_array_length(outs) = 0 THEN RAISE EXCEPTION 'Enter the product cast and its pieces' USING ERRCODE = '23514'; END IF;
  SELECT coalesce((SELECT x FROM jsonb_array_elements(outs) x WHERE (x->>'primary')::boolean LIMIT 1), outs->0) INTO o;
  SELECT * INTO main FROM public.products WHERE id = nullif(o->>'product_id', '')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'Choose the product' USING ERRCODE = '23514'; END IF;
  IF public.product_is_coloured(main.id) THEN
    IF col IS NULL OR NOT public.product_color_ok(main.id, col) THEN
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
    other_products_allowed_by, team_id, machine_id, worker_ids)
  VALUES (org, raw.branch_id, bdate, main.id, col, rv, raw.id, cur.id, bags, 0,
          bdate + (SELECT curing_days FROM public.organizations WHERE id = org),
          nullif(btrim(p->>'notes'), ''), auth.uid(), CASE WHEN others THEN auth.uid() END, team.id, mach.id, workers)
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
    -- each product's own colour (047): the main product takes the mix's colour;
    -- a residual its own color_id, else the mix's
    ocol := CASE WHEN prod.id = main.id THEN col ELSE coalesce(nullif(o->>'color_id', '')::uuid, col) END;
    IF public.product_is_coloured(prod.id) THEN
      IF ocol IS NULL OR NOT public.product_color_ok(prod.id, ocol) THEN
        RAISE EXCEPTION '%: choose one of its colours', prod.canonical_name USING ERRCODE = '23514';
      END IF;
    ELSIF prod.id <> main.id AND nullif(o->>'color_id', '') IS NOT NULL THEN
      RAISE EXCEPTION '% has no colours', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    -- the production order it counts towards, if any (048): an open order of this branch, same product and colour
    oline := nullif(o->>'order_line_id', '')::uuid;
    IF oline IS NOT NULL THEN
      SELECT l.product_id, l.color_id, po.status, po.branch_id, po.order_no INTO ol
        FROM public.production_order_lines l JOIN public.production_orders po ON po.id = l.order_id
       WHERE l.id = oline AND l.organization_id = org;
      IF NOT FOUND THEN RAISE EXCEPTION '%: that production order isn''t available', prod.canonical_name USING ERRCODE = '23514'; END IF;
      IF ol.status <> 'open' THEN
        RAISE EXCEPTION '%: production order % is %', prod.canonical_name, ol.order_no, ol.status USING ERRCODE = '23514';
      END IF;
      IF ol.branch_id <> raw.branch_id OR ol.product_id <> prod.id
         OR ol.color_id IS DISTINCT FROM (CASE WHEN public.product_is_coloured(prod.id) THEN ocol END) THEN
        RAISE EXCEPTION '%: production order % is for a different product, colour or branch', prod.canonical_name, ol.order_no USING ERRCODE = '23514';
      END IF;
    END IF;
    IF nullif(o->>'pieces', '')::int IS NULL OR (o->>'pieces')::int < 0 THEN
      RAISE EXCEPTION '%: enter the pieces cast', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    SELECT * INTO band FROM public.product_yield_band(prod.id, raw.branch_id);
    INSERT INTO public.production_batch_outputs (organization_id, batch_id, product_id, color_id, is_primary, pieces_cast, yield_per_bag, yield_tolerance, order_line_id)
    VALUES (org, bid, prod.id, CASE WHEN public.product_is_coloured(prod.id) THEN ocol END,
            prod.id = main.id, (o->>'pieces')::int, band.average_yield_per_bag, band.yield_tolerance, oline);
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
  -- material thrown away making it (056): out of stock with its reason, costed apart
  IF jsonb_array_length(coalesce(p->'waste', '[]'::jsonb)) > 0 THEN PERFORM public.production_post_waste(bid, p->'waste'); END IF;

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
$function$;
