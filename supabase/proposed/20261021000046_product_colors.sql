-- ============================================================
-- 046 — A product's own colours (1c/1d)
--
-- SwahziTech, 2026-10-21: colours are switched on or off per product in the
-- product's edit screen. Until an admin sets them, a product follows its
-- category's colours (as before) — so press products, whose categories have
-- no colours, have none unless an admin turns some on.
--
--   products.own_colors   false = the category's colours; true = the
--                         product's own list in product_colors (empty = none)
--   product_color_ids()   a product's colours, in order — what every stock,
--                         production and reclassification check now reads
--   set_product_colors()  the one way to change them (org admins). Stock on
--                         hand, or a batch still curing, in a colour that is
--                         being switched off is never stranded: the change is
--                         refused and says where that stock is, unless the
--                         admin says which colour (or no colour) it moves to —
--                         then it moves by a reclassification today, in the
--                         same call.
--
-- Recipes, colour prices and the pricing approval stay per category.
-- ============================================================

ALTER TABLE public.products ADD COLUMN own_colors boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.products.own_colors
  IS 'false: the product has its category''s colours. true: its own list in product_colors (none = not coloured). Changed only by set_product_colors().';

CREATE TABLE public.product_colors (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  product_id      uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  color_id        uuid NOT NULL REFERENCES public.color_palette(id) ON DELETE RESTRICT,
  display_order   int NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (product_id, color_id)
);
CREATE INDEX idx_product_colors_org ON public.product_colors(organization_id);
ALTER TABLE public.product_colors ENABLE ROW LEVEL SECURITY;
CREATE POLICY "product_colors: read own org" ON public.product_colors FOR SELECT
  USING (organization_id = public.get_my_org_id());
-- no write policies: set_product_colors() is the only writer
CREATE TRIGGER trg_product_colors_audit AFTER INSERT OR UPDATE OR DELETE ON public.product_colors
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('product_color', 'product_id,color_id');
COMMENT ON TABLE public.product_colors IS 'A product''s own colours, used when products.own_colors is true (046).';


-- ------------------------------------------------------------
-- A product's colours
-- ------------------------------------------------------------
CREATE FUNCTION public.product_color_ids(p_product uuid)
RETURNS SETOF uuid
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT color_id FROM (
    SELECT pc.color_id, pc.display_order FROM public.products p
      JOIN public.product_colors pc ON pc.product_id = p.id
     WHERE p.id = p_product AND p.own_colors
    UNION ALL
    SELECT cc.color_id, cc.display_order FROM public.products p
      JOIN public.product_category_colors cc ON cc.category_id = p.category_id
     WHERE p.id = p_product AND NOT p.own_colors
  ) x ORDER BY display_order
$$;

