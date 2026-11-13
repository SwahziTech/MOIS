-- ============================================================
-- 120 — A purchase paid as one, delivered in portions
-- ============================================================
-- SwahziTech, 2026-11-13: a purchase is one record per supplier slip, with two tracks —
--   Paid      (payments, as before: not paid · part paid · paid)
--   Delivered (deliveries recorded against it: not delivered · part · delivered).
-- On the purchase form the person states it: the goods ARRIVED NOW (as before — the receipt
-- is posted with the purchase, delivered in full) or are COMING LATER (nothing into stock yet).
-- A purchase coming later keeps what was bought (purchase_items); each delivery is an ordinary
-- receipt into the purchase's store on its date, priced from the purchase (purchase_lines, as for
-- any purchase), never more than was bought. Who may record a delivery: whoever may receive
-- goods today (procurement.receive) — no role changes.
-- Costing: transport and VAT are shared over the WHOLE bought amount (not only what has come),
-- so a portion's cost doesn't move when the next portion arrives.
-- Every existing purchase arrived with its goods: delivered in full, nothing changes for it.
-- ============================================================

-- 1. a purchase without a receipt yet: its store
ALTER TABLE public.purchases ALTER COLUMN movement_id DROP NOT NULL;
ALTER TABLE public.purchases ADD COLUMN warehouse_id uuid REFERENCES public.warehouses(id) ON DELETE RESTRICT;
UPDATE public.purchases p SET warehouse_id = m.warehouse_id FROM public.inventory_movements m WHERE m.id = p.movement_id AND p.warehouse_id IS NULL;
ALTER TABLE public.purchases ADD CONSTRAINT purchases_receipt_or_store CHECK (movement_id IS NOT NULL OR warehouse_id IS NOT NULL);
COMMENT ON COLUMN public.purchases.warehouse_id IS 'The store the goods go into; for a purchase coming later, where its deliveries are received (120).';

-- 2. what was bought, for a purchase coming later
CREATE TABLE public.purchase_items (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  purchase_id     uuid NOT NULL REFERENCES public.purchases(id) ON DELETE CASCADE,
  line_no         integer NOT NULL,
  material_id     uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
  unit_id         uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  quantity        numeric NOT NULL CHECK (quantity > 0),        -- as bought, in unit_id
  stock_quantity  numeric NOT NULL CHECK (stock_quantity > 0),  -- the same in the material's stock unit
  unit_price      numeric NOT NULL CHECK (unit_price >= 0),     -- per unit_id
  line_amount     numeric NOT NULL CHECK (line_amount >= 0),
  UNIQUE (purchase_id, material_id)
);
CREATE INDEX idx_purchase_items_purchase ON public.purchase_items (purchase_id);
ALTER TABLE public.purchase_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "purchase_items: read own org" ON public.purchase_items FOR SELECT USING (organization_id = public.get_my_org_id());
GRANT SELECT ON public.purchase_items TO authenticated;
COMMENT ON TABLE public.purchase_items IS 'What a purchase coming later bought — delivered in portions against it (120).';

-- a delivered portion's priced line points at the item it delivers
ALTER TABLE public.purchase_lines ADD COLUMN item_id uuid REFERENCES public.purchase_items(id) ON DELETE SET NULL;

