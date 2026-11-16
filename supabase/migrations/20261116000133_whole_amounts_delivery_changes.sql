-- ============================================================
-- 133 — Whole-shilling purchase totals, paid in full by agreement, deliveries changed
-- ============================================================
-- SwahziTech, 2026-11-16 (the user), "in the whole system": an amount set by quantity × price is
-- rounded to a whole figure (quantities to 3 decimals, 13.158), and a small gap left by the rounding
-- is taken as paid in full once the user confirms. Also, for a purchase bought from an order and
-- delivered in portions, "Change" changes only the deliveries: their date and quantity.
--   1. purchase_totals: the total in whole shillings; a purchase marked paid in full owes nothing.
--   2. settle_purchase: marks it paid in full when what is left is under 1% of the total.
--   3. change_purchase_delivery: a delivery's date / quantities changed — the old receipt is reversed
--      (kept in the stock history) and the delivery recorded again; quantity 0 everywhere removes it.
-- ============================================================

ALTER TABLE public.purchases ADD COLUMN settled boolean NOT NULL DEFAULT false;   -- paid in full by agreement (a rounding gap)

CREATE OR REPLACE VIEW public.purchase_totals
WITH (security_invoker = true) AS
SELECT p.id AS purchase_id, p.organization_id, p.branch_id,
       coalesce(s.subtotal, 0)                                                        AS subtotal,
       p.transport_charge,
       p.vat_amount,
       round(coalesce(s.subtotal, 0) + p.transport_charge
         + CASE WHEN p.prices_include_vat THEN 0 ELSE coalesce(p.vat_amount, 0) END, 0)  AS total,
       p.amount_paid,
       CASE WHEN p.settled THEN 0
            ELSE round(coalesce(s.subtotal, 0) + p.transport_charge
                 + CASE WHEN p.prices_include_vat THEN 0 ELSE coalesce(p.vat_amount, 0) END, 0) - p.amount_paid END AS balance,
       CASE WHEN p.status = 'void' THEN 'void'
            WHEN p.settled THEN 'paid'
            WHEN p.amount_paid <= 0 THEN 'unpaid'
            WHEN p.amount_paid >= round(coalesce(s.subtotal, 0) + p.transport_charge
                                  + CASE WHEN p.prices_include_vat THEN 0 ELSE coalesce(p.vat_amount, 0) END, 0) THEN 'paid'
            ELSE 'part_paid' END                                                     AS payment_status
FROM public.purchases p
LEFT JOIN LATERAL (SELECT coalesce((SELECT sum(line_amount) FROM public.purchase_items WHERE purchase_id = p.id),
                                   (SELECT sum(line_amount) FROM public.purchase_lines WHERE purchase_id = p.id)) AS subtotal) s ON true;

