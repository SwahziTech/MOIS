-- ============================================================
-- 077 — Procurement: supplier payments and balances, purchase requests,
--       approval, purchase orders (the "Not yet" items of 1c)
--
-- SwahziTech, 2026-10-28, all three together:
--   * a purchase is paid in one or more payments (part payments allowed);
--     what each supplier is owed is purchases (and expenses) less payments;
--   * a purchase request (materials needed) is asked by the storekeeper or
--     secretary and approved by the branch manager (directors and the
--     Technical admin too);
--   * a purchase order to a supplier — from an approved request or on its
--     own — kept in MOIS, and printable for the supplier when wanted; goods
--     are received against it as purchases (part deliveries allowed).
-- Purchases already recorded keep their paid amount as one payment.
-- ============================================================

INSERT INTO public.permissions (code, description, module) VALUES
  ('procurement.request', 'Ask for materials to be bought (purchase request)', 'procurement'),
  ('procurement.approve', 'Approve or turn down purchase requests', 'procurement'),
  ('procurement.order',   'Make purchase orders to suppliers', 'procurement')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code IN ('procurement.request', 'procurement.approve', 'procurement.order')
WHERE r.is_system_role AND r.name IN ('owner', 'director', 'branch_manager')
ON CONFLICT DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code IN ('procurement.request', 'procurement.order')
WHERE r.is_system_role AND r.name = 'secretary'
ON CONFLICT DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code = 'procurement.request'
WHERE r.is_system_role AND r.name = 'storekeeper'
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------
-- 1. Payments to suppliers, per purchase
-- ------------------------------------------------------------
CREATE TABLE public.purchase_payments (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  purchase_id     uuid NOT NULL REFERENCES public.purchases(id) ON DELETE CASCADE,
  kind            text NOT NULL DEFAULT 'later' CHECK (kind IN ('at_purchase', 'later')),   -- paid when recorded, or afterwards
  paid_on         date NOT NULL,
  amount          numeric NOT NULL CHECK (amount > 0),
  method          text,                     -- cash | bank | mobile_money
  account_id      uuid REFERENCES public.payment_accounts(id) ON DELETE RESTRICT,   -- paid from
  reference       text,
  notes           text,
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_purchase_payments_purchase ON public.purchase_payments (purchase_id);
CREATE UNIQUE INDEX uq_purchase_payments_at_purchase ON public.purchase_payments (purchase_id) WHERE kind = 'at_purchase';
CREATE TRIGGER trg_purchase_payments_audit AFTER INSERT OR UPDATE OR DELETE ON public.purchase_payments FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('purchase_payment', 'id');
ALTER TABLE public.purchase_payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "purchase_payments: read own org" ON public.purchase_payments FOR SELECT USING (organization_id = public.get_my_org_id());

-- what is already paid becomes the purchase's first payment
INSERT INTO public.purchase_payments (organization_id, purchase_id, kind, paid_on, amount, method, created_by, created_at)
SELECT organization_id, id, 'at_purchase', coalesce(paid_on, purchase_date), amount_paid, payment_method, created_by, created_at
FROM public.purchases WHERE amount_paid > 0;

-- the purchase form still sets "paid" — that is the at-purchase payment; later payments are kept apart
CREATE OR REPLACE FUNCTION public.sync_purchase_paid()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  later numeric;
  first numeric;
BEGIN
  IF coalesce(current_setting('mois.purchase_pay_sync', true), '') = 'on' THEN RETURN NEW; END IF;
  SELECT coalesce(sum(amount), 0) INTO later FROM public.purchase_payments WHERE purchase_id = NEW.id AND kind = 'later';
  first := NEW.amount_paid - later;
  IF first < -0.004 THEN
    RAISE EXCEPTION 'Paid can''t be less than the payments recorded after the purchase (%)', later USING ERRCODE = '23514';
  END IF;
  IF first > 0.004 THEN
    INSERT INTO public.purchase_payments (organization_id, purchase_id, kind, paid_on, amount, method, created_by)
    VALUES (NEW.organization_id, NEW.id, 'at_purchase', coalesce(NEW.paid_on, NEW.purchase_date), first, NEW.payment_method, auth.uid())
    ON CONFLICT (purchase_id) WHERE kind = 'at_purchase'
    DO UPDATE SET amount = EXCLUDED.amount, paid_on = EXCLUDED.paid_on, method = EXCLUDED.method;
  ELSE
    DELETE FROM public.purchase_payments WHERE purchase_id = NEW.id AND kind = 'at_purchase';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_purchases_paid AFTER INSERT OR UPDATE OF amount_paid, paid_on, payment_method ON public.purchases
  FOR EACH ROW EXECUTE FUNCTION public.sync_purchase_paid();

-- A later payment for a purchase — p: { amount, paid_on?, method?, account_id?, reference?, notes? }
CREATE OR REPLACE FUNCTION public.record_purchase_payment(p_purchase uuid, p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  pu  public.purchases;
  tot numeric;
  amt numeric := round(nullif(p->>'amount', '')::numeric, 2);
  dt  date;
  acc public.payment_accounts;
  meth text := nullif(btrim(p->>'method'), '');
  pid uuid;
BEGIN
  SELECT * INTO pu FROM public.purchases WHERE id = p_purchase AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND OR pu.status <> 'recorded' THEN RAISE EXCEPTION 'Purchase not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.receive', pu.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t record supplier payments at this branch' USING ERRCODE = '42501'; END IF;
  IF amt IS NULL OR amt <= 0 THEN RAISE EXCEPTION 'Enter the amount paid' USING ERRCODE = '23514'; END IF;
  SELECT total INTO tot FROM public.purchase_totals WHERE purchase_id = pu.id;
  IF amt > tot - pu.amount_paid + 0.004 THEN
    RAISE EXCEPTION 'That is more than the % still owed', to_char(tot - pu.amount_paid, 'FM999G999G990D00') USING ERRCODE = '23514';
  END IF;
  dt := coalesce(nullif(p->>'paid_on', '')::date, public.org_today(pu.organization_id));
  IF dt > public.org_today(pu.organization_id) THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;
  IF dt < pu.purchase_date THEN RAISE EXCEPTION 'A payment can''t be before the purchase' USING ERRCODE = '23514'; END IF;
  IF nullif(p->>'account_id', '') IS NOT NULL THEN
    SELECT * INTO acc FROM public.payment_accounts WHERE id = (p->>'account_id')::uuid AND branch_id = pu.branch_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Choose the account it was paid from' USING ERRCODE = '23514'; END IF;
    meth := coalesce(meth, acc.kind);
  END IF;
  INSERT INTO public.purchase_payments (organization_id, purchase_id, kind, paid_on, amount, method, account_id, reference, notes, created_by)
  VALUES (pu.organization_id, pu.id, 'later', dt, amt, coalesce(meth, 'cash'), acc.id, nullif(btrim(p->>'reference'), ''), nullif(btrim(p->>'notes'), ''), auth.uid())
  RETURNING id INTO pid;
  PERFORM set_config('mois.purchase_pay_sync', 'on', true);
  UPDATE public.purchases SET amount_paid = amount_paid + amt WHERE id = pu.id;
  PERFORM set_config('mois.purchase_pay_sync', '', true);
  RETURN pid;
END;
$$;

-- What each supplier is owed, per branch: purchases and expenses less what was paid
CREATE OR REPLACE VIEW public.supplier_balances WITH (security_invoker = true) AS
WITH bills AS (
  SELECT p.organization_id, p.branch_id, p.supplier_id, 'purchase' AS kind, p.id AS doc_id, p.purchase_date AS doc_date,
         t.total AS amount, p.amount_paid AS paid
    FROM public.purchases p JOIN public.purchase_totals t ON t.purchase_id = p.id
   WHERE p.status = 'recorded'
  UNION ALL
  SELECT e.organization_id, e.branch_id, e.supplier_id, 'expense', e.id, e.expense_date, e.amount, e.amount_paid
    FROM public.expenses e
   WHERE e.status = 'recorded' AND e.supplier_id IS NOT NULL
)
SELECT organization_id, branch_id, supplier_id,
       count(*) AS bills, sum(amount) AS billed, sum(paid) AS paid, sum(amount - paid) AS owed,
       min(doc_date) FILTER (WHERE amount - paid > 0.004) AS owed_since
FROM bills GROUP BY 1, 2, 3;
GRANT SELECT ON public.supplier_balances TO authenticated;

-- ------------------------------------------------------------
-- 2. Purchase requests
-- ------------------------------------------------------------
CREATE TABLE public.purchase_requests (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  request_no      int  NOT NULL,
  requested_on    date NOT NULL,
  needed_by       date,
  status          text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'approved', 'rejected', 'ordered', 'cancelled')),
  notes           text,
  requested_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  decided_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  decided_at      timestamptz,
  decision_note   text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, request_no)
);
CREATE TABLE public.purchase_request_lines (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  request_id      uuid NOT NULL REFERENCES public.purchase_requests(id) ON DELETE CASCADE,
  line_no         int  NOT NULL,
  material_id     uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
  quantity        numeric NOT NULL CHECK (quantity > 0),
  unit_id         uuid NOT NULL REFERENCES public.units(id),
  note            text
);
CREATE INDEX idx_purchase_requests_branch ON public.purchase_requests (branch_id, requested_on DESC);
CREATE TRIGGER trg_purchase_requests_updated_at BEFORE UPDATE ON public.purchase_requests FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_purchase_requests_audit AFTER INSERT OR UPDATE OR DELETE ON public.purchase_requests FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('purchase_request', 'id');
CREATE TRIGGER trg_purchase_requests_no_delete BEFORE DELETE ON public.purchase_requests FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('purchase request');
ALTER TABLE public.purchase_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_request_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "purchase_requests: read own org" ON public.purchase_requests FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "purchase_request_lines: read own org" ON public.purchase_request_lines FOR SELECT USING (organization_id = public.get_my_org_id());

