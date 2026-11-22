-- ============================================================
-- 141 — Customer orders: note → quotation → order → invoice, joined to production
--
-- SwahziTech, 2026-11-22 (the user: "use what we already have — planner,
-- production, sale, order, invoice — and make it smooth"). Most sales stay
-- direct; this is the longer path:
--   1. sales.stage 'note' — a customer's wish written down, nothing confirmed:
--      holds nothing, not in the sales book. save_sale(p.as_note) makes one;
--      set_sale_stage moves note → quotation → order → invoice.
--   2. sales.waiting_for — Stock · Cash · Transport · Customer (any of them).
--   3. production_orders.sale_id, production_order_lines.sale_line_id — a
--      production order made for a sale; make_production_for_sale() creates it
--      from the sale's lines (the Planner's own save_production_order()).
--   4. sales_availability(): an order holds what is in the store now — the part
--      still to be made by its open production order is not held (pieces made
--      join the general stock and may be sold if time allows).
-- ============================================================

ALTER TABLE public.sales DROP CONSTRAINT sales_stage_check;
ALTER TABLE public.sales ADD CONSTRAINT sales_stage_check CHECK (stage IN ('note', 'quotation', 'order', 'invoice', 'cancelled'));

ALTER TABLE public.sales ADD COLUMN waiting_for text[] NOT NULL DEFAULT '{}'
  CHECK (waiting_for <@ ARRAY['stock', 'cash', 'transport', 'customer']::text[]);
COMMENT ON COLUMN public.sales.waiting_for IS 'What the order waits for: stock, cash, transport, customer (141).';

ALTER TABLE public.production_orders ADD COLUMN sale_id uuid REFERENCES public.sales(id) ON DELETE SET NULL;
ALTER TABLE public.production_order_lines ADD COLUMN sale_line_id uuid REFERENCES public.sale_lines(id) ON DELETE SET NULL;
CREATE INDEX idx_production_orders_sale ON public.production_orders(sale_id) WHERE sale_id IS NOT NULL;
CREATE INDEX idx_production_order_lines_sale_line ON public.production_order_lines(sale_line_id) WHERE sale_line_id IS NOT NULL;

