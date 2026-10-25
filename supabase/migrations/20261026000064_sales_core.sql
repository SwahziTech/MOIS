-- ============================================================
-- 064 — Sales, stage 1 (1e): customers, the sale document
-- (Quotation → Order → Invoice) and payments
--
-- SwahziTech, 2026-10-25, the user's decisions:
--   * one document moving through stages — quotation, order, invoice — the
--     same lines and number throughout (cancelled ends it);
--   * goods leave finished goods on delivery/collection (stage 2), up to
--     the value paid so far; until then an order or invoice reserves them;
--   * payments by cash, mobile money or bank, with a reference; part
--     payments allowed;
--   * discounts by managers only, with a reason (new permission
--     sales.discount: owner, director, branch manager);
--   * secretaries and branch managers record sales at their branch
--     (sales.create, invoices.create, payments.record — already theirs);
--   * walk-in buyers allowed (name and phone optional), or a saved customer;
--   * the EFD receipt number is recorded on the invoice.
-- Prices come from the branch's price list per stock unit (m² or piece, as
-- the product is counted — 063), WITHOUT VAT, plus VAT at the price's own
-- rate (061; 0 = sold without VAT). All arithmetic is done here, never in
-- the screens (PRD 4.12).
-- ============================================================

INSERT INTO public.permissions (code, description, module)
VALUES ('sales.discount', 'Give a discount on a sale (with a reason)', 'sales')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code = 'sales.discount'
WHERE r.is_system_role AND r.name IN ('owner', 'director', 'branch_manager')
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------
-- 1. Customers (shared by the organization's branches)
-- ------------------------------------------------------------
CREATE TABLE public.customers (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name            text NOT NULL CHECK (btrim(name) <> ''),
  phone           text,
  email           text,
  tin             text,          -- TRA taxpayer number
  vrn             text,          -- VAT registration number
  address         text,
  branch_id       uuid REFERENCES public.branches(id) ON DELETE SET NULL,   -- the branch that added it
  notes           text,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_customers_org_name ON public.customers (organization_id, public.normalize_name(name));
CREATE TRIGGER trg_customers_updated_at BEFORE UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_customers_audit AFTER INSERT OR UPDATE OR DELETE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('customer', 'id');
CREATE TRIGGER trg_customers_no_delete BEFORE DELETE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('customer');
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "customers: sales staff read" ON public.customers FOR SELECT
  USING (organization_id = public.get_my_org_id() AND public.has_permission_anywhere('sales.view'));
CREATE POLICY "customers: sales staff add" ON public.customers FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_anywhere('sales.create'));
CREATE POLICY "customers: sales staff change" ON public.customers FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND public.has_permission_anywhere('sales.create'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_anywhere('sales.create'));

-- ------------------------------------------------------------
-- 2. Sales and their lines
-- ------------------------------------------------------------
CREATE TABLE public.sales (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  sale_no         int  NOT NULL,
  stage           text NOT NULL DEFAULT 'quotation' CHECK (stage IN ('quotation', 'order', 'invoice', 'cancelled')),
  customer_id     uuid REFERENCES public.customers(id) ON DELETE RESTRICT,
  walk_in_name    text,
  walk_in_phone   text,
  sale_date       date NOT NULL,
  valid_until     date,                       -- a quotation's validity
  ordered_on      date,
  invoiced_on     date,
  efd_receipt_no  text,                       -- TRA fiscal receipt from the EFD machine
  notes           text,
  subtotal        numeric NOT NULL DEFAULT 0, -- without VAT
  vat             numeric NOT NULL DEFAULT 0,
  total           numeric NOT NULL DEFAULT 0, -- with VAT
  cancel_reason   text,
  cancelled_from  text,                       -- the stage it was cancelled at
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, sale_no),
  CHECK ((stage = 'cancelled') = (cancel_reason IS NOT NULL))
);
CREATE INDEX idx_sales_branch_date ON public.sales (organization_id, branch_id, sale_date DESC);

CREATE TABLE public.sale_lines (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  sale_id         uuid NOT NULL REFERENCES public.sales(id) ON DELETE CASCADE,
  line_no         int  NOT NULL,
  product_id      uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  color_id        uuid REFERENCES public.color_palette(id) ON DELETE RESTRICT,
  quantity        numeric NOT NULL CHECK (quantity > 0),   -- in the product's stock unit (m² or pieces)
  unit_id         uuid NOT NULL REFERENCES public.units(id),
  list_price      numeric NOT NULL,           -- the price list's, per stock unit, without VAT
  price           numeric NOT NULL CHECK (price >= 0),    -- charged, per stock unit, without VAT
  vat_rate        numeric NOT NULL CHECK (vat_rate >= 0 AND vat_rate < 100),
  discount_reason text,                       -- required when price < list price
  discount_by     uuid REFERENCES auth.users(id),
  amount          numeric NOT NULL,           -- quantity × price, without VAT
  vat             numeric NOT NULL,
  total           numeric NOT NULL,           -- with VAT
  UNIQUE (sale_id, line_no)
);

