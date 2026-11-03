-- ============================================================
-- 104 — Other items on a sale
-- ============================================================
-- SwahziTech, 2026-11-03, the user: some things are sold at a price agreed
-- with the customer, with no price list and no count — rejects ("vipande")
-- for a lump sum, for example — often paid together with a normal sale.
--   * A sale line can be an OTHER ITEM: product_id NULL, item_name and the
--     price typed by the user; quantity 1, no VAT (user: no VAT), no unit.
--   * It never comes out of stock and is never delivered: it counts as
--     handed over with the sale (deliveries up to the paid value count it).
--   * Branch Manager and Secretary add them (sales.other_items; the owner
--     too). Corrections can change an other item's name and price.
--   * Its cost is nothing (rejects never re-cost the products, 2026-10-25).
-- ============================================================

ALTER TABLE public.sale_lines ALTER COLUMN product_id DROP NOT NULL;
ALTER TABLE public.sale_lines ALTER COLUMN unit_id DROP NOT NULL;
ALTER TABLE public.sale_lines ADD COLUMN item_name text;
ALTER TABLE public.sale_lines ADD CONSTRAINT sale_lines_product_or_item
  CHECK ((product_id IS NOT NULL AND unit_id IS NOT NULL) OR (product_id IS NULL AND nullif(btrim(item_name), '') IS NOT NULL AND vat_rate = 0));
COMMENT ON COLUMN public.sale_lines.item_name IS 'An other item (104): what it is, as typed; product_id is then NULL, no stock, no VAT.';

INSERT INTO public.permissions (code, description, module) VALUES
  ('sales.other_items', 'Add other items to a sale: a name and a price typed in (rejects and the like), no stock', 'sales')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code = 'sales.other_items'
