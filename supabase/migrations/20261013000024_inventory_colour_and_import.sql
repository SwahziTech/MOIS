-- ============================================================
-- 024 — Colour on stock, and the stock-sheet import (1b)
--
-- 1. Products in a coloured category are stocked per colour (a red and a
--    white 40 Combo are different stock). inventory_transactions gets
--    color_id; every balance, check and view now keys on
--    (store, item, colour). A product line must name one of its
--    category's colours when the category has colours, and none otherwise;
--    materials never carry a colour.
-- 2. import_aliases: how a name on a stock sheet maps to the catalogue
--    ("40*80 COMBO" under FLOOR TILES → product Combo), saved when an
--    import posts, so the next sheet matches it exactly.
-- 3. post_inventory_batch(): several movements (e.g. one opening balance
--    per effective date) + the aliases they taught, in ONE transaction,
--    each movement through post_inventory_movement() — no second write
--    path into the ledger.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Colour dimension
-- ------------------------------------------------------------
ALTER TABLE public.inventory_transactions
  ADD COLUMN color_id uuid REFERENCES public.color_palette(id);
ALTER TABLE public.inventory_transactions
  ADD CONSTRAINT inv_tx_colour_products_only CHECK (color_id IS NULL OR product_id IS NOT NULL);
CREATE TRIGGER trg_inv_tx_color_org
  BEFORE INSERT ON public.inventory_transactions
  FOR EACH ROW EXECUTE FUNCTION public.check_color_org('color_id');

DROP INDEX public.idx_inv_tx_balance;
DROP INDEX public.idx_inv_tx_timeline;
CREATE INDEX idx_inv_tx_timeline
  ON public.inventory_transactions (warehouse_id, material_id, product_id, color_id, transaction_date, created_at, id);

DROP VIEW public.stock_balances;
CREATE VIEW public.stock_balances WITH (security_invoker = true) AS
SELECT organization_id, branch_id, warehouse_id, material_id, product_id, color_id, stock_unit_id,
       sum(quantity)         AS quantity,
       max(transaction_date) AS last_movement_date,
       count(*)              AS movement_lines
FROM public.inventory_transactions
GROUP BY organization_id, branch_id, warehouse_id, material_id, product_id, color_id, stock_unit_id;
COMMENT ON VIEW public.stock_balances
  IS 'Current stock per store per item (per colour for coloured products) = SUM of the ledger.';

DROP VIEW public.inventory_ledger_running;
CREATE VIEW public.inventory_ledger_running WITH (security_invoker = true) AS
SELECT t.*,
       sum(t.quantity) OVER (PARTITION BY t.warehouse_id, t.material_id, t.product_id, t.color_id
                             ORDER BY t.transaction_date, t.created_at, t.id) AS running_balance
FROM public.inventory_transactions t;

DROP FUNCTION public.stock_balances_as_of(date);
CREATE FUNCTION public.stock_balances_as_of(p_date date)
RETURNS TABLE (organization_id uuid, branch_id uuid, warehouse_id uuid, material_id uuid, product_id uuid,
               color_id uuid, stock_unit_id uuid, quantity numeric, last_movement_date date)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT organization_id, branch_id, warehouse_id, material_id, product_id, color_id, stock_unit_id,
         sum(quantity), max(transaction_date)
  FROM public.inventory_transactions
  WHERE transaction_date <= p_date
  GROUP BY organization_id, branch_id, warehouse_id, material_id, product_id, color_id, stock_unit_id
$$;
GRANT EXECUTE ON FUNCTION public.stock_balances_as_of(date) TO authenticated;

-- Internal helpers, now keyed on colour too
DROP FUNCTION public.inventory_locked_balance(uuid, uuid, uuid);
DROP FUNCTION public.inventory_balance_as_of(uuid, uuid, uuid, date);
DROP FUNCTION public.inventory_check_outflow(uuid, uuid, uuid, date, numeric, text, text);
DROP FUNCTION public.inventory_check_after_opening(uuid, uuid, uuid, date, text, text);

CREATE FUNCTION public.inventory_lock_item(p_wh uuid, p_mat uuid, p_prod uuid, p_color uuid)
RETURNS void
LANGUAGE sql
SET search_path = public
AS $$
  SELECT pg_advisory_xact_lock(hashtextextended(
    p_wh::text || coalesce(p_mat, p_prod)::text || coalesce(p_color::text, ''), 22))
$$;

CREATE FUNCTION public.inventory_balance_as_of(p_wh uuid, p_mat uuid, p_prod uuid, p_color uuid, p_date date)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT coalesce(sum(quantity), 0) FROM public.inventory_transactions
  WHERE warehouse_id = p_wh AND material_id IS NOT DISTINCT FROM p_mat AND product_id IS NOT DISTINCT FROM p_prod
    AND color_id IS NOT DISTINCT FROM p_color AND transaction_date <= p_date
