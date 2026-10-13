-- ============================================================
-- 023 — Dated movements + suppliers created while receiving (1b)
--
-- 022 already stores a business date on every movement (movement_date /
-- transaction_date) separate from when it was recorded (created_at), but
-- checked stock against the all-time total. This makes the ledger
-- date-ordered:
--
--   1. Stock at any date = sum of lines with transaction_date <= that date,
--      ordered (transaction_date, created_at, id). A line entered late for
--      an earlier date slots into its date, not at the end.
--   2. An outflow is accepted only if stock stays >= 0 at its date AND at
--      every later point in the timeline (a backdated issue can't make an
--      already-recorded later issue go negative).
--   3. A count compares what was found with stock AS OF the count date.
--   4. Nothing may be dated before an item's opening balance in that store.
--   5. Backdating (any date before today, in the organization's time zone)
--      needs inventory.adjust at the store — the same level as an opening
--      balance; plain storekeepers can only post for today.
--   6. A reversal is dated at the movement it reverses, so stock at every
--      date in between is corrected too.
--   7. organizations.timezone: "today" is the organization's date, not UTC.
--   8. Suppliers: names unique ignoring case/spaces/punctuation, and a
--      receipt can create its supplier in the same posting.
--
-- Reads: stock_balances_as_of(date) and the inventory_ledger_running view.
-- ============================================================


-- ------------------------------------------------------------
-- 7. Organization time zone
-- ------------------------------------------------------------
ALTER TABLE public.organizations ADD COLUMN timezone text NOT NULL DEFAULT 'UTC';

CREATE OR REPLACE FUNCTION public.check_org_timezone()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = NEW.timezone) THEN
    RAISE EXCEPTION 'Unknown time zone: %', NEW.timezone USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_organizations_timezone
  BEFORE INSERT OR UPDATE OF timezone ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION public.check_org_timezone();

-- Today's date where the organization operates
CREATE OR REPLACE FUNCTION public.org_today(p_org uuid)
RETURNS date
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT (now() AT TIME ZONE coalesce((SELECT timezone FROM public.organizations WHERE id = p_org), 'UTC'))::date
$$;


