-- ============================================================
-- 035 — Purchases (1c)
--
-- A purchase is the money side of a material receipt: supplier, what each
-- line cost, transport, VAT and payment. The stock side stays the receipt
-- in the append-only ledger (022); a purchase points at it and never
-- changes it. Decided with SwahziTech (2026-10-16):
--
--   * Only the purchase record + payment status now (no requests / orders /
--     supplier ledger — Stumarcot buys informally; add later if needed).
--   * Separation of duties: the storekeeper receives the goods (a plain
--     receipt, no cost or supplier); the secretary or branch manager then
--     completes the purchase on that receipt. They can also record goods +
--     purchase in one go. Storekeepers can't record purchases.
--   * Transport/other charges are part of landed cost (spread over the
--     lines by value).
--   * VAT is optional per purchase. When shown separately it is recorded
--     but excluded from material cost.
--   * Cost: moving average per branch, from purchases only — the existing
--     opening stock gets no retroactive cost.
--   * Ordinary purchases need no approval; a backdated receipt still goes
--     through the approval queue (033) like any backdated entry.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Posting order on the ledger
-- ------------------------------------------------------------
-- Lines posted in one transaction share created_at; the moving average
-- needs their exact order. Existing lines get numbers once, now.
ALTER TABLE public.inventory_transactions ADD COLUMN seq bigint GENERATED ALWAYS AS IDENTITY;
CREATE UNIQUE INDEX uq_inventory_transactions_seq ON public.inventory_transactions (seq);
COMMENT ON COLUMN public.inventory_transactions.seq IS 'Posting order (035): ties within one transaction are broken by it.';

CREATE TABLE public.purchases (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id    uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id          uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  movement_id        uuid NOT NULL REFERENCES public.inventory_movements(id) ON DELETE RESTRICT,  -- the receipt
  supplier_id        uuid NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  purchase_date      date NOT NULL,                     -- the receipt's date
  invoice_reference  text,                              -- supplier's invoice / receipt / EFD number
  transport_charge   numeric NOT NULL DEFAULT 0 CHECK (transport_charge >= 0),   -- part of landed cost
  vat_amount         numeric CHECK (vat_amount IS NULL OR vat_amount >= 0),       -- only when shown separately
  prices_include_vat boolean NOT NULL DEFAULT false,    -- line prices already contain vat_amount
  amount_paid        numeric NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
  payment_method     text,
  paid_on            date,
  status             text NOT NULL DEFAULT 'recorded' CHECK (status IN ('recorded', 'void')),
  void_reason        text,
  notes              text,
  created_by         uuid REFERENCES auth.users(id) DEFAULT auth.uid(),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CHECK ((status = 'void') = (void_reason IS NOT NULL))
);

-- One live purchase per receipt (a voided one can be recorded again)
CREATE UNIQUE INDEX uq_purchases_movement ON public.purchases (movement_id) WHERE status = 'recorded';
CREATE INDEX idx_purchases_org_branch ON public.purchases (organization_id, branch_id, purchase_date DESC);
CREATE INDEX idx_purchases_supplier ON public.purchases (supplier_id);