CREATE TABLE public.sale_payments (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  sale_id         uuid NOT NULL REFERENCES public.sales(id) ON DELETE RESTRICT,
  paid_on         date NOT NULL,
  amount          numeric NOT NULL CHECK (amount > 0),
  method          text NOT NULL CHECK (method IN ('cash', 'mobile_money', 'bank')),
  reference       text,                       -- mobile money / bank reference
  notes           text,
  received_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_sale_payments_sale ON public.sale_payments (sale_id);

CREATE TRIGGER trg_sales_updated_at BEFORE UPDATE ON public.sales FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_sales_audit AFTER INSERT OR UPDATE OR DELETE ON public.sales FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('sale', 'id');
CREATE TRIGGER trg_sales_no_delete BEFORE DELETE ON public.sales FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('sale');
CREATE TRIGGER trg_sale_lines_audit AFTER INSERT OR UPDATE OR DELETE ON public.sale_lines FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('sale_line', 'id');
CREATE TRIGGER trg_sale_payments_audit AFTER INSERT OR UPDATE OR DELETE ON public.sale_payments FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('sale_payment', 'id');
CREATE TRIGGER trg_sale_payments_no_delete BEFORE DELETE ON public.sale_payments FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('payment');

-- read at the branches where one may see sales; written only through the functions below
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sales: read at branch" ON public.sales FOR SELECT
  USING (organization_id = public.get_my_org_id() AND public.has_permission_at('sales.view', branch_id, NULL));
CREATE POLICY "sale_lines: read with the sale" ON public.sale_lines FOR SELECT
  USING (organization_id = public.get_my_org_id() AND EXISTS (SELECT 1 FROM public.sales s WHERE s.id = sale_id AND public.has_permission_at('sales.view', s.branch_id, NULL)));
CREATE POLICY "sale_payments: read with the sale" ON public.sale_payments FOR SELECT
  USING (organization_id = public.get_my_org_id() AND EXISTS (SELECT 1 FROM public.sales s WHERE s.id = sale_id AND public.has_permission_at('sales.view', s.branch_id, NULL)));

-- What each sale has been paid and still owes
CREATE VIEW public.sale_balances WITH (security_invoker = true) AS
SELECT s.id AS sale_id, s.organization_id, s.branch_id, s.customer_id, s.stage, s.total,
       coalesce((SELECT sum(p.amount) FROM public.sale_payments p WHERE p.sale_id = s.id), 0) AS paid,
       s.total - coalesce((SELECT sum(p.amount) FROM public.sale_payments p WHERE p.sale_id = s.id), 0) AS balance
FROM public.sales s;


-- ------------------------------------------------------------
-- 3. The VAT rate of a product's price at a branch (its own, else the branch's)
-- ------------------------------------------------------------
CREATE FUNCTION public.product_price_vat_rate(p_branch_id uuid, p_product_id uuid, p_color_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(
    (SELECT x.vat_rate FROM public.product_branch_pricing x WHERE x.product_id = p_product_id AND x.branch_id = p_branch_id
        AND x.color_id IS NOT DISTINCT FROM p_color_id AND x.is_available),
    (SELECT x.vat_rate FROM public.product_branch_pricing x WHERE x.product_id = p_product_id AND x.branch_id = p_branch_id
        AND x.color_id IS NULL AND x.is_available),
    (SELECT vat_rate FROM public.branches WHERE id = p_branch_id), 0)
$$;
REVOKE ALL ON FUNCTION public.product_price_vat_rate(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.product_price_vat_rate(uuid, uuid, uuid) TO authenticated;


-- ------------------------------------------------------------
-- 4. Save a quotation or order (an invoice is fixed)
-- p: { id?, branch_id, customer_id? | walk_in_name?, walk_in_phone?, sale_date?, valid_until?, notes?,
--      lines: [{ product_id, color_id?, quantity, price? (without VAT; lower = discount), discount_reason? }] }
-- ------------------------------------------------------------
CREATE FUNCTION public.save_sale(p jsonb)
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
  why    text;
  n      int := 0;
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
    pr := coalesce(nullif(l->>'price', '')::numeric, lp);
    IF pr IS NULL THEN
      RAISE EXCEPTION '% has no price at this branch — set it in Pricing', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    rate := public.product_price_vat_rate(br, prod.id, col);
    why := nullif(btrim(l->>'discount_reason'), '');
    -- a price other than the list's is a discount: managers only, with a reason
    IF lp IS NULL OR round(pr, 2) <> round(lp, 2) THEN
      IF NOT public.has_permission_at('sales.discount', br, NULL) THEN
        RAISE EXCEPTION '%: only a manager can change the price (the list price is %)', prod.canonical_name,
          coalesce(to_char(round(lp, 2), 'FM999G999G999D00'), 'not set') USING ERRCODE = '42501';
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


-- ------------------------------------------------------------
-- 5. Move a sale on: quotation → order → invoice, or cancel it
-- p: { efd_receipt_no?, reason? (cancel), date? }
-- ------------------------------------------------------------
CREATE FUNCTION public.set_sale_stage(p_sale uuid, p_stage text, p jsonb DEFAULT '{}'::jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s   public.sales;
  dt  date;
BEGIN
  SELECT * INTO s FROM public.sales WHERE id = p_sale AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
  dt := coalesce(nullif(p->>'date', '')::date, public.org_today(s.organization_id));
  IF p_stage = 'order' THEN
    IF s.stage <> 'quotation' THEN RAISE EXCEPTION 'Only a quotation becomes an order' USING ERRCODE = '23514'; END IF;
    IF NOT public.has_permission_at('sales.create', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t confirm orders at this branch' USING ERRCODE = '42501'; END IF;
    UPDATE public.sales SET stage = 'order', ordered_on = dt WHERE id = s.id;
  ELSIF p_stage = 'invoice' THEN
    IF s.stage NOT IN ('quotation', 'order') THEN RAISE EXCEPTION 'This sale is already invoiced or cancelled' USING ERRCODE = '23514'; END IF;
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
$$;
REVOKE ALL ON FUNCTION public.set_sale_stage(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_sale_stage(uuid, text, jsonb) TO authenticated;


-- ------------------------------------------------------------
-- 6. Record a payment on an order or invoice (part payments allowed, never more than owed)
-- ------------------------------------------------------------
CREATE FUNCTION public.record_sale_payment(p_sale uuid, p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s    public.sales;
  amt  numeric := round(nullif(p->>'amount', '')::numeric, 2);
  owed numeric;
  pid  uuid;
  dt   date;
BEGIN
  SELECT * INTO s FROM public.sales WHERE id = p_sale AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
  IF s.stage NOT IN ('order', 'invoice') THEN RAISE EXCEPTION 'Payments are taken on an order or an invoice' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('payments.record', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t record payments at this branch' USING ERRCODE = '42501'; END IF;
  IF amt IS NULL OR amt <= 0 THEN RAISE EXCEPTION 'Enter the amount paid' USING ERRCODE = '23514'; END IF;
  IF coalesce(p->>'method', '') NOT IN ('cash', 'mobile_money', 'bank') THEN RAISE EXCEPTION 'Choose how it was paid' USING ERRCODE = '23514'; END IF;
  IF p->>'method' <> 'cash' AND nullif(btrim(p->>'reference'), '') IS NULL THEN
    RAISE EXCEPTION 'Enter the % reference', CASE p->>'method' WHEN 'bank' THEN 'bank' ELSE 'mobile money' END USING ERRCODE = '23514';
  END IF;
  owed := s.total - coalesce((SELECT sum(amount) FROM public.sale_payments WHERE sale_id = s.id), 0);
  IF amt > owed THEN RAISE EXCEPTION 'That is more than the % still owed', to_char(owed, 'FM999G999G999D00') USING ERRCODE = '23514'; END IF;
  dt := coalesce(nullif(p->>'paid_on', '')::date, public.org_today(s.organization_id));
  IF dt > public.org_today(s.organization_id) THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;
  INSERT INTO public.sale_payments (organization_id, sale_id, paid_on, amount, method, reference, notes, received_by)
  VALUES (s.organization_id, s.id, dt, amt, p->>'method', nullif(btrim(p->>'reference'), ''), nullif(btrim(p->>'notes'), ''), auth.uid())
  RETURNING id INTO pid;
  RETURN pid;
END;
$$;
REVOKE ALL ON FUNCTION public.record_sale_payment(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_sale_payment(uuid, jsonb) TO authenticated;


-- ------------------------------------------------------------
-- 7. What can be sold now: finished goods on hand (not curing) less what open orders and invoices hold
-- ------------------------------------------------------------
CREATE FUNCTION public.sales_availability(p_branch_id uuid)
RETURNS TABLE (product_id uuid, color_id uuid, on_hand numeric, reserved numeric, available numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH stock AS (
    SELECT t.product_id, t.color_id, sum(t.quantity) AS q
      FROM public.inventory_transactions t JOIN public.warehouses w ON w.id = t.warehouse_id
     WHERE w.branch_id = p_branch_id AND w.type = 'finished_goods' AND t.product_id IS NOT NULL
       AND t.organization_id = public.get_my_org_id()
     GROUP BY 1, 2
  ), held AS (
    SELECT l.product_id, l.color_id, sum(l.quantity) AS q
      FROM public.sale_lines l JOIN public.sales s ON s.id = l.sale_id
     WHERE s.branch_id = p_branch_id AND s.stage IN ('order', 'invoice') AND s.organization_id = public.get_my_org_id()
     GROUP BY 1, 2
  )
  SELECT coalesce(st.product_id, h.product_id), coalesce(st.color_id, h.color_id),
         coalesce(st.q, 0), coalesce(h.q, 0), coalesce(st.q, 0) - coalesce(h.q, 0)
    FROM stock st FULL JOIN held h ON h.product_id = st.product_id AND h.color_id IS NOT DISTINCT FROM st.color_id
$$;
REVOKE ALL ON FUNCTION public.sales_availability(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_availability(uuid) TO authenticated;
COMMENT ON FUNCTION public.sales_availability(uuid)
  IS 'Finished goods on hand (curing excluded) less what open orders and invoices hold; deliveries (stage 2) will release the hold (064).';
