-- ============================================================
-- 082 — Orders for expenses too; LUKU top-ups through an order; recorded by
--       the secretary or branch manager when the directors are away
--
-- SwahziTech, 2026-10-28: an approved top-up (or any expense request) goes
-- through a purchase order like materials do — to the LUKU seller — and
-- when it is bought the secretary or branch manager can record it (not only
-- the directors), so the work carries on when no director is available.
-- Recording the token tops the meter up, makes the expense, closes the order
-- line and the request.
-- ============================================================

ALTER TABLE public.purchase_order_lines
  ADD COLUMN kind        text NOT NULL DEFAULT 'material' CHECK (kind IN ('material', 'expense')),
  ADD COLUMN category_id uuid REFERENCES public.expense_categories(id) ON DELETE RESTRICT,
  ADD COLUMN meter_id    uuid REFERENCES public.power_meters(id) ON DELETE RESTRICT,
  ADD COLUMN description text,
  ADD COLUMN unit_text   text,
  ADD COLUMN amount      numeric CHECK (amount >= 0),
  ADD COLUMN request_line_id uuid REFERENCES public.purchase_request_lines(id) ON DELETE SET NULL;
ALTER TABLE public.purchase_order_lines ALTER COLUMN material_id DROP NOT NULL, ALTER COLUMN unit_id DROP NOT NULL,
  ALTER COLUMN stock_quantity DROP NOT NULL, ALTER COLUMN quantity DROP NOT NULL;
ALTER TABLE public.purchase_order_lines ADD CONSTRAINT purchase_order_lines_kind_fields_check CHECK (
  (kind = 'material' AND material_id IS NOT NULL AND unit_id IS NOT NULL AND quantity IS NOT NULL AND stock_quantity IS NOT NULL)
  OR (kind = 'expense' AND category_id IS NOT NULL AND btrim(coalesce(description, '')) <> ''));

ALTER TABLE public.expenses ADD COLUMN order_line_id uuid REFERENCES public.purchase_order_lines(id) ON DELETE SET NULL;
COMMENT ON COLUMN public.expenses.order_line_id IS 'The purchase-order line this expense fulfils (082).';

