-- 110 (2026-11-08, the user): a VAT box on each product line of a sale.
-- Ticked, the price paid includes VAT; unticked, no VAT. The form unticks it when
-- the price differs from the price list, unless the user ticks it again. A price
-- other than the list's still needs a manager and a reason, with or without VAT.
-- Lines sent without the box keep the old rule (069: a discount has no VAT).
-- Only save_sale changes; record_sale passes its lines through it.

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
      pr := round((l->>'price')::numeric, 2);
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
    off := lp IS NULL OR round(pr * (1 + rate / 100), 2) <> lpi;
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
REVOKE ALL ON FUNCTION public.save_sale(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_sale(jsonb) TO authenticated;