-- 3. the deliveries: each one a receipt into the store
CREATE TABLE public.purchase_deliveries (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  purchase_id     uuid NOT NULL REFERENCES public.purchases(id) ON DELETE CASCADE,
  movement_id     uuid NOT NULL UNIQUE REFERENCES public.inventory_movements(id) ON DELETE RESTRICT,
  delivered_on    date NOT NULL,
  received_by     text,
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_purchase_deliveries_purchase ON public.purchase_deliveries (purchase_id, delivered_on);
ALTER TABLE public.purchase_deliveries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "purchase_deliveries: read own org" ON public.purchase_deliveries FOR SELECT USING (organization_id = public.get_my_org_id());
GRANT SELECT ON public.purchase_deliveries TO authenticated;

-- 4. totals over what was BOUGHT (items when there are any, else the priced receipt lines — as before)
CREATE OR REPLACE VIEW public.purchase_totals
WITH (security_invoker = true) AS
SELECT p.id AS purchase_id, p.organization_id, p.branch_id,
       coalesce(s.subtotal, 0)                                                        AS subtotal,
       p.transport_charge,
       p.vat_amount,
       coalesce(s.subtotal, 0) + p.transport_charge
         + CASE WHEN p.prices_include_vat THEN 0 ELSE coalesce(p.vat_amount, 0) END  AS total,
       p.amount_paid,
       coalesce(s.subtotal, 0) + p.transport_charge
         + CASE WHEN p.prices_include_vat THEN 0 ELSE coalesce(p.vat_amount, 0) END - p.amount_paid AS balance,
       CASE WHEN p.status = 'void' THEN 'void'
            WHEN p.amount_paid <= 0 THEN 'unpaid'
            WHEN p.amount_paid >= coalesce(s.subtotal, 0) + p.transport_charge
                                  + CASE WHEN p.prices_include_vat THEN 0 ELSE coalesce(p.vat_amount, 0) END THEN 'paid'
            ELSE 'part_paid' END                                                     AS payment_status
FROM public.purchases p
LEFT JOIN LATERAL (SELECT coalesce((SELECT sum(line_amount) FROM public.purchase_items WHERE purchase_id = p.id),
                                   (SELECT sum(line_amount) FROM public.purchase_lines WHERE purchase_id = p.id)) AS subtotal) s ON true;

-- 5. a line's cost: transport and VAT shared over the whole bought amount (stable as portions arrive)
CREATE OR REPLACE VIEW public.purchase_line_costs
WITH (security_invoker = true) AS
SELECT l.id AS purchase_line_id, l.purchase_id, l.transaction_id, p.organization_id, p.branch_id, p.supplier_id, p.purchase_date,
       t.material_id, t.warehouse_id, t.seq, t.quantity AS stock_quantity, t.stock_unit_id, t.entered_quantity, t.entered_unit_id,
       l.unit_price, l.line_amount,
       l.line_amount * CASE WHEN NOT p.prices_include_vat AND coalesce(p.vat_amount, 0) > 0 AND s.subtotal > 0
                            THEN (s.subtotal + p.vat_amount) / s.subtotal ELSE 1 END
       + CASE WHEN s.subtotal > 0 THEN p.transport_charge * l.line_amount / s.subtotal
              ELSE p.transport_charge / s.lines END                         AS landed_cost,
       ( l.line_amount * CASE WHEN NOT p.prices_include_vat AND coalesce(p.vat_amount, 0) > 0 AND s.subtotal > 0
                              THEN (s.subtotal + p.vat_amount) / s.subtotal ELSE 1 END
         + CASE WHEN s.subtotal > 0 THEN p.transport_charge * l.line_amount / s.subtotal
                ELSE p.transport_charge / s.lines END ) / nullif(t.quantity, 0) AS cost_per_stock_unit,
       CASE WHEN coalesce(p.vat_amount, 0) > 0 AND s.subtotal > 0 THEN p.vat_amount * l.line_amount / s.subtotal ELSE 0 END AS vat_share
FROM public.purchase_lines l
JOIN public.purchases p ON p.id = l.purchase_id AND p.status = 'recorded'
JOIN public.inventory_transactions t ON t.id = l.transaction_id
JOIN LATERAL (SELECT coalesce((SELECT sum(line_amount) FROM public.purchase_items WHERE purchase_id = p.id),
                              (SELECT sum(line_amount) FROM public.purchase_lines WHERE purchase_id = p.id)) AS subtotal,
                     greatest(coalesce((SELECT count(*) FROM public.purchase_items WHERE purchase_id = p.id), 0),
                              (SELECT count(*) FROM public.purchase_lines WHERE purchase_id = p.id)) AS lines) s ON true;

-- 6. a delivery's receipt belongs to its purchase: never "awaiting a purchase"
CREATE OR REPLACE VIEW public.receipts_awaiting_purchase
WITH (security_invoker = true) AS
SELECT m.id AS movement_id, m.organization_id, m.branch_id, m.warehouse_id, m.movement_date, m.reference, m.notes,
       m.supplier_id, m.created_by, m.created_at,
       (SELECT count(*) FROM public.inventory_transactions t WHERE t.movement_id = m.id AND t.material_id IS NOT NULL) AS material_lines
FROM public.inventory_movements m
WHERE m.movement_type = 'receipt'
  AND EXISTS (SELECT 1 FROM public.inventory_transactions t WHERE t.movement_id = m.id AND t.material_id IS NOT NULL)
  AND NOT EXISTS (SELECT 1 FROM public.purchases p WHERE p.movement_id = m.id AND p.status = 'recorded')
  AND NOT EXISTS (SELECT 1 FROM public.purchase_deliveries d JOIN public.purchases p ON p.id = d.purchase_id AND p.status = 'recorded' WHERE d.movement_id = m.id)
  AND NOT EXISTS (SELECT 1 FROM public.inventory_movements r WHERE r.reverses_movement_id = m.id);

-- 7. how far each purchase has been delivered
CREATE OR REPLACE VIEW public.purchase_delivery_status
WITH (security_invoker = true) AS
SELECT p.id AS purchase_id, p.organization_id, p.branch_id,
       CASE WHEN NOT EXISTS (SELECT 1 FROM public.purchase_items i WHERE i.purchase_id = p.id) THEN 'delivered'
            WHEN bool_and(x.delivered + 1e-9 >= x.stock_quantity) THEN 'delivered'
            WHEN sum(x.delivered) > 1e-9 THEN 'part'
            ELSE 'not' END AS delivery_status,
       (SELECT max(d.delivered_on) FROM public.purchase_deliveries d WHERE d.purchase_id = p.id) AS last_delivered_on,
       coalesce(jsonb_agg(jsonb_build_object('item_id', x.id, 'material_id', x.material_id, 'unit_id', x.unit_id,
                 'quantity', x.quantity, 'stock_quantity', x.stock_quantity,
                 'delivered_stock', x.delivered,
                 'delivered', CASE WHEN x.stock_quantity > 0 THEN x.delivered * x.quantity / x.stock_quantity ELSE 0 END)
                 ORDER BY x.line_no) FILTER (WHERE x.id IS NOT NULL), '[]'::jsonb) AS items
FROM public.purchases p
LEFT JOIN LATERAL (
  SELECT i.id, i.line_no, i.material_id, i.unit_id, i.quantity, i.stock_quantity,
         coalesce((SELECT sum(t.quantity) FROM public.purchase_lines pl JOIN public.inventory_transactions t ON t.id = pl.transaction_id
                   WHERE pl.item_id = i.id), 0) AS delivered
    FROM public.purchase_items i WHERE i.purchase_id = p.id) x ON true
GROUP BY p.id;
GRANT SELECT ON public.purchase_delivery_status TO authenticated;
COMMENT ON VIEW public.purchase_delivery_status IS 'Delivered · part · not, per purchase, with each bought item and how much of it has come (120).';

-- 8. recording: arrived now (as before) or coming later (items, nothing into stock yet)
CREATE OR REPLACE FUNCTION public.record_purchase(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org     uuid := public.get_my_org_id();
  mv      public.inventory_movements;
  mv_id   uuid;
  sup     uuid := nullif(p->>'supplier_id', '')::uuid;
  new_sup text := nullif(btrim(p->>'new_supplier_name'), '');
  pid     uuid;
  later   boolean := coalesce((p->>'coming_later')::boolean, false);
  wh      public.warehouses;
  pdate   date;
  x       jsonb;
  n       int := 0;
  sq      numeric;
BEGIN
  IF org IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not signed in to an organization' USING ERRCODE = '42501';
  END IF;

  IF later THEN
    -- coming later: the store and the date of the purchase, no receipt yet
    SELECT * INTO wh FROM public.warehouses WHERE id = nullif(p->>'warehouse_id', '')::uuid AND organization_id = org;
    IF NOT FOUND THEN RAISE EXCEPTION 'Choose the store the goods will come to' USING ERRCODE = '23514'; END IF;
    IF NOT public.has_permission_at('procurement.receive', wh.branch_id, wh.id) THEN
      RAISE EXCEPTION 'You can''t record purchases at this store' USING ERRCODE = '42501';
    END IF;
    pdate := coalesce(nullif(p->>'purchase_date', '')::date, public.org_today(org));
    IF pdate > public.org_today(org) THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;
    IF jsonb_typeof(p->'items') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'items') = 0 THEN
      RAISE EXCEPTION 'Add what was bought' USING ERRCODE = '23514';
    END IF;
  ELSIF nullif(p->>'movement_id', '') IS NOT NULL THEN
    mv_id := (p->>'movement_id')::uuid;
  ELSIF p ? 'receipt' THEN
    IF coalesce(p->'receipt'->>'type', '') <> 'receipt' THEN
      RAISE EXCEPTION 'A purchase records a receipt' USING ERRCODE = '23514';
    END IF;
    mv_id := public.post_inventory_movement((p->'receipt') - 'supplier_id' - 'new_supplier_name');
  ELSE
    RAISE EXCEPTION 'Choose the receipt this purchase is for' USING ERRCODE = '23514';
  END IF;

  IF NOT later THEN
    SELECT * INTO mv FROM public.inventory_movements WHERE id = mv_id AND organization_id = org;
    IF NOT FOUND OR mv.movement_type <> 'receipt' THEN
      RAISE EXCEPTION 'Receipt not found' USING ERRCODE = '23514';
    END IF;
    IF NOT public.has_permission_at('procurement.receive', mv.branch_id, mv.warehouse_id) THEN
      RAISE EXCEPTION 'You can''t record purchases at this store' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM public.inventory_movements WHERE reverses_movement_id = mv.id) THEN
      RAISE EXCEPTION 'That receipt was reversed' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (SELECT 1 FROM public.purchases WHERE movement_id = mv.id AND status = 'recorded')
       OR EXISTS (SELECT 1 FROM public.purchase_deliveries d JOIN public.purchases q ON q.id = d.purchase_id AND q.status = 'recorded' WHERE d.movement_id = mv.id) THEN
      RAISE EXCEPTION 'This receipt already has a purchase — change that one instead' USING ERRCODE = '23514';
    END IF;
  END IF;

  -- Supplier: chosen, or named now (same rule as receipts, 023)
  IF sup IS NOT NULL AND new_sup IS NOT NULL THEN
    RAISE EXCEPTION 'Choose a supplier or name a new one — not both' USING ERRCODE = '23514';
  END IF;
  IF new_sup IS NOT NULL THEN
    SELECT id INTO sup FROM public.suppliers WHERE organization_id = org AND public.normalize_name(name) = public.normalize_name(new_sup);
    IF sup IS NULL THEN
      IF public.normalize_name(new_sup) = '' THEN RAISE EXCEPTION 'Name the supplier' USING ERRCODE = '23514'; END IF;
      INSERT INTO public.suppliers (organization_id, name) VALUES (org, new_sup) RETURNING id INTO sup;
    END IF;
  END IF;
  IF sup IS NULL OR NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id = sup AND organization_id = org) THEN
    RAISE EXCEPTION 'Choose the supplier' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.purchases (organization_id, branch_id, movement_id, warehouse_id, supplier_id, purchase_date, invoice_reference,
                                transport_charge, vat_amount, prices_include_vat, amount_paid, payment_method, paid_on, notes)
  VALUES (org, CASE WHEN later THEN wh.branch_id ELSE mv.branch_id END, CASE WHEN later THEN NULL ELSE mv.id END,
          CASE WHEN later THEN wh.id ELSE mv.warehouse_id END, sup,
          CASE WHEN later THEN pdate ELSE mv.movement_date END, nullif(btrim(p->>'invoice_reference'), ''),
          coalesce(nullif(p->>'transport_charge', '')::numeric, 0), nullif(p->>'vat_amount', '')::numeric,
          coalesce((p->>'prices_include_vat')::boolean, false),
          coalesce(nullif(p->>'amount_paid', '')::numeric, 0), nullif(btrim(p->>'payment_method'), ''),
          nullif(p->>'paid_on', '')::date, nullif(btrim(p->>'notes'), ''))
  RETURNING id INTO pid;

  IF later THEN
    FOR x IN SELECT value FROM jsonb_array_elements(p->'items') LOOP
      n := n + 1;
      IF NOT EXISTS (SELECT 1 FROM public.materials WHERE id = nullif(x->>'material_id', '')::uuid AND organization_id = org) THEN
        RAISE EXCEPTION 'Line %: choose the material', n USING ERRCODE = '23514';
      END IF;
      IF nullif(x->>'quantity', '') IS NULL OR (x->>'quantity')::numeric <= 0 THEN RAISE EXCEPTION 'Line %: enter the quantity bought', n USING ERRCODE = '23514'; END IF;
      IF nullif(x->>'unit_id', '') IS NULL THEN RAISE EXCEPTION 'Line %: choose the unit', n USING ERRCODE = '23514'; END IF;
      IF nullif(x->>'unit_price', '') IS NULL OR (x->>'unit_price')::numeric < 0 THEN RAISE EXCEPTION 'Line %: enter a price of zero or more', n USING ERRCODE = '23514'; END IF;
      sq := public.material_stock_qty((x->>'material_id')::uuid, (x->>'unit_id')::uuid, (x->>'quantity')::numeric);
      IF sq IS NULL OR sq <= 0 THEN RAISE EXCEPTION 'Line %: that unit can''t be counted in the material''s stock unit', n USING ERRCODE = '23514'; END IF;
      IF EXISTS (SELECT 1 FROM public.purchase_items WHERE purchase_id = pid AND material_id = (x->>'material_id')::uuid) THEN
        RAISE EXCEPTION 'A material appears twice — combine the lines' USING ERRCODE = '23514';
      END IF;
      INSERT INTO public.purchase_items (organization_id, purchase_id, line_no, material_id, unit_id, quantity, stock_quantity, unit_price, line_amount)
      VALUES (org, pid, n, (x->>'material_id')::uuid, (x->>'unit_id')::uuid, (x->>'quantity')::numeric, sq,
              (x->>'unit_price')::numeric, round((x->>'unit_price')::numeric * (x->>'quantity')::numeric, 2));
    END LOOP;
  ELSE
    PERFORM public.write_purchase_lines(pid, mv.id, p->'lines');
  END IF;
  PERFORM public.check_purchase_figures(pid);
  RETURN pid;