-- p: { branch_id, needed_by?, notes?, lines: [{ material_id, quantity, unit_id, note? }] }
CREATE OR REPLACE FUNCTION public.submit_purchase_request(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  br  uuid := nullif(p->>'branch_id', '')::uuid;
  rid uuid;
  x   jsonb;
  n   int := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = br AND organization_id = org) THEN RAISE EXCEPTION 'Branch not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.request', br, NULL) THEN RAISE EXCEPTION 'You can''t ask for purchases at this branch' USING ERRCODE = '42501'; END IF;
  IF jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines') = 0 THEN RAISE EXCEPTION 'Add what is needed' USING ERRCODE = '23514'; END IF;
  INSERT INTO public.purchase_requests (organization_id, branch_id, request_no, requested_on, needed_by, notes, requested_by)
  VALUES (org, br, coalesce((SELECT max(request_no) FROM public.purchase_requests WHERE organization_id = org), 0) + 1,
          public.org_today(org), nullif(p->>'needed_by', '')::date, nullif(btrim(p->>'notes'), ''), auth.uid())
  RETURNING id INTO rid;
  FOR x IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    n := n + 1;
    IF nullif(x->>'quantity', '')::numeric IS NULL OR (x->>'quantity')::numeric <= 0 THEN RAISE EXCEPTION 'Line %: enter the quantity', n USING ERRCODE = '23514'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.materials WHERE id = (x->>'material_id')::uuid AND organization_id = org) THEN RAISE EXCEPTION 'Line %: choose the material', n USING ERRCODE = '23514'; END IF;
    INSERT INTO public.purchase_request_lines (organization_id, request_id, line_no, material_id, quantity, unit_id, note)
    VALUES (org, rid, n, (x->>'material_id')::uuid, (x->>'quantity')::numeric, (x->>'unit_id')::uuid, nullif(btrim(x->>'note'), ''));
  END LOOP;
  RETURN rid;