-- ------------------------------------------------------------
-- 8. Supplier names: no "Tanesco" and "TANESCO" twins
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.normalize_name(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$ SELECT regexp_replace(lower(coalesce(p, '')), '[^[:alnum:]]+', '', 'g') $$;

CREATE UNIQUE INDEX uq_suppliers_normalized_name
  ON public.suppliers (organization_id, public.normalize_name(name));


-- ------------------------------------------------------------
-- Reads: dated balances
-- ------------------------------------------------------------
CREATE INDEX idx_inv_tx_timeline
  ON public.inventory_transactions (warehouse_id, material_id, product_id, transaction_date, created_at, id);

-- Every ledger line with the store's running balance after it
CREATE VIEW public.inventory_ledger_running WITH (security_invoker = true) AS
SELECT t.*,
       sum(t.quantity) OVER (PARTITION BY t.warehouse_id, t.material_id, t.product_id
                             ORDER BY t.transaction_date, t.created_at, t.id) AS running_balance
FROM public.inventory_transactions t;

COMMENT ON VIEW public.inventory_ledger_running
  IS 'Ledger lines in date order with the running balance per store per item.';

-- Stock per store per item at the end of a given date (RLS applies)
CREATE OR REPLACE FUNCTION public.stock_balances_as_of(p_date date)
RETURNS TABLE (organization_id uuid, branch_id uuid, warehouse_id uuid, material_id uuid, product_id uuid,
               stock_unit_id uuid, quantity numeric, last_movement_date date)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT organization_id, branch_id, warehouse_id, material_id, product_id, stock_unit_id,
         sum(quantity), max(transaction_date)
  FROM public.inventory_transactions
  WHERE transaction_date <= p_date
  GROUP BY organization_id, branch_id, warehouse_id, material_id, product_id, stock_unit_id
$$;
GRANT EXECUTE ON FUNCTION public.stock_balances_as_of(date) TO authenticated;


-- ------------------------------------------------------------
-- Internal: balance as of a date; outflow check across the timeline
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.inventory_balance_as_of(p_wh uuid, p_mat uuid, p_prod uuid, p_date date)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT coalesce(sum(quantity), 0) FROM public.inventory_transactions
  WHERE warehouse_id = p_wh AND material_id IS NOT DISTINCT FROM p_mat AND product_id IS NOT DISTINCT FROM p_prod
    AND transaction_date <= p_date
$$;

-- Raise unless adding p_delta (< 0) at p_date keeps every point of the
-- store's timeline from p_date onward at zero or more. Call after
-- inventory_locked_balance() has taken the item's lock.
CREATE OR REPLACE FUNCTION public.inventory_check_outflow(p_wh uuid, p_mat uuid, p_prod uuid, p_date date,
                                                         p_delta numeric, p_item text, p_where text)
RETURNS void
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  at_date numeric;
  bad     record;
BEGIN
  IF p_delta >= 0 THEN RETURN; END IF;
  at_date := public.inventory_balance_as_of(p_wh, p_mat, p_prod, p_date);
  IF at_date + p_delta < 0 THEN
    RAISE EXCEPTION '%: only % in stock at % on %', p_item, trim_scale(at_date), p_where, p_date
      USING ERRCODE = '23514';
  END IF;
  SELECT x.transaction_date, x.run INTO bad
  FROM (SELECT transaction_date,
               sum(quantity) OVER (ORDER BY transaction_date, created_at, id) AS run
        FROM public.inventory_transactions
        WHERE warehouse_id = p_wh AND material_id IS NOT DISTINCT FROM p_mat AND product_id IS NOT DISTINCT FROM p_prod) x
  WHERE x.transaction_date > p_date AND x.run + p_delta < 0
  ORDER BY x.transaction_date
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION '%: stock at % would drop to % on % — later movements already use it',
      p_item, p_where, trim_scale(bad.run + p_delta), bad.transaction_date USING ERRCODE = '23514';
  END IF;
END;
$$;

-- Nothing dated before the item's opening balance in that store
CREATE OR REPLACE FUNCTION public.inventory_check_after_opening(p_wh uuid, p_mat uuid, p_prod uuid, p_date date,
                                                               p_item text, p_where text)
RETURNS void
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE ob date;
BEGIN
  SELECT min(t.transaction_date) INTO ob FROM public.inventory_transactions t
  WHERE t.warehouse_id = p_wh AND t.material_id IS NOT DISTINCT FROM p_mat AND t.product_id IS NOT DISTINCT FROM p_prod
    AND t.transaction_type = 'opening_balance'
    AND NOT EXISTS (SELECT 1 FROM public.inventory_movements r WHERE r.reverses_movement_id = t.movement_id);
  IF ob IS NOT NULL AND p_date < ob THEN
    RAISE EXCEPTION '%: % is before its opening balance at % (%)', p_item, p_date, p_where, ob USING ERRCODE = '23514';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.inventory_balance_as_of(uuid, uuid, uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inventory_check_outflow(uuid, uuid, uuid, date, numeric, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inventory_check_after_opening(uuid, uuid, uuid, date, text, text) FROM PUBLIC, anon, authenticated;


-- ------------------------------------------------------------
-- Posting (replaces 022's version)
-- ------------------------------------------------------------
-- p: { type, warehouse_id, to_warehouse_id?, supplier_id? | new_supplier_name?,
--      movement_date?, reason?, reference?, notes?,
--      lines: [{ material_id | product_id, quantity, unit_id, unit_cost? }] }
CREATE OR REPLACE FUNCTION public.post_inventory_movement(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
  IF mdate < today AND NOT public.has_permission_at('inventory.adjust', wh.branch_id, wh.id) THEN
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

  -- Supplier: an existing one, or created here by whoever may receive
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
    IF num_nonnulls(item_mat, item_pro) <> 1 THEN
      RAISE EXCEPTION 'Each line needs one material or one product' USING ERRCODE = '23514';
    END IF;
    IF coalesce(item_mat, item_pro)::text = ANY (seen) THEN
      RAISE EXCEPTION 'An item appears twice — combine the lines' USING ERRCODE = '23514';
    END IF;
    seen := seen || coalesce(item_mat, item_pro)::text;

    IF item_mat IS NOT NULL THEN
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

    PERFORM public.inventory_locked_balance(wh.id, item_mat, item_pro);

    IF mtype = 'opening_balance' THEN
      -- only before anything else — a reversed (wrong) opening balance and
      -- its reversal don't count, so the right one can be entered
      IF EXISTS (SELECT 1 FROM public.inventory_transactions t
                 JOIN public.inventory_movements m ON m.id = t.movement_id
                 WHERE t.warehouse_id = wh.id AND t.material_id IS NOT DISTINCT FROM item_mat AND t.product_id IS NOT DISTINCT FROM item_pro
                   AND NOT (m.movement_type = 'opening_balance'
                            AND EXISTS (SELECT 1 FROM public.inventory_movements r WHERE r.reverses_movement_id = m.id))
                   AND NOT (m.movement_type = 'reversal'
                            AND EXISTS (SELECT 1 FROM public.inventory_movements o
                                        WHERE o.id = m.reverses_movement_id AND o.movement_type = 'opening_balance'))) THEN
        RAISE EXCEPTION '%: already has stock movements here — use an adjustment or a count', item_name USING ERRCODE = '23514';
      END IF;
    ELSE
      PERFORM public.inventory_check_after_opening(wh.id, item_mat, item_pro, mdate, item_name, wh_label);
    END IF;

    delta := CASE mtype
      WHEN 'issue'    THEN -qty
      WHEN 'transfer' THEN -qty
      WHEN 'count'    THEN qty - public.inventory_balance_as_of(wh.id, item_mat, item_pro, mdate)
      ELSE qty
    END;
    PERFORM public.inventory_check_outflow(wh.id, item_mat, item_pro, mdate, delta, item_name, wh_label);

    INSERT INTO public.inventory_transactions
      (organization_id, movement_id, transaction_type, branch_id, warehouse_id, material_id, product_id,
       quantity, stock_unit_id, entered_quantity, entered_unit_id, counted_quantity, unit_cost, transaction_date, created_by)
    VALUES
      (org, mov_id, CASE mtype WHEN 'transfer' THEN 'transfer_out' ELSE mtype END,
       wh.branch_id, wh.id, item_mat, item_pro,
       delta, stock_u, entered, (line->>'unit_id')::uuid,
       CASE WHEN mtype = 'count' THEN qty END,
       nullif(line->>'unit_cost', '')::numeric, mdate, uid);

    IF mtype = 'transfer' THEN
      PERFORM public.inventory_locked_balance(to_wh.id, item_mat, item_pro);
      PERFORM public.inventory_check_after_opening(to_wh.id, item_mat, item_pro, mdate, item_name, to_label);
      INSERT INTO public.inventory_transactions
        (organization_id, movement_id, transaction_type, branch_id, warehouse_id, material_id, product_id,
         quantity, stock_unit_id, entered_quantity, entered_unit_id, transaction_date, created_by)
      VALUES
        (org, mov_id, 'transfer_in', to_wh.branch_id, to_wh.id, item_mat, item_pro,
         qty, stock_u, entered, (line->>'unit_id')::uuid, mdate, uid);
    END IF;
  END LOOP;

  RETURN mov_id;
END;
$$;


-- ------------------------------------------------------------
-- Reversal (replaces 022's): dated at the movement it undoes
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reverse_inventory_movement(p_movement_id uuid, p_reason text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org    uuid := public.get_my_org_id();
  uid    uuid := auth.uid();
  orig   public.inventory_movements;
  t      public.inventory_transactions;
  rev_id uuid;
  label  text;
  place  text;
BEGIN
  IF uid IS NULL OR org IS NULL THEN
    RAISE EXCEPTION 'Sign in to record stock movements' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO orig FROM public.inventory_movements WHERE id = p_movement_id AND organization_id = org FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Movement not found' USING ERRCODE = '23514';
  END IF;
  IF NOT public.has_permission_at('inventory.adjust', orig.branch_id, orig.warehouse_id) THEN
    RAISE EXCEPTION 'You don''t have permission to reverse movements here' USING ERRCODE = '42501';
  END IF;
  IF orig.movement_type = 'reversal' THEN
    RAISE EXCEPTION 'A reversal can''t itself be reversed — post a new movement instead' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventory_movements WHERE reverses_movement_id = orig.id) THEN
    RAISE EXCEPTION 'This movement has already been reversed' USING ERRCODE = '23514';
  END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Give a reason for the reversal' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.inventory_movements
    (organization_id, movement_type, branch_id, warehouse_id, reverses_movement_id, movement_date, reason, reference, created_by)
  VALUES
    (org, 'reversal', orig.branch_id, orig.warehouse_id, orig.id, orig.movement_date, btrim(p_reason), orig.reference, uid)
  RETURNING id INTO rev_id;

  FOR t IN SELECT * FROM public.inventory_transactions WHERE movement_id = orig.id AND quantity <> 0 LOOP
    PERFORM public.inventory_locked_balance(t.warehouse_id, t.material_id, t.product_id);
    SELECT coalesce(m.name, pr.canonical_name) INTO label
    FROM (SELECT 1) x
    LEFT JOIN public.materials m ON m.id = t.material_id
    LEFT JOIN public.products pr ON pr.id = t.product_id;
    place := (SELECT b.name || ' — ' || w.name FROM public.warehouses w JOIN public.branches b ON b.id = w.branch_id WHERE w.id = t.warehouse_id);
    PERFORM public.inventory_check_outflow(t.warehouse_id, t.material_id, t.product_id, orig.movement_date,
                                           -t.quantity, label, place);
    INSERT INTO public.inventory_transactions
      (organization_id, movement_id, transaction_type, branch_id, warehouse_id, material_id, product_id,
       quantity, stock_unit_id, entered_quantity, entered_unit_id, transaction_date, created_by)
    VALUES
      (org, rev_id, 'reversal', t.branch_id, t.warehouse_id, t.material_id, t.product_id,
       -t.quantity, t.stock_unit_id, t.entered_quantity, t.entered_unit_id, orig.movement_date, uid);
  END LOOP;

  RETURN rev_id;
END;
$$;