WHERE r.is_system_role AND r.name IN ('owner', 'branch_manager', 'secretary')
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.save_sale(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org    uuid := public.get_my_org_id();
  sid    uuid := nullif(p->>'id', '')::uuid;
  s      public.sales;
  br     uuid := nullif(p->>'branch_id', '')::uuid;
  cust   uuid := nullif(p->>'customer_id', '')::uuid;
  l      jsonb;
  prod   public.products;
  col    uuid;
  qty    numeric;
  lp     numeric;
  pr     numeric;
  rate   numeric;
  amt    numeric;
  vt     numeric;
  pi     numeric;   -- unit price with VAT, to the cent: what the customer sees
  lpi    numeric;   -- the list price as the customer sees it (with VAT, when it carries VAT)
  why    text;
  n      int := 0;
  nm     text;      -- an other item's name (104)
BEGIN
  IF org IS NULL OR auth.uid() IS NULL THEN RAISE EXCEPTION 'Not signed in to an organization' USING ERRCODE = '42501'; END IF;
  IF sid IS NOT NULL THEN
    SELECT * INTO s FROM public.sales WHERE id = sid AND organization_id = org FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
    IF s.stage NOT IN ('quotation', 'order') THEN RAISE EXCEPTION 'An invoiced or cancelled sale can''t be changed' USING ERRCODE = '23514'; END IF;
    br := s.branch_id;
  END IF;
  IF br IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = br AND organization_id = org) THEN
    RAISE EXCEPTION 'Choose the branch' USING ERRCODE = '23514';
  END IF;
  IF NOT public.has_permission_at('sales.create', br, NULL) THEN RAISE EXCEPTION 'You can''t record sales at this branch' USING ERRCODE = '42501'; END IF;
  IF cust IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.customers WHERE id = cust AND organization_id = org) THEN
    RAISE EXCEPTION 'Customer not found' USING ERRCODE = '23514';
  END IF;
  IF jsonb_array_length(coalesce(p->'lines', '[]'::jsonb)) = 0 THEN RAISE EXCEPTION 'Add at least one product' USING ERRCODE = '23514'; END IF;

  IF sid IS NULL THEN
    INSERT INTO public.sales (organization_id, branch_id, sale_no, stage, sale_date, created_by)
    VALUES (org, br, coalesce((SELECT max(sale_no) FROM public.sales WHERE organization_id = org), 0) + 1, 'quotation',
            coalesce(nullif(p->>'sale_date', '')::date, public.org_today(org)), auth.uid())
    RETURNING * INTO s;
    sid := s.id;
  ELSE
    DELETE FROM public.sale_lines WHERE sale_id = sid;
  END IF;
  UPDATE public.sales SET customer_id = cust,
         walk_in_name = CASE WHEN cust IS NULL THEN nullif(btrim(p->>'walk_in_name'), '') END,
         walk_in_phone = CASE WHEN cust IS NULL THEN nullif(btrim(p->>'walk_in_phone'), '') END,
         sale_date = coalesce(nullif(p->>'sale_date', '')::date, sale_date),
         valid_until = nullif(p->>'valid_until', '')::date,
         notes = nullif(btrim(p->>'notes'), '')
   WHERE id = sid;

  FOR l IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    n := n + 1;
    -- an other item (104): a name and a price typed in; no stock, no VAT, quantity 1
    IF nullif(l->>'product_id', '') IS NULL AND l ? 'item_name' THEN
      nm := nullif(btrim(l->>'item_name'), '');
      IF nm IS NULL THEN RAISE EXCEPTION 'Line %: write what the item is', n USING ERRCODE = '23514'; END IF;
      IF NOT public.has_permission_at('sales.other_items', br, NULL) THEN
        RAISE EXCEPTION 'Only the branch manager or the secretary can add an other item' USING ERRCODE = '42501';
      END IF;
      pr := round(nullif(l->>'price', '')::numeric, 2);
      IF pr IS NULL OR pr <= 0 THEN RAISE EXCEPTION '%: enter its price', nm USING ERRCODE = '23514'; END IF;
      INSERT INTO public.sale_lines (organization_id, sale_id, line_no, product_id, item_name, color_id, quantity, unit_id, list_price, price, vat_rate, amount, vat, total)
      VALUES (org, sid, n, NULL, nm, NULL, 1, NULL, pr, pr, 0, pr, 0, pr);
      CONTINUE;
    END IF;
    SELECT * INTO prod FROM public.products WHERE id = nullif(l->>'product_id', '')::uuid AND organization_id = org AND status = 'active';
    IF NOT FOUND THEN RAISE EXCEPTION 'Line %: choose the product', n USING ERRCODE = '23514'; END IF;
    col := nullif(l->>'color_id', '')::uuid;
    IF public.product_is_coloured(prod.id) AND (col IS NULL OR NOT public.product_color_ok(prod.id, col)) THEN
      RAISE EXCEPTION '%: choose one of its colours', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    IF NOT public.product_is_coloured(prod.id) THEN col := NULL; END IF;
    qty := nullif(l->>'quantity', '')::numeric;
    IF qty IS NULL OR qty <= 0 THEN RAISE EXCEPTION '%: enter the quantity', prod.canonical_name USING ERRCODE = '23514'; END IF;
    lp := (SELECT x.price FROM public.product_price_ex_vat(br, prod.id, col) x);
    rate := public.product_price_vat_rate(br, prod.id, col);
    lpi := round(lp * (1 + rate / 100), 2);
    why := nullif(btrim(l->>'discount_reason'), '');
    -- 'price' is the price charged a unit, as the customer pays it (069). The list price keeps its VAT;
    -- any other price is a discount — managers only, with a reason — and is sold WITHOUT VAT
    IF nullif(l->>'price', '') IS NULL OR (lpi IS NOT NULL AND round((l->>'price')::numeric, 2) = lpi) THEN
      pr := lp;
    ELSE
      pr := round((l->>'price')::numeric, 2);
      rate := 0;
    END IF;
    IF pr IS NULL THEN
      RAISE EXCEPTION '% has no price at this branch — set it in Pricing', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    IF rate = 0 AND (lp IS NULL OR pr <> lpi) THEN
      IF NOT public.has_permission_at('sales.discount', br, NULL) THEN
        RAISE EXCEPTION '%: only a manager can change the price (the list price is %)', prod.canonical_name,
          coalesce(to_char(lpi, 'FM999G999G990D00'), 'not set') USING ERRCODE = '42501';
      END IF;
      IF why IS NULL THEN RAISE EXCEPTION '%: give the reason for the price change', prod.canonical_name USING ERRCODE = '23514'; END IF;
    ELSE
      why := NULL;
    END IF;
    -- the customer's figures: the unit price with VAT to the cent (27,500 a m², not 27,499.99);
    -- the line total from it, and the VAT inside that total
    pi := round(pr * (1 + rate / 100), 2);
    vt := round(qty * pi, 2);                    -- line total with VAT
    amt := round(vt / (1 + rate / 100), 2);      -- without VAT
    INSERT INTO public.sale_lines (organization_id, sale_id, line_no, product_id, color_id, quantity, unit_id, list_price, price, vat_rate,
                                   discount_reason, discount_by, amount, vat, total)
    VALUES (org, sid, n, prod.id, col, qty, prod.unit_id, round(coalesce(lp, pr), 4), round(pr, 4), rate,
            why, CASE WHEN why IS NOT NULL THEN auth.uid() END, amt, vt - amt, vt);
  END LOOP;
  UPDATE public.sales SET subtotal = (SELECT sum(amount) FROM public.sale_lines WHERE sale_id = sid),
         vat = (SELECT sum(vat) FROM public.sale_lines WHERE sale_id = sid),
         total = (SELECT sum(total) FROM public.sale_lines WHERE sale_id = sid)
   WHERE id = sid;
  IF (SELECT total FROM public.sales WHERE id = sid) < (SELECT coalesce(sum(amount), 0) FROM public.sale_payments WHERE sale_id = sid) THEN
    RAISE EXCEPTION 'The new total is less than what has already been paid' USING ERRCODE = '23514';
  END IF;
  RETURN sid;
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
  b0      record;
  b1      record;
  today   date;