$$;

CREATE FUNCTION public.inventory_check_outflow(p_wh uuid, p_mat uuid, p_prod uuid, p_color uuid, p_date date,
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
  at_date := public.inventory_balance_as_of(p_wh, p_mat, p_prod, p_color, p_date);
  IF at_date + p_delta < 0 THEN
    RAISE EXCEPTION '%: only % in stock at % on %', p_item, trim_scale(at_date), p_where, p_date
      USING ERRCODE = '23514';
  END IF;
  SELECT x.transaction_date, x.run INTO bad
  FROM (SELECT transaction_date,
               sum(quantity) OVER (ORDER BY transaction_date, created_at, id) AS run
        FROM public.inventory_transactions
        WHERE warehouse_id = p_wh AND material_id IS NOT DISTINCT FROM p_mat AND product_id IS NOT DISTINCT FROM p_prod
          AND color_id IS NOT DISTINCT FROM p_color) x
  WHERE x.transaction_date > p_date AND x.run + p_delta < 0
  ORDER BY x.transaction_date
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION '%: stock at % would drop to % on % — later movements already use it',
      p_item, p_where, trim_scale(bad.run + p_delta), bad.transaction_date USING ERRCODE = '23514';
  END IF;
END;
$$;

CREATE FUNCTION public.inventory_check_after_opening(p_wh uuid, p_mat uuid, p_prod uuid, p_color uuid, p_date date,
                                                     p_item text, p_where text)
RETURNS void
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE ob date;
BEGIN
  SELECT min(t.transaction_date) INTO ob FROM public.inventory_transactions t
  WHERE t.warehouse_id = p_wh AND t.material_id IS NOT DISTINCT FROM p_mat AND t.product_id IS NOT DISTINCT FROM p_prod
    AND t.color_id IS NOT DISTINCT FROM p_color
    AND t.transaction_type = 'opening_balance'
    AND NOT EXISTS (SELECT 1 FROM public.inventory_movements r WHERE r.reverses_movement_id = t.movement_id);
  IF ob IS NOT NULL AND p_date < ob THEN
    RAISE EXCEPTION '%: % is before its opening balance at % (%)', p_item, p_date, p_where, ob USING ERRCODE = '23514';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.inventory_lock_item(uuid, uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inventory_balance_as_of(uuid, uuid, uuid, uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inventory_check_outflow(uuid, uuid, uuid, uuid, date, numeric, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inventory_check_after_opening(uuid, uuid, uuid, uuid, date, text, text) FROM PUBLIC, anon, authenticated;


-- ------------------------------------------------------------
-- Posting (replaces 023's): lines may carry color_id
-- ------------------------------------------------------------
-- p: { type, warehouse_id, to_warehouse_id?, supplier_id? | new_supplier_name?,
--      movement_date?, reason?, reference?, notes?,
--      lines: [{ material_id | product_id, color_id?, quantity, unit_id, unit_cost? }] }
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
      IF EXISTS (SELECT 1 FROM public.product_category_colors WHERE category_id = prod.category_id) THEN
        IF item_col IS NULL THEN
          RAISE EXCEPTION '%: choose the colour', prod.canonical_name USING ERRCODE = '23514';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM public.product_category_colors WHERE category_id = prod.category_id AND color_id = item_col) THEN
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
$$;


-- ------------------------------------------------------------
-- Reversal (replaces 023's): keeps the colour
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
    PERFORM public.inventory_lock_item(t.warehouse_id, t.material_id, t.product_id, t.color_id);
    SELECT coalesce(m.name, pr.canonical_name) || coalesce(' ' || cp.name, '') INTO label
    FROM (SELECT 1) x
    LEFT JOIN public.materials m ON m.id = t.material_id
    LEFT JOIN public.products pr ON pr.id = t.product_id
    LEFT JOIN public.color_palette cp ON cp.id = t.color_id;
    place := (SELECT b.name || ' — ' || w.name FROM public.warehouses w JOIN public.branches b ON b.id = w.branch_id WHERE w.id = t.warehouse_id);
    PERFORM public.inventory_check_outflow(t.warehouse_id, t.material_id, t.product_id, t.color_id, orig.movement_date,
                                           -t.quantity, label, place);
    INSERT INTO public.inventory_transactions
      (organization_id, movement_id, transaction_type, branch_id, warehouse_id, material_id, product_id, color_id,
       quantity, stock_unit_id, entered_quantity, entered_unit_id, transaction_date, created_by)
    VALUES
      (org, rev_id, 'reversal', t.branch_id, t.warehouse_id, t.material_id, t.product_id, t.color_id,
       -t.quantity, t.stock_unit_id, t.entered_quantity, t.entered_unit_id, orig.movement_date, uid);
  END LOOP;

  RETURN rev_id;
END;
$$;


-- ------------------------------------------------------------
-- 2. Import aliases
-- ------------------------------------------------------------
CREATE TABLE public.import_aliases (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  alias_type       text NOT NULL CHECK (alias_type IN ('product', 'color', 'category')),
  scope            text NOT NULL DEFAULT '',   -- normalized sheet heading the name appeared under ('' = anywhere)
  alias_normalized text NOT NULL CHECK (alias_normalized <> ''),
  alias_text       text NOT NULL,              -- as written on the sheet
  product_id       uuid REFERENCES public.products(id),
  color_id         uuid REFERENCES public.color_palette(id),
  category_id      uuid REFERENCES public.product_categories(id),
  created_by       uuid REFERENCES auth.users(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, alias_type, scope, alias_normalized),
  CHECK (CASE alias_type WHEN 'product'  THEN product_id IS NOT NULL
                         WHEN 'color'    THEN color_id IS NOT NULL
                         ELSE category_id IS NOT NULL END)
);

CREATE TRIGGER trg_import_aliases_audit AFTER INSERT OR UPDATE OR DELETE ON public.import_aliases
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('import_alias', 'id');
CREATE TRIGGER trg_import_aliases_product_org BEFORE INSERT OR UPDATE ON public.import_aliases
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('products', 'product_id');
CREATE TRIGGER trg_import_aliases_category_org BEFORE INSERT OR UPDATE ON public.import_aliases
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('product_categories', 'category_id');
CREATE TRIGGER trg_import_aliases_color_org BEFORE INSERT OR UPDATE ON public.import_aliases
  FOR EACH ROW EXECUTE FUNCTION public.check_color_org('color_id');

ALTER TABLE public.import_aliases ENABLE ROW LEVEL SECURITY;
CREATE POLICY "import_aliases: read own org" ON public.import_aliases FOR SELECT
  USING (organization_id = public.get_my_org_id());
-- Master-data admins can correct a learned match; imports add them via post_inventory_batch
CREATE POLICY "import_aliases: admins can manage" ON public.import_aliases FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'));

COMMENT ON TABLE public.import_aliases
  IS 'How names on imported stock sheets map to the catalogue; learned when an import is posted.';


-- ------------------------------------------------------------
-- 3. Batch posting
-- ------------------------------------------------------------
-- p: { movements: [<post_inventory_movement payload>, ...],
--      aliases:   [{ alias_type, scope, alias_text, product_id | color_id | category_id }, ...] }
-- All movements post (each fully checked by post_inventory_movement) and
-- the aliases are saved — or nothing is.
CREATE OR REPLACE FUNCTION public.post_inventory_batch(p jsonb)
RETURNS uuid[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  uid uuid := auth.uid();
  mv  jsonb;
  a   jsonb;
  ids uuid[] := '{}';
BEGIN
  IF uid IS NULL OR org IS NULL THEN
    RAISE EXCEPTION 'Sign in to record stock movements' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p->'movements') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'movements') = 0 THEN
    RAISE EXCEPTION 'Nothing to post' USING ERRCODE = '23514';
  END IF;

  FOR mv IN SELECT * FROM jsonb_array_elements(p->'movements') LOOP
    ids := ids || public.post_inventory_movement(mv);
  END LOOP;

  -- Only someone who just posted may teach matches, and only for this org
  FOR a IN SELECT * FROM jsonb_array_elements(coalesce(p->'aliases', '[]'::jsonb)) LOOP
    INSERT INTO public.import_aliases
      (organization_id, alias_type, scope, alias_normalized, alias_text, product_id, color_id, category_id, created_by)
    VALUES
      (org, a->>'alias_type', public.normalize_name(coalesce(a->>'scope', '')), public.normalize_name(a->>'alias_text'),
       btrim(a->>'alias_text'), nullif(a->>'product_id', '')::uuid, nullif(a->>'color_id', '')::uuid,
       nullif(a->>'category_id', '')::uuid, uid)
    ON CONFLICT (organization_id, alias_type, scope, alias_normalized) DO UPDATE
      SET product_id = EXCLUDED.product_id, color_id = EXCLUDED.color_id, category_id = EXCLUDED.category_id,
          alias_text = EXCLUDED.alias_text, created_by = EXCLUDED.created_by;
  END LOOP;

  RETURN ids;
END;
$$;

REVOKE ALL ON FUNCTION public.post_inventory_batch(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_inventory_batch(jsonb) TO authenticated;
