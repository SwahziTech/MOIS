-- ============================================================
-- 126 — Delivery dates for testing; cancelled sales deleted by the user
-- ============================================================
-- SwahziTech, 2026-11-16 (the user):
--   1. "Allow this for testing": a purchase paid as one and delivered in portions — whoever may
--      receive goods may date a delivery back (never before the purchase day, never in the future).
--      Before, an earlier date needed stock-adjustment permission. Only record_purchase_delivery sets
--      the flag; every other stock entry keeps the old rule. Revisit after testing.
--   2. A cancelled sale can be deleted for good by whoever may cancel it (sales.create at its branch),
--      when nothing was paid or delivered on it. Its lines and corrections go with it; a lead that
--      pointed to it keeps its record (link cleared). The audit log keeps a copy.
-- ============================================================

-- 1. the stock entry (live definition, one check changed)
CREATE OR REPLACE FUNCTION public.post_inventory_movement(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  org       uuid := public.get_my_org_id();
  uid       uuid := auth.uid();
  mtype     text := p->>'type';
  today     date;
  wh        public.warehouses;
  to_wh     public.warehouses;
  wh_label  text;
  to_label  text;
  perm      text;
  mdate     date;
  sup_id    uuid := nullif(p->>'supplier_id', '')::uuid;
  new_sup   text := nullif(btrim(p->>'new_supplier_name'), '');
  clash     text;
  mov_id    uuid;
  line      jsonb;
  n_lines   int;
  mat       public.materials;
  prod      public.products;
  item_mat  uuid;
  item_pro  uuid;
  item_col  uuid;
  item_name text;
  stock_u   uuid;
  factor    numeric;
  entered   numeric;
  qty       numeric;
  delta     numeric;
  seen      text[] := '{}';
BEGIN
  IF uid IS NULL OR org IS NULL THEN
    RAISE EXCEPTION 'Sign in to record stock movements' USING ERRCODE = '42501';
  END IF;
  today := public.org_today(org);
  mdate := coalesce(nullif(p->>'movement_date', '')::date, today);

  perm := CASE mtype
    WHEN 'opening_balance' THEN 'inventory.adjust'
    WHEN 'receipt'         THEN 'inventory.receive'
    WHEN 'issue'           THEN 'inventory.issue'
    WHEN 'transfer'        THEN 'inventory.transfer'
    WHEN 'adjustment'      THEN 'inventory.adjust'
    WHEN 'count'           THEN 'inventory.count'
  END;
  IF perm IS NULL THEN
    RAISE EXCEPTION 'Unknown movement type' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO wh FROM public.warehouses
  WHERE id = (p->>'warehouse_id')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Choose an active warehouse' USING ERRCODE = '23514';
  END IF;
  wh_label := (SELECT b.name FROM public.branches b WHERE b.id = wh.branch_id) || ' — ' || wh.name;
  IF NOT public.has_permission_at(perm, wh.branch_id, wh.id) THEN
    RAISE EXCEPTION 'You don''t have permission for this at %', wh_label USING ERRCODE = '42501';
  END IF;

  IF mdate > today THEN
    RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514';
  END IF;
  IF mdate < today AND NOT public.has_permission_at('inventory.adjust', wh.branch_id, wh.id)
     AND coalesce(current_setting('mois.delivery_backdate', true), '') <> 'on' THEN   -- 126: a purchase's delivery
    RAISE EXCEPTION 'Recording a movement for an earlier date (%) needs stock-adjustment permission at %', mdate, wh_label
      USING ERRCODE = '42501';
  END IF;

  IF mtype = 'transfer' THEN
    SELECT * INTO to_wh FROM public.warehouses
    WHERE id = (p->>'to_warehouse_id')::uuid AND organization_id = org AND status = 'active';
    IF NOT FOUND OR to_wh.id = wh.id THEN
      RAISE EXCEPTION 'Choose a different, active destination warehouse' USING ERRCODE = '23514';
    END IF;
    to_label := (SELECT b.name FROM public.branches b WHERE b.id = to_wh.branch_id) || ' — ' || to_wh.name;
  ELSIF nullif(p->>'to_warehouse_id', '') IS NOT NULL THEN
    RAISE EXCEPTION 'Only transfers have a destination' USING ERRCODE = '23514';
  END IF;

  IF sup_id IS NOT NULL OR new_sup IS NOT NULL THEN
    IF mtype <> 'receipt' THEN
      RAISE EXCEPTION 'Only receipts have a supplier' USING ERRCODE = '23514';
    END IF;
    IF sup_id IS NOT NULL AND new_sup IS NOT NULL THEN
      RAISE EXCEPTION 'Choose an existing supplier or a new one, not both' USING ERRCODE = '23514';
    END IF;
  END IF;
  IF sup_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id = sup_id AND organization_id = org) THEN
    RAISE EXCEPTION 'Supplier not found' USING ERRCODE = '23514';
  END IF;
  IF new_sup IS NOT NULL THEN
    SELECT name INTO clash FROM public.suppliers
    WHERE organization_id = org AND public.normalize_name(name) = public.normalize_name(new_sup);
    IF FOUND THEN
      RAISE EXCEPTION 'A supplier called "%" already exists — choose it instead', clash USING ERRCODE = '23505';
    END IF;
    IF public.normalize_name(new_sup) = '' THEN
      RAISE EXCEPTION 'Give the supplier a name' USING ERRCODE = '23514';
    END IF;
    INSERT INTO public.suppliers (organization_id, name) VALUES (org, new_sup) RETURNING id INTO sup_id;
  END IF;

  IF mtype = 'adjustment' AND nullif(btrim(p->>'reason'), '') IS NULL THEN
    RAISE EXCEPTION 'Give a reason for the adjustment' USING ERRCODE = '23514';
  END IF;

  n_lines := CASE WHEN jsonb_typeof(p->'lines') = 'array' THEN jsonb_array_length(p->'lines') ELSE 0 END;
  IF n_lines = 0 THEN
    RAISE EXCEPTION 'Add at least one item' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.inventory_movements
    (organization_id, movement_type, branch_id, warehouse_id, to_warehouse_id, supplier_id,
     movement_date, reason, reference, notes, created_by)
  VALUES
    (org, mtype, wh.branch_id, wh.id, to_wh.id, sup_id,
     mdate, nullif(btrim(p->>'reason'), ''), nullif(btrim(p->>'reference'), ''), nullif(btrim(p->>'notes'), ''), uid)
  RETURNING id INTO mov_id;

  FOR line IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    item_mat := nullif(line->>'material_id', '')::uuid;
    item_pro := nullif(line->>'product_id', '')::uuid;
    item_col := nullif(line->>'color_id', '')::uuid;
    IF num_nonnulls(item_mat, item_pro) <> 1 THEN
      RAISE EXCEPTION 'Each line needs one material or one product' USING ERRCODE = '23514';
    END IF;
    IF coalesce(item_mat, item_pro)::text || coalesce(item_col::text, '') = ANY (seen) THEN
      RAISE EXCEPTION 'An item appears twice — combine the lines' USING ERRCODE = '23514';
    END IF;
    seen := seen || (coalesce(item_mat, item_pro)::text || coalesce(item_col::text, ''));

    IF item_mat IS NOT NULL THEN
      IF item_col IS NOT NULL THEN
        RAISE EXCEPTION 'Materials are not stocked by colour' USING ERRCODE = '23514';
      END IF;
      SELECT * INTO mat FROM public.materials WHERE id = item_mat AND organization_id = org AND status = 'active';
      IF NOT FOUND THEN RAISE EXCEPTION 'Material not found or inactive' USING ERRCODE = '23514'; END IF;
      item_name := mat.name;
      stock_u := mat.stock_unit_id;
      IF stock_u IS NULL THEN
        RAISE EXCEPTION '%: set its stock unit under Materials first', mat.name USING ERRCODE = '23514';
      END IF;
      IF (line->>'unit_id')::uuid = stock_u THEN
        factor := 1;
      ELSE
        SELECT factor_to_stock_unit INTO factor FROM public.material_unit_conversions
        WHERE material_id = mat.id AND unit_id = (line->>'unit_id')::uuid;
        IF NOT FOUND THEN
          RAISE EXCEPTION '%: use its stock unit or one of its listed units', mat.name USING ERRCODE = '23514';
        END IF;
      END IF;
    ELSE
      SELECT * INTO prod FROM public.products WHERE id = item_pro AND organization_id = org AND status = 'active';
      IF NOT FOUND THEN RAISE EXCEPTION 'Product not found or inactive' USING ERRCODE = '23514'; END IF;
      item_name := prod.canonical_name;
      -- Coloured categories are stocked per colour; plain ones are not
      IF public.product_is_coloured(prod.id) THEN
        IF item_col IS NULL THEN
          RAISE EXCEPTION '%: choose the colour', prod.canonical_name USING ERRCODE = '23514';
        END IF;
        IF NOT public.product_color_ok(prod.id, item_col) THEN
          RAISE EXCEPTION '%: that colour isn''t one of its category''s colours', prod.canonical_name USING ERRCODE = '23514';
        END IF;
        item_name := item_name || ' ' || (SELECT name FROM public.color_palette WHERE id = item_col);
      ELSIF item_col IS NOT NULL THEN
        RAISE EXCEPTION '%: its category has no colours', prod.canonical_name USING ERRCODE = '23514';
      END IF;
      stock_u := prod.unit_id;
      IF (line->>'unit_id')::uuid IS DISTINCT FROM stock_u THEN
        RAISE EXCEPTION '%: record it in its stock unit', prod.canonical_name USING ERRCODE = '23514';
      END IF;
      factor := 1;
    END IF;

    entered := (line->>'quantity')::numeric;
    IF entered IS NULL
       OR (mtype = 'count' AND entered < 0)
       OR (mtype = 'adjustment' AND entered = 0)
       OR (mtype NOT IN ('count', 'adjustment') AND entered <= 0) THEN
      RAISE EXCEPTION '%: enter a valid quantity', item_name USING ERRCODE = '23514';
    END IF;
    IF nullif(line->>'unit_cost', '') IS NOT NULL AND mtype NOT IN ('receipt', 'opening_balance') THEN
      RAISE EXCEPTION 'Only receipts and opening balances carry a cost' USING ERRCODE = '23514';
    END IF;
    qty := entered * factor;

    PERFORM public.inventory_lock_item(wh.id, item_mat, item_pro, item_col);

    IF mtype = 'opening_balance' THEN
      IF EXISTS (SELECT 1 FROM public.inventory_transactions t
                 JOIN public.inventory_movements m ON m.id = t.movement_id
                 WHERE t.warehouse_id = wh.id AND t.material_id IS NOT DISTINCT FROM item_mat
                   AND t.product_id IS NOT DISTINCT FROM item_pro AND t.color_id IS NOT DISTINCT FROM item_col
                   AND NOT (m.movement_type = 'opening_balance'
                            AND EXISTS (SELECT 1 FROM public.inventory_movements r WHERE r.reverses_movement_id = m.id))
                   AND NOT (m.movement_type = 'reversal'
                            AND EXISTS (SELECT 1 FROM public.inventory_movements o
                                        WHERE o.id = m.reverses_movement_id AND o.movement_type = 'opening_balance'))) THEN
        RAISE EXCEPTION '%: already has stock movements here — use an adjustment or a count', item_name USING ERRCODE = '23514';
      END IF;
    ELSE
      PERFORM public.inventory_check_after_opening(wh.id, item_mat, item_pro, item_col, mdate, item_name, wh_label);
    END IF;

    delta := CASE mtype
      WHEN 'issue'    THEN -qty
      WHEN 'transfer' THEN -qty
      WHEN 'count'    THEN qty - public.inventory_balance_as_of(wh.id, item_mat, item_pro, item_col, mdate)
      ELSE qty
    END;
    PERFORM public.inventory_check_outflow(wh.id, item_mat, item_pro, item_col, mdate, delta, item_name, wh_label);

    INSERT INTO public.inventory_transactions
      (organization_id, movement_id, transaction_type, branch_id, warehouse_id, material_id, product_id, color_id,
       quantity, stock_unit_id, entered_quantity, entered_unit_id, counted_quantity, unit_cost, transaction_date, created_by)
    VALUES
      (org, mov_id, CASE mtype WHEN 'transfer' THEN 'transfer_out' ELSE mtype END,
       wh.branch_id, wh.id, item_mat, item_pro, item_col,
       delta, stock_u, entered, (line->>'unit_id')::uuid,
       CASE WHEN mtype = 'count' THEN qty END,
       nullif(line->>'unit_cost', '')::numeric, mdate, uid);

    IF mtype = 'transfer' THEN
      PERFORM public.inventory_lock_item(to_wh.id, item_mat, item_pro, item_col);
      PERFORM public.inventory_check_after_opening(to_wh.id, item_mat, item_pro, item_col, mdate, item_name, to_label);
      INSERT INTO public.inventory_transactions
        (organization_id, movement_id, transaction_type, branch_id, warehouse_id, material_id, product_id, color_id,
         quantity, stock_unit_id, entered_quantity, entered_unit_id, transaction_date, created_by)
      VALUES
        (org, mov_id, 'transfer_in', to_wh.branch_id, to_wh.id, item_mat, item_pro, item_col,
         qty, stock_u, entered, (line->>'unit_id')::uuid, mdate, uid);
    END IF;
  END LOOP;

  RETURN mov_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_purchase_delivery(p_purchase uuid, p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  pu   public.purchases;
  dt   date;
  x    jsonb;
  it   public.purchase_items;
  q    numeric;
  done numeric;
  rl   jsonb := '[]'::jsonb;
  mv   uuid;
  tx   public.inventory_transactions;
BEGIN
  SELECT * INTO pu FROM public.purchases WHERE id = p_purchase AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND OR pu.status <> 'recorded' THEN RAISE EXCEPTION 'Purchase not found' USING ERRCODE = '23514'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.purchase_items WHERE purchase_id = pu.id) THEN
    RAISE EXCEPTION 'This purchase came with its goods — nothing is waiting' USING ERRCODE = '23514';
  END IF;
  IF NOT public.has_permission_at('procurement.receive', pu.branch_id, pu.warehouse_id) THEN
    RAISE EXCEPTION 'You can''t receive goods at this store' USING ERRCODE = '42501';
  END IF;
  dt := coalesce(nullif(p->>'delivered_on', '')::date, public.org_today(pu.organization_id));
  IF dt > public.org_today(pu.organization_id) THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;
  IF dt < pu.purchase_date THEN RAISE EXCEPTION 'A delivery can''t be before the purchase' USING ERRCODE = '23514'; END IF;
  IF jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Enter what came' USING ERRCODE = '23514'; END IF;

  FOR x IN SELECT value FROM jsonb_array_elements(p->'lines') LOOP
    q := nullif(x->>'quantity', '')::numeric;
    CONTINUE WHEN q IS NULL OR q = 0;
    IF q < 0 THEN RAISE EXCEPTION 'A quantity can''t be below zero' USING ERRCODE = '23514'; END IF;
    SELECT * INTO it FROM public.purchase_items WHERE id = nullif(x->>'item_id', '')::uuid AND purchase_id = pu.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'That line isn''t on this purchase' USING ERRCODE = '23514'; END IF;
    SELECT coalesce(sum(t.entered_quantity), 0) INTO done
      FROM public.purchase_lines pl JOIN public.inventory_transactions t ON t.id = pl.transaction_id WHERE pl.item_id = it.id;
    IF done + q > it.quantity + 0.0001 THEN
      RAISE EXCEPTION '%: only % more to come (bought %)', (SELECT name FROM public.materials WHERE id = it.material_id),
        trim(to_char(it.quantity - done, 'FM999G999G990D####')), trim(to_char(it.quantity, 'FM999G999G990D####')) USING ERRCODE = '23514';
    END IF;
    rl := rl || jsonb_build_object('material_id', it.material_id, 'quantity', q, 'unit_id', it.unit_id);
  END LOOP;
  IF jsonb_array_length(rl) = 0 THEN RAISE EXCEPTION 'Enter what came' USING ERRCODE = '23514'; END IF;

  -- the receipt; for testing (126) whoever receives may date it back to the purchase day
  PERFORM set_config('mois.delivery_backdate', 'on', true);
  PERFORM set_config('mois.approved_change', 'on', true);
  mv := public.post_inventory_movement(jsonb_build_object('type', 'receipt', 'warehouse_id', pu.warehouse_id, 'movement_date', dt,
          'reference', coalesce(pu.invoice_reference, 'Purchase delivery'), 'lines', rl,
          'notes', 'Delivery for the purchase of ' || to_char(pu.purchase_date, 'DD Mon YYYY')));
  PERFORM set_config('mois.delivery_backdate', '', true);
  PERFORM set_config('mois.approved_change', '', true);
  FOR tx IN SELECT * FROM public.inventory_transactions WHERE movement_id = mv AND material_id IS NOT NULL LOOP
    SELECT * INTO it FROM public.purchase_items WHERE purchase_id = pu.id AND material_id = tx.material_id;
    INSERT INTO public.purchase_lines (organization_id, purchase_id, transaction_id, unit_price, line_amount, item_id)
    VALUES (pu.organization_id, pu.id, tx.id, it.unit_price, round(it.unit_price * tx.entered_quantity, 2), it.id);
  END LOOP;
  INSERT INTO public.purchase_deliveries (organization_id, purchase_id, movement_id, delivered_on, received_by, created_by)
  VALUES (pu.organization_id, pu.id, mv, dt, nullif(btrim(p->>'received_by'), ''), auth.uid());
  RETURN mv;