BEGIN
  SELECT * INTO s FROM public.sales WHERE id = p_sale AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
  IF s.stage NOT IN ('order', 'invoice') THEN RAISE EXCEPTION 'Goods leave on an order or an invoice' USING ERRCODE = '23514'; END IF;
  today := public.org_today(s.organization_id);
  IF nullif(p->>'warehouse_id', '') IS NOT NULL THEN
    SELECT * INTO wh FROM public.warehouses WHERE id = (p->>'warehouse_id')::uuid AND branch_id = s.branch_id AND type = 'finished_goods' AND status = 'active';
  ELSE
    SELECT * INTO wh FROM public.warehouses WHERE branch_id = s.branch_id AND type = 'finished_goods' AND status = 'active' ORDER BY name LIMIT 1;
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
  VALUES (s.organization_id, 'sale_delivery', s.branch_id, wh.id, today,
          CASE p->>'kind' WHEN 'collection' THEN 'Collected by the customer' ELSE 'Delivered to the customer' END,
          'Sale #' || s.sale_no, auth.uid(), s.id)
  RETURNING id INTO mv;
  INSERT INTO public.sale_deliveries (organization_id, sale_id, delivery_no, kind, delivered_on, warehouse_id, movement_id, received_by, vehicle, notes, value, created_by)
  VALUES (s.organization_id, s.id, coalesce((SELECT max(delivery_no) FROM public.sale_deliveries WHERE organization_id = s.organization_id), 0) + 1,
          p->>'kind', today, wh.id, mv, nullif(btrim(p->>'received_by'), ''), nullif(btrim(p->>'vehicle'), ''), nullif(btrim(p->>'notes'), ''), val, auth.uid())
  RETURNING id INTO did;

  -- line by line: out of stock, its cost first in first out (the value of the stock before less after)
  FOR l IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    qty := nullif(l->>'quantity', '')::numeric;
    CONTINUE WHEN qty IS NULL OR qty = 0;
    SELECT * INTO sl FROM public.sale_lines WHERE id = (l->>'sale_line_id')::uuid;
    SELECT * INTO prod FROM public.products WHERE id = sl.product_id;
    SELECT * INTO b0 FROM public.product_stock_value(s.branch_id, sl.product_id, sl.color_id);
    PERFORM public.production_ledger_line(mv, 'sale_delivery', wh, NULL, sl.product_id, sl.color_id, -qty, sl.unit_id, qty, sl.unit_id, today, prod.canonical_name);
    SELECT * INTO b1 FROM public.product_stock_value(s.branch_id, sl.product_id, sl.color_id);
    lv := round(sl.total * qty / sl.quantity, 2);
    INSERT INTO public.sale_delivery_lines (organization_id, delivery_id, sale_line_id, quantity, value, cost, estimated_cost)
    VALUES (s.organization_id, did, sl.id, qty, lv,
            CASE WHEN b0.value IS NOT NULL THEN round(coalesce(b0.value, 0) - coalesce(b1.value, 0), 2) END,
            round(coalesce(b0.estimated_value, 0) - coalesce(b1.estimated_value, 0), 2));
  END LOOP;
  UPDATE public.sale_deliveries d SET cost = x.c, estimated_cost = x.e
    FROM (SELECT sum(cost) AS c, sum(estimated_cost) AS e FROM public.sale_delivery_lines WHERE delivery_id = did) x
   WHERE d.id = did;
  RETURN did;
END;
$$;

