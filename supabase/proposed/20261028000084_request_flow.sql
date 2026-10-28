-- ============================================================
-- 084 — One flow for every request, from its row
--
-- SwahziTech, 2026-10-28: a request is followed from its own row in
-- Purchases › Requests — waiting → approved → ordered → done. Once ordered,
-- the order can be edited (while nothing has come) or completed by
-- confirming what was bought: goods received, expenses or LUKU tokens
-- recorded. The order closes itself when everything has come, and its
-- request is then done; closing an order by hand closes its request too.
-- ============================================================

-- edit an open order while nothing has been received — p: { expected_on?, notes?, lines: [{ id, quantity?, unit_price?, amount? }] }
CREATE OR REPLACE FUNCTION public.update_purchase_order(p_id uuid, p jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  po public.purchase_orders;
  x  jsonb;
  l  public.purchase_order_lines;
  q  numeric;
BEGIN
  SELECT * INTO po FROM public.purchase_orders WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.order', po.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change purchase orders at this branch' USING ERRCODE = '42501'; END IF;
  IF po.status <> 'open' THEN RAISE EXCEPTION 'Only an open order can be changed' USING ERRCODE = '23514'; END IF;
  IF EXISTS (SELECT 1 FROM public.purchases WHERE purchase_order_id = po.id AND status = 'recorded')
     OR EXISTS (SELECT 1 FROM public.expenses e JOIN public.purchase_order_lines ol ON ol.id = e.order_line_id WHERE ol.order_id = po.id AND e.status = 'recorded') THEN
    RAISE EXCEPTION 'Something has already come against this order — it can''t be changed' USING ERRCODE = '23514';
  END IF;
  UPDATE public.purchase_orders SET expected_on = CASE WHEN p ? 'expected_on' THEN nullif(p->>'expected_on', '')::date ELSE expected_on END,
         notes = CASE WHEN p ? 'notes' THEN nullif(btrim(p->>'notes'), '') ELSE notes END WHERE id = po.id;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p->'lines', '[]'::jsonb)) LOOP
    SELECT * INTO l FROM public.purchase_order_lines WHERE id = (x->>'id')::uuid AND order_id = po.id;
    IF NOT FOUND THEN CONTINUE; END IF;
    q := coalesce(nullif(x->>'quantity', '')::numeric, l.quantity);
    IF q IS NOT NULL AND q <= 0 THEN RAISE EXCEPTION 'A quantity must be above zero' USING ERRCODE = '23514'; END IF;
    UPDATE public.purchase_order_lines SET
      quantity = q,
      stock_quantity = CASE WHEN l.kind = 'material' THEN public.material_stock_qty(l.material_id, l.unit_id, q) ELSE stock_quantity END,
      unit_price = CASE WHEN l.kind = 'material' AND x ? 'unit_price' THEN nullif(x->>'unit_price', '')::numeric ELSE unit_price END,
      amount = CASE WHEN l.kind = 'expense' AND x ? 'amount' THEN round(nullif(x->>'amount', '')::numeric, 2) ELSE amount END
    WHERE id = l.id;
  END LOOP;
END;
$$;

-- an order closes itself once everything on it has come (082), and its request is done
CREATE OR REPLACE FUNCTION public.close_order_if_complete(p_order uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.purchase_order_receipts r WHERE r.order_id = p_order AND r.received < r.ordered - 1e-9)
     AND NOT EXISTS (SELECT 1 FROM public.purchase_order_lines l WHERE l.order_id = p_order AND l.kind = 'expense'
                     AND NOT EXISTS (SELECT 1 FROM public.expenses e WHERE e.order_line_id = l.id AND e.status = 'recorded')) THEN
    UPDATE public.purchase_orders SET status = 'closed', close_reason = coalesce(close_reason, 'Received in full') WHERE id = p_order AND status = 'open';
    UPDATE public.purchase_requests SET status = 'done'
     WHERE id = (SELECT request_id FROM public.purchase_orders WHERE id = p_order) AND status = 'ordered';
  END IF;
END;
$$;

-- goods received against an order may complete it
CREATE OR REPLACE FUNCTION public.trg_purchase_completes_order()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.purchase_order_id IS NOT NULL THEN PERFORM public.close_order_if_complete(NEW.purchase_order_id); END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER trg_purchases_complete_order AFTER UPDATE OF purchase_order_id ON public.purchases
  FOR EACH ROW EXECUTE FUNCTION public.trg_purchase_completes_order();

-- closing an order by hand (the rest is not coming) closes its request; cancelling it puts the request back to approved
CREATE OR REPLACE FUNCTION public.trg_order_closes_request()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.request_id IS NOT NULL AND NEW.status IS DISTINCT FROM OLD.status THEN
    IF NEW.status = 'closed' THEN UPDATE public.purchase_requests SET status = 'done' WHERE id = NEW.request_id AND status = 'ordered';
    ELSIF NEW.status = 'cancelled' THEN UPDATE public.purchase_requests SET status = 'approved' WHERE id = NEW.request_id AND status = 'ordered';
    END IF;
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER trg_purchase_orders_request AFTER UPDATE OF status ON public.purchase_orders
  FOR EACH ROW EXECUTE FUNCTION public.trg_order_closes_request();

REVOKE ALL ON FUNCTION public.update_purchase_order(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_purchase_order(uuid, jsonb) TO authenticated;
