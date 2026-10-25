-- ============================================================
-- 065 — Sales, stage 2 (1e): deliveries and collections
--
-- SwahziTech, 2026-10-25, the user: goods leave finished goods on delivery
-- or collection, "up to what's been paid" — the value delivered on a sale
-- (at the sale's own prices with VAT) never exceeds the payments taken.
--   * a delivery is made against an order or an invoice, line by line, never
--     more than ordered; it leaves the branch's finished-goods store as a
--     'sale_delivery' movement (stock shown everywhere follows);
--   * its cost is the finished stock it took, first in first out (058–060):
--     production cost apart from estimated cost (stock with no production
--     cost, valued at its price without VAT) — the sale's margin is worked
--     out on what has been delivered;
--   * what an order or invoice holds (sales_availability) is what is still
--     to be delivered;
--   * secretaries and branch managers (sales.create) or storekeepers
--     (inventory.issue at the store) record deliveries.
-- ============================================================

ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_movement_type_check;
ALTER TABLE public.inventory_movements ADD CONSTRAINT inventory_movements_movement_type_check
  CHECK (movement_type IN ('opening_balance', 'receipt', 'issue', 'transfer', 'adjustment', 'count', 'reversal', 'reclassification',
                           'production_use', 'production_output', 'curing_release', 'waste', 'sale_delivery'));
ALTER TABLE public.inventory_transactions DROP CONSTRAINT inventory_transactions_transaction_type_check;
ALTER TABLE public.inventory_transactions ADD CONSTRAINT inventory_transactions_transaction_type_check
  CHECK (transaction_type IN ('opening_balance', 'receipt', 'issue', 'transfer_out', 'transfer_in', 'adjustment', 'count', 'reversal', 'reclassification',
                              'production_use', 'production_output', 'curing_out', 'curing_in', 'waste', 'sale_delivery'));
ALTER TABLE public.inventory_movements ADD COLUMN sale_id uuid REFERENCES public.sales(id);

CREATE TABLE public.sale_deliveries (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  sale_id         uuid NOT NULL REFERENCES public.sales(id) ON DELETE RESTRICT,
  delivery_no     int  NOT NULL,
  kind            text NOT NULL CHECK (kind IN ('delivery', 'collection')),
  delivered_on    date NOT NULL,
  warehouse_id    uuid NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  movement_id     uuid NOT NULL REFERENCES public.inventory_movements(id),
  received_by     text,                       -- who took the goods (name)
  vehicle         text,                       -- vehicle / driver, for a delivery
  notes           text,
  value           numeric NOT NULL,           -- at the sale's prices with VAT
  cost            numeric,                    -- production cost of the stock taken (NULL: none known)
  estimated_cost  numeric NOT NULL DEFAULT 0, -- part of it estimated at the price without VAT
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, delivery_no)
);
CREATE TABLE public.sale_delivery_lines (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  delivery_id     uuid NOT NULL REFERENCES public.sale_deliveries(id) ON DELETE RESTRICT,
  sale_line_id    uuid NOT NULL REFERENCES public.sale_lines(id) ON DELETE RESTRICT,
  quantity        numeric NOT NULL CHECK (quantity > 0),
  value           numeric NOT NULL,
  cost            numeric,
  estimated_cost  numeric NOT NULL DEFAULT 0
);
CREATE INDEX idx_sale_deliveries_sale ON public.sale_deliveries (sale_id);
CREATE INDEX idx_sale_delivery_lines_line ON public.sale_delivery_lines (sale_line_id);
CREATE TRIGGER trg_sale_deliveries_audit AFTER INSERT OR UPDATE OR DELETE ON public.sale_deliveries FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('sale_delivery', 'id');
CREATE TRIGGER trg_sale_deliveries_no_delete BEFORE DELETE ON public.sale_deliveries FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('delivery');
ALTER TABLE public.sale_deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_delivery_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sale_deliveries: read with the sale" ON public.sale_deliveries FOR SELECT
  USING (organization_id = public.get_my_org_id() AND EXISTS (SELECT 1 FROM public.sales s WHERE s.id = sale_id AND public.has_permission_at('sales.view', s.branch_id, NULL)));
CREATE POLICY "sale_delivery_lines: read with the delivery" ON public.sale_delivery_lines FOR SELECT
  USING (organization_id = public.get_my_org_id() AND EXISTS (SELECT 1 FROM public.sale_deliveries d JOIN public.sales s ON s.id = d.sale_id
         WHERE d.id = delivery_id AND public.has_permission_at('sales.view', s.branch_id, NULL)));


