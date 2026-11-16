-- ============================================================
-- 131 — A paid order stays on Orders until it is recorded as a purchase
-- ============================================================
-- SwahziTech, 2026-11-16 (the user): "the paid order should stay on orders, its status paid, until the
-- BM / secretary add it to purchases." Replaces 129's way (paying made the purchase at once):
--   * pay_purchase_order: the director's payment is kept on the order (amount_paid, paid_on, account);
--     part payments add up, never above the order's value. The order stays open: Paid / Part paid.
--   * the BM or secretary records the purchase from the order (filled in, the payment included); when
--     the purchase is linked to the order, the director's proof moves onto the purchase, and an order
--     bought as "coming later" is closed (its goods are followed on the purchase) — its request is done.
-- purchase_from_order (129) stays but the Pay window no longer uses it.
-- ============================================================

ALTER TABLE public.purchase_orders
  ADD COLUMN amount_paid     numeric NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
  ADD COLUMN paid_on         date,
  ADD COLUMN paid_account_id uuid REFERENCES public.payment_accounts(id) ON DELETE SET NULL;

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
  IF EXISTS (SELECT 1 FROM public.purchases WHERE purchase_order_id = po.id AND status = 'recorded') THEN
    RAISE EXCEPTION 'This order is already a purchase — pay it under the supplier''s purchases' USING ERRCODE = '23514';
  END IF;
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
REVOKE ALL ON FUNCTION public.pay_purchase_order(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pay_purchase_order(uuid, jsonb) TO authenticated;

-- a purchase recorded from an order: the director's proof goes with it; bought "coming later" closes the order
CREATE OR REPLACE FUNCTION public.trg_purchase_takes_order()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.purchase_order_id IS NOT NULL AND NEW.purchase_order_id IS DISTINCT FROM OLD.purchase_order_id AND NEW.status = 'recorded' THEN
    UPDATE public.director_payments SET ref_id = NEW.id WHERE kind = 'supplier' AND ref_id = NEW.purchase_order_id;
    IF EXISTS (SELECT 1 FROM public.purchase_items WHERE purchase_id = NEW.id) THEN
      UPDATE public.purchase_orders SET status = 'closed', close_reason = coalesce(close_reason, 'Bought · goods coming')
       WHERE id = NEW.purchase_order_id AND status = 'open';
    END IF;
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER trg_purchases_take_order AFTER UPDATE OF purchase_order_id ON public.purchases
  FOR EACH ROW EXECUTE FUNCTION public.trg_purchase_takes_order();

-- the proof of an order paid first is kept on the order until its purchase is recorded (live definition, one check widened)
CREATE OR REPLACE FUNCTION public.post_director_payment(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  org  uuid := public.get_my_org_id();
  br   uuid := nullif(p->>'branch_id', '')::uuid;
  k    text := p->>'kind';
  ref  uuid := nullif(p->>'ref_id', '')::uuid;
  fp   text := nullif(btrim(p->>'file_path'), '');
  txt  text := nullif(btrim(p->>'sms_text'), '');
  amt  numeric := round(nullif(p->>'amount', '')::numeric, 2);
  dt   date := nullif(p->>'paid_on', '')::date;
  acc  uuid := nullif(p->>'account_id', '')::uuid;
  rid  uuid;
BEGIN
  IF br IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = br AND organization_id = org) THEN
    RAISE EXCEPTION 'Choose the branch' USING ERRCODE = '23514';
  END IF;
  IF NOT public.has_permission_at('finance.pay', br, NULL) THEN RAISE EXCEPTION 'Only directors record these payments' USING ERRCODE = '42501'; END IF;
  IF k IS NULL OR k NOT IN ('supplier', 'expense', 'weekly_cash', 'salaries', 'other') THEN RAISE EXCEPTION 'Choose what is paid' USING ERRCODE = '23514'; END IF;
  IF amt IS NULL OR amt <= 0 THEN RAISE EXCEPTION 'Enter the amount' USING ERRCODE = '23514'; END IF;
  IF dt IS NULL OR dt > public.org_today(org) THEN RAISE EXCEPTION 'Choose the date it was paid' USING ERRCODE = '23514'; END IF;
  IF fp IS NULL AND txt IS NULL THEN RAISE EXCEPTION 'Add the proof: a photo or the SMS' USING ERRCODE = '23514'; END IF;
  IF fp IS NOT NULL AND fp NOT LIKE org::text || '/' || br::text || '/%' THEN RAISE EXCEPTION 'That file belongs elsewhere' USING ERRCODE = '42501'; END IF;
  IF acc IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.payment_accounts WHERE id = acc AND organization_id = org) THEN
    RAISE EXCEPTION 'Account not found' USING ERRCODE = '23514';
  END IF;
  -- the thing paid belongs to this company and branch
  IF k = 'supplier' AND NOT EXISTS (SELECT 1 FROM public.purchases WHERE id = ref AND organization_id = org AND branch_id = br)
     AND NOT EXISTS (SELECT 1 FROM public.purchase_orders WHERE id = ref AND organization_id = org AND branch_id = br) THEN   -- 131: an order paid first
    RAISE EXCEPTION 'Choose the purchase' USING ERRCODE = '23514';
  ELSIF k = 'expense' AND ref IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.expenses WHERE id = ref AND organization_id = org AND branch_id = br) THEN
    RAISE EXCEPTION 'Expense not found' USING ERRCODE = '23514';
  ELSIF k = 'weekly_cash' AND NOT EXISTS (SELECT 1 FROM public.cash_requests WHERE id = ref AND organization_id = org AND branch_id = br) THEN
    RAISE EXCEPTION 'Choose the weekly request' USING ERRCODE = '23514';
  ELSIF k = 'salaries' AND NOT EXISTS (SELECT 1 FROM public.pay_sheets WHERE id = ref AND organization_id = org AND branch_id = br) THEN
    RAISE EXCEPTION 'Choose the pay sheet' USING ERRCODE = '23514';
  ELSIF k IN ('expense', 'other') AND ref IS NULL AND nullif(btrim(p->>'description'), '') IS NULL THEN
    RAISE EXCEPTION 'Write what was paid' USING ERRCODE = '23514';
  END IF;
  INSERT INTO public.director_payments (organization_id, branch_id, kind, ref_id, description, amount, account_id, paid_on, file_path, file_name, sms_text, created_by)
  VALUES (org, br, k, ref, nullif(btrim(p->>'description'), ''), amt, acc, dt, fp, nullif(btrim(p->>'file_name'), ''), txt, auth.uid())
  RETURNING id INTO rid;
  -- the director who paid has seen it
  INSERT INTO public.director_payment_seen (payment_id, user_id, organization_id) VALUES (rid, auth.uid(), org);
  RETURN rid;
END;
$function$;