CREATE FUNCTION public.product_is_coloured(p_product uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = public
AS $$ SELECT EXISTS (SELECT 1 FROM public.product_color_ids(p_product)) $$;

CREATE FUNCTION public.product_color_ok(p_product uuid, p_color uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = public
AS $$ SELECT p_color IS NOT NULL AND EXISTS (SELECT 1 FROM public.product_color_ids(p_product) c WHERE c = p_color) $$;


-- own_colors only through set_product_colors(), which looks after the stock
CREATE FUNCTION public.check_own_colors_via_rpc()
RETURNS trigger LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  IF NEW.own_colors IS DISTINCT FROM OLD.own_colors AND coalesce(current_setting('mois.product_colors', true), '') <> 'on' THEN
    RAISE EXCEPTION 'Change a product''s colours from its edit screen' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_products_own_colors BEFORE UPDATE OF own_colors ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.check_own_colors_via_rpc();


-- ------------------------------------------------------------
-- set_product_colors
-- ------------------------------------------------------------
-- p_own false: back to the category's colours. p_own true: exactly p_color_ids
-- (empty = no colour). p_move_to: where stock in a colour being switched off
-- goes — a colour id from the new list, or 'none' when the new list is empty.
-- Without it, such stock refuses the change (HINT 'move_stock').
CREATE FUNCTION public.set_product_colors(p_product uuid, p_own boolean, p_color_ids uuid[] DEFAULT '{}', p_move_to text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org      uuid := public.get_my_org_id();
  uid      uuid := auth.uid();
  prod     public.products;
  new_ids  uuid[];
  tcol     uuid;
  r        record;
  stranded text := '';
  movs     jsonb := '{}';
  mov      uuid;
  today    date;
  wh_label text;
  fname    text;
  tname    text;
BEGIN
  IF uid IS NULL OR org IS NULL THEN
    RAISE EXCEPTION 'Sign in to change products' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO prod FROM public.products WHERE id = p_product AND organization_id = org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Product not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission('products.manage') THEN
    RAISE EXCEPTION 'Only an organization admin can change a product''s colours' USING ERRCODE = '42501';
  END IF;

  IF p_own THEN
    IF EXISTS (SELECT 1 FROM unnest(coalesce(p_color_ids, '{}')) c
               WHERE NOT EXISTS (SELECT 1 FROM public.color_palette cp WHERE cp.id = c AND cp.organization_id = org)) THEN
      RAISE EXCEPTION 'Colour not found' USING ERRCODE = '23514';
    END IF;
    new_ids := ARRAY(SELECT c FROM unnest(coalesce(p_color_ids, '{}')) WITH ORDINALITY u(c, o) GROUP BY c ORDER BY min(o));
  ELSE
    new_ids := ARRAY(SELECT color_id FROM public.product_category_colors WHERE category_id = prod.category_id ORDER BY display_order);
  END IF;

  -- a batch still curing in a colour that goes away can't be released into it
  SELECT b.batch_date, cp.name AS cname INTO r
    FROM public.production_batch_outputs o
    JOIN public.production_batches b ON b.id = o.batch_id
    LEFT JOIN public.color_palette cp ON cp.id = o.color_id
   WHERE o.product_id = prod.id AND b.status = 'curing'
     AND (CASE WHEN cardinality(new_ids) = 0 THEN o.color_id IS NOT NULL
               ELSE o.color_id IS NULL OR NOT o.color_id = ANY (new_ids) END)
   ORDER BY b.batch_date LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION '% has a batch still curing in % (cast %) — release or void it first',
      prod.canonical_name, coalesce(r.cname, 'no colour'), to_char(r.batch_date, 'DD Mon YYYY') USING ERRCODE = '23514';
  END IF;

  -- where stock in a colour being switched off goes
  IF p_move_to IS NOT NULL THEN
    IF cardinality(new_ids) = 0 THEN
      IF p_move_to <> 'none' THEN RAISE EXCEPTION 'With no colours, the stock can only move to no colour' USING ERRCODE = '23514'; END IF;
      tcol := NULL;
    ELSE
      tcol := nullif(p_move_to, 'none')::uuid;
      IF tcol IS NULL OR NOT tcol = ANY (new_ids) THEN
        RAISE EXCEPTION 'Choose one of the colours being kept for the stock' USING ERRCODE = '23514';
      END IF;
    END IF;
  END IF;

  today := public.org_today(org);
  PERFORM set_config('mois.product_colors', 'on', true);

  FOR r IN
    SELECT sb.warehouse_id, sb.color_id, sb.quantity, w.branch_id, w.name AS wname, b.name AS bname, cp.name AS cname
      FROM public.stock_balances sb
      JOIN public.warehouses w ON w.id = sb.warehouse_id
      JOIN public.branches b ON b.id = w.branch_id
      LEFT JOIN public.color_palette cp ON cp.id = sb.color_id
     WHERE sb.product_id = prod.id AND sb.quantity <> 0
       AND (CASE WHEN cardinality(new_ids) = 0 THEN sb.color_id IS NOT NULL
                 ELSE sb.color_id IS NULL OR NOT sb.color_id = ANY (new_ids) END)
     ORDER BY b.name, w.name, cp.name
  LOOP
    wh_label := r.bname || ' — ' || r.wname;
    IF p_move_to IS NULL THEN
      stranded := stranded || CASE WHEN stranded = '' THEN '' ELSE '; ' END
        || trim(to_char(r.quantity, 'FM999,999,999,990.##'), '.') || ' ' || coalesce(r.cname, 'with no colour') || ' at ' || wh_label;
      CONTINUE;
    END IF;
    IF r.quantity < 0 THEN
      RAISE EXCEPTION '% % at % is below zero — correct the count first', prod.canonical_name, coalesce(r.cname, ''), wh_label USING ERRCODE = '23514';
    END IF;
    IF NOT public.has_permission_at('inventory.adjust', r.branch_id, r.warehouse_id) THEN
      RAISE EXCEPTION 'You don''t have permission to move stock at %', wh_label USING ERRCODE = '42501';
    END IF;
    fname := prod.canonical_name || coalesce(' ' || r.cname, '');
    tname := prod.canonical_name || coalesce(' ' || (SELECT name FROM public.color_palette WHERE id = tcol), '');
    PERFORM public.inventory_lock_item(r.warehouse_id, NULL, prod.id, r.color_id);
    PERFORM public.inventory_lock_item(r.warehouse_id, NULL, prod.id, tcol);
    PERFORM public.inventory_check_after_opening(r.warehouse_id, NULL, prod.id, tcol, today, tname, wh_label);
    PERFORM public.inventory_check_outflow(r.warehouse_id, NULL, prod.id, r.color_id, today, -r.quantity, fname, wh_label);

    mov := nullif(movs->>r.warehouse_id::text, '')::uuid;
    IF mov IS NULL THEN
      INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, created_by)
      VALUES (org, 'reclassification', r.branch_id, r.warehouse_id, today,
              prod.canonical_name || ': colours changed — stock moved to ' || coalesce((SELECT name FROM public.color_palette WHERE id = tcol), 'no colour'), uid)
      RETURNING id INTO mov;
      movs := movs || jsonb_build_object(r.warehouse_id::text, mov);
    END IF;
    INSERT INTO public.inventory_transactions
      (organization_id, movement_id, transaction_type, branch_id, warehouse_id, product_id, color_id,
       quantity, stock_unit_id, entered_quantity, entered_unit_id, transaction_date, created_by)
    VALUES
      (org, mov, 'reclassification', r.branch_id, r.warehouse_id, prod.id, r.color_id, -r.quantity, prod.unit_id, r.quantity, prod.unit_id, today, uid),
      (org, mov, 'reclassification', r.branch_id, r.warehouse_id, prod.id, tcol,        r.quantity, prod.unit_id, r.quantity, prod.unit_id, today, uid);
  END LOOP;

  IF stranded <> '' THEN
    RAISE EXCEPTION '% has stock that won''t match its new colours: % — choose where that stock goes', prod.canonical_name, stranded
      USING ERRCODE = '23514', HINT = 'move_stock';
  END IF;

  UPDATE public.products SET own_colors = p_own WHERE id = prod.id AND own_colors IS DISTINCT FROM p_own;
  DELETE FROM public.product_colors WHERE product_id = prod.id;
  IF p_own THEN
    INSERT INTO public.product_colors (organization_id, product_id, color_id, display_order)
    SELECT org, prod.id, c, o FROM unnest(new_ids) WITH ORDINALITY u(c, o);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.set_product_colors(uuid, boolean, uuid[], text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_product_colors(uuid, boolean, uuid[], text) TO authenticated;


-- ------------------------------------------------------------
-- Stock, reclassification and production read the product's colours
-- (live definitions as of 044; only the colour checks change)
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.post_inventory_movement(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  org       uuid := public.get_my_org_id();
  uid       uuid := auth.uid();
  mtype     text := p->>'type';
  today     date;
  wh        public.warehouses;
  to_wh     public.warehouses;
  wh_label  text;
  to_label  text;
  perm      text;
  mdate     date;
  sup_id    uuid := nullif(p->>'supplier_id', '')::uuid;
  new_sup   text := nullif(btrim(p->>'new_supplier_name'), '');
  clash     text;
  mov_id    uuid;
  line      jsonb;
  n_lines   int;
  mat       public.materials;
  prod      public.products;
  item_mat  uuid;
  item_pro  uuid;
  item_col  uuid;
  item_name text;
  stock_u   uuid;
  factor    numeric;
  entered   numeric;
  qty       numeric;
  delta     numeric;
  seen      text[] := '{}';
BEGIN
  IF uid IS NULL OR org IS NULL THEN
    RAISE EXCEPTION 'Sign in to record stock movements' USING ERRCODE = '42501';
  END IF;
  today := public.org_today(org);
  mdate := coalesce(nullif(p->>'movement_date', '')::date, today);

  perm := CASE mtype
    WHEN 'opening_balance' THEN 'inventory.adjust'
    WHEN 'receipt'         THEN 'inventory.receive'
    WHEN 'issue'           THEN 'inventory.issue'
    WHEN 'transfer'        THEN 'inventory.transfer'
    WHEN 'adjustment'      THEN 'inventory.adjust'
    WHEN 'count'           THEN 'inventory.count'
  END;
  IF perm IS NULL THEN
    RAISE EXCEPTION 'Unknown movement type' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO wh FROM public.warehouses
  WHERE id = (p->>'warehouse_id')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Choose an active warehouse' USING ERRCODE = '23514';
  END IF;
  wh_label := (SELECT b.name FROM public.branches b WHERE b.id = wh.branch_id) || ' — ' || wh.name;
  IF NOT public.has_permission_at(perm, wh.branch_id, wh.id) THEN
    RAISE EXCEPTION 'You don''t have permission for this at %', wh_label USING ERRCODE = '42501';
  END IF;

  IF mdate > today THEN
    RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514';
  END IF;
  IF mdate < today AND NOT public.has_permission_at('inventory.adjust', wh.branch_id, wh.id) THEN
    RAISE EXCEPTION 'Recording a movement for an earlier date (%) needs stock-adjustment permission at %', mdate, wh_label
      USING ERRCODE = '42501';
  END IF;

  IF mtype = 'transfer' THEN
    SELECT * INTO to_wh FROM public.warehouses
    WHERE id = (p->>'to_warehouse_id')::uuid AND organization_id = org AND status = 'active';
    IF NOT FOUND OR to_wh.id = wh.id THEN
      RAISE EXCEPTION 'Choose a different, active destination warehouse' USING ERRCODE = '23514';
    END IF;
    to_label := (SELECT b.name FROM public.branches b WHERE b.id = to_wh.branch_id) || ' — ' || to_wh.name;
  ELSIF nullif(p->>'to_warehouse_id', '') IS NOT NULL THEN
    RAISE EXCEPTION 'Only transfers have a destination' USING ERRCODE = '23514';
  END IF;

  IF sup_id IS NOT NULL OR new_sup IS NOT NULL THEN
    IF mtype <> 'receipt' THEN
      RAISE EXCEPTION 'Only receipts have a supplier' USING ERRCODE = '23514';
    END IF;
    IF sup_id IS NOT NULL AND new_sup IS NOT NULL THEN
      RAISE EXCEPTION 'Choose an existing supplier or a new one, not both' USING ERRCODE = '23514';
    END IF;
  END IF;
  IF sup_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id = sup_id AND organization_id = org) THEN
    RAISE EXCEPTION 'Supplier not found' USING ERRCODE = '23514';
  END IF;
  IF new_sup IS NOT NULL THEN
    SELECT name INTO clash FROM public.suppliers
    WHERE organization_id = org AND public.normalize_name(name) = public.normalize_name(new_sup);
    IF FOUND THEN
      RAISE EXCEPTION 'A supplier called "%" already exists — choose it instead', clash USING ERRCODE = '23505';
    END IF;
    IF public.normalize_name(new_sup) = '' THEN
      RAISE EXCEPTION 'Give the supplier a name' USING ERRCODE = '23514';
    END IF;
    INSERT INTO public.suppliers (organization_id, name) VALUES (org, new_sup) RETURNING id INTO sup_id;
  END IF;

  IF mtype = 'adjustment' AND nullif(btrim(p->>'reason'), '') IS NULL THEN
    RAISE EXCEPTION 'Give a reason for the adjustment' USING ERRCODE = '23514';
  END IF;

  n_lines := CASE WHEN jsonb_typeof(p->'lines') = 'array' THEN jsonb_array_length(p->'lines') ELSE 0 END;
  IF n_lines = 0 THEN
    RAISE EXCEPTION 'Add at least one item' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.inventory_movements
    (organization_id, movement_type, branch_id, warehouse_id, to_warehouse_id, supplier_id,
     movement_date, reason, reference, notes, created_by)
  VALUES
    (org, mtype, wh.branch_id, wh.id, to_wh.id, sup_id,
     mdate, nullif(btrim(p->>'reason'), ''), nullif(btrim(p->>'reference'), ''), nullif(btrim(p->>'notes'), ''), uid)
  RETURNING id INTO mov_id;

  FOR line IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    item_mat := nullif(line->>'material_id', '')::uuid;
    item_pro := nullif(line->>'product_id', '')::uuid;
    item_col := nullif(line->>'color_id', '')::uuid;
    IF num_nonnulls(item_mat, item_pro) <> 1 THEN
      RAISE EXCEPTION 'Each line needs one material or one product' USING ERRCODE = '23514';
    END IF;
    IF coalesce(item_mat, item_pro)::text || coalesce(item_col::text, '') = ANY (seen) THEN
      RAISE EXCEPTION 'An item appears twice — combine the lines' USING ERRCODE = '23514';
    END IF;
    seen := seen || (coalesce(item_mat, item_pro)::text || coalesce(item_col::text, ''));

    IF item_mat IS NOT NULL THEN
      IF item_col IS NOT NULL THEN
        RAISE EXCEPTION 'Materials are not stocked by colour' USING ERRCODE = '23514';
      END IF;
      SELECT * INTO mat FROM public.materials WHERE id = item_mat AND organization_id = org AND status = 'active';
      IF NOT FOUND THEN RAISE EXCEPTION 'Material not found or inactive' USING ERRCODE = '23514'; END IF;
      item_name := mat.name;
      stock_u := mat.stock_unit_id;
      IF stock_u IS NULL THEN
        RAISE EXCEPTION '%: set its stock unit under Materials first', mat.name USING ERRCODE = '23514';
      END IF;
      IF (line->>'unit_id')::uuid = stock_u THEN
        factor := 1;
      ELSE
        SELECT factor_to_stock_unit INTO factor FROM public.material_unit_conversions
        WHERE material_id = mat.id AND unit_id = (line->>'unit_id')::uuid;
        IF NOT FOUND THEN
          RAISE EXCEPTION '%: use its stock unit or one of its listed units', mat.name USING ERRCODE = '23514';
        END IF;
      END IF;
    ELSE
      SELECT * INTO prod FROM public.products WHERE id = item_pro AND organization_id = org AND status = 'active';
      IF NOT FOUND THEN RAISE EXCEPTION 'Product not found or inactive' USING ERRCODE = '23514'; END IF;
      item_name := prod.canonical_name;
      -- Coloured categories are stocked per colour; plain ones are not
      IF public.product_is_coloured(prod.id) THEN
        IF item_col IS NULL THEN
          RAISE EXCEPTION '%: choose the colour', prod.canonical_name USING ERRCODE = '23514';
        END IF;
        IF NOT public.product_color_ok(prod.id, item_col) THEN
          RAISE EXCEPTION '%: that colour isn''t one of its category''s colours', prod.canonical_name USING ERRCODE = '23514';
        END IF;
        item_name := item_name || ' ' || (SELECT name FROM public.color_palette WHERE id = item_col);
      ELSIF item_col IS NOT NULL THEN
        RAISE EXCEPTION '%: its category has no colours', prod.canonical_name USING ERRCODE = '23514';
      END IF;
      stock_u := prod.unit_id;
      IF (line->>'unit_id')::uuid IS DISTINCT FROM stock_u THEN
        RAISE EXCEPTION '%: record it in its stock unit', prod.canonical_name USING ERRCODE = '23514';
      END IF;
      factor := 1;
    END IF;

    entered := (line->>'quantity')::numeric;
    IF entered IS NULL
       OR (mtype = 'count' AND entered < 0)
       OR (mtype = 'adjustment' AND entered = 0)
       OR (mtype NOT IN ('count', 'adjustment') AND entered <= 0) THEN
      RAISE EXCEPTION '%: enter a valid quantity', item_name USING ERRCODE = '23514';
    END IF;
    IF nullif(line->>'unit_cost', '') IS NOT NULL AND mtype NOT IN ('receipt', 'opening_balance') THEN
      RAISE EXCEPTION 'Only receipts and opening balances carry a cost' USING ERRCODE = '23514';
    END IF;
    qty := entered * factor;

    PERFORM public.inventory_lock_item(wh.id, item_mat, item_pro, item_col);

    IF mtype = 'opening_balance' THEN
      IF EXISTS (SELECT 1 FROM public.inventory_transactions t
                 JOIN public.inventory_movements m ON m.id = t.movement_id
                 WHERE t.warehouse_id = wh.id AND t.material_id IS NOT DISTINCT FROM item_mat
                   AND t.product_id IS NOT DISTINCT FROM item_pro AND t.color_id IS NOT DISTINCT FROM item_col
                   AND NOT (m.movement_type = 'opening_balance'
                            AND EXISTS (SELECT 1 FROM public.inventory_movements r WHERE r.reverses_movement_id = m.id))
                   AND NOT (m.movement_type = 'reversal'
                            AND EXISTS (SELECT 1 FROM public.inventory_movements o
                                        WHERE o.id = m.reverses_movement_id AND o.movement_type = 'opening_balance'))) THEN
        RAISE EXCEPTION '%: already has stock movements here — use an adjustment or a count', item_name USING ERRCODE = '23514';
      END IF;
    ELSE
      PERFORM public.inventory_check_after_opening(wh.id, item_mat, item_pro, item_col, mdate, item_name, wh_label);
    END IF;

    delta := CASE mtype
      WHEN 'issue'    THEN -qty
      WHEN 'transfer' THEN -qty
      WHEN 'count'    THEN qty - public.inventory_balance_as_of(wh.id, item_mat, item_pro, item_col, mdate)
      ELSE qty
    END;
    PERFORM public.inventory_check_outflow(wh.id, item_mat, item_pro, item_col, mdate, delta, item_name, wh_label);

    INSERT INTO public.inventory_transactions
      (organization_id, movement_id, transaction_type, branch_id, warehouse_id, material_id, product_id, color_id,
       quantity, stock_unit_id, entered_quantity, entered_unit_id, counted_quantity, unit_cost, transaction_date, created_by)
    VALUES
      (org, mov_id, CASE mtype WHEN 'transfer' THEN 'transfer_out' ELSE mtype END,
       wh.branch_id, wh.id, item_mat, item_pro, item_col,
       delta, stock_u, entered, (line->>'unit_id')::uuid,
       CASE WHEN mtype = 'count' THEN qty END,
       nullif(line->>'unit_cost', '')::numeric, mdate, uid);

    IF mtype = 'transfer' THEN
      PERFORM public.inventory_lock_item(to_wh.id, item_mat, item_pro, item_col);
      PERFORM public.inventory_check_after_opening(to_wh.id, item_mat, item_pro, item_col, mdate, item_name, to_label);
      INSERT INTO public.inventory_transactions
        (organization_id, movement_id, transaction_type, branch_id, warehouse_id, material_id, product_id, color_id,
         quantity, stock_unit_id, entered_quantity, entered_unit_id, transaction_date, created_by)
      VALUES
        (org, mov_id, 'transfer_in', to_wh.branch_id, to_wh.id, item_mat, item_pro, item_col,
         qty, stock_u, entered, (line->>'unit_id')::uuid, mdate, uid);
    END IF;
  END LOOP;

  RETURN mov_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.reclassify_stock(p jsonb)
 RETURNS uuid[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  org     uuid := public.get_my_org_id();
  uid     uuid := auth.uid();
  today   date;
  mdate   date;
  line    jsonb;
  wh      public.warehouses;
  wh_label text;
  fp      public.products;
  tp      public.products;
  fcol    uuid;
  tcol    uuid;
  qty     numeric;
  mov     uuid;
  movs    jsonb := '{}';     -- warehouse id → movement id
  ids     uuid[] := '{}';
  fname   text;
  tname   text;
BEGIN
  IF uid IS NULL OR org IS NULL THEN
    RAISE EXCEPTION 'Sign in to record stock movements' USING ERRCODE = '42501';
  END IF;
  today := public.org_today(org);
  mdate := coalesce(nullif(p->>'date', '')::date, today);
  IF mdate > today THEN
    RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514';
  END IF;
  IF nullif(btrim(p->>'reason'), '') IS NULL THEN
    RAISE EXCEPTION 'Say why the stock is being moved to another product' USING ERRCODE = '23514';
  END IF;
  IF jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines') = 0 THEN
    RAISE EXCEPTION 'Nothing to move' USING ERRCODE = '23514';
  END IF;

  FOR line IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    SELECT * INTO wh FROM public.warehouses WHERE id = (line->>'warehouse_id')::uuid AND organization_id = org;
    IF NOT FOUND THEN RAISE EXCEPTION 'Store not found' USING ERRCODE = '23514'; END IF;
    wh_label := (SELECT b.name FROM public.branches b WHERE b.id = wh.branch_id) || ' — ' || wh.name;
    IF NOT public.has_permission_at('inventory.adjust', wh.branch_id, wh.id) THEN
      RAISE EXCEPTION 'You don''t have permission to move stock between products at %', wh_label USING ERRCODE = '42501';
    END IF;

    SELECT * INTO fp FROM public.products WHERE id = (line->>'from_product_id')::uuid AND organization_id = org;
    SELECT * INTO tp FROM public.products WHERE id = (line->>'to_product_id')::uuid AND organization_id = org AND status = 'active';
    IF fp.id IS NULL OR tp.id IS NULL THEN RAISE EXCEPTION 'Product not found (the one receiving stock must be active)' USING ERRCODE = '23514'; END IF;
    IF fp.id = tp.id THEN RAISE EXCEPTION '%: choose a different product to move the stock to', fp.canonical_name USING ERRCODE = '23514'; END IF;
    IF fp.unit_id <> tp.unit_id THEN
      RAISE EXCEPTION '% and % are counted in different units, so stock can''t be moved between them', fp.canonical_name, tp.canonical_name
        USING ERRCODE = '23514';
    END IF;

    fcol := nullif(line->>'color_id', '')::uuid;
    tcol := coalesce(nullif(line->>'to_color_id', '')::uuid, fcol);
    IF public.product_is_coloured(tp.id) THEN
      IF tcol IS NULL OR NOT public.product_color_ok(tp.id, tcol) THEN
        RAISE EXCEPTION '%: choose one of its colours for the stock', tp.canonical_name USING ERRCODE = '23514';
      END IF;
    ELSE
      tcol := NULL;
    END IF;

    qty := (line->>'quantity')::numeric;
    IF qty IS NULL OR qty <= 0 THEN RAISE EXCEPTION 'Enter how much to move' USING ERRCODE = '23514'; END IF;

    fname := fp.canonical_name || coalesce(' ' || (SELECT name FROM public.color_palette WHERE id = fcol), '');
    tname := tp.canonical_name || coalesce(' ' || (SELECT name FROM public.color_palette WHERE id = tcol), '');
    PERFORM public.inventory_lock_item(wh.id, NULL, fp.id, fcol);
    PERFORM public.inventory_lock_item(wh.id, NULL, tp.id, tcol);
    PERFORM public.inventory_check_after_opening(wh.id, NULL, fp.id, fcol, mdate, fname, wh_label);
    PERFORM public.inventory_check_after_opening(wh.id, NULL, tp.id, tcol, mdate, tname, wh_label);
    PERFORM public.inventory_check_outflow(wh.id, NULL, fp.id, fcol, mdate, -qty, fname, wh_label);

    mov := nullif(movs->>wh.id::text, '')::uuid;
    IF mov IS NULL THEN
      INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, reference, created_by)
      VALUES (org, 'reclassification', wh.branch_id, wh.id, mdate, btrim(p->>'reason'), nullif(btrim(p->>'reference'), ''), uid)
      RETURNING id INTO mov;
      movs := movs || jsonb_build_object(wh.id::text, mov);
      ids := ids || mov;
    END IF;

    INSERT INTO public.inventory_transactions
      (organization_id, movement_id, transaction_type, branch_id, warehouse_id, product_id, color_id,
       quantity, stock_unit_id, entered_quantity, entered_unit_id, transaction_date, created_by)
    VALUES
      (org, mov, 'reclassification', wh.branch_id, wh.id, fp.id, fcol, -qty, fp.unit_id, qty, fp.unit_id, mdate, uid),
      (org, mov, 'reclassification', wh.branch_id, wh.id, tp.id, tcol,  qty, tp.unit_id, qty, tp.unit_id, mdate, uid);
  END LOOP;

  RETURN ids;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_production_batch(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    -- the mix's colour must be one this product comes in (or none, for a plain category)
    IF public.product_is_coloured(prod.id) THEN
      IF col IS NULL OR NOT public.product_color_ok(prod.id, col) THEN
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
    VALUES (org, bid, prod.id, CASE WHEN public.product_is_coloured(prod.id) THEN col END,
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
$function$;