-- ------------------------------------------------------------
-- Record a delivery or collection
-- p: { kind: 'delivery' | 'collection', warehouse_id?, received_by?, vehicle?, notes?,
--      lines: [{ sale_line_id, quantity }] }
-- ------------------------------------------------------------
CREATE FUNCTION public.record_sale_delivery(p_sale uuid, p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s       public.sales;
  wh      public.warehouses;
  l       jsonb;
  sl      public.sale_lines;
  prod    public.products;
  qty     numeric;
  done    numeric;
  val     numeric := 0;
  lv      numeric;
  paid    numeric;
  given   numeric;
  mv      uuid;
  did     uuid;
  b0      record;
  b1      record;
  today   date;
BEGIN
  SELECT * INTO s FROM public.sales WHERE id = p_sale AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
  IF s.stage NOT IN ('order', 'invoice') THEN RAISE EXCEPTION 'Goods leave on an order or an invoice' USING ERRCODE = '23514'; END IF;
  today := public.org_today(s.organization_id);
  IF nullif(p->>'warehouse_id', '') IS NOT NULL THEN
    SELECT * INTO wh FROM public.warehouses WHERE id = (p->>'warehouse_id')::uuid AND branch_id = s.branch_id AND type = 'finished_goods' AND status = 'active';
  ELSE
    SELECT * INTO wh FROM public.warehouses WHERE branch_id = s.branch_id AND type = 'finished_goods' AND status = 'active' ORDER BY name LIMIT 1;
  END IF;
  IF wh.id IS NULL THEN RAISE EXCEPTION 'This branch has no finished-goods store' USING ERRCODE = '23514'; END IF;
  IF NOT (public.has_permission_at('sales.create', s.branch_id, NULL) OR public.has_permission_at('inventory.issue', s.branch_id, wh.id)) THEN
    RAISE EXCEPTION 'You can''t record deliveries at this branch' USING ERRCODE = '42501';
  END IF;
  IF coalesce(p->>'kind', '') NOT IN ('delivery', 'collection') THEN RAISE EXCEPTION 'Say whether it is delivered or collected' USING ERRCODE = '23514'; END IF;
  IF jsonb_array_length(coalesce(p->'lines', '[]'::jsonb)) = 0 THEN RAISE EXCEPTION 'Enter what leaves' USING ERRCODE = '23514'; END IF;

  -- the value of this delivery at the sale's prices with VAT; never more than ordered
  FOR l IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    SELECT * INTO sl FROM public.sale_lines WHERE id = nullif(l->>'sale_line_id', '')::uuid AND sale_id = s.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'A line is not on this sale' USING ERRCODE = '23514'; END IF;
    qty := nullif(l->>'quantity', '')::numeric;
    CONTINUE WHEN qty IS NULL OR qty = 0;
    IF qty < 0 THEN RAISE EXCEPTION 'Quantities are zero or more' USING ERRCODE = '23514'; END IF;
    SELECT coalesce(sum(dl.quantity), 0) INTO done FROM public.sale_delivery_lines dl WHERE dl.sale_line_id = sl.id;
    IF qty > sl.quantity - done + 1e-9 THEN
      RAISE EXCEPTION '%: only % left to deliver', (SELECT canonical_name FROM public.products WHERE id = sl.product_id), trim_scale(sl.quantity - done) USING ERRCODE = '23514';
    END IF;
    val := val + round(sl.total * qty / sl.quantity, 2);
  END LOOP;
  IF val = 0 THEN RAISE EXCEPTION 'Enter what leaves' USING ERRCODE = '23514'; END IF;
  -- up to what has been paid
  SELECT coalesce(sum(amount), 0) INTO paid FROM public.sale_payments WHERE sale_id = s.id;
  SELECT coalesce(sum(value), 0) INTO given FROM public.sale_deliveries WHERE sale_id = s.id;
  IF given + val > paid + 0.01 THEN
    RAISE EXCEPTION 'Goods worth % can leave — paid %, already delivered %. Record a payment first.',
      to_char(greatest(paid - given, 0), 'FM999G999G990D00'), to_char(paid, 'FM999G999G990D00'), to_char(given, 'FM999G999G990D00') USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, reference, created_by, sale_id)
  VALUES (s.organization_id, 'sale_delivery', s.branch_id, wh.id, today,
          CASE p->>'kind' WHEN 'collection' THEN 'Collected by the customer' ELSE 'Delivered to the customer' END,
          'Sale #' || s.sale_no, auth.uid(), s.id)
  RETURNING id INTO mv;
  INSERT INTO public.sale_deliveries (organization_id, sale_id, delivery_no, kind, delivered_on, warehouse_id, movement_id, received_by, vehicle, notes, value, created_by)
  VALUES (s.organization_id, s.id, coalesce((SELECT max(delivery_no) FROM public.sale_deliveries WHERE organization_id = s.organization_id), 0) + 1,
          p->>'kind', today, wh.id, mv, nullif(btrim(p->>'received_by'), ''), nullif(btrim(p->>'vehicle'), ''), nullif(btrim(p->>'notes'), ''), val, auth.uid())
  RETURNING id INTO did;

  -- line by line: out of stock, its cost first in first out (the value of the stock before less after)
  FOR l IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    qty := nullif(l->>'quantity', '')::numeric;
    CONTINUE WHEN qty IS NULL OR qty = 0;
    SELECT * INTO sl FROM public.sale_lines WHERE id = (l->>'sale_line_id')::uuid;
    SELECT * INTO prod FROM public.products WHERE id = sl.product_id;
    SELECT * INTO b0 FROM public.product_stock_value(s.branch_id, sl.product_id, sl.color_id);
    PERFORM public.production_ledger_line(mv, 'sale_delivery', wh, NULL, sl.product_id, sl.color_id, -qty, sl.unit_id, qty, sl.unit_id, today, prod.canonical_name);
    SELECT * INTO b1 FROM public.product_stock_value(s.branch_id, sl.product_id, sl.color_id);
    lv := round(sl.total * qty / sl.quantity, 2);
    INSERT INTO public.sale_delivery_lines (organization_id, delivery_id, sale_line_id, quantity, value, cost, estimated_cost)
    VALUES (s.organization_id, did, sl.id, qty, lv,
            CASE WHEN b0.value IS NOT NULL THEN round(coalesce(b0.value, 0) - coalesce(b1.value, 0), 2) END,
            round(coalesce(b0.estimated_value, 0) - coalesce(b1.estimated_value, 0), 2));
  END LOOP;
  UPDATE public.sale_deliveries d SET cost = x.c, estimated_cost = x.e
    FROM (SELECT sum(cost) AS c, sum(estimated_cost) AS e FROM public.sale_delivery_lines WHERE delivery_id = did) x
   WHERE d.id = did;
  RETURN did;