END;
$$;

-- 9. a delivery: an ordinary receipt into the purchase's store, priced from the purchase
-- p: { delivered_on, received_by?, lines: [{ item_id, quantity }] }  (quantity in the item's unit)
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

  -- the receipt (the usual checks run: a backdated one is refused for non-admins, as for any receipt)
  mv := public.post_inventory_movement(jsonb_build_object('type', 'receipt', 'warehouse_id', pu.warehouse_id, 'movement_date', dt,
          'reference', coalesce(pu.invoice_reference, 'Purchase delivery'), 'lines', rl,
          'notes', 'Delivery for the purchase of ' || to_char(pu.purchase_date, 'DD Mon YYYY')));
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

-- 10. changing a purchase: the store comes from the purchase (one coming later has no receipt);
--     a purchase coming later changes its prices through its items (deliveries re-priced with them)
CREATE OR REPLACE FUNCTION public.update_purchase(p_id uuid, p jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org  uuid := public.get_my_org_id();
  pu   public.purchases;
  sup  uuid;
  x    jsonb;
  it   public.purchase_items;
BEGIN
  SELECT * INTO pu FROM public.purchases WHERE id = p_id AND organization_id = org FOR UPDATE;
  IF NOT FOUND OR pu.status <> 'recorded' THEN RAISE EXCEPTION 'Purchase not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.receive', pu.branch_id, pu.warehouse_id) THEN
    RAISE EXCEPTION 'You can''t change purchases at this store' USING ERRCODE = '42501';
  END IF;
  sup := coalesce(nullif(p->>'supplier_id', '')::uuid, pu.supplier_id);
  IF NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id = sup AND organization_id = org) THEN
    RAISE EXCEPTION 'Choose the supplier' USING ERRCODE = '23514';
  END IF;
  UPDATE public.purchases SET
    supplier_id        = sup,
    invoice_reference  = CASE WHEN p ? 'invoice_reference' THEN nullif(btrim(p->>'invoice_reference'), '') ELSE invoice_reference END,
    transport_charge   = CASE WHEN p ? 'transport_charge' THEN coalesce(nullif(p->>'transport_charge', '')::numeric, 0) ELSE transport_charge END,
    vat_amount         = CASE WHEN p ? 'vat_amount' THEN nullif(p->>'vat_amount', '')::numeric ELSE vat_amount END,
    prices_include_vat = CASE WHEN p ? 'prices_include_vat' THEN coalesce((p->>'prices_include_vat')::boolean, false) ELSE prices_include_vat END,
    amount_paid        = CASE WHEN p ? 'amount_paid' THEN coalesce(nullif(p->>'amount_paid', '')::numeric, 0) ELSE amount_paid END,
    payment_method     = CASE WHEN p ? 'payment_method' THEN nullif(btrim(p->>'payment_method'), '') ELSE payment_method END,
    paid_on            = CASE WHEN p ? 'paid_on' THEN nullif(p->>'paid_on', '')::date ELSE paid_on END,
    notes              = CASE WHEN p ? 'notes' THEN nullif(btrim(p->>'notes'), '') ELSE notes END
  WHERE id = pu.id;
  IF EXISTS (SELECT 1 FROM public.purchase_items WHERE purchase_id = pu.id) THEN
    IF jsonb_typeof(p->'items') = 'array' THEN
      FOR x IN SELECT value FROM jsonb_array_elements(p->'items') LOOP
        SELECT * INTO it FROM public.purchase_items WHERE id = nullif(x->>'id', '')::uuid AND purchase_id = pu.id;
        IF NOT FOUND THEN RAISE EXCEPTION 'That line isn''t on this purchase' USING ERRCODE = '23514'; END IF;
        IF nullif(x->>'unit_price', '') IS NULL OR (x->>'unit_price')::numeric < 0 THEN RAISE EXCEPTION 'Enter a price of zero or more for each material' USING ERRCODE = '23514'; END IF;
        UPDATE public.purchase_items SET unit_price = (x->>'unit_price')::numeric, line_amount = round((x->>'unit_price')::numeric * quantity, 2) WHERE id = it.id;
        UPDATE public.purchase_lines pl SET unit_price = (x->>'unit_price')::numeric,
               line_amount = round((x->>'unit_price')::numeric * t.entered_quantity, 2)
          FROM public.inventory_transactions t WHERE pl.item_id = it.id AND t.id = pl.transaction_id;
      END LOOP;
    END IF;
  ELSIF p ? 'lines' THEN
    PERFORM public.write_purchase_lines(pu.id, pu.movement_id, p->'lines');
  END IF;
  PERFORM public.check_purchase_figures(pu.id);