-- what an order waits for
CREATE FUNCTION public.set_sale_waiting(p_sale uuid, p_for text[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.sales;
BEGIN
  SELECT * INTO s FROM public.sales WHERE id = p_sale AND organization_id = public.get_my_org_id();
  IF NOT FOUND OR s.stage = 'cancelled' THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('sales.create', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change sales at this branch' USING ERRCODE = '42501'; END IF;
  UPDATE public.sales SET waiting_for = (SELECT coalesce(array_agg(DISTINCT x ORDER BY x), '{}') FROM unnest(coalesce(p_for, '{}')) x) WHERE id = s.id;
END;
$$;
REVOKE ALL ON FUNCTION public.set_sale_waiting(uuid, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_sale_waiting(uuid, text[]) TO authenticated;

-- stages: note → quotation → order → invoice (064's function, the note step added)
CREATE OR REPLACE FUNCTION public.set_sale_stage(p_sale uuid, p_stage text, p jsonb DEFAULT '{}'::jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  s   public.sales;
  dt  date;
BEGIN
  SELECT * INTO s FROM public.sales WHERE id = p_sale AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
  dt := coalesce(nullif(p->>'date', '')::date, public.org_today(s.organization_id));
  IF p_stage = 'quotation' THEN
    IF s.stage <> 'note' THEN RAISE EXCEPTION 'Only a note becomes a quotation' USING ERRCODE = '23514'; END IF;
    IF NOT public.has_permission_at('sales.create', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change sales at this branch' USING ERRCODE = '42501'; END IF;
    UPDATE public.sales SET stage = 'quotation' WHERE id = s.id;
  ELSIF p_stage = 'order' THEN
    IF s.stage NOT IN ('note', 'quotation') THEN RAISE EXCEPTION 'Only a note or a quotation becomes an order' USING ERRCODE = '23514'; END IF;
    IF NOT public.has_permission_at('sales.create', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t confirm orders at this branch' USING ERRCODE = '42501'; END IF;
    UPDATE public.sales SET stage = 'order', ordered_on = dt WHERE id = s.id;
  ELSIF p_stage = 'invoice' THEN
    IF s.stage NOT IN ('note', 'quotation', 'order') THEN RAISE EXCEPTION 'This sale is already invoiced or cancelled' USING ERRCODE = '23514'; END IF;
    IF NOT public.has_permission_at('invoices.create', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t invoice at this branch' USING ERRCODE = '42501'; END IF;
    UPDATE public.sales SET stage = 'invoice', ordered_on = coalesce(ordered_on, dt), invoiced_on = dt,
           efd_receipt_no = nullif(btrim(p->>'efd_receipt_no'), '') WHERE id = s.id;
  ELSIF p_stage = 'efd' THEN   -- the EFD receipt number, added or corrected on an invoice
    IF s.stage <> 'invoice' THEN RAISE EXCEPTION 'The EFD receipt goes on an invoice' USING ERRCODE = '23514'; END IF;
    IF NOT public.has_permission_at('invoices.create', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change invoices at this branch' USING ERRCODE = '42501'; END IF;
    UPDATE public.sales SET efd_receipt_no = nullif(btrim(p->>'efd_receipt_no'), '') WHERE id = s.id;
  ELSIF p_stage = 'cancelled' THEN
    IF s.stage = 'cancelled' THEN RAISE EXCEPTION 'Already cancelled' USING ERRCODE = '23514'; END IF;
    IF nullif(btrim(p->>'reason'), '') IS NULL THEN RAISE EXCEPTION 'Give the reason for cancelling' USING ERRCODE = '23514'; END IF;
    IF EXISTS (SELECT 1 FROM public.sale_payments WHERE sale_id = s.id) THEN
      RAISE EXCEPTION 'This sale has payments — they must be refunded first' USING ERRCODE = '23514';
    END IF;
    IF s.stage = 'invoice' AND NOT public.has_permission_at('sales.discount', s.branch_id, NULL) THEN
      RAISE EXCEPTION 'Only a manager can cancel an invoice' USING ERRCODE = '42501';
    END IF;
    IF NOT public.has_permission_at('sales.create', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t cancel sales at this branch' USING ERRCODE = '42501'; END IF;
    UPDATE public.sales SET stage = 'cancelled', cancelled_from = s.stage, cancel_reason = btrim(p->>'reason') WHERE id = s.id;
  ELSE
    RAISE EXCEPTION 'Unknown stage %', p_stage USING ERRCODE = '23514';
  END IF;
END;
$fn$;

-- a production order for what an order or invoice still needs (the Planner's own writer, then linked)
-- p: { due_date?, notes?, lines: [{ sale_line_id, pieces, sqm? }] }
CREATE FUNCTION public.make_production_for_sale(p_sale uuid, p jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  s     public.sales;
  who   text;
  l     jsonb;
  sl    public.sale_lines;
  lines jsonb := '[]'::jsonb;
  oid   uuid;
BEGIN
  SELECT * INTO s FROM public.sales WHERE id = p_sale AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
  IF s.stage NOT IN ('order', 'invoice') THEN RAISE EXCEPTION 'Confirm it as an order first' USING ERRCODE = '23514'; END IF;
  who := coalesce((SELECT name FROM public.customers WHERE id = s.customer_id), s.walk_in_name, 'Walk-in');
  FOR l IN SELECT * FROM jsonb_array_elements(coalesce(p->'lines', '[]'::jsonb)) LOOP
    SELECT * INTO sl FROM public.sale_lines WHERE id = nullif(l->>'sale_line_id', '')::uuid AND sale_id = s.id;
    IF NOT FOUND OR sl.product_id IS NULL THEN RAISE EXCEPTION 'A line is not a product of this sale' USING ERRCODE = '23514'; END IF;
    CONTINUE WHEN coalesce(nullif(l->>'pieces', '')::int, 0) <= 0;
    lines := lines || jsonb_build_object('product_id', sl.product_id, 'color_id', sl.color_id, 'pieces', (l->>'pieces')::int, 'sqm', l->'sqm', 'sale_line_id', sl.id);
  END LOOP;
  IF jsonb_array_length(lines) = 0 THEN RAISE EXCEPTION 'Enter the pieces to make' USING ERRCODE = '23514'; END IF;
  oid := public.save_production_order(jsonb_build_object('branch_id', s.branch_id, 'reference', 'Customer order #' || s.sale_no || ' · ' || who,
           'due_date', coalesce(nullif(p->>'due_date', ''), s.due_date::text), 'notes', p->>'notes', 'lines', lines));
  UPDATE public.production_orders SET sale_id = s.id WHERE id = oid;
  UPDATE public.production_order_lines pl SET sale_line_id = (x->>'sale_line_id')::uuid
    FROM jsonb_array_elements(lines) x
   WHERE pl.order_id = oid AND pl.product_id = (x->>'product_id')::uuid
     AND pl.color_id IS NOT DISTINCT FROM nullif(x->>'color_id', '')::uuid;
  RETURN oid;
END;
$fn$;
REVOKE ALL ON FUNCTION public.make_production_for_sale(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.make_production_for_sale(uuid, jsonb) TO authenticated;

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
  vflag  boolean;   -- the line's VAT box (110): true, false, or not given (the old rule)
  off    boolean;   -- the price charged differs from the list's
  inc    numeric;   -- the price typed, as the customer pays it, to 3 decimals (112)
BEGIN
  IF org IS NULL OR auth.uid() IS NULL THEN RAISE EXCEPTION 'Not signed in to an organization' USING ERRCODE = '42501'; END IF;
  IF sid IS NOT NULL THEN
    SELECT * INTO s FROM public.sales WHERE id = sid AND organization_id = org FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
    IF s.stage NOT IN ('note', 'quotation', 'order') THEN RAISE EXCEPTION 'An invoiced or cancelled sale can''t be changed' USING ERRCODE = '23514'; END IF;
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
    VALUES (org, br, coalesce((SELECT max(sale_no) FROM public.sales WHERE organization_id = org), 0) + 1,
            CASE WHEN coalesce((p->>'as_note')::boolean, false) THEN 'note' ELSE 'quotation' END,   -- 141: a note first
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
    inc := NULL;
    vflag := CASE WHEN l ? 'vat' AND jsonb_typeof(l->'vat') = 'boolean' THEN (l->>'vat')::boolean END;
    -- 'price' is the price charged a unit, as the customer pays it (069). The list price keeps its VAT;
    -- any other price is a discount — managers only, with a reason. Without the VAT box (old rule) a
    -- discount is sold WITHOUT VAT; with it (110) the box decides: ticked, the price paid includes VAT
    -- (the product's rate, or the branch's when the product has none); unticked, no VAT.
    IF nullif(l->>'price', '') IS NULL OR (lpi IS NOT NULL AND round((l->>'price')::numeric, 2) = lpi) THEN
      pr := lp;
      IF vflag IS FALSE AND rate > 0 THEN pr := lpi; rate := 0; END IF;
      IF vflag IS TRUE AND rate = 0 AND lp IS NOT NULL THEN
        rate := coalesce((SELECT b.vat_rate FROM public.branches b WHERE b.id = br), 18);
        pr := lp / (1 + rate / 100);
      END IF;
    ELSE
      inc := round((l->>'price')::numeric, 3);
      pr := inc;
      IF vflag IS TRUE THEN
        IF rate = 0 THEN rate := coalesce((SELECT b.vat_rate FROM public.branches b WHERE b.id = br), 18); END IF;
        pr := pr / (1 + rate / 100);
      ELSE
        rate := 0;
      END IF;
    END IF;
    IF pr IS NULL THEN
      RAISE EXCEPTION '% has no price at this branch — set it in Pricing', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    off := lp IS NULL OR coalesce(round(inc, 2), round(pr * (1 + rate / 100), 2)) <> lpi;
    IF off THEN
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
    -- 112: a typed price is used as typed (3 decimals), and the line total is in whole shillings —
    -- the amount the form showed and the user agreed, with no hidden cents
    pi := coalesce(inc, round(pr * (1 + rate / 100), 2));
    vt := round(qty * pi, 0);                    -- line total with VAT
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


CREATE OR REPLACE FUNCTION public.sales_availability(p_branch_id uuid, p_warehouse_id uuid DEFAULT NULL)
RETURNS TABLE (product_id uuid, color_id uuid, on_hand numeric, reserved numeric, available numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH stock AS (
    SELECT t.product_id, t.color_id, sum(t.quantity) AS q
      FROM public.inventory_transactions t JOIN public.warehouses w ON w.id = t.warehouse_id
     WHERE w.branch_id = p_branch_id AND w.type = 'finished_goods' AND t.product_id IS NOT NULL
       AND (p_warehouse_id IS NULL OR w.id = p_warehouse_id)
       AND t.organization_id = public.get_my_org_id()
     GROUP BY 1, 2
  ), held AS (   -- still to be delivered on open orders and invoices (065), from this store
    SELECT l.product_id, l.color_id,
           sum(greatest(l.quantity - coalesce((SELECT sum(dl.quantity) FROM public.sale_delivery_lines dl WHERE dl.sale_line_id = l.id), 0)
               - coalesce((SELECT sum(public.production_stock_qty(pl.product_id, greatest(pl.pieces - pr.passed, 0)))
                             FROM public.production_order_lines pl JOIN public.production_orders po ON po.id = pl.order_id
                             JOIN public.production_order_line_progress pr ON pr.line_id = pl.id
                            WHERE pl.sale_line_id = l.id AND po.status = 'open'), 0), 0)) AS q
      FROM public.sale_lines l JOIN public.sales s ON s.id = l.sale_id
     WHERE s.branch_id = p_branch_id AND s.stage IN ('order', 'invoice') AND s.organization_id = public.get_my_org_id()
       AND (p_warehouse_id IS NULL OR s.warehouse_id IS NULL OR s.warehouse_id = p_warehouse_id)
     GROUP BY 1, 2
  )
  SELECT coalesce(st.product_id, h.product_id), coalesce(st.color_id, h.color_id),
         coalesce(st.q, 0), coalesce(h.q, 0), coalesce(st.q, 0) - coalesce(h.q, 0)
    FROM stock st FULL JOIN held h ON h.product_id = st.product_id AND h.color_id IS NOT DISTINCT FROM st.color_id
$$;

