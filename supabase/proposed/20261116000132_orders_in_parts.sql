-- ============================================================
-- 132 — An order paid and bought in parts
-- ============================================================
-- SwahziTech, 2026-11-16 (the user): "the request can ask 3m, the director can pay 2m; the users record
-- what was paid, and decide whether to close the order or leave its partial part."
--   * the directors may pay an order again after part of it was recorded as a purchase (131 refused),
--     up to the order's value;
--   * recording a purchase from an order no longer closes the order by itself: the person recording
--     closes it (the rest is not needed) or keeps it open for the rest; when everything ordered is bought
--     it is closed for them (from the app). The director's proof still moves onto the purchase.
-- ============================================================

CREATE OR REPLACE FUNCTION public.pay_purchase_order(p_order uuid, p jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  po  public.purchase_orders;
  amt numeric := round(nullif(p->>'amount', '')::numeric, 2);
  val numeric;
BEGIN
  SELECT * INTO po FROM public.purchase_orders WHERE id = p_order AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE = '23514'; END IF;
  IF po.status <> 'open' THEN RAISE EXCEPTION 'This order is closed' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('finance.pay', po.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t pay at this branch' USING ERRCODE = '42501'; END IF;
  IF amt IS NULL OR amt <= 0 THEN RAISE EXCEPTION 'Enter the amount' USING ERRCODE = '23514'; END IF;
  SELECT coalesce(sum(quantity * coalesce(unit_price, 0)), 0) INTO val FROM public.purchase_order_lines WHERE order_id = po.id AND kind = 'material';
  IF po.amount_paid + amt > round(val, 2) + 0.01 THEN
    RAISE EXCEPTION 'That is more than the order''s value (still to pay: %)', round(val - po.amount_paid, 2) USING ERRCODE = '23514';
  END IF;
  UPDATE public.purchase_orders
     SET amount_paid = po.amount_paid + amt,
         paid_on = coalesce(nullif(p->>'paid_on', '')::date, public.org_today(po.organization_id)),
         paid_account_id = coalesce(nullif(p->>'account_id', '')::uuid, po.paid_account_id)
   WHERE id = po.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_purchase_takes_order()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.purchase_order_id IS NOT NULL AND NEW.purchase_order_id IS DISTINCT FROM OLD.purchase_order_id AND NEW.status = 'recorded' THEN
    -- the director's proof of what was paid on the order goes with the purchase recorded from it
    UPDATE public.director_payments SET ref_id = NEW.id WHERE kind = 'supplier' AND ref_id = NEW.purchase_order_id;
  END IF;
  RETURN NULL;
END;
$$;