END;
$$;

CREATE OR REPLACE FUNCTION public.void_purchase(p_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  pu public.purchases;
BEGIN
  SELECT * INTO pu FROM public.purchases WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND OR pu.status <> 'recorded' THEN RAISE EXCEPTION 'Purchase not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.receive', pu.branch_id, pu.warehouse_id) THEN
    RAISE EXCEPTION 'You can''t change purchases at this store' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN RAISE EXCEPTION 'Give a reason' USING ERRCODE = '23514'; END IF;
  UPDATE public.purchases SET status = 'void', void_reason = btrim(p_reason) WHERE id = pu.id;
END;
$$;

-- the Technical admin's delete: undoing the receipt undoes every delivery's receipt too
CREATE OR REPLACE FUNCTION public.delete_purchase(p_id uuid, p_reason text, p_undo_receipt boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  pu   public.purchases;
  why  text := nullif(btrim(p_reason), '');
  rev  uuid;
  revs uuid[] := '{}';
  dm   uuid[];
  m    uuid;
BEGIN
  IF NOT public.has_permission('system.manage') THEN
    RAISE EXCEPTION 'Only the technical admin can delete a purchase' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO pu FROM public.purchases WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found' USING ERRCODE = '23514'; END IF;
  IF why IS NULL THEN RAISE EXCEPTION 'Give a reason' USING ERRCODE = '23514'; END IF;
  SELECT coalesce(array_agg(movement_id), '{}') INTO dm FROM public.purchase_deliveries WHERE purchase_id = pu.id;

  INSERT INTO public.audit_log (organization_id, entity_type, entity_id, action, field, old_value, new_value, changed_by, changed_via)
  VALUES (pu.organization_id, 'purchase', pu.id::text, 'delete', 'delete_reason',
          jsonb_build_object('purchase_date', pu.purchase_date, 'movement_id', pu.movement_id, 'deliveries', to_jsonb(dm), 'status', pu.status),
          jsonb_build_object('reason', why, 'undo_receipt', coalesce(p_undo_receipt, false)),
          auth.uid(), 'app');

  PERFORM set_config('mois.deleting_purchase', pu.id::text, true);
  DELETE FROM public.purchases WHERE id = pu.id;   -- its lines, items and deliveries go with it (ON DELETE CASCADE)
  PERFORM set_config('mois.deleting_purchase', '', true);

  IF coalesce(p_undo_receipt, false) THEN
    IF pu.movement_id IS NOT NULL THEN
      rev := public.reverse_inventory_movement(pu.movement_id, 'Purchase deleted: ' || why);
      revs := revs || rev;
    END IF;
    FOREACH m IN ARRAY dm LOOP
      revs := revs || public.reverse_inventory_movement(m, 'Purchase deleted: ' || why);
    END LOOP;
  END IF;

  RETURN jsonb_build_object('deleted', pu.id, 'reversal_movement_id', revs[1], 'reversal_movement_ids', to_jsonb(revs));
END;
$$;
