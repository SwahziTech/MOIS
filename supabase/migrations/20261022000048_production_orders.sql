-- ============================================================
-- 048 — Production orders (1d)
--
-- SwahziTech, 2026-10-22: an order to make products — "cast 2,000 × 40 Dot
-- Red and 500 × 60 Sq by Friday" — planned in the capacity simulator and
-- tracked as batches are cast against it.
--
--   production_orders        one per job: branch, number, reference
--                            (customer / note), due date, open | completed |
--                            cancelled
--   production_order_lines   its products: product, colour, pieces
--   production_batch_outputs.order_line_id
--                            the order line a product cast counts towards —
--                            suggested on the production form (the oldest
--                            open order for that product and colour), can be
--                            changed or left empty
--   production_order_line_progress
--                            planned, cast, curing, passed, rejected per line
--
-- An order is done when every line's PASSED pieces (after quality release)
-- reach the planned pieces: it completes itself at that release. Branch
-- managers (for their branch), directors and the technical admin create,
-- change, close and cancel orders (new permission production.plan); the
-- secretary records batches against them. The saved day plans of 045
-- ("plan & compare") are superseded by orders — their tables stay, unused.
-- ============================================================

INSERT INTO public.permissions (code, description, module)
VALUES ('production.plan', 'Create, change, close and cancel production orders', 'production')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code = 'production.plan'
WHERE r.is_system_role AND r.name IN ('owner', 'director', 'branch_manager')
ON CONFLICT DO NOTHING;


CREATE TABLE public.production_orders (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  order_no        int  NOT NULL,
  reference       text,
  due_date        date,
  notes           text,
  status          text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'completed', 'cancelled')),
  created_by      uuid REFERENCES auth.users(id) DEFAULT auth.uid(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  closed_by       uuid REFERENCES auth.users(id),
  closed_at       timestamptz,
  close_note      text,
  UNIQUE (organization_id, order_no)
);
CREATE INDEX idx_production_orders_branch ON public.production_orders(branch_id, status);