CREATE TABLE public.purchase_lines (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  purchase_id     uuid NOT NULL REFERENCES public.purchases(id) ON DELETE CASCADE,
  transaction_id  uuid NOT NULL REFERENCES public.inventory_transactions(id) ON DELETE RESTRICT,  -- the receipt line
  unit_price      numeric NOT NULL CHECK (unit_price >= 0),   -- per unit as bought (the receipt line's entered unit)
  line_amount     numeric NOT NULL CHECK (line_amount >= 0),  -- unit_price × quantity as bought
  UNIQUE (purchase_id, transaction_id)
);
CREATE INDEX idx_purchase_lines_tx ON public.purchase_lines (transaction_id);

COMMENT ON TABLE public.purchases
  IS 'Money side of a material receipt: supplier, charges, VAT, payment. Points at the receipt (stock side, append-only); never changes it.';
COMMENT ON COLUMN public.purchases.vat_amount
  IS 'Recorded only when the supplier''s receipt shows VAT separately; excluded from material cost.';

CREATE TRIGGER trg_purchases_updated_at BEFORE UPDATE ON public.purchases
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_purchases_audit AFTER INSERT OR UPDATE OR DELETE ON public.purchases
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('purchase', 'id');
CREATE TRIGGER trg_purchases_no_delete BEFORE DELETE ON public.purchases
  FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('purchase');
CREATE TRIGGER trg_purchase_lines_audit AFTER INSERT OR UPDATE OR DELETE ON public.purchase_lines
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('purchase_line', 'id');

-- Read across the organization; written only through the functions below
ALTER TABLE public.purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "purchases: read own org" ON public.purchases FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "purchase_lines: read own org" ON public.purchase_lines FOR SELECT USING (organization_id = public.get_my_org_id());


-- ------------------------------------------------------------
-- 1. Totals, landed cost and payment status
-- ------------------------------------------------------------
-- Landed cost of a line, excluding VAT: its amount (less its share of VAT
-- when prices include it) plus its share of transport, both by value
CREATE VIEW public.purchase_line_costs
WITH (security_invoker = true) AS
SELECT l.id AS purchase_line_id, l.purchase_id, l.transaction_id, p.organization_id, p.branch_id, p.supplier_id, p.purchase_date,
       t.material_id, t.warehouse_id, t.seq, t.quantity AS stock_quantity, t.stock_unit_id, t.entered_quantity, t.entered_unit_id,
       l.unit_price, l.line_amount,
       l.line_amount * CASE WHEN p.prices_include_vat AND coalesce(p.vat_amount, 0) > 0 AND s.subtotal > 0
                            THEN (s.subtotal - p.vat_amount) / s.subtotal ELSE 1 END
       + CASE WHEN s.subtotal > 0 THEN p.transport_charge * l.line_amount / s.subtotal
              ELSE p.transport_charge / s.lines END                         AS landed_cost,
       ( l.line_amount * CASE WHEN p.prices_include_vat AND coalesce(p.vat_amount, 0) > 0 AND s.subtotal > 0
                              THEN (s.subtotal - p.vat_amount) / s.subtotal ELSE 1 END
         + CASE WHEN s.subtotal > 0 THEN p.transport_charge * l.line_amount / s.subtotal
                ELSE p.transport_charge / s.lines END ) / nullif(t.quantity, 0) AS cost_per_stock_unit
FROM public.purchase_lines l
JOIN public.purchases p ON p.id = l.purchase_id AND p.status = 'recorded'
JOIN public.inventory_transactions t ON t.id = l.transaction_id
JOIN LATERAL (SELECT sum(line_amount) AS subtotal, count(*) AS lines FROM public.purchase_lines WHERE purchase_id = p.id) s ON true;

CREATE VIEW public.purchase_totals
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
LEFT JOIN LATERAL (SELECT sum(line_amount) AS subtotal FROM public.purchase_lines WHERE purchase_id = p.id) s ON true;

-- Material receipts with no purchase recorded yet: what the secretary completes
CREATE VIEW public.receipts_awaiting_purchase
WITH (security_invoker = true) AS
SELECT m.id AS movement_id, m.organization_id, m.branch_id, m.warehouse_id, m.movement_date, m.reference, m.notes,
       m.supplier_id, m.created_by, m.created_at,
       (SELECT count(*) FROM public.inventory_transactions t WHERE t.movement_id = m.id AND t.material_id IS NOT NULL) AS material_lines
FROM public.inventory_movements m
WHERE m.movement_type = 'receipt'
  AND EXISTS (SELECT 1 FROM public.inventory_transactions t WHERE t.movement_id = m.id AND t.material_id IS NOT NULL)
  AND NOT EXISTS (SELECT 1 FROM public.purchases p WHERE p.movement_id = m.id AND p.status = 'recorded')
  AND NOT EXISTS (SELECT 1 FROM public.inventory_movements r WHERE r.reverses_movement_id = m.id);


-- ------------------------------------------------------------
-- 2. Moving average cost per branch
-- ------------------------------------------------------------
-- Walks the branch's ledger for the material in date order. A costed
-- receipt adds its quantity and landed cost; stock out leaves the average
-- unchanged and takes value away at it. Stock that came in without a cost
-- (a receipt whose purchase isn't recorded yet, opening stock) carries the
-- average current at the time — or, before the first purchase, no cost at
-- all: it is left out of the average rather than guessed. Recomputed from
-- the ledger on every call, so completing a purchase later corrects it.
CREATE OR REPLACE FUNCTION public.material_average_cost(p_branch_id uuid, p_material_id uuid, p_as_of date DEFAULT NULL)
RETURNS TABLE (average_cost numeric, costed_quantity numeric, uncosted_quantity numeric, last_purchase_cost numeric, last_purchase_date date)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  r      record;
  q      numeric := 0;   -- costed quantity on hand
  v      numeric := 0;   -- its value
  u      numeric := 0;   -- quantity on hand with no cost basis
  take   numeric;
BEGIN
  FOR r IN
    SELECT t.quantity, c.landed_cost
    FROM public.inventory_transactions t
    LEFT JOIN public.purchase_line_costs c ON c.transaction_id = t.id
    WHERE t.material_id = p_material_id AND t.branch_id = p_branch_id
      AND (p_as_of IS NULL OR t.transaction_date <= p_as_of)
    ORDER BY t.transaction_date, t.seq
  LOOP
    IF r.quantity > 0 AND r.landed_cost IS NOT NULL THEN
      q := q + r.quantity; v := v + r.landed_cost;
    ELSIF r.quantity > 0 THEN
      IF q > 0 THEN v := v + r.quantity * v / q; q := q + r.quantity;
      ELSE u := u + r.quantity; END IF;
    ELSIF r.quantity < 0 THEN
      take := least(-r.quantity, q);
      IF q > 0 THEN v := v - take * v / q; END IF;
      q := q - take;
      u := greatest(u - (-r.quantity - take), 0);
    END IF;
  END LOOP;

  average_cost := CASE WHEN q > 0 THEN v / q END;
  costed_quantity := q;
  uncosted_quantity := u;
  SELECT c.cost_per_stock_unit, c.purchase_date INTO last_purchase_cost, last_purchase_date
  FROM public.purchase_line_costs c
  WHERE c.material_id = p_material_id AND c.branch_id = p_branch_id AND (p_as_of IS NULL OR c.purchase_date <= p_as_of)
  ORDER BY c.purchase_date DESC, c.seq DESC LIMIT 1;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.material_average_cost(uuid, uuid, date)
  IS 'Moving average landed cost per stock unit (excl. VAT) of a material at a branch, from purchases only.';


-- ------------------------------------------------------------
-- 3. Record / change / void a purchase
-- ------------------------------------------------------------
-- p: { movement_id            — complete a receipt already posted (by a storekeeper)
--      | receipt: {...}       — or post the receipt now: a post_inventory_movement() payload of type 'receipt'
--      supplier_id | new_supplier_name,
--      invoice_reference?, transport_charge?, vat_amount?, prices_include_vat?,
--      amount_paid?, payment_method?, paid_on?, notes?,
--      lines: [{ transaction_id | material_id, unit_price }] — every material line of the receipt, priced }
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
  l       jsonb;
  tx      public.inventory_transactions;
  n_lines int;
BEGIN
  IF org IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not signed in to an organization' USING ERRCODE = '42501';
  END IF;

  -- The receipt: an existing one, or posted now (all the usual checks run;
  -- a backdated one is refused for non-admins and goes to approval first)
  IF nullif(p->>'movement_id', '') IS NOT NULL THEN
    mv_id := (p->>'movement_id')::uuid;
  ELSIF p ? 'receipt' THEN
    IF coalesce(p->'receipt'->>'type', '') <> 'receipt' THEN
      RAISE EXCEPTION 'A purchase records a receipt' USING ERRCODE = '23514';
    END IF;
    mv_id := public.post_inventory_movement((p->'receipt') - 'supplier_id' - 'new_supplier_name');
  ELSE
    RAISE EXCEPTION 'Choose the receipt this purchase is for' USING ERRCODE = '23514';
  END IF;

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
  IF EXISTS (SELECT 1 FROM public.purchases WHERE movement_id = mv.id AND status = 'recorded') THEN
    RAISE EXCEPTION 'This receipt already has a purchase — change that one instead' USING ERRCODE = '23514';
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

  INSERT INTO public.purchases (organization_id, branch_id, movement_id, supplier_id, purchase_date, invoice_reference,
                                transport_charge, vat_amount, prices_include_vat, amount_paid, payment_method, paid_on, notes)
  VALUES (org, mv.branch_id, mv.id, sup, mv.movement_date, nullif(btrim(p->>'invoice_reference'), ''),
          coalesce(nullif(p->>'transport_charge', '')::numeric, 0), nullif(p->>'vat_amount', '')::numeric,
          coalesce((p->>'prices_include_vat')::boolean, false),
          coalesce(nullif(p->>'amount_paid', '')::numeric, 0), nullif(btrim(p->>'payment_method'), ''),
          nullif(p->>'paid_on', '')::date, nullif(btrim(p->>'notes'), ''))
  RETURNING id INTO pid;

  PERFORM public.write_purchase_lines(pid, mv.id, p->'lines');
  PERFORM public.check_purchase_figures(pid);
  RETURN pid;
END;
$$;

-- Prices for the receipt's material lines: each priced exactly once
CREATE OR REPLACE FUNCTION public.write_purchase_lines(p_purchase uuid, p_movement uuid, p_lines jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := (SELECT organization_id FROM public.purchases WHERE id = p_purchase);
  l   jsonb;
  tx  public.inventory_transactions;
  missing text;
BEGIN
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Enter the price of each material' USING ERRCODE = '23514';
  END IF;
  DELETE FROM public.purchase_lines WHERE purchase_id = p_purchase;
  FOR l IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    SELECT * INTO tx FROM public.inventory_transactions
    WHERE movement_id = p_movement AND material_id IS NOT NULL
      AND (id = nullif(l->>'transaction_id', '')::uuid OR (l->>'transaction_id' IS NULL AND material_id = nullif(l->>'material_id', '')::uuid));
    IF NOT FOUND THEN RAISE EXCEPTION 'A priced line isn''t a material on this receipt' USING ERRCODE = '23514'; END IF;
    IF nullif(l->>'unit_price', '') IS NULL OR (l->>'unit_price')::numeric < 0 THEN
      RAISE EXCEPTION 'Enter a price of zero or more for each material' USING ERRCODE = '23514';
    END IF;
    INSERT INTO public.purchase_lines (organization_id, purchase_id, transaction_id, unit_price, line_amount)
    VALUES (org, p_purchase, tx.id, (l->>'unit_price')::numeric, round((l->>'unit_price')::numeric * tx.entered_quantity, 2));
  END LOOP;
  SELECT string_agg(m.name, ', ') INTO missing
  FROM public.inventory_transactions t JOIN public.materials m ON m.id = t.material_id
  WHERE t.movement_id = p_movement AND NOT EXISTS (SELECT 1 FROM public.purchase_lines pl WHERE pl.purchase_id = p_purchase AND pl.transaction_id = t.id);
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'Enter the price for: %', missing USING ERRCODE = '23514';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.check_purchase_figures(p_purchase uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE t public.purchase_totals;
BEGIN
  SELECT * INTO t FROM public.purchase_totals WHERE purchase_id = p_purchase;
  IF (SELECT prices_include_vat FROM public.purchases WHERE id = p_purchase) AND coalesce(t.vat_amount, 0) > t.subtotal THEN
    RAISE EXCEPTION 'VAT can''t be more than the prices that include it' USING ERRCODE = '23514';
  END IF;
  IF t.amount_paid > t.total THEN
    RAISE EXCEPTION 'Amount paid is more than the purchase total' USING ERRCODE = '23514';
  END IF;
END;
$$;

-- Change a recorded purchase (supplier, prices, charges, VAT, payment).
-- The receipt itself is never changed here; audit_log keeps old values.
CREATE OR REPLACE FUNCTION public.update_purchase(p_id uuid, p jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org  uuid := public.get_my_org_id();
  pu   public.purchases;
  mv   public.inventory_movements;
  sup  uuid;
BEGIN
  SELECT * INTO pu FROM public.purchases WHERE id = p_id AND organization_id = org FOR UPDATE;
  IF NOT FOUND OR pu.status <> 'recorded' THEN RAISE EXCEPTION 'Purchase not found' USING ERRCODE = '23514'; END IF;
  SELECT * INTO mv FROM public.inventory_movements WHERE id = pu.movement_id;
  IF NOT public.has_permission_at('procurement.receive', mv.branch_id, mv.warehouse_id) THEN
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
  IF p ? 'lines' THEN PERFORM public.write_purchase_lines(pu.id, pu.movement_id, p->'lines'); END IF;
  PERFORM public.check_purchase_figures(pu.id);
END;
$$;

-- Void a purchase entered wrongly. The receipt stays (stock is physical);
-- a new purchase can then be recorded for it. To undo the stock itself,
-- reverse the receipt (a correction — approval queue, 033).
CREATE OR REPLACE FUNCTION public.void_purchase(p_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  pu public.purchases;
  mv public.inventory_movements;
BEGIN
  SELECT * INTO pu FROM public.purchases WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND OR pu.status <> 'recorded' THEN RAISE EXCEPTION 'Purchase not found' USING ERRCODE = '23514'; END IF;
  SELECT * INTO mv FROM public.inventory_movements WHERE id = pu.movement_id;
  IF NOT public.has_permission_at('procurement.receive', mv.branch_id, mv.warehouse_id) THEN
    RAISE EXCEPTION 'You can''t change purchases at this store' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN RAISE EXCEPTION 'Give a reason' USING ERRCODE = '23514'; END IF;
  UPDATE public.purchases SET status = 'void', void_reason = btrim(p_reason) WHERE id = pu.id;
END;
$$;

REVOKE ALL ON FUNCTION public.record_purchase(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_purchase(uuid, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.void_purchase(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.write_purchase_lines(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.check_purchase_figures(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_purchase(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_purchase(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.void_purchase(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.material_average_cost(uuid, uuid, date) TO authenticated;