END;
$$;

-- approve | reject (a reason) | cancel (by the one who asked, or an approver)
CREATE OR REPLACE FUNCTION public.decide_purchase_request(p_id uuid, p_decision text, p_note text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r public.purchase_requests;
BEGIN
  SELECT * INTO r FROM public.purchase_requests WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Request not found' USING ERRCODE = '23514'; END IF;
  IF p_decision NOT IN ('approved', 'rejected', 'cancelled') THEN RAISE EXCEPTION 'Approve, turn down or cancel' USING ERRCODE = '23514'; END IF;
  IF p_decision = 'cancelled' THEN
    IF r.status NOT IN ('waiting', 'approved') THEN RAISE EXCEPTION 'This request can''t be cancelled now' USING ERRCODE = '23514'; END IF;
    IF r.requested_by IS DISTINCT FROM auth.uid() AND NOT public.has_permission_at('procurement.approve', r.branch_id, NULL) THEN
      RAISE EXCEPTION 'Only who asked, or an approver, can cancel it' USING ERRCODE = '42501';
    END IF;
  ELSE
    IF r.status <> 'waiting' THEN RAISE EXCEPTION 'This request has already been decided' USING ERRCODE = '23514'; END IF;
    IF NOT public.has_permission_at('procurement.approve', r.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t approve purchase requests at this branch' USING ERRCODE = '42501'; END IF;
    IF p_decision = 'rejected' AND nullif(btrim(p_note), '') IS NULL THEN RAISE EXCEPTION 'Say why it is turned down' USING ERRCODE = '23514'; END IF;
  END IF;
  UPDATE public.purchase_requests SET status = p_decision, decided_by = auth.uid(), decided_at = now(), decision_note = nullif(btrim(p_note), '') WHERE id = r.id;
END;
$$;

-- ------------------------------------------------------------
-- 3. Purchase orders, received against as purchases
-- ------------------------------------------------------------
CREATE TABLE public.purchase_orders (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  po_no           int  NOT NULL,
  supplier_id     uuid NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  request_id      uuid REFERENCES public.purchase_requests(id) ON DELETE RESTRICT,
  order_date      date NOT NULL,
  expected_on     date,
  status          text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'cancelled')),   -- received in full shows from the lines
  sent_to_supplier boolean NOT NULL DEFAULT false,      -- printed/sent, or kept internal
  notes           text,
  close_reason    text,
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, po_no)
);
CREATE TABLE public.purchase_order_lines (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  order_id        uuid NOT NULL REFERENCES public.purchase_orders(id) ON DELETE CASCADE,
  line_no         int  NOT NULL,
  material_id     uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
  quantity        numeric NOT NULL CHECK (quantity > 0),          -- as ordered, in unit_id
  unit_id         uuid NOT NULL REFERENCES public.units(id),
  stock_quantity  numeric NOT NULL CHECK (stock_quantity > 0),    -- in the material's stock unit
  unit_price      numeric CHECK (unit_price >= 0)                 -- agreed price per unit_id, if known
);
CREATE INDEX idx_purchase_orders_branch ON public.purchase_orders (branch_id, order_date DESC);
CREATE TRIGGER trg_purchase_orders_updated_at BEFORE UPDATE ON public.purchase_orders FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_purchase_orders_audit AFTER INSERT OR UPDATE OR DELETE ON public.purchase_orders FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('purchase_order', 'id');
CREATE TRIGGER trg_purchase_orders_no_delete BEFORE DELETE ON public.purchase_orders FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('purchase order');
ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_order_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "purchase_orders: read own org" ON public.purchase_orders FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "purchase_order_lines: read own org" ON public.purchase_order_lines FOR SELECT USING (organization_id = public.get_my_org_id());

