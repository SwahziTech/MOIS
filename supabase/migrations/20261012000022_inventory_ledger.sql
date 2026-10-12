-- ============================================================
-- 022 — Inventory engine (build-plan 1b, PRD 4.6 / 6.25 / 6.26)
--
-- Stock is never a number someone types (AGENTS.md §5). It is the sum of
-- an append-only ledger:
--
--   inventory_movements      one document: a receipt, an issue, a transfer,
--                            an adjustment, a stock count, an opening
--                            balance, or the reversal of an earlier one
--   inventory_transactions   its lines — what, how much (signed, in the
--                            item's stock unit, plus exactly what was
--                            entered), where, when, why, who, reference
--   stock_balances (view)    SUM of the ledger per warehouse per item
--
-- The app writes ONLY through post_inventory_movement() and
-- reverse_inventory_movement() (SECURITY DEFINER, permission-checked per
-- warehouse); there are no insert/update policies, and ledger rows can
-- never be updated. Mistakes are corrected by a reversal, which keeps both.
--
-- Access is scoped: has_permission_at() honours role grants that are
-- org-wide, for a branch, or for a single warehouse (PRD 3.1 C:
-- storekeepers work in their assigned warehouses).
--
-- Also: suppliers (PRD 4.4), linked from material_branch_sources, which
-- 019 left as free text "until 1b".
-- ============================================================


-- ------------------------------------------------------------
-- 1. Scoped permission check
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.has_permission_at(code text, p_branch_id uuid, p_warehouse_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles ur
    JOIN public.roles r             ON r.id = ur.role_id
    JOIN public.role_permissions rp ON rp.role_id = r.id
    JOIN public.permissions p       ON p.id = rp.permission_id
    WHERE ur.user_id = auth.uid()
      AND ur.organization_id = public.get_my_org_id()
      AND r.organization_id = ur.organization_id
      AND p.code = has_permission_at.code
      AND (   (ur.branch_id IS NULL AND ur.warehouse_id IS NULL)            -- org-wide
           OR (ur.warehouse_id IS NULL AND ur.branch_id = p_branch_id)      -- this branch
           OR (ur.warehouse_id = p_warehouse_id))                           -- this warehouse
  )
$$;

COMMENT ON FUNCTION public.has_permission_at(text, uuid, uuid)
  IS 'True if the caller holds this permission org-wide, for this branch, or for this warehouse.';


-- ------------------------------------------------------------
-- 2. Suppliers
-- ------------------------------------------------------------
CREATE TABLE public.suppliers (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name            text NOT NULL CHECK (btrim(name) <> ''),
  contact_person  text,
  phone           text,
  email           text,
  address         text,
  tax_id          text,
  notes           text,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);

CREATE INDEX idx_suppliers_org ON public.suppliers(organization_id);

CREATE TRIGGER trg_suppliers_updated_at
  BEFORE UPDATE ON public.suppliers
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_suppliers_audit AFTER INSERT OR UPDATE OR DELETE ON public.suppliers
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('supplier', 'id');
CREATE TRIGGER trg_suppliers_no_delete BEFORE DELETE ON public.suppliers
  FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('supplier');

ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "suppliers: read own org" ON public.suppliers FOR SELECT
  USING (organization_id = public.get_my_org_id());
