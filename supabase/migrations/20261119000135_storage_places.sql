-- ============================================================
-- 135 — Storage places: where goods cure, wait and are sold from
--
-- A branch can have several curing places and several stores of ready
-- goods (Dodoma: vibro batches cure in the godown on racks, other products
-- cure in the yard; ready goods wait in the yard, and a shop in town keeps
-- its own stock). This makes MOIS follow that:
--
--   1. machines.curing_warehouse_id — where a machine's batches cure (a
--      curing store of the same branch). The production form uses it.
--   2. warehouses.receives_production — ready-goods stores quality release
--      puts goods into (a shop is not one). The first such store is the
--      default when nothing else says where.
--   3. sales.warehouse_id — the store a sale is sold from (a ready-goods
--      store of the sale's branch); set with set_sale_store().
--   4. sales_availability(branch, store) — what can be sold from one store:
--      its stock less what that store's open orders still hold (orders with
--      no store count against every store, as before).
--   5. record_sale_delivery() — a delivery with no store named takes the
--      sale's store, else the branch's first store that receives production
--      (it used to take the first ready-goods store by name).
-- ============================================================

ALTER TABLE public.machines
  ADD COLUMN curing_warehouse_id uuid REFERENCES public.warehouses(id) ON DELETE RESTRICT;
ALTER TABLE public.warehouses
  ADD COLUMN receives_production boolean NOT NULL DEFAULT true;
ALTER TABLE public.sales
  ADD COLUMN warehouse_id uuid REFERENCES public.warehouses(id) ON DELETE RESTRICT;

COMMENT ON COLUMN public.machines.curing_warehouse_id IS 'Where this machine''s batches cure (a curing store of the same branch); empty = asked on the production form.';
COMMENT ON COLUMN public.warehouses.receives_production IS 'A ready-goods store quality release can put goods into (a shop is not).';
COMMENT ON COLUMN public.sales.warehouse_id IS 'The ready-goods store this sale is sold from; empty = the branch''s production store.';

-- A store reference must be this row's branch, of the right kind
CREATE OR REPLACE FUNCTION public.check_store_ref()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ref  uuid;
  w    public.warehouses;
BEGIN
  EXECUTE format('SELECT ($1).%I', TG_ARGV[0]) USING NEW INTO ref;
  IF ref IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO w FROM public.warehouses WHERE id = ref;
  IF NOT FOUND OR w.organization_id <> NEW.organization_id OR w.branch_id <> NEW.branch_id OR w.type <> TG_ARGV[1] THEN
    RAISE EXCEPTION 'That store isn''t a % store of this branch', CASE TG_ARGV[1] WHEN 'wip' THEN 'curing' ELSE 'ready-goods' END
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_machines_curing_store
  BEFORE INSERT OR UPDATE OF curing_warehouse_id, branch_id ON public.machines
  FOR EACH ROW EXECUTE FUNCTION public.check_store_ref('curing_warehouse_id', 'wip');
CREATE TRIGGER trg_sales_store
  BEFORE INSERT OR UPDATE OF warehouse_id, branch_id ON public.sales
  FOR EACH ROW EXECUTE FUNCTION public.check_store_ref('warehouse_id', 'finished_goods');