ALTER TABLE public.purchases ADD COLUMN purchase_order_id uuid REFERENCES public.purchase_orders(id) ON DELETE RESTRICT;
COMMENT ON COLUMN public.purchases.purchase_order_id IS 'The purchase order these goods were received against (077).';

-- a material's quantity in its stock unit (the unit's factor, 1 for the stock unit)
CREATE OR REPLACE FUNCTION public.material_stock_qty(p_material uuid, p_unit uuid, p_qty numeric)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN m.stock_unit_id = p_unit THEN p_qty ELSE p_qty * c.factor_to_stock_unit END
  FROM public.materials m
  LEFT JOIN public.material_unit_conversions c ON c.material_id = m.id AND c.unit_id = p_unit
  WHERE m.id = p_material
$$;

-- p: { branch_id, supplier_id, request_id?, expected_on?, notes?, sent_to_supplier?, lines: [{ material_id, quantity, unit_id, unit_price? }] }
CREATE OR REPLACE FUNCTION public.create_purchase_order(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  br  uuid := nullif(p->>'branch_id', '')::uuid;
  req public.purchase_requests;
  oid uuid;
  x   jsonb;
  n   int := 0;
  sq  numeric;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = br AND organization_id = org) THEN RAISE EXCEPTION 'Branch not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.order', br, NULL) THEN RAISE EXCEPTION 'You can''t make purchase orders at this branch' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id = (p->>'supplier_id')::uuid AND organization_id = org) THEN RAISE EXCEPTION 'Choose the supplier' USING ERRCODE = '23514'; END IF;
  IF nullif(p->>'request_id', '') IS NOT NULL THEN
    SELECT * INTO req FROM public.purchase_requests WHERE id = (p->>'request_id')::uuid AND organization_id = org FOR UPDATE;
    IF NOT FOUND OR req.branch_id <> br THEN RAISE EXCEPTION 'Request not found' USING ERRCODE = '23514'; END IF;
    IF req.status NOT IN ('approved', 'ordered') THEN RAISE EXCEPTION 'Only an approved request can be ordered' USING ERRCODE = '23514'; END IF;
  END IF;
  IF jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines') = 0 THEN RAISE EXCEPTION 'Add what is ordered' USING ERRCODE = '23514'; END IF;
  INSERT INTO public.purchase_orders (organization_id, branch_id, po_no, supplier_id, request_id, order_date, expected_on, notes, sent_to_supplier, created_by)
  VALUES (org, br, coalesce((SELECT max(po_no) FROM public.purchase_orders WHERE organization_id = org), 0) + 1, (p->>'supplier_id')::uuid, req.id,
          public.org_today(org), nullif(p->>'expected_on', '')::date, nullif(btrim(p->>'notes'), ''), coalesce((p->>'sent_to_supplier')::boolean, false), auth.uid())
  RETURNING id INTO oid;
  FOR x IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    n := n + 1;
    IF nullif(x->>'quantity', '')::numeric IS NULL OR (x->>'quantity')::numeric <= 0 THEN RAISE EXCEPTION 'Line %: enter the quantity', n USING ERRCODE = '23514'; END IF;
    sq := public.material_stock_qty((x->>'material_id')::uuid, (x->>'unit_id')::uuid, (x->>'quantity')::numeric);
    IF sq IS NULL THEN RAISE EXCEPTION 'Line %: that unit is not one this material is counted in', n USING ERRCODE = '23514'; END IF;
    INSERT INTO public.purchase_order_lines (organization_id, order_id, line_no, material_id, quantity, unit_id, stock_quantity, unit_price)
    VALUES (org, oid, n, (x->>'material_id')::uuid, (x->>'quantity')::numeric, (x->>'unit_id')::uuid, sq, nullif(x->>'unit_price', '')::numeric);
  END LOOP;
  IF req.id IS NOT NULL THEN UPDATE public.purchase_requests SET status = 'ordered' WHERE id = req.id; END IF;
  RETURN oid;