END;
$$;
REVOKE ALL ON FUNCTION public.record_sale_delivery(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_sale_delivery(uuid, jsonb) TO authenticated;


-- What is held: what is still to be delivered (deliveries are posted today — no back-dating)
CREATE OR REPLACE FUNCTION public.sales_availability(p_branch_id uuid)
RETURNS TABLE (product_id uuid, color_id uuid, on_hand numeric, reserved numeric, available numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH stock AS (
    SELECT t.product_id, t.color_id, sum(t.quantity) AS q
      FROM public.inventory_transactions t JOIN public.warehouses w ON w.id = t.warehouse_id
     WHERE w.branch_id = p_branch_id AND w.type = 'finished_goods' AND t.product_id IS NOT NULL
       AND t.organization_id = public.get_my_org_id()
     GROUP BY 1, 2
  ), held AS (   -- still to be delivered on open orders and invoices (065)
    SELECT l.product_id, l.color_id,
           sum(l.quantity - coalesce((SELECT sum(dl.quantity) FROM public.sale_delivery_lines dl WHERE dl.sale_line_id = l.id), 0)) AS q
      FROM public.sale_lines l JOIN public.sales s ON s.id = l.sale_id
     WHERE s.branch_id = p_branch_id AND s.stage IN ('order', 'invoice') AND s.organization_id = public.get_my_org_id()
     GROUP BY 1, 2
  )
  SELECT coalesce(st.product_id, h.product_id), coalesce(st.color_id, h.color_id),
         coalesce(st.q, 0), coalesce(h.q, 0), coalesce(st.q, 0) - coalesce(h.q, 0)
    FROM stock st FULL JOIN held h ON h.product_id = st.product_id AND h.color_id IS NOT DISTINCT FROM st.color_id
$$;

-- a sale with goods delivered can't be cancelled (its stock has left)
CREATE OR REPLACE FUNCTION public.check_sale_cancel()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.stage = 'cancelled' AND OLD.stage <> 'cancelled' AND EXISTS (SELECT 1 FROM public.sale_deliveries WHERE sale_id = NEW.id) THEN
    RAISE EXCEPTION 'Goods have left on this sale — it can''t be cancelled' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_sale_cancel BEFORE UPDATE OF stage ON public.sales FOR EACH ROW EXECUTE FUNCTION public.check_sale_cancel();