-- The store a sale is sold from (like set_sale_site)
CREATE FUNCTION public.set_sale_store(p_sale uuid, p_warehouse uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.sales;
BEGIN
  SELECT * INTO s FROM public.sales WHERE id = p_sale AND organization_id = public.get_my_org_id();
  IF NOT FOUND OR s.stage = 'cancelled' THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('sales.create', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change sales at this branch' USING ERRCODE = '42501'; END IF;
  UPDATE public.sales SET warehouse_id = p_warehouse WHERE id = s.id;
END;
$$;
REVOKE ALL ON FUNCTION public.set_sale_store(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_sale_store(uuid, uuid) TO authenticated;

-- What can be sold, from one store or (no store) the whole branch
DROP FUNCTION public.sales_availability(uuid);
CREATE FUNCTION public.sales_availability(p_branch_id uuid, p_warehouse_id uuid DEFAULT NULL)
RETURNS TABLE (product_id uuid, color_id uuid, on_hand numeric, reserved numeric, available numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH stock AS (
    SELECT t.product_id, t.color_id, sum(t.quantity) AS q
      FROM public.inventory_transactions t JOIN public.warehouses w ON w.id = t.warehouse_id
     WHERE w.branch_id = p_branch_id AND w.type = 'finished_goods' AND t.product_id IS NOT NULL
       AND (p_warehouse_id IS NULL OR w.id = p_warehouse_id)
       AND t.organization_id = public.get_my_org_id()
     GROUP BY 1, 2
  ), held AS (   -- still to be delivered on open orders and invoices (065), from this store
    SELECT l.product_id, l.color_id,
           sum(l.quantity - coalesce((SELECT sum(dl.quantity) FROM public.sale_delivery_lines dl WHERE dl.sale_line_id = l.id), 0)) AS q
      FROM public.sale_lines l JOIN public.sales s ON s.id = l.sale_id
     WHERE s.branch_id = p_branch_id AND s.stage IN ('order', 'invoice') AND s.organization_id = public.get_my_org_id()
       AND (p_warehouse_id IS NULL OR s.warehouse_id IS NULL OR s.warehouse_id = p_warehouse_id)
     GROUP BY 1, 2
  )
  SELECT coalesce(st.product_id, h.product_id), coalesce(st.color_id, h.color_id),
         coalesce(st.q, 0), coalesce(h.q, 0), coalesce(st.q, 0) - coalesce(h.q, 0)
    FROM stock st FULL JOIN held h ON h.product_id = st.product_id AND h.color_id IS NOT DISTINCT FROM st.color_id
$$;
REVOKE ALL ON FUNCTION public.sales_availability(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sales_availability(uuid, uuid) TO authenticated;
COMMENT ON FUNCTION public.sales_availability(uuid, uuid)
  IS 'Ready goods that can be sold at a branch, or from one of its stores: stock less what open orders still hold.';

-- Deliveries: the sale's store when none is named (copied from 104, one line changed)
CREATE OR REPLACE FUNCTION public.record_sale_delivery(p_sale uuid, p jsonb)
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
    SELECT * INTO wh FROM public.warehouses WHERE branch_id = s.branch_id AND type = 'finished_goods' AND status = 'active'
     ORDER BY (id = s.warehouse_id) IS TRUE DESC, receives_production DESC, name LIMIT 1;   -- the sale's store, else where production goes (135)
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
    IF sl.product_id IS NULL THEN RAISE EXCEPTION '% is an other item — it isn''t delivered from stock', sl.item_name USING ERRCODE = '23514'; END IF;
    IF qty < 0 THEN RAISE EXCEPTION 'Quantities are zero or more' USING ERRCODE = '23514'; END IF;
    SELECT coalesce(sum(dl.quantity), 0) INTO done FROM public.sale_delivery_lines dl WHERE dl.sale_line_id = sl.id;
    IF qty > sl.quantity - done + 1e-9 THEN
      RAISE EXCEPTION '%: only % left to deliver', (SELECT canonical_name FROM public.products WHERE id = sl.product_id), trim_scale(sl.quantity - done) USING ERRCODE = '23514';
    END IF;
    val := val + round(sl.total * qty / sl.quantity, 2);
  END LOOP;
  IF val = 0 THEN RAISE EXCEPTION 'Enter what leaves' USING ERRCODE = '23514'; END IF;
  -- a sale carrying VAT leaves only with its EFD receipt (069): given here, or already on the sale
  IF nullif(btrim(p->>'efd_receipt_no'), '') IS NOT NULL THEN
    UPDATE public.sales SET efd_receipt_no = btrim(p->>'efd_receipt_no') WHERE id = s.id;
    s.efd_receipt_no := btrim(p->>'efd_receipt_no');
  END IF;
  IF s.vat > 0 AND s.efd_receipt_no IS NULL THEN
    RAISE EXCEPTION 'This sale carries VAT — enter the EFD receipt number before the goods leave' USING ERRCODE = '23514';
  END IF;
  -- up to what has been paid
  SELECT coalesce(sum(amount), 0) INTO paid FROM public.sale_payments WHERE sale_id = s.id;
  SELECT coalesce(sum(value), 0) INTO given FROM public.sale_deliveries WHERE sale_id = s.id;
  -- other items (104) were handed over with the sale: they count as given
  given := given + coalesce((SELECT sum(total) FROM public.sale_lines WHERE sale_id = s.id AND product_id IS NULL), 0);
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