END;
$$;

-- received against an order: what its purchases brought in, per material (stock unit)
CREATE OR REPLACE VIEW public.purchase_order_receipts WITH (security_invoker = true) AS
SELECT l.id AS order_line_id, l.order_id, l.material_id, l.stock_quantity AS ordered,
       coalesce((SELECT sum(t.quantity) FROM public.purchases pu
                   JOIN public.purchase_lines pl ON pl.purchase_id = pu.id
                   JOIN public.inventory_transactions t ON t.id = pl.transaction_id
                  WHERE pu.purchase_order_id = l.order_id AND pu.status = 'recorded' AND t.material_id = l.material_id), 0) AS received
FROM public.purchase_order_lines l;
GRANT SELECT ON public.purchase_order_receipts TO authenticated;

-- a purchase received against an order (or no order)
CREATE OR REPLACE FUNCTION public.set_purchase_order(p_purchase uuid, p_order uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  pu public.purchases;
  po public.purchase_orders;
BEGIN
  SELECT * INTO pu FROM public.purchases WHERE id = p_purchase AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND OR pu.status <> 'recorded' THEN RAISE EXCEPTION 'Purchase not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.receive', pu.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change purchases at this branch' USING ERRCODE = '42501'; END IF;
  IF p_order IS NOT NULL THEN
    SELECT * INTO po FROM public.purchase_orders WHERE id = p_order AND organization_id = pu.organization_id;
    IF NOT FOUND OR po.branch_id <> pu.branch_id THEN RAISE EXCEPTION 'Order not found at this branch' USING ERRCODE = '23514'; END IF;
    IF po.status = 'cancelled' THEN RAISE EXCEPTION 'That order was cancelled' USING ERRCODE = '23514'; END IF;
    IF po.supplier_id <> pu.supplier_id THEN RAISE EXCEPTION 'The order is with another supplier' USING ERRCODE = '23514'; END IF;
  END IF;
  PERFORM set_config('mois.purchase_pay_sync', 'on', true);
  UPDATE public.purchases SET purchase_order_id = p_order WHERE id = pu.id;
  PERFORM set_config('mois.purchase_pay_sync', '', true);
END;
$$;

-- close (received what will come) or cancel (nothing received) an order
CREATE OR REPLACE FUNCTION public.close_purchase_order(p_id uuid, p_cancel boolean, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  po public.purchase_orders;
BEGIN
  SELECT * INTO po FROM public.purchase_orders WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.order', po.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change purchase orders at this branch' USING ERRCODE = '42501'; END IF;
  IF po.status <> 'open' THEN RAISE EXCEPTION 'This order is already %', po.status USING ERRCODE = '23514'; END IF;
  IF p_cancel AND EXISTS (SELECT 1 FROM public.purchases WHERE purchase_order_id = po.id AND status = 'recorded') THEN
    RAISE EXCEPTION 'Goods were received against it — close it instead' USING ERRCODE = '23514';
  END IF;
  IF nullif(btrim(p_reason), '') IS NULL AND p_cancel THEN RAISE EXCEPTION 'Say why it is cancelled' USING ERRCODE = '23514'; END IF;
  UPDATE public.purchase_orders SET status = CASE WHEN p_cancel THEN 'cancelled' ELSE 'closed' END, close_reason = nullif(btrim(p_reason), '') WHERE id = po.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_purchase_order_sent(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  po public.purchase_orders;
BEGIN
  SELECT * INTO po FROM public.purchase_orders WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.order', po.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change purchase orders at this branch' USING ERRCODE = '42501'; END IF;
  UPDATE public.purchase_orders SET sent_to_supplier = true WHERE id = po.id;
END;
$$;

REVOKE ALL ON FUNCTION public.record_purchase_payment(uuid, jsonb), public.submit_purchase_request(jsonb), public.decide_purchase_request(uuid, text, text),
  public.create_purchase_order(jsonb), public.set_purchase_order(uuid, uuid), public.close_purchase_order(uuid, boolean, text),
  public.mark_purchase_order_sent(uuid), public.material_stock_qty(uuid, uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_purchase_payment(uuid, jsonb), public.submit_purchase_request(jsonb), public.decide_purchase_request(uuid, text, text),
  public.create_purchase_order(jsonb), public.set_purchase_order(uuid, uuid), public.close_purchase_order(uuid, boolean, text),
  public.mark_purchase_order_sent(uuid), public.material_stock_qty(uuid, uuid, numeric) TO authenticated;
