-- ============================================================
-- 139 — Broken while loading: into a rejects store, for the sale
--
-- SwahziTech, 2026-11-21 (the user): pieces found broken while a sale is
-- loaded were never recorded, so stock stopped matching. The goods leaving
-- window now takes, per line, the pieces broken: the customer gets what was
-- loaded (600), the broken ones (3) leave the same store into the branch's
-- REJECTS store, marked as broken while loading for that sale (603 out).
--
--   1. warehouses.type may be 'rejects'; every branch with a ready-goods
--      store gets a "Rejects" store.
--   2. sale_delivery_lines.broken / broken_cost — what broke and its cost.
--   3. product_stock_value() leaves the rejects store out: broken pieces are
--      a loss, not stock at cost (their cost is recorded on the line).
--   5. a back-dated delivery (sale day .. today, 136) is no longer refused for branch managers.
--   4. record_sale_delivery(): lines take "broken"; a 'waste' movement
--      (Broken while loading · Sale #n · DN-n) moves them out of the store
--      into the rejects store on the same day.
-- ============================================================

ALTER TABLE public.warehouses DROP CONSTRAINT warehouses_type_check;
ALTER TABLE public.warehouses ADD CONSTRAINT warehouses_type_check
  CHECK (type IN ('raw_materials', 'finished_goods', 'wip', 'general', 'rejects'));

INSERT INTO public.warehouses (organization_id, branch_id, name, type, receives_production)
SELECT DISTINCT w.organization_id, w.branch_id, 'Rejects', 'rejects', false
  FROM public.warehouses w
 WHERE w.type = 'finished_goods' AND w.status = 'active'
   AND NOT EXISTS (SELECT 1 FROM public.warehouses x WHERE x.branch_id = w.branch_id AND x.type = 'rejects');

ALTER TABLE public.sale_delivery_lines
  ADD COLUMN broken numeric NOT NULL DEFAULT 0 CHECK (broken >= 0),
  ADD COLUMN broken_cost numeric;
COMMENT ON COLUMN public.sale_delivery_lines.broken IS 'Pieces found broken while loading this line — moved into the rejects store (139).';

CREATE OR REPLACE FUNCTION public.product_stock_value(p_branch_id uuid, p_product_id uuid, p_color_id uuid, p_as_of date DEFAULT NULL)
RETURNS TABLE (on_hand numeric, value numeric, unit_cost numeric, uncosted_quantity numeric, estimated_quantity numeric, estimated_value numeric,
               last_cost numeric, price numeric, layers jsonb)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r      record;
  lq     numeric[] := '{}';   -- layer quantities (stock unit)
  lc     numeric[] := '{}';   -- cost per stock unit (NULL = unknown)
  ld     date[]    := '{}';
  lb     uuid[]    := '{}';   -- the batch a layer came from
  le     boolean[] := '{}';   -- estimated at the price without VAT (no production cost)
  ls     text[]    := '{}';   -- curing (cast, not released yet) or released
  n      int := 0;
  need   numeric;
  take   numeric;
  cost   numeric;
  est    boolean;
  latest numeric;
  est_price numeric;
  o      public.production_batch_outputs;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id AND organization_id = public.get_my_org_id()) THEN RETURN; END IF;
  est_price := (SELECT x.price FROM public.product_price_ex_vat(p_branch_id, p_product_id, p_color_id) x);
  FOR r IN
    SELECT t.quantity AS q, t.transaction_type AS tt, t.unit_cost, t.entered_quantity, t.transaction_date,
           -- a reversal belongs to the batch of what it reverses (a voided batch)
           coalesce(m.production_batch_id, (SELECT r0.production_batch_id FROM public.inventory_movements r0 WHERE r0.id = m.reverses_movement_id)) AS batch
      FROM public.inventory_transactions t
      JOIN public.warehouses w ON w.id = t.warehouse_id
      JOIN public.inventory_movements m ON m.id = t.movement_id
     WHERE t.product_id = p_product_id AND t.color_id IS NOT DISTINCT FROM p_color_id AND w.branch_id = p_branch_id AND w.type <> 'rejects'
       AND (p_as_of IS NULL OR t.transaction_date <= p_as_of)
       -- a move between this branch's own stores changes nothing here
       AND NOT (t.transaction_type IN ('transfer_out', 'transfer_in') AND NOT EXISTS (
             SELECT 1 FROM public.inventory_transactions t2 JOIN public.warehouses w2 ON w2.id = t2.warehouse_id
              WHERE t2.movement_id = t.movement_id AND t2.id <> t.id AND w2.branch_id <> p_branch_id))
     ORDER BY t.transaction_date, t.seq
  LOOP
    IF r.q > 0 THEN
      est := false; cost := NULL;
      IF r.batch IS NOT NULL AND r.tt IN ('production_output', 'curing_in') THEN
        -- a batch's pieces carry the batch's cost (cast, or passed at release)
        SELECT * INTO o FROM public.production_batch_outputs x WHERE x.batch_id = r.batch AND x.product_id = p_product_id
           AND x.color_id IS NOT DISTINCT FROM p_color_id LIMIT 1;
        cost := public.output_cost_per_unit(o);
      ELSIF r.tt = 'opening_balance' AND r.unit_cost IS NOT NULL THEN
        cost := r.unit_cost * r.entered_quantity / r.q;
      END IF;
      -- no production cost: the latest production cost for stock coming back (a count up …); else the price without VAT, estimated
      IF cost IS NULL AND r.tt <> 'opening_balance' THEN cost := latest; END IF;
      IF cost IS NULL AND est_price IS NOT NULL THEN cost := est_price; est := true; END IF;
      n := n + 1;
      lq[n] := r.q; lc[n] := cost; ld[n] := r.transaction_date; lb[n] := CASE WHEN r.tt IN ('production_output', 'curing_in') THEN r.batch END; le[n] := est;
      ls[n] := CASE r.tt WHEN 'production_output' THEN 'curing' WHEN 'curing_in' THEN 'released' END;
      IF cost IS NOT NULL AND NOT est THEN latest := cost; END IF;
    ELSIF r.q < 0 THEN
      need := -r.q;
      -- a batch's own pieces leave first (released from curing, rejects, a voided batch); then the oldest
      IF r.batch IS NOT NULL THEN
        FOR i IN 1 .. n LOOP
          EXIT WHEN need <= 0;
          CONTINUE WHEN lb[i] IS DISTINCT FROM r.batch OR lq[i] <= 0;
          take := least(lq[i], need); lq[i] := lq[i] - take; need := need - take;
        END LOOP;
      END IF;
      FOR i IN 1 .. n LOOP
        EXIT WHEN need <= 0;
        CONTINUE WHEN lq[i] <= 0;
        take := least(lq[i], need); lq[i] := lq[i] - take; need := need - take;
      END LOOP;
      IF need > 0 THEN            -- more out than in: carried as negative, uncosted
        n := n + 1; lq[n] := -need; lc[n] := NULL; ld[n] := r.transaction_date; lb[n] := NULL; le[n] := false; ls[n] := NULL;
      END IF;
    END IF;
  END LOOP;

  on_hand := 0; value := 0; uncosted_quantity := 0; estimated_quantity := 0; estimated_value := 0; layers := '[]'::jsonb;
  FOR i IN 1 .. n LOOP
    CONTINUE WHEN lq[i] = 0;
    on_hand := on_hand + lq[i];
    IF lc[i] IS NULL THEN uncosted_quantity := uncosted_quantity + lq[i];
    ELSE value := value + lq[i] * lc[i]; END IF;
    IF le[i] THEN estimated_quantity := estimated_quantity + lq[i]; estimated_value := estimated_value + lq[i] * lc[i]; END IF;
    layers := layers || jsonb_build_object('date', ld[i], 'quantity', lq[i], 'cost', lc[i], 'batch', lb[i], 'stage', ls[i], 'estimated', le[i]);
  END LOOP;
  unit_cost := CASE WHEN on_hand - uncosted_quantity > 0 THEN value / (on_hand - uncosted_quantity) END;
  last_cost := latest;
  price := est_price;
  IF on_hand - uncosted_quantity <= 0 THEN value := NULL; END IF;
  RETURN NEXT;