END;
$$;
REVOKE ALL ON FUNCTION public.record_purchase_delivery(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_purchase_delivery(uuid, jsonb) TO authenticated;

-- 2. the delete guard lets a cancelled sale through
CREATE OR REPLACE FUNCTION public.prevent_hard_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.role() = 'service_role' OR auth.uid() IS NULL THEN
    RETURN OLD;
  END IF;
  -- 068: a sale correction may remove a wrong payment (set only inside apply_sale_correction)
  IF TG_TABLE_NAME = 'sale_payments' AND coalesce(current_setting('mois.sale_correction', true), '') = 'on' THEN
    RETURN OLD;
  END IF;
  -- 123: an unwanted weekly cash import (set only inside delete_cash_request)
  IF TG_TABLE_NAME = 'cash_requests' AND coalesce(current_setting('mois.cash_request_delete', true), '') = 'on' THEN
    RETURN OLD;
  END IF;
  -- 125: a cancelled order or request (set only inside drop_cancelled_order)
  IF TG_TABLE_NAME IN ('purchase_orders', 'purchase_requests') AND coalesce(current_setting('mois.order_delete', true), '') = 'on' THEN
    RETURN OLD;
  END IF;
  -- 126: a cancelled sale deleted by the user (set only inside delete_cancelled_sale)
  IF TG_TABLE_NAME = 'sales' AND coalesce(current_setting('mois.sale_delete', true), '') = 'on' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION '% records cannot be deleted — deactivate them instead', TG_ARGV[0]
    USING ERRCODE = '42501';
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_cancelled_sale(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE s public.sales;
BEGIN
  SELECT * INTO s FROM public.sales WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
  IF s.stage <> 'cancelled' THEN RAISE EXCEPTION 'Only a cancelled sale can be deleted' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('sales.create', s.branch_id, NULL) THEN
    RAISE EXCEPTION 'You can''t delete sales at this branch' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM public.sale_payments WHERE sale_id = s.id) THEN
    RAISE EXCEPTION 'This sale has payments — it can''t be deleted' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (SELECT 1 FROM public.sale_deliveries WHERE sale_id = s.id)
     OR EXISTS (SELECT 1 FROM public.inventory_movements WHERE sale_id = s.id) THEN
    RAISE EXCEPTION 'Goods were delivered on this sale — it can''t be deleted' USING ERRCODE = '23514';
  END IF;
  UPDATE public.leads SET sale_id = NULL WHERE sale_id = s.id;
  DELETE FROM public.sale_corrections WHERE sale_id = s.id;
  PERFORM set_config('mois.sale_delete', 'on', true);
  DELETE FROM public.sales WHERE id = s.id;   -- its lines go with it
  PERFORM set_config('mois.sale_delete', '', true);
END;
$$;
REVOKE ALL ON FUNCTION public.delete_cancelled_sale(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_cancelled_sale(uuid) TO authenticated;