-- p: { branch_id, supplier_id? | new_supplier_name?, request_id?, expected_on?, notes?, sent_to_supplier?,
--      lines: [{ kind?, material_id, quantity, unit_id, unit_price? } | { kind: 'expense', category_id, meter_id?, description, quantity?, unit_text?, amount?, request_line_id? }] }
CREATE OR REPLACE FUNCTION public.create_purchase_order(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  br  uuid := nullif(p->>'branch_id', '')::uuid;
  sup uuid := nullif(p->>'supplier_id', '')::uuid;
  new_sup text := nullif(btrim(p->>'new_supplier_name'), '');
  req public.purchase_requests;
  oid uuid;
  x   jsonb;
  n   int := 0;
  sq  numeric;
  k   text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = br AND organization_id = org) THEN RAISE EXCEPTION 'Branch not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.order', br, NULL) THEN RAISE EXCEPTION 'You can''t make purchase orders at this branch' USING ERRCODE = '42501'; END IF;
  IF sup IS NULL AND new_sup IS NOT NULL THEN
    SELECT id INTO sup FROM public.suppliers WHERE organization_id = org AND public.normalize_name(name) = public.normalize_name(new_sup);
    IF sup IS NULL THEN INSERT INTO public.suppliers (organization_id, name) VALUES (org, new_sup) RETURNING id INTO sup; END IF;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id = sup AND organization_id = org) THEN RAISE EXCEPTION 'Choose the supplier' USING ERRCODE = '23514'; END IF;
  IF nullif(p->>'request_id', '') IS NOT NULL THEN
    SELECT * INTO req FROM public.purchase_requests WHERE id = (p->>'request_id')::uuid AND organization_id = org FOR UPDATE;
    IF NOT FOUND OR req.branch_id <> br THEN RAISE EXCEPTION 'Request not found' USING ERRCODE = '23514'; END IF;
    IF req.status NOT IN ('approved', 'ordered') THEN RAISE EXCEPTION 'Only an approved request can be ordered' USING ERRCODE = '23514'; END IF;
  END IF;
  IF jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines') = 0 THEN RAISE EXCEPTION 'Add what is ordered' USING ERRCODE = '23514'; END IF;
  INSERT INTO public.purchase_orders (organization_id, branch_id, po_no, supplier_id, request_id, order_date, expected_on, notes, sent_to_supplier, created_by)
  VALUES (org, br, coalesce((SELECT max(po_no) FROM public.purchase_orders WHERE organization_id = org), 0) + 1, sup, req.id,
          public.org_today(org), nullif(p->>'expected_on', '')::date, nullif(btrim(p->>'notes'), ''), coalesce((p->>'sent_to_supplier')::boolean, false), auth.uid())
  RETURNING id INTO oid;
  FOR x IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    n := n + 1;
    k := coalesce(nullif(x->>'kind', ''), 'material');
    IF k = 'material' THEN
      IF nullif(x->>'quantity', '')::numeric IS NULL OR (x->>'quantity')::numeric <= 0 THEN RAISE EXCEPTION 'Line %: enter the quantity', n USING ERRCODE = '23514'; END IF;
      sq := public.material_stock_qty((x->>'material_id')::uuid, (x->>'unit_id')::uuid, (x->>'quantity')::numeric);
      IF sq IS NULL THEN RAISE EXCEPTION 'Line %: that unit is not one this material is counted in', n USING ERRCODE = '23514'; END IF;
      INSERT INTO public.purchase_order_lines (organization_id, order_id, line_no, kind, material_id, quantity, unit_id, stock_quantity, unit_price)
      VALUES (org, oid, n, 'material', (x->>'material_id')::uuid, (x->>'quantity')::numeric, (x->>'unit_id')::uuid, sq, nullif(x->>'unit_price', '')::numeric);
    ELSE
      IF NOT EXISTS (SELECT 1 FROM public.expense_categories WHERE id = nullif(x->>'category_id', '')::uuid AND organization_id = org) THEN RAISE EXCEPTION 'Line %: choose what kind of expense', n USING ERRCODE = '23514'; END IF;
      IF nullif(btrim(x->>'description'), '') IS NULL THEN RAISE EXCEPTION 'Line %: say what it is', n USING ERRCODE = '23514'; END IF;
      IF nullif(x->>'meter_id', '') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.power_meters WHERE id = (x->>'meter_id')::uuid AND branch_id = br) THEN
        RAISE EXCEPTION 'Line %: that meter is not at this branch', n USING ERRCODE = '23514';
      END IF;
      INSERT INTO public.purchase_order_lines (organization_id, order_id, line_no, kind, category_id, meter_id, description, quantity, unit_text, amount, request_line_id)
      VALUES (org, oid, n, 'expense', (x->>'category_id')::uuid, nullif(x->>'meter_id', '')::uuid, btrim(x->>'description'), nullif(x->>'quantity', '')::numeric,
              nullif(btrim(x->>'unit_text'), ''), round(nullif(x->>'amount', '')::numeric, 2), nullif(x->>'request_line_id', '')::uuid);
    END IF;
  END LOOP;
  IF req.id IS NOT NULL THEN UPDATE public.purchase_requests SET status = 'ordered' WHERE id = req.id; END IF;
  RETURN oid;
END;
$$;

-- an order closes itself once everything on it has come: materials received, expenses recorded
CREATE OR REPLACE FUNCTION public.close_order_if_complete(p_order uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.purchase_order_receipts r WHERE r.order_id = p_order AND r.received < r.ordered - 1e-9)
     AND NOT EXISTS (SELECT 1 FROM public.purchase_order_lines l WHERE l.order_id = p_order AND l.kind = 'expense'
                     AND NOT EXISTS (SELECT 1 FROM public.expenses e WHERE e.order_line_id = l.id AND e.status = 'recorded')) THEN
    UPDATE public.purchase_orders SET status = 'closed', close_reason = coalesce(close_reason, 'Received in full') WHERE id = p_order AND status = 'open';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.close_order_if_complete(uuid) FROM PUBLIC, anon, authenticated;

-- 077's receipts view: material lines only (expense lines are closed by their expense)
CREATE OR REPLACE VIEW public.purchase_order_receipts WITH (security_invoker = true) AS
SELECT l.id AS order_line_id, l.order_id, l.material_id, l.stock_quantity AS ordered,
       coalesce((SELECT sum(t.quantity) FROM public.purchases pu
                   JOIN public.purchase_lines pl ON pl.purchase_id = pu.id
                   JOIN public.inventory_transactions t ON t.id = pl.transaction_id
                  WHERE pu.purchase_order_id = l.order_id AND pu.status = 'recorded' AND t.material_id = l.material_id), 0) AS received
FROM public.purchase_order_lines l WHERE l.kind = 'material';