END;
$$;


CREATE OR REPLACE FUNCTION public.record_sale_delivery(p_sale uuid, p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s       public.sales;
  wh      public.warehouses;
  l       jsonb;
  sl      public.sale_lines;
  prod    public.products;
  qty     numeric;
  done    numeric;
  val     numeric := 0;
  lv      numeric;
  paid    numeric;
  given   numeric;
  mv      uuid;
  did     uuid;
  br      numeric;           -- broken while loading (139)
  rj      public.warehouses;
  mvb     uuid;
  bb      record;
  bcost   numeric;
  b0      record;
  b1      record;
  today   date;
  v_on    date;
BEGIN
  SELECT * INTO s FROM public.sales WHERE id = p_sale AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
  IF s.stage NOT IN ('order', 'invoice') THEN RAISE EXCEPTION 'Goods leave on an order or an invoice' USING ERRCODE = '23514'; END IF;
  today := public.org_today(s.organization_id);
  v_on := coalesce(nullif(p->>'delivered_on', '')::date, today);   -- 136
  IF v_on > today THEN RAISE EXCEPTION 'The goods can''t leave on a future day' USING ERRCODE = '23514'; END IF;
  IF v_on < s.sale_date THEN RAISE EXCEPTION 'The goods can''t leave before the sale (%)', to_char(s.sale_date, 'DD Mon YYYY') USING ERRCODE = '23514'; END IF;
  -- a day between the sale and today is the real day the goods left — not a correction: allowed for whoever records
  -- the delivery, not only stock admins (139; the back-dating guard of 060 would otherwise refuse a branch manager)
  IF v_on < today THEN PERFORM set_config('mois.approved_change', 'on', true); END IF;
  IF nullif(p->>'warehouse_id', '') IS NOT NULL THEN
    SELECT * INTO wh FROM public.warehouses WHERE id = (p->>'warehouse_id')::uuid AND branch_id = s.branch_id AND type = 'finished_goods' AND status = 'active';
  ELSE
    SELECT * INTO wh FROM public.warehouses WHERE branch_id = s.branch_id AND type = 'finished_goods' AND status = 'active'
     ORDER BY (id = s.warehouse_id) IS TRUE DESC, receives_production DESC, name LIMIT 1;   -- the sale's store, else where production goes (135)
  END IF;
  IF wh.id IS NULL THEN RAISE EXCEPTION 'This branch has no finished-goods store' USING ERRCODE = '23514'; END IF;
  IF NOT (public.has_permission_at('sales.create', s.branch_id, NULL) OR public.has_permission_at('inventory.issue', s.branch_id, wh.id)) THEN
    RAISE EXCEPTION 'You can''t record deliveries at this branch' USING ERRCODE = '42501';
  END IF;
  IF coalesce(p->>'kind', '') NOT IN ('delivery', 'collection') THEN RAISE EXCEPTION 'Say whether it is delivered or collected' USING ERRCODE = '23514'; END IF;
  IF jsonb_array_length(coalesce(p->'lines', '[]'::jsonb)) = 0 THEN RAISE EXCEPTION 'Enter what leaves' USING ERRCODE = '23514'; END IF;

  -- the value of this delivery at the sale's prices with VAT; never more than ordered
  FOR l IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    SELECT * INTO sl FROM public.sale_lines WHERE id = nullif(l->>'sale_line_id', '')::uuid AND sale_id = s.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'A line is not on this sale' USING ERRCODE = '23514'; END IF;
    qty := nullif(l->>'quantity', '')::numeric;
    br := coalesce(nullif(l->>'broken', '')::numeric, 0);
    IF br < 0 THEN RAISE EXCEPTION 'Broken pieces are zero or more' USING ERRCODE = '23514'; END IF;
    IF br > 0 AND (qty IS NULL OR qty = 0) THEN RAISE EXCEPTION 'Enter what leaves with the broken pieces' USING ERRCODE = '23514'; END IF;
    CONTINUE WHEN qty IS NULL OR qty = 0;
    IF sl.product_id IS NULL THEN RAISE EXCEPTION '% is an other item — it isn''t delivered from stock', sl.item_name USING ERRCODE = '23514'; END IF;
    IF qty < 0 THEN RAISE EXCEPTION 'Quantities are zero or more' USING ERRCODE = '23514'; END IF;
    SELECT coalesce(sum(dl.quantity), 0) INTO done FROM public.sale_delivery_lines dl WHERE dl.sale_line_id = sl.id;
    IF qty > sl.quantity - done + 1e-9 THEN
      RAISE EXCEPTION '%: only % left to deliver', (SELECT canonical_name FROM public.products WHERE id = sl.product_id), trim_scale(sl.quantity - done) USING ERRCODE = '23514';
    END IF;
    val := val + round(sl.total * qty / sl.quantity, 2);
  END LOOP;
  IF val = 0 THEN RAISE EXCEPTION 'Enter what leaves' USING ERRCODE = '23514'; END IF;
  -- a sale carrying VAT leaves only with its EFD receipt (069): given here, or already on the sale
  IF nullif(btrim(p->>'efd_receipt_no'), '') IS NOT NULL THEN
    UPDATE public.sales SET efd_receipt_no = btrim(p->>'efd_receipt_no') WHERE id = s.id;
    s.efd_receipt_no := btrim(p->>'efd_receipt_no');
  END IF;
  IF s.vat > 0 AND s.efd_receipt_no IS NULL THEN
    RAISE EXCEPTION 'This sale carries VAT — enter the EFD receipt number before the goods leave' USING ERRCODE = '23514';
  END IF;
  -- up to what has been paid
  SELECT coalesce(sum(amount), 0) INTO paid FROM public.sale_payments WHERE sale_id = s.id;
  SELECT coalesce(sum(value), 0) INTO given FROM public.sale_deliveries WHERE sale_id = s.id;
  -- other items (104) were handed over with the sale: they count as given
  given := given + coalesce((SELECT sum(total) FROM public.sale_lines WHERE sale_id = s.id AND product_id IS NULL), 0);
  IF given + val > paid + 0.01 THEN
    RAISE EXCEPTION 'Goods worth % can leave — paid %, already delivered %. Record a payment first.',
      to_char(greatest(paid - given, 0), 'FM999G999G990D00'), to_char(paid, 'FM999G999G990D00'), to_char(given, 'FM999G999G990D00') USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, reference, created_by, sale_id)
  VALUES (s.organization_id, 'sale_delivery', s.branch_id, wh.id, v_on,
          CASE p->>'kind' WHEN 'collection' THEN 'Collected by the customer' ELSE 'Delivered to the customer' END,
          'Sale #' || s.sale_no, auth.uid(), s.id)
  RETURNING id INTO mv;
  INSERT INTO public.sale_deliveries (organization_id, sale_id, delivery_no, kind, delivered_on, warehouse_id, movement_id, received_by, vehicle, notes, value, created_by)
  VALUES (s.organization_id, s.id, coalesce((SELECT max(delivery_no) FROM public.sale_deliveries WHERE organization_id = s.organization_id), 0) + 1,
          p->>'kind', v_on, wh.id, mv, nullif(btrim(p->>'received_by'), ''), nullif(btrim(p->>'vehicle'), ''), nullif(btrim(p->>'notes'), ''), val, auth.uid())
  RETURNING id INTO did;

  -- line by line: out of stock, its cost first in first out (the value of the stock before less after)
  FOR l IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    qty := nullif(l->>'quantity', '')::numeric;
    CONTINUE WHEN qty IS NULL OR qty = 0;
    SELECT * INTO sl FROM public.sale_lines WHERE id = (l->>'sale_line_id')::uuid;
    SELECT * INTO prod FROM public.products WHERE id = sl.product_id;
    SELECT * INTO b0 FROM public.product_stock_value(s.branch_id, sl.product_id, sl.color_id);
    PERFORM public.production_ledger_line(mv, 'sale_delivery', wh, NULL, sl.product_id, sl.color_id, -qty, sl.unit_id, qty, sl.unit_id, v_on, prod.canonical_name);
    SELECT * INTO b1 FROM public.product_stock_value(s.branch_id, sl.product_id, sl.color_id);
    -- broken while loading (139): out of this store into the branch's rejects store, for this sale; their cost is a loss
    br := coalesce(nullif(l->>'broken', '')::numeric, 0);
    bcost := NULL;
    IF br > 0 THEN
      IF rj.id IS NULL THEN
        SELECT * INTO rj FROM public.warehouses WHERE branch_id = s.branch_id AND type = 'rejects' AND status = 'active' ORDER BY name LIMIT 1;
        IF rj.id IS NULL THEN RAISE EXCEPTION 'This branch has no rejects store' USING ERRCODE = '23514'; END IF;
        INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, reference, created_by, sale_id)
        VALUES (s.organization_id, 'waste', s.branch_id, wh.id, v_on, 'Broken while loading',
                'Sale #' || s.sale_no || ' · DN-' || (SELECT delivery_no FROM public.sale_deliveries WHERE id = did), auth.uid(), s.id)
        RETURNING id INTO mvb;
      END IF;
      PERFORM public.production_ledger_line(mvb, 'waste', wh, NULL, sl.product_id, sl.color_id, -br, sl.unit_id, br, sl.unit_id, v_on, prod.canonical_name);
      PERFORM public.production_ledger_line(mvb, 'waste', rj, NULL, sl.product_id, sl.color_id, br, sl.unit_id, br, sl.unit_id, v_on, prod.canonical_name);
      SELECT * INTO bb FROM public.product_stock_value(s.branch_id, sl.product_id, sl.color_id);
      bcost := round(coalesce(b1.value, 0) - coalesce(bb.value, 0), 2);
    END IF;
    lv := round(sl.total * qty / sl.quantity, 2);
    INSERT INTO public.sale_delivery_lines (organization_id, delivery_id, sale_line_id, quantity, value, cost, estimated_cost, broken, broken_cost)
    VALUES (s.organization_id, did, sl.id, qty, lv,
            CASE WHEN b0.value IS NOT NULL THEN round(coalesce(b0.value, 0) - coalesce(b1.value, 0), 2) END,
            round(coalesce(b0.estimated_value, 0) - coalesce(b1.estimated_value, 0), 2), br, bcost);
  END LOOP;
  UPDATE public.sale_deliveries d SET cost = x.c, estimated_cost = x.e
    FROM (SELECT sum(cost) AS c, sum(estimated_cost) AS e FROM public.sale_delivery_lines WHERE delivery_id = did) x
   WHERE d.id = did;
  PERFORM set_config('mois.approved_change', '', true);
  RETURN did;
END;
$$;