-- Supplier master data is administered with the materials it supplies
CREATE POLICY "suppliers: admins can manage" ON public.suppliers FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('materials.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('materials.manage'));

ALTER TABLE public.material_branch_sources
  ADD COLUMN supplier_id uuid REFERENCES public.suppliers(id) ON DELETE RESTRICT;
CREATE TRIGGER trg_mbs_supplier_org
  BEFORE INSERT OR UPDATE ON public.material_branch_sources
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('suppliers', 'supplier_id');
COMMENT ON COLUMN public.material_branch_sources.supplier_id
  IS 'The supplier, once recorded. source_name stays as the place/description from the source data.';


-- ------------------------------------------------------------
-- 3. The ledger
-- ------------------------------------------------------------
CREATE TABLE public.inventory_movements (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id      uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  movement_type        text NOT NULL CHECK (movement_type IN
                         ('opening_balance', 'receipt', 'issue', 'transfer', 'adjustment', 'count', 'reversal')),
  branch_id            uuid NOT NULL REFERENCES public.branches(id),
  warehouse_id         uuid NOT NULL REFERENCES public.warehouses(id),
  to_warehouse_id      uuid REFERENCES public.warehouses(id),        -- transfer destination
  supplier_id          uuid REFERENCES public.suppliers(id),         -- receipt
  reverses_movement_id uuid UNIQUE REFERENCES public.inventory_movements(id),
  movement_date        date NOT NULL,
  reason               text,
  reference            text,           -- delivery note, request no., ...
  notes                text,
  created_by           uuid NOT NULL REFERENCES auth.users(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  CHECK ((movement_type = 'transfer') = (to_warehouse_id IS NOT NULL)),
  CHECK ((movement_type = 'reversal') = (reverses_movement_id IS NOT NULL)),
  CHECK (supplier_id IS NULL OR movement_type = 'receipt')
);

CREATE INDEX idx_inv_mov_org_date ON public.inventory_movements(organization_id, movement_date DESC, created_at DESC);
CREATE INDEX idx_inv_mov_wh       ON public.inventory_movements(warehouse_id);

CREATE TABLE public.inventory_transactions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  movement_id      uuid NOT NULL REFERENCES public.inventory_movements(id),
  transaction_type text NOT NULL CHECK (transaction_type IN
                     ('opening_balance', 'receipt', 'issue', 'transfer_out', 'transfer_in', 'adjustment', 'count', 'reversal')),
  branch_id        uuid NOT NULL REFERENCES public.branches(id),
  warehouse_id     uuid NOT NULL REFERENCES public.warehouses(id),
  material_id      uuid REFERENCES public.materials(id),
  product_id       uuid REFERENCES public.products(id),
  quantity         numeric NOT NULL,   -- signed, in stock_unit_id: + in, - out
  stock_unit_id    uuid NOT NULL REFERENCES public.units(id),
  entered_quantity numeric NOT NULL,   -- exactly as entered
  entered_unit_id  uuid NOT NULL REFERENCES public.units(id),
  counted_quantity numeric,            -- count: quantity found, in the stock unit
  unit_cost        numeric CHECK (unit_cost IS NULL OR unit_cost >= 0),  -- per entered unit; receipts/opening
  transaction_date date NOT NULL,
  created_by       uuid NOT NULL REFERENCES auth.users(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(material_id, product_id) = 1),
  CHECK (quantity <> 0 OR transaction_type = 'count'),
  CHECK ((transaction_type = 'count') = (counted_quantity IS NOT NULL))
);

CREATE INDEX idx_inv_tx_balance  ON public.inventory_transactions(warehouse_id, material_id, product_id);
CREATE INDEX idx_inv_tx_movement ON public.inventory_transactions(movement_id);
CREATE INDEX idx_inv_tx_org_date ON public.inventory_transactions(organization_id, transaction_date DESC);

COMMENT ON TABLE public.inventory_transactions
  IS 'Authoritative, append-only inventory ledger (AGENTS.md §5). Written only by post_inventory_movement / reverse_inventory_movement.';

-- Append-only: never updated; deleted only by server-side maintenance
-- (service_role / SQL), e.g. removing a whole test organization
CREATE OR REPLACE FUNCTION public.inventory_ledger_append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' AND (auth.role() = 'service_role' OR auth.uid() IS NULL) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'Inventory records are permanent — post a correcting movement instead'
    USING ERRCODE = '42501';
END;
$$;

CREATE TRIGGER trg_inv_mov_append_only
  BEFORE UPDATE OR DELETE ON public.inventory_movements
  FOR EACH ROW EXECUTE FUNCTION public.inventory_ledger_append_only();
CREATE TRIGGER trg_inv_tx_append_only
  BEFORE UPDATE OR DELETE ON public.inventory_transactions
  FOR EACH ROW EXECUTE FUNCTION public.inventory_ledger_append_only();

ALTER TABLE public.inventory_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_transactions ENABLE ROW LEVEL SECURITY;

-- Read: where the caller may view inventory. No write policies at all.
CREATE POLICY "inv_mov: read where allowed" ON public.inventory_movements FOR SELECT
  USING (organization_id = public.get_my_org_id()
         AND (public.has_permission_at('inventory.view', branch_id, warehouse_id)
              OR (to_warehouse_id IS NOT NULL AND public.has_permission_at('inventory.view',
                    (SELECT w.branch_id FROM public.warehouses w WHERE w.id = to_warehouse_id), to_warehouse_id))));
CREATE POLICY "inv_tx: read where allowed" ON public.inventory_transactions FOR SELECT
  USING (organization_id = public.get_my_org_id()
         AND public.has_permission_at('inventory.view', branch_id, warehouse_id));

-- Derived balances: the caller's RLS on the ledger applies
CREATE VIEW public.stock_balances WITH (security_invoker = true) AS
SELECT organization_id, branch_id, warehouse_id, material_id, product_id, stock_unit_id,
       sum(quantity)         AS quantity,
       max(transaction_date) AS last_movement_date,
       count(*)              AS movement_lines
FROM public.inventory_transactions
GROUP BY organization_id, branch_id, warehouse_id, material_id, product_id, stock_unit_id;

COMMENT ON VIEW public.stock_balances
  IS 'Current stock per warehouse per item = SUM of the ledger. Never stored, never typed.';


-- ------------------------------------------------------------
-- 4. Posting
-- ------------------------------------------------------------
-- Current balance of one item in one warehouse, under a transaction lock
-- so two postings can't both spend the same stock.
CREATE OR REPLACE FUNCTION public.inventory_locked_balance(p_warehouse_id uuid, p_material_id uuid, p_product_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE bal numeric;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_warehouse_id::text || coalesce(p_material_id, p_product_id)::text, 22));
  SELECT coalesce(sum(quantity), 0) INTO bal
  FROM public.inventory_transactions
  WHERE warehouse_id = p_warehouse_id
    AND material_id IS NOT DISTINCT FROM p_material_id
    AND product_id  IS NOT DISTINCT FROM p_product_id;
  RETURN bal;
