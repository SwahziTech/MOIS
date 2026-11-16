-- ============================================================
-- 129 — Pay first: an approved order goes to the directors to pay
-- ============================================================
-- SwahziTech, 2026-11-16 (the user): once the branch manager approves a request and its order is made,
-- it goes straight to the directors to pay — before any purchase or delivery is recorded.
-- purchase_from_order(order): the director's Pay makes the purchase from the order, as "coming later"
-- (its items, the order's supplier and prices, the branch's raw-materials store, dated today), links
-- it to the order and closes the order (its request is then done). The payment and its proof follow
-- through the usual steps (record_purchase_payment, post_director_payment); deliveries are recorded on
-- the purchase as the goods arrive. Calling it again for the same order returns the same purchase.
-- Material orders only: an order with expense lines is paid as expenses, as before.
-- ============================================================

CREATE OR REPLACE FUNCTION public.purchase_from_order(p_order uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  po    public.purchase_orders;
  wh    uuid;
  pid   uuid;
  items jsonb;
BEGIN
  SELECT * INTO po FROM public.purchase_orders WHERE id = p_order AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE = '23514'; END IF;
  -- already made (a second click, or paid in parts): the same purchase
  SELECT id INTO pid FROM public.purchases WHERE purchase_order_id = po.id AND status = 'recorded' ORDER BY created_at LIMIT 1;
  IF pid IS NOT NULL THEN RETURN pid; END IF;
  IF po.status <> 'open' THEN RAISE EXCEPTION 'This order is closed' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.receive', po.branch_id, NULL) THEN
    RAISE EXCEPTION 'You can''t record purchases at this branch' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM public.purchase_order_lines WHERE order_id = po.id AND kind = 'expense') THEN
    RAISE EXCEPTION 'This order has expenses — record them as expenses' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (SELECT 1 FROM public.purchase_order_lines WHERE order_id = po.id AND unit_price IS NULL) THEN
    RAISE EXCEPTION 'Put a price on every line of the order first' USING ERRCODE = '23514';
  END IF;
  SELECT id INTO wh FROM public.warehouses
   WHERE branch_id = po.branch_id AND organization_id = po.organization_id AND type = 'raw_materials' AND status = 'active'
   ORDER BY created_at LIMIT 1;
  IF wh IS NULL THEN RAISE EXCEPTION 'The branch has no raw-materials store' USING ERRCODE = '23514'; END IF;

  SELECT jsonb_agg(jsonb_build_object('material_id', l.material_id, 'quantity', l.quantity, 'unit_id', l.unit_id, 'unit_price', l.unit_price) ORDER BY l.line_no)
    INTO items FROM public.purchase_order_lines l WHERE l.order_id = po.id;
  IF items IS NULL THEN RAISE EXCEPTION 'The order has nothing on it' USING ERRCODE = '23514'; END IF;

  pid := public.record_purchase(jsonb_build_object('supplier_id', po.supplier_id, 'coming_later', true, 'warehouse_id', wh,
           'purchase_date', public.org_today(po.organization_id), 'amount_paid', 0,
           'notes', 'From order #' || po.po_no, 'items', items));

  PERFORM set_config('mois.purchase_pay_sync', 'on', true);
  UPDATE public.purchases SET purchase_order_id = po.id WHERE id = pid;
  PERFORM set_config('mois.purchase_pay_sync', '', true);
  -- bought: the order (and its request) leave Orders; the goods are followed on the purchase
  UPDATE public.purchase_orders SET status = 'closed', close_reason = 'Paid · goods coming' WHERE id = po.id AND status = 'open';
  RETURN pid;
END;
$$;
REVOKE ALL ON FUNCTION public.purchase_from_order(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.purchase_from_order(uuid) TO authenticated;