CREATE TABLE public.production_order_lines (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  order_id        uuid NOT NULL REFERENCES public.production_orders(id) ON DELETE CASCADE,
  product_id      uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  color_id        uuid REFERENCES public.color_palette(id) ON DELETE RESTRICT,
  pieces          int  NOT NULL CHECK (pieces > 0),
  sqm             numeric CHECK (sqm IS NULL OR sqm > 0),   -- as entered, when the order was given in m²
  display_order   int  NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX uq_production_order_lines ON public.production_order_lines
  (order_id, product_id, coalesce(color_id, '00000000-0000-0000-0000-000000000000'::uuid));

ALTER TABLE public.production_batch_outputs
  ADD COLUMN order_line_id uuid REFERENCES public.production_order_lines(id) ON DELETE RESTRICT;
CREATE INDEX idx_batch_outputs_order_line ON public.production_batch_outputs(order_line_id) WHERE order_line_id IS NOT NULL;

ALTER TABLE public.production_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.production_order_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "production_orders: read own org" ON public.production_orders FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "production_order_lines: read own org" ON public.production_order_lines FOR SELECT USING (organization_id = public.get_my_org_id());
-- no write policies: save_production_order() / set_production_order_status() are the writers
CREATE TRIGGER trg_production_orders_audit AFTER INSERT OR UPDATE OR DELETE ON public.production_orders
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('production_order', 'id');
CREATE TRIGGER trg_production_order_lines_audit AFTER INSERT OR UPDATE OR DELETE ON public.production_order_lines
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('production_order_line', 'id');


-- ------------------------------------------------------------
-- Progress per order line
-- ------------------------------------------------------------
CREATE VIEW public.production_order_line_progress WITH (security_invoker = true) AS
SELECT l.id AS line_id, l.order_id, l.product_id, l.color_id, l.pieces AS planned,
       coalesce(sum(o.pieces_cast)   FILTER (WHERE b.status <> 'void'), 0)::int    AS cast_pieces,
       coalesce(sum(o.pieces_cast)   FILTER (WHERE b.status = 'curing'), 0)::int   AS curing,
       coalesce(sum(o.pieces_passed) FILTER (WHERE b.status = 'released'), 0)::int AS passed,
       coalesce(sum(o.pieces_cast - o.pieces_passed) FILTER (WHERE b.status = 'released'), 0)::int AS rejected
  FROM public.production_order_lines l
  LEFT JOIN public.production_batch_outputs o ON o.order_line_id = l.id
  LEFT JOIN public.production_batches b ON b.id = o.batch_id
 GROUP BY l.id;
GRANT SELECT ON public.production_order_line_progress TO authenticated;

-- An open order whose every line has its pieces passed completes itself
CREATE FUNCTION public.production_order_check_complete(p_order uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  UPDATE public.production_orders o SET status = 'completed', closed_at = now(), closed_by = NULL,
         close_note = 'All pieces passed quality', updated_at = now()
   WHERE o.id = p_order AND o.status = 'open'
     AND EXISTS (SELECT 1 FROM public.production_order_lines WHERE order_id = o.id)
     AND NOT EXISTS (SELECT 1 FROM public.production_order_line_progress g WHERE g.order_id = o.id AND g.passed < g.planned);
END;
$$;
REVOKE ALL ON FUNCTION public.production_order_check_complete(uuid) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.production_orders_after_release()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM public.production_order_check_complete(l.order_id)
     FROM public.production_order_lines l WHERE l.id = NEW.order_line_id;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_batch_outputs_order_complete AFTER UPDATE OF pieces_passed ON public.production_batch_outputs
  FOR EACH ROW WHEN (NEW.order_line_id IS NOT NULL) EXECUTE FUNCTION public.production_orders_after_release();


-- ------------------------------------------------------------
-- save_production_order
-- ------------------------------------------------------------
-- p: { id?, branch_id, reference?, due_date?, notes?,
--      lines: [{ product_id, color_id?, pieces, sqm? }] }
-- A new order gets the next number. Changing one: only while open; a line
-- that already has batches counted can't be removed.
CREATE FUNCTION public.save_production_order(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org    uuid := public.get_my_org_id();
  uid    uuid := auth.uid();
  ord    public.production_orders;
  br     uuid;
  oid    uuid := nullif(p->>'id', '')::uuid;
  l      jsonb;
  prod   public.products;
  col    uuid;
  pcs    int;
  n      int := 0;
  keep   uuid[] := '{}';
  lid    uuid;
  gone   record;
BEGIN
  IF uid IS NULL OR org IS NULL THEN RAISE EXCEPTION 'Sign in to plan production' USING ERRCODE = '42501'; END IF;

  IF oid IS NOT NULL THEN
    SELECT * INTO ord FROM public.production_orders WHERE id = oid AND organization_id = org FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE = '23514'; END IF;
    IF ord.status <> 'open' THEN RAISE EXCEPTION 'Order % is %, so it can''t be changed — reopen it first', ord.order_no, ord.status USING ERRCODE = '23514'; END IF;
    br := ord.branch_id;
  ELSE
    br := nullif(p->>'branch_id', '')::uuid;
    IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = br AND organization_id = org) THEN
      RAISE EXCEPTION 'Choose the branch' USING ERRCODE = '23514';
    END IF;
  END IF;
  IF NOT public.has_permission_at('production.plan', br, NULL) THEN
    RAISE EXCEPTION 'Only the branch manager or an admin can plan production orders' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines') = 0 THEN
    RAISE EXCEPTION 'Add at least one product to the order' USING ERRCODE = '23514';
  END IF;

  IF oid IS NULL THEN
    PERFORM 1 FROM public.organizations WHERE id = org FOR UPDATE;   -- one numbering at a time
    INSERT INTO public.production_orders (organization_id, branch_id, order_no, reference, due_date, notes, created_by)
    VALUES (org, br, coalesce((SELECT max(order_no) FROM public.production_orders WHERE organization_id = org), 0) + 1,
            nullif(btrim(p->>'reference'), ''), nullif(p->>'due_date', '')::date, nullif(btrim(p->>'notes'), ''), uid)
    RETURNING * INTO ord;
  ELSE
    UPDATE public.production_orders SET reference = nullif(btrim(p->>'reference'), ''), due_date = nullif(p->>'due_date', '')::date,
           notes = nullif(btrim(p->>'notes'), ''), updated_at = now()
     WHERE id = ord.id;
  END IF;

  FOR l IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    n := n + 1;
    SELECT * INTO prod FROM public.products WHERE id = nullif(l->>'product_id', '')::uuid AND organization_id = org AND status = 'active';
    IF NOT FOUND THEN RAISE EXCEPTION 'Choose each product' USING ERRCODE = '23514'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.branch_products WHERE branch_id = br AND product_id = prod.id AND status = 'active') THEN
      RAISE EXCEPTION '% isn''t in this branch''s product list — add it there first', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    col := nullif(l->>'color_id', '')::uuid;
    IF public.product_is_coloured(prod.id) THEN
      IF NOT public.product_color_ok(prod.id, col) THEN
        RAISE EXCEPTION '%: choose one of its colours', prod.canonical_name USING ERRCODE = '23514';
      END IF;
    ELSIF col IS NOT NULL THEN
      RAISE EXCEPTION '% has no colours', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    pcs := nullif(l->>'pieces', '')::numeric;
    IF pcs IS NULL OR pcs <= 0 OR (l->>'pieces')::numeric <> pcs THEN
      RAISE EXCEPTION '%: enter the pieces to make (a whole number)', prod.canonical_name USING ERRCODE = '23514';
    END IF;

    SELECT id INTO lid FROM public.production_order_lines
     WHERE order_id = ord.id AND product_id = prod.id AND color_id IS NOT DISTINCT FROM col;
    IF lid = ANY (keep) THEN
      RAISE EXCEPTION '% appears twice — add its pieces together', prod.canonical_name || coalesce(' ' || (SELECT name FROM public.color_palette WHERE id = col), '')
        USING ERRCODE = '23514';
    END IF;
    IF lid IS NULL THEN
      INSERT INTO public.production_order_lines (organization_id, order_id, product_id, color_id, pieces, sqm, display_order)
      VALUES (org, ord.id, prod.id, col, pcs, nullif(l->>'sqm', '')::numeric, n) RETURNING id INTO lid;
    ELSE
      UPDATE public.production_order_lines SET pieces = pcs, sqm = nullif(l->>'sqm', '')::numeric, display_order = n WHERE id = lid;
    END IF;
    keep := keep || lid;
  END LOOP;

  -- lines left out are removed, unless batches already count towards them
  SELECT p2.canonical_name || coalesce(' ' || cp.name, '') AS name INTO gone
    FROM public.production_order_lines x
    JOIN public.products p2 ON p2.id = x.product_id
    LEFT JOIN public.color_palette cp ON cp.id = x.color_id
   WHERE x.order_id = ord.id AND NOT x.id = ANY (keep)
     AND EXISTS (SELECT 1 FROM public.production_batch_outputs o WHERE o.order_line_id = x.id)
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION '% already has batches counted towards this order — keep it (you can change its pieces)', gone.name USING ERRCODE = '23514';
  END IF;
  DELETE FROM public.production_order_lines WHERE order_id = ord.id AND NOT id = ANY (keep);

  PERFORM public.production_order_check_complete(ord.id);
  RETURN ord.id;
END;
$$;
REVOKE ALL ON FUNCTION public.save_production_order(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_production_order(jsonb) TO authenticated;


-- ------------------------------------------------------------
-- set_production_order_status: close (completed), cancel, or reopen
-- ------------------------------------------------------------
CREATE FUNCTION public.set_production_order_status(p_order uuid, p_status text, p_note text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ord public.production_orders;
BEGIN
  SELECT * INTO ord FROM public.production_orders WHERE id = p_order AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('production.plan', ord.branch_id, NULL) THEN
    RAISE EXCEPTION 'Only the branch manager or an admin can close or cancel production orders' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('open', 'completed', 'cancelled') THEN RAISE EXCEPTION 'Unknown status' USING ERRCODE = '23514'; END IF;
  IF p_status = ord.status THEN RETURN; END IF;
  UPDATE public.production_orders
     SET status = p_status, updated_at = now(),
         closed_at  = CASE WHEN p_status = 'open' THEN NULL ELSE now() END,
         closed_by  = CASE WHEN p_status = 'open' THEN NULL ELSE auth.uid() END,
         close_note = CASE WHEN p_status = 'open' THEN NULL ELSE nullif(btrim(p_note), '') END
   WHERE id = ord.id;
END;
$$;
REVOKE ALL ON FUNCTION public.set_production_order_status(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_production_order_status(uuid, text, text) TO authenticated;


-- ------------------------------------------------------------
-- Batches count towards an order line (live definition as of 047; only
-- the order line is added)
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