END;
$$;
REVOKE ALL ON FUNCTION public.inventory_locked_balance(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;

-- p: { type, warehouse_id, to_warehouse_id?, supplier_id?, movement_date?,
--      reason?, reference?, notes?,
--      lines: [{ material_id | product_id, quantity, unit_id, unit_cost? }] }
-- quantity: > 0 as entered; adjustment may be negative (stock removed);
-- count: the quantity found (>= 0).
CREATE OR REPLACE FUNCTION public.post_inventory_movement(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org      uuid := public.get_my_org_id();
  uid      uuid := auth.uid();
  mtype    text := p->>'type';
  wh       public.warehouses;
  to_wh    public.warehouses;
  perm     text;
  mdate    date := coalesce(nullif(p->>'movement_date', '')::date, current_date);
  mov_id   uuid;
  line     jsonb;
  n_lines  int;
  mat      public.materials;
  prod     public.products;
  item_mat uuid;
  item_pro uuid;
  item_name text;
  stock_u  uuid;
  factor   numeric;
  entered  numeric;
  qty      numeric;
  bal      numeric;
  seen     text[] := '{}';
  wh_label text;
BEGIN
  IF uid IS NULL OR org IS NULL THEN
    RAISE EXCEPTION 'Sign in to record stock movements' USING ERRCODE = '42501';
  END IF;

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

  IF mtype = 'transfer' THEN
    SELECT * INTO to_wh FROM public.warehouses
    WHERE id = (p->>'to_warehouse_id')::uuid AND organization_id = org AND status = 'active';
    IF NOT FOUND OR to_wh.id = wh.id THEN
      RAISE EXCEPTION 'Choose a different, active destination warehouse' USING ERRCODE = '23514';
    END IF;
  ELSIF p ? 'to_warehouse_id' AND nullif(p->>'to_warehouse_id', '') IS NOT NULL THEN
    RAISE EXCEPTION 'Only transfers have a destination' USING ERRCODE = '23514';
  END IF;

  IF nullif(p->>'supplier_id', '') IS NOT NULL THEN
    IF mtype <> 'receipt' THEN
      RAISE EXCEPTION 'Only receipts have a supplier' USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id = (p->>'supplier_id')::uuid AND organization_id = org) THEN
      RAISE EXCEPTION 'Supplier not found' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF mdate > current_date THEN
    RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514';
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
    (org, mtype, wh.branch_id, wh.id, to_wh.id, nullif(p->>'supplier_id', '')::uuid,
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

    -- Item, its stock unit, and the factor from the entered unit
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

    bal := public.inventory_locked_balance(wh.id, item_mat, item_pro);

    IF mtype = 'opening_balance' AND EXISTS (
         SELECT 1 FROM public.inventory_transactions
         WHERE warehouse_id = wh.id AND material_id IS NOT DISTINCT FROM item_mat AND product_id IS NOT DISTINCT FROM item_pro) THEN
      RAISE EXCEPTION '%: already has stock movements here — use an adjustment or a count', item_name USING ERRCODE = '23514';
    END IF;

    IF mtype IN ('issue', 'transfer') AND qty > bal THEN
      RAISE EXCEPTION '%: only % in stock at %', item_name, trim_scale(bal), wh_label USING ERRCODE = '23514';
    END IF;
    IF mtype = 'adjustment' AND qty < 0 AND -qty > bal THEN
      RAISE EXCEPTION '%: only % in stock at % — can''t remove more', item_name, trim_scale(bal), wh_label USING ERRCODE = '23514';
    END IF;

    INSERT INTO public.inventory_transactions
      (organization_id, movement_id, transaction_type, branch_id, warehouse_id, material_id, product_id,
       quantity, stock_unit_id, entered_quantity, entered_unit_id, counted_quantity, unit_cost, transaction_date, created_by)
    VALUES
      (org, mov_id,
       CASE mtype WHEN 'transfer' THEN 'transfer_out' ELSE mtype END,
       wh.branch_id, wh.id, item_mat, item_pro,
       CASE mtype WHEN 'issue' THEN -qty WHEN 'transfer' THEN -qty WHEN 'count' THEN qty - bal ELSE qty END,
       stock_u, entered, (line->>'unit_id')::uuid,
       CASE WHEN mtype = 'count' THEN qty END,
       nullif(line->>'unit_cost', '')::numeric, mdate, uid);

    IF mtype = 'transfer' THEN
      PERFORM public.inventory_locked_balance(to_wh.id, item_mat, item_pro);
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

-- Undo a movement by posting its exact opposite; both stay on record.
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
  bal    numeric;
  label  text;
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
    (org, 'reversal', orig.branch_id, orig.warehouse_id, orig.id, current_date, btrim(p_reason), orig.reference, uid)
  RETURNING id INTO rev_id;

  FOR t IN SELECT * FROM public.inventory_transactions WHERE movement_id = orig.id AND quantity <> 0 LOOP
    bal := public.inventory_locked_balance(t.warehouse_id, t.material_id, t.product_id);
    IF t.quantity > 0 AND t.quantity > bal THEN
      SELECT coalesce(m.name, pr.canonical_name) INTO label
      FROM (SELECT 1) x
      LEFT JOIN public.materials m ON m.id = t.material_id
      LEFT JOIN public.products pr ON pr.id = t.product_id;
      RAISE EXCEPTION '%: only % left in stock — part of it has already moved on', label, trim_scale(bal)
        USING ERRCODE = '23514';
    END IF;
    INSERT INTO public.inventory_transactions
      (organization_id, movement_id, transaction_type, branch_id, warehouse_id, material_id, product_id,
       quantity, stock_unit_id, entered_quantity, entered_unit_id, transaction_date, created_by)
    VALUES
      (org, rev_id, 'reversal', t.branch_id, t.warehouse_id, t.material_id, t.product_id,
       -t.quantity, t.stock_unit_id, t.entered_quantity, t.entered_unit_id, current_date, uid);
  END LOOP;

  RETURN rev_id;
END;
$$;

REVOKE ALL ON FUNCTION public.post_inventory_movement(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reverse_inventory_movement(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_inventory_movement(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reverse_inventory_movement(uuid, text) TO authenticated;