-- an expense bought for an order line (and the request line behind it)
CREATE OR REPLACE FUNCTION public.link_expense_to_order_line(p_expense uuid, p_line uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ex public.expenses;
  l  public.purchase_order_lines;
  po public.purchase_orders;
BEGIN
  SELECT * INTO ex FROM public.expenses WHERE id = p_expense AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Expense not found' USING ERRCODE = '23514'; END IF;
  SELECT * INTO l FROM public.purchase_order_lines WHERE id = p_line AND kind = 'expense';
  IF NOT FOUND THEN RAISE EXCEPTION 'Order line not found' USING ERRCODE = '23514'; END IF;
  SELECT * INTO po FROM public.purchase_orders WHERE id = l.order_id;
  IF po.branch_id <> ex.branch_id THEN RAISE EXCEPTION 'The order is for another branch' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.receive', ex.branch_id, NULL) AND NOT public.has_permission_at('cash.approve', ex.branch_id, NULL) THEN
    RAISE EXCEPTION 'You can''t record against orders at this branch' USING ERRCODE = '42501';
  END IF;
  UPDATE public.expenses SET order_line_id = l.id, request_line_id = coalesce(request_line_id, l.request_line_id) WHERE id = ex.id;
  -- the request is done once its expense lines are recorded and nothing else is open on it
  IF l.request_line_id IS NOT NULL THEN
    UPDATE public.purchase_requests q SET status = 'done'
     WHERE q.id = (SELECT request_id FROM public.purchase_request_lines WHERE id = l.request_line_id)
       AND NOT EXISTS (SELECT 1 FROM public.purchase_request_lines rl WHERE rl.request_id = q.id AND rl.kind = 'expense'
                       AND NOT EXISTS (SELECT 1 FROM public.expenses e WHERE e.request_line_id = rl.id AND e.status = 'recorded'))
       AND NOT EXISTS (SELECT 1 FROM public.purchase_request_lines rl WHERE rl.request_id = q.id AND rl.kind = 'material');
  END IF;
  PERFORM public.close_order_if_complete(po.id);
END;
$$;

-- A top-up bought (081, widened): the request approved or ordered; recorded by the directors, or by the
-- secretary or branch manager when no director is available; the order line (if any) closes with it
-- p: { units, amount, token_no?, vat_amount?, ewura_levy?, rea_levy?, debt_deducted?, receipt_ref?, loaded_at?, paid_from? }
CREATE OR REPLACE FUNCTION public.buy_power_topup(p_request uuid, p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  q   public.purchase_requests;
  l   public.purchase_request_lines;
  ol  uuid;
  tid uuid;
  eid uuid;
BEGIN
  SELECT * INTO q FROM public.purchase_requests WHERE id = p_request AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Request not found' USING ERRCODE = '23514'; END IF;
  SELECT * INTO l FROM public.purchase_request_lines WHERE request_id = q.id AND meter_id IS NOT NULL LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'This is not a LUKU top-up' USING ERRCODE = '23514'; END IF;
  IF q.status NOT IN ('approved', 'ordered') THEN RAISE EXCEPTION 'The branch manager approves it first' USING ERRCODE = '23514'; END IF;
  IF NOT (public.has_permission_at('cash.approve', q.branch_id, NULL) OR public.has_permission_at('procurement.receive', q.branch_id, NULL)) THEN
    RAISE EXCEPTION 'You can''t record the token at this branch' USING ERRCODE = '42501';
  END IF;
  tid := public.record_power_token(p || jsonb_build_object('meter_id', l.meter_id, 'paid_from', coalesce(nullif(p->>'paid_from', ''), 'directors_account')));
  SELECT expense_id INTO eid FROM public.power_tokens WHERE id = tid;
  UPDATE public.expenses SET request_line_id = l.id, description = description || ' (request #' || q.request_no || ')' WHERE id = eid;
  SELECT pol.id INTO ol FROM public.purchase_order_lines pol JOIN public.purchase_orders po ON po.id = pol.order_id
   WHERE pol.request_line_id = l.id AND po.status = 'open' LIMIT 1;
  IF ol IS NOT NULL THEN
    UPDATE public.expenses SET order_line_id = ol WHERE id = eid;
    PERFORM public.close_order_if_complete((SELECT order_id FROM public.purchase_order_lines WHERE id = ol));
  END IF;
  UPDATE public.purchase_requests SET status = 'done' WHERE id = q.id;
  RETURN tid;
END;
$$;

REVOKE ALL ON FUNCTION public.link_expense_to_order_line(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.link_expense_to_order_line(uuid, uuid) TO authenticated;