CREATE OR REPLACE FUNCTION public.settle_purchase(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  pu public.purchases;
  t  record;
BEGIN
  SELECT * INTO pu FROM public.purchases WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND OR pu.status <> 'recorded' THEN RAISE EXCEPTION 'Purchase not found' USING ERRCODE = '23514'; END IF;
  IF NOT (public.has_permission_at('procurement.receive', pu.branch_id, NULL) OR public.has_permission_at('finance.pay', pu.branch_id, NULL)) THEN
    RAISE EXCEPTION 'You can''t change purchases at this branch' USING ERRCODE = '42501';
  END IF;
  SELECT total, balance INTO t FROM public.purchase_totals WHERE purchase_id = pu.id;
  IF t.balance <= 0 THEN RETURN; END IF;
  IF pu.amount_paid <= 0 OR t.balance > t.total * 0.01 THEN
    RAISE EXCEPTION 'Only a small rounding gap can be taken as paid in full (still to pay: %)', t.balance USING ERRCODE = '23514';
  END IF;
  UPDATE public.purchases SET settled = true WHERE id = pu.id;
END;
$$;
REVOKE ALL ON FUNCTION public.settle_purchase(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.settle_purchase(uuid) TO authenticated;

-- a delivery's date or quantities changed: the old receipt reversed, the delivery recorded again
CREATE OR REPLACE FUNCTION public.change_purchase_delivery(p_delivery uuid, p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d     public.purchase_deliveries;
  pu    public.purchases;
  orig  public.inventory_movements;
  t     public.inventory_transactions;
  rev   uuid;
  uid   uuid := auth.uid();
  label text;
  place text;
  anyq  boolean;
BEGIN
  SELECT * INTO d FROM public.purchase_deliveries WHERE id = p_delivery AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Delivery not found' USING ERRCODE = '23514'; END IF;
  SELECT * INTO pu FROM public.purchases WHERE id = d.purchase_id FOR UPDATE;
  IF pu.status <> 'recorded' THEN RAISE EXCEPTION 'This purchase is void' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.receive', pu.branch_id, pu.warehouse_id) THEN
    RAISE EXCEPTION 'You can''t receive goods at this store' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO orig FROM public.inventory_movements WHERE id = d.movement_id FOR UPDATE;

  -- 1. the old receipt reversed (the stock history keeps both); nothing used from it may go below zero
  PERFORM set_config('mois.approved_change', 'on', true);
  INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, reverses_movement_id, movement_date, reason, reference, created_by)
  VALUES (orig.organization_id, 'reversal', orig.branch_id, orig.warehouse_id, orig.id, orig.movement_date, 'Delivery changed', orig.reference, uid)
  RETURNING id INTO rev;
  FOR t IN SELECT * FROM public.inventory_transactions WHERE movement_id = orig.id AND quantity <> 0 LOOP
    PERFORM public.inventory_lock_item(t.warehouse_id, t.material_id, t.product_id, t.color_id);
    SELECT m.name INTO label FROM public.materials m WHERE m.id = t.material_id;
    place := (SELECT b.name || ' — ' || w.name FROM public.warehouses w JOIN public.branches b ON b.id = w.branch_id WHERE w.id = t.warehouse_id);
    PERFORM public.inventory_check_outflow(t.warehouse_id, t.material_id, t.product_id, t.color_id, orig.movement_date, -t.quantity, label, place);
    INSERT INTO public.inventory_transactions (organization_id, movement_id, transaction_type, branch_id, warehouse_id, material_id, product_id, color_id,
       quantity, stock_unit_id, entered_quantity, entered_unit_id, transaction_date, created_by)
    VALUES (t.organization_id, rev, 'reversal', t.branch_id, t.warehouse_id, t.material_id, t.product_id, t.color_id,
       -t.quantity, t.stock_unit_id, t.entered_quantity, t.entered_unit_id, orig.movement_date, uid);
  END LOOP;
  PERFORM set_config('mois.approved_change', '', true);

  -- 2. the delivery's links gone (the purchase lines priced from it, the delivery itself)
  DELETE FROM public.purchase_lines WHERE purchase_id = pu.id AND transaction_id IN (SELECT id FROM public.inventory_transactions WHERE movement_id = orig.id);
  DELETE FROM public.purchase_deliveries WHERE id = d.id;

  -- 3. recorded again with the new date and quantities (all zero: the delivery is simply removed)
  SELECT coalesce(bool_or(nullif(x->>'quantity', '')::numeric > 0), false) INTO anyq FROM jsonb_array_elements(coalesce(p->'lines', '[]'::jsonb)) x;
  IF NOT anyq THEN RETURN NULL; END IF;
  RETURN public.record_purchase_delivery(pu.id, jsonb_build_object('delivered_on', coalesce(nullif(p->>'delivered_on', ''), d.delivered_on::text),
           'received_by', coalesce(p->>'received_by', d.received_by), 'lines', p->'lines'));
END;
$$;
REVOKE ALL ON FUNCTION public.change_purchase_delivery(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.change_purchase_delivery(uuid, jsonb) TO authenticated;