CREATE OR REPLACE FUNCTION public.apply_sale_correction(p_sale uuid, ch jsonb, p_reason text, p_requested_by uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s      public.sales;
  snap   jsonb;
  l      jsonb;
  old    public.sale_lines;
  prod   public.products;
  col    uuid;
  qty    numeric;
  done   numeric;
  lp     numeric;
  pr     numeric;
  rate   numeric;
  pi     numeric;
  lpi    numeric;
  same   boolean;
  tot    numeric;
  amt    numeric;
  pm     jsonb;
  pay    public.sale_payments;
  acc    public.payment_accounts;
  n      int;
  paid   numeric;
  nm     text;      -- an other item's name (104)
BEGIN
  IF nullif(btrim(p_reason), '') IS NULL THEN RAISE EXCEPTION 'Give the reason for the correction' USING ERRCODE = '23514'; END IF;
  SELECT * INTO s FROM public.sales WHERE id = p_sale FOR UPDATE;
  IF NOT FOUND OR s.stage = 'cancelled' THEN RAISE EXCEPTION 'Sale not found or cancelled' USING ERRCODE = '23514'; END IF;
  snap := jsonb_build_object('sale', to_jsonb(s),
    'lines', (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.line_no), '[]') FROM public.sale_lines x WHERE x.sale_id = s.id),
    'payments', (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.paid_on), '[]') FROM public.sale_payments x WHERE x.sale_id = s.id));

  -- the sale itself
  IF ch ? 'customer_id' AND nullif(ch->>'customer_id', '') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.customers WHERE id = (ch->>'customer_id')::uuid AND organization_id = s.organization_id) THEN
    RAISE EXCEPTION 'Customer not found' USING ERRCODE = '23514';
  END IF;
  IF ch ? 'sale_date' AND (ch->>'sale_date')::date > public.org_today(s.organization_id) THEN
    RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514';
  END IF;
  UPDATE public.sales SET
         sale_date      = CASE WHEN ch ? 'sale_date' THEN (ch->>'sale_date')::date ELSE sale_date END,
         invoiced_on    = CASE WHEN ch ? 'sale_date' AND stage = 'invoice' AND invoiced_on = sale_date THEN (ch->>'sale_date')::date ELSE invoiced_on END,
         customer_id    = CASE WHEN ch ? 'customer_id' OR ch ? 'walk_in_name' THEN nullif(ch->>'customer_id', '')::uuid ELSE customer_id END,
         walk_in_name   = CASE WHEN ch ? 'customer_id' OR ch ? 'walk_in_name' THEN CASE WHEN nullif(ch->>'customer_id', '') IS NULL THEN nullif(btrim(ch->>'walk_in_name'), '') END ELSE walk_in_name END,
         walk_in_phone  = CASE WHEN ch ? 'customer_id' OR ch ? 'walk_in_name' THEN CASE WHEN nullif(ch->>'customer_id', '') IS NULL THEN nullif(btrim(ch->>'walk_in_phone'), '') END ELSE walk_in_phone END,
         site           = CASE WHEN ch ? 'site' THEN nullif(btrim(ch->>'site'), '') ELSE site END,
         efd_receipt_no = CASE WHEN ch ? 'efd_receipt_no' THEN nullif(btrim(ch->>'efd_receipt_no'), '') ELSE efd_receipt_no END,
         notes          = CASE WHEN ch ? 'notes' THEN nullif(btrim(ch->>'notes'), '') ELSE notes END
   WHERE id = s.id;

  -- lines: the database prices them as save_sale does; delivered quantities stand
  FOR l IN SELECT * FROM jsonb_array_elements(coalesce(ch->'lines', '[]'::jsonb)) LOOP
    old := NULL;
    IF nullif(l->>'id', '') IS NOT NULL THEN
      SELECT * INTO old FROM public.sale_lines WHERE id = (l->>'id')::uuid AND sale_id = s.id;
      IF NOT FOUND THEN RAISE EXCEPTION 'A line is not on this sale' USING ERRCODE = '23514'; END IF;
    END IF;
    done := CASE WHEN old.id IS NULL THEN 0 ELSE coalesce((SELECT sum(quantity) FROM public.sale_delivery_lines WHERE sale_line_id = old.id), 0) END;
    IF coalesce((l->>'remove')::boolean, false) THEN
      IF old.id IS NULL THEN CONTINUE; END IF;
      IF done > 0 THEN RAISE EXCEPTION 'A line with goods delivered can''t be removed' USING ERRCODE = '23514'; END IF;
      DELETE FROM public.sale_lines WHERE id = old.id;
      CONTINUE;
    END IF;
    -- an other item (104): name and price; no stock, no VAT, quantity 1
    IF nullif(l->>'product_id', '') IS NULL AND (l ? 'item_name' OR (old.id IS NOT NULL AND old.product_id IS NULL)) THEN
      nm := coalesce(nullif(btrim(l->>'item_name'), ''), old.item_name);
      IF nm IS NULL THEN RAISE EXCEPTION 'Write what the item is' USING ERRCODE = '23514'; END IF;
      pr := round(coalesce(nullif(l->>'price', '')::numeric, old.price), 2);
      IF pr IS NULL OR pr <= 0 THEN RAISE EXCEPTION '%: enter its price', nm USING ERRCODE = '23514'; END IF;
      IF old.id IS NOT NULL THEN
        UPDATE public.sale_lines SET item_name = nm, list_price = pr, price = pr, amount = pr, vat = 0, total = pr WHERE id = old.id;
      ELSE
        SELECT coalesce(max(line_no), 0) + 1 INTO n FROM public.sale_lines WHERE sale_id = s.id;
        INSERT INTO public.sale_lines (organization_id, sale_id, line_no, product_id, item_name, quantity, unit_id, list_price, price, vat_rate, amount, vat, total)
        VALUES (s.organization_id, s.id, n, NULL, nm, 1, NULL, pr, pr, 0, pr, 0, pr);
      END IF;
      CONTINUE;
    END IF;
    SELECT * INTO prod FROM public.products WHERE id = nullif(l->>'product_id', '')::uuid AND organization_id = s.organization_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Choose the product' USING ERRCODE = '23514'; END IF;
    col := CASE WHEN public.product_is_coloured(prod.id) THEN nullif(l->>'color_id', '')::uuid END;
    IF public.product_is_coloured(prod.id) AND (col IS NULL OR NOT public.product_color_ok(prod.id, col)) THEN
      RAISE EXCEPTION '%: choose one of its colours', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    IF done > 0 AND (prod.id <> old.product_id OR col IS DISTINCT FROM old.color_id) THEN
      RAISE EXCEPTION '%: goods have been delivered on this line — its product stays', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    qty := nullif(l->>'quantity', '')::numeric;
    IF qty IS NULL OR qty <= 0 THEN RAISE EXCEPTION '%: enter the quantity', prod.canonical_name USING ERRCODE = '23514'; END IF;
    IF qty + 1e-9 < done THEN RAISE EXCEPTION '%: % already delivered — the quantity can''t go below it', prod.canonical_name, trim_scale(done) USING ERRCODE = '23514'; END IF;
    lp := (SELECT x.price FROM public.product_price_ex_vat(s.branch_id, prod.id, col) x);
    same := old.id IS NOT NULL AND old.product_id = prod.id AND old.color_id IS NOT DISTINCT FROM col;
    -- 'price' is the price charged a unit, as the customer pays it (069): the list price keeps its VAT,
    -- the line's own price stays as it was, any other price is a discount sold without VAT
    rate := public.product_price_vat_rate(s.branch_id, prod.id, col);
    lpi := round(lp * (1 + rate / 100), 2);
    IF nullif(l->>'price', '') IS NULL THEN
      IF same THEN pr := old.price; rate := old.vat_rate; ELSE pr := lp; END IF;
    ELSIF same AND round((l->>'price')::numeric, 2) = round(old.price * (1 + old.vat_rate / 100), 2) THEN
      pr := old.price; rate := old.vat_rate;
    ELSIF lpi IS NOT NULL AND round((l->>'price')::numeric, 2) = lpi THEN
      pr := lp;
    ELSE
      pr := round((l->>'price')::numeric, 2); rate := 0;
    END IF;
    IF pr IS NULL THEN RAISE EXCEPTION '% has no price at this branch — give one', prod.canonical_name USING ERRCODE = '23514'; END IF;
    pi := round(pr * (1 + rate / 100), 2);
    tot := round(qty * pi, 2);
    amt := round(tot / (1 + rate / 100), 2);
    IF old.id IS NOT NULL THEN
      UPDATE public.sale_lines SET product_id = prod.id, color_id = col, quantity = qty, unit_id = prod.unit_id,
             list_price = round(coalesce(lp, pr), 4), price = round(pr, 4), vat_rate = rate,
             discount_reason = CASE WHEN lp IS NULL OR round(pr, 4) <> round(lp, 4) THEN coalesce(old.discount_reason, btrim(p_reason)) END,
             discount_by = CASE WHEN lp IS NULL OR round(pr, 4) <> round(lp, 4) THEN coalesce(old.discount_by, auth.uid()) END,
             amount = amt, vat = tot - amt, total = tot
       WHERE id = old.id;
    ELSE
      SELECT coalesce(max(line_no), 0) + 1 INTO n FROM public.sale_lines WHERE sale_id = s.id;
      INSERT INTO public.sale_lines (organization_id, sale_id, line_no, product_id, color_id, quantity, unit_id, list_price, price, vat_rate,
                                     discount_reason, discount_by, amount, vat, total)
      VALUES (s.organization_id, s.id, n, prod.id, col, qty, prod.unit_id, round(coalesce(lp, pr), 4), round(pr, 4), rate,
              CASE WHEN lp IS NULL OR round(pr, 4) <> round(lp, 4) THEN btrim(p_reason) END,
              CASE WHEN lp IS NULL OR round(pr, 4) <> round(lp, 4) THEN auth.uid() END, amt, tot - amt, tot);
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM public.sale_lines WHERE sale_id = s.id) THEN RAISE EXCEPTION 'A sale keeps at least one line' USING ERRCODE = '23514'; END IF;

  -- payments
  FOR pm IN SELECT * FROM jsonb_array_elements(coalesce(ch->'payments', '[]'::jsonb)) LOOP
    SELECT * INTO pay FROM public.sale_payments WHERE id = nullif(pm->>'id', '')::uuid AND sale_id = s.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'A payment is not on this sale' USING ERRCODE = '23514'; END IF;
    IF coalesce((pm->>'remove')::boolean, false) THEN
      PERFORM set_config('mois.sale_correction', 'on', true);
      DELETE FROM public.sale_payments WHERE id = pay.id;
      PERFORM set_config('mois.sale_correction', '', true);
      CONTINUE;
    END IF;
    acc := NULL;
    IF nullif(pm->>'account_id', '') IS NOT NULL THEN
      SELECT * INTO acc FROM public.payment_accounts WHERE id = (pm->>'account_id')::uuid AND branch_id = s.branch_id;
      IF NOT FOUND THEN RAISE EXCEPTION 'Account not found at this branch' USING ERRCODE = '23514'; END IF;
    END IF;
    IF pm ? 'amount' AND coalesce(nullif(pm->>'amount', '')::numeric, 0) <= 0 THEN RAISE EXCEPTION 'A payment is more than zero — remove it instead' USING ERRCODE = '23514'; END IF;
    IF pm ? 'paid_on' AND (pm->>'paid_on')::date > public.org_today(s.organization_id) THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;
    UPDATE public.sale_payments SET
           amount     = CASE WHEN pm ? 'amount' THEN round((pm->>'amount')::numeric, 2) ELSE amount END,
           account_id = CASE WHEN acc.id IS NOT NULL THEN acc.id ELSE account_id END,
           method     = CASE WHEN acc.id IS NOT NULL THEN acc.kind ELSE method END,
           paid_on    = CASE WHEN pm ? 'paid_on' THEN (pm->>'paid_on')::date ELSE paid_on END,
           receipt_no = CASE WHEN pm ? 'receipt_no' THEN nullif(btrim(pm->>'receipt_no'), '') ELSE receipt_no END
     WHERE id = pay.id;
  END LOOP;

  UPDATE public.sales SET subtotal = (SELECT sum(amount) FROM public.sale_lines WHERE sale_id = s.id),
         vat = (SELECT sum(vat) FROM public.sale_lines WHERE sale_id = s.id),
         total = (SELECT sum(total) FROM public.sale_lines WHERE sale_id = s.id)
   WHERE id = s.id;
  SELECT coalesce(sum(amount), 0) INTO paid FROM public.sale_payments WHERE sale_id = s.id;
  IF (SELECT total FROM public.sales WHERE id = s.id) + 0.004 < paid THEN
    RAISE EXCEPTION 'The total would be less than what has been paid (%) — correct or remove a payment too', to_char(paid, 'FM999G999G990D00') USING ERRCODE = '23514';
  END IF;
  INSERT INTO public.sale_corrections (organization_id, sale_id, reason, changes, before, requested_by, applied_by)
  VALUES (s.organization_id, s.id, btrim(p_reason), ch, snap, coalesce(p_requested_by, auth.uid()), auth.uid());
  RETURN jsonb_build_object('sale_id', s.id);
END;
$$;
