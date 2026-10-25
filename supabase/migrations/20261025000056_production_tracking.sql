-- ============================================================
-- 056 — Production tracking (1d): who made a batch, on what, what was
-- thrown away making it, and what quality control saw at release
--
-- SwahziTech, 2026-10-25, the user: build them all, in the batch's note
-- zone, "let them not consume space, though they are very important for
-- labour cost calculations"; team and machine REQUIRED on every new batch,
-- without feeding names each time — a team is created once and selected;
-- "team name only … if edits are required, record who worked".
--
--   * Teams per branch, with their members (names only — not system users).
--     A batch records its team; who worked only when that differs (someone
--     away, a helper): worker_ids NULL = the whole team.
--   * Machines / lines per branch, linked to the products they make.
--   * Thrown away (waste): material lost making a batch — out of the raw
--     store on its own movement ('waste') with a reason, costed first in
--     first out like the batch, but NOT in the batch's material cost
--     (rejects and waste never re-cost the products — 2026-10-25).
--   * Quality tags at release (Colour, Edges, Size, Strength, Surface) with
--     the release note already there.
-- Batches already recorded keep no team or machine.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Teams and their members
-- ------------------------------------------------------------
CREATE TABLE public.production_teams (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  name            text NOT NULL CHECK (btrim(name) <> ''),
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_production_teams_name ON public.production_teams (branch_id, public.normalize_name(name));

CREATE TABLE public.production_team_members (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  team_id         uuid NOT NULL REFERENCES public.production_teams(id) ON DELETE RESTRICT,
  name            text NOT NULL CHECK (btrim(name) <> ''),
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),   -- left the team: kept for past batches
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_production_team_members_team ON public.production_team_members (team_id);

-- ------------------------------------------------------------
-- 2. Machines / lines and the products they make
-- ------------------------------------------------------------
CREATE TABLE public.machines (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  name            text NOT NULL CHECK (btrim(name) <> ''),
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_machines_name ON public.machines (branch_id, public.normalize_name(name));

CREATE TABLE public.machine_products (
  machine_id      uuid NOT NULL REFERENCES public.machines(id) ON DELETE CASCADE,
  product_id      uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  PRIMARY KEY (machine_id, product_id)
);

-- ------------------------------------------------------------
-- 3. Waste reasons (a list per organization, like reject reasons)
-- ------------------------------------------------------------
CREATE TABLE public.waste_reasons (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name            text NOT NULL CHECK (btrim(name) <> ''),
  display_order   int  NOT NULL DEFAULT 0,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_waste_reasons_name ON public.waste_reasons (organization_id, public.normalize_name(name));
INSERT INTO public.waste_reasons (organization_id, name, display_order)
SELECT o.id, r.name, r.ord FROM public.organizations o
CROSS JOIN (VALUES ('Mix hardened', 1), ('Spilled', 2), ('Bad mix', 3), ('Torn bag', 4)) AS r(name, ord)
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------
-- 4. On the batch
-- ------------------------------------------------------------
ALTER TABLE public.production_batches
  ADD COLUMN team_id uuid REFERENCES public.production_teams(id) ON DELETE RESTRICT,
  ADD COLUMN worker_ids uuid[],            -- who worked when not the whole team (NULL = the whole team)
  ADD COLUMN machine_id uuid REFERENCES public.machines(id) ON DELETE RESTRICT,
  ADD COLUMN waste_movement_id uuid REFERENCES public.inventory_movements(id),
  ADD COLUMN qc_tags text[] CHECK (qc_tags <@ ARRAY['Colour', 'Edges', 'Size', 'Strength', 'Surface']);
COMMENT ON COLUMN public.production_batches.worker_ids IS 'production_team_members who worked, when not the whole team (056).';
COMMENT ON COLUMN public.production_batches.qc_tags IS 'Quality issues seen at release (056); details in release_note.';

CREATE TABLE public.production_batch_waste (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  batch_id        uuid NOT NULL REFERENCES public.production_batches(id) ON DELETE RESTRICT,
  material_id     uuid NOT NULL REFERENCES public.materials(id) ON DELETE RESTRICT,
  quantity        numeric NOT NULL CHECK (quantity > 0),          -- as entered, in unit_id
  unit_id         uuid NOT NULL REFERENCES public.units(id),
  stock_quantity  numeric NOT NULL CHECK (stock_quantity > 0),
  reason_id       uuid NOT NULL REFERENCES public.waste_reasons(id) ON DELETE RESTRICT,
  cost            numeric                                          -- first in first out, VAT included; NULL = no cost known
);
CREATE INDEX idx_production_batch_waste_batch ON public.production_batch_waste (batch_id);

-- The ledger: a 'waste' entry
ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_movement_type_check;
ALTER TABLE public.inventory_movements ADD CONSTRAINT inventory_movements_movement_type_check
  CHECK (movement_type IN ('opening_balance', 'receipt', 'issue', 'transfer', 'adjustment', 'count', 'reversal', 'reclassification',
                           'production_use', 'production_output', 'curing_release', 'waste'));
ALTER TABLE public.inventory_transactions DROP CONSTRAINT inventory_transactions_transaction_type_check;
ALTER TABLE public.inventory_transactions ADD CONSTRAINT inventory_transactions_transaction_type_check
  CHECK (transaction_type IN ('opening_balance', 'receipt', 'issue', 'transfer_out', 'transfer_in', 'adjustment', 'count', 'reversal', 'reclassification',
                              'production_use', 'production_output', 'curing_out', 'curing_in', 'waste'));

-- ------------------------------------------------------------
-- 5. Housekeeping and who may change the lists
-- ------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['production_teams', 'production_team_members', 'machines', 'waste_reasons'] LOOP
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_no_delete BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete(%L)', t, t, replace(t, '_', ' '));
  END LOOP;
  FOREACH t IN ARRAY ARRAY['production_teams', 'production_team_members', 'machines', 'waste_reasons', 'production_batch_waste'] LOOP
    EXECUTE format('CREATE TRIGGER trg_%s_audit AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.audit_row_change(%L, %L)', t, t, rtrim(t, 's'), 'id');
  END LOOP;
END;
$$;
CREATE TRIGGER trg_machine_products_audit AFTER INSERT OR UPDATE OR DELETE ON public.machine_products
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('machine_product', 'machine_id');

ALTER TABLE public.production_teams ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.production_team_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.machines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.machine_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.waste_reasons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.production_batch_waste ENABLE ROW LEVEL SECURITY;

-- whoever records production at the branch keeps its teams and machines (created where the batch is entered)
CREATE FUNCTION public.can_keep_production_lists(p_branch_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT public.has_permission_at('production.create', p_branch_id, NULL) OR public.has_permission_at('products.manage', p_branch_id, NULL)
$$;

CREATE POLICY "production_teams: read own org" ON public.production_teams FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "production_teams: branch adds" ON public.production_teams FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.can_keep_production_lists(branch_id));
CREATE POLICY "production_teams: branch changes" ON public.production_teams FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND public.can_keep_production_lists(branch_id))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.can_keep_production_lists(branch_id));

CREATE POLICY "production_team_members: read own org" ON public.production_team_members FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "production_team_members: branch adds" ON public.production_team_members FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND EXISTS (SELECT 1 FROM public.production_teams t
              WHERE t.id = team_id AND t.organization_id = production_team_members.organization_id AND public.can_keep_production_lists(t.branch_id)));
CREATE POLICY "production_team_members: branch changes" ON public.production_team_members FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND EXISTS (SELECT 1 FROM public.production_teams t
         WHERE t.id = team_id AND public.can_keep_production_lists(t.branch_id)))
  WITH CHECK (organization_id = public.get_my_org_id() AND EXISTS (SELECT 1 FROM public.production_teams t
              WHERE t.id = team_id AND t.organization_id = production_team_members.organization_id AND public.can_keep_production_lists(t.branch_id)));

CREATE POLICY "machines: read own org" ON public.machines FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "machines: branch adds" ON public.machines FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.can_keep_production_lists(branch_id));
CREATE POLICY "machines: branch changes" ON public.machines FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND public.can_keep_production_lists(branch_id))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.can_keep_production_lists(branch_id));

CREATE POLICY "machine_products: read own org" ON public.machine_products FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "machine_products: branch adds" ON public.machine_products FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND EXISTS (SELECT 1 FROM public.machines m
              WHERE m.id = machine_id AND m.organization_id = machine_products.organization_id AND public.can_keep_production_lists(m.branch_id))
              AND EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.organization_id = machine_products.organization_id));
CREATE POLICY "machine_products: branch removes" ON public.machine_products FOR DELETE
  USING (organization_id = public.get_my_org_id() AND EXISTS (SELECT 1 FROM public.machines m
         WHERE m.id = machine_id AND public.can_keep_production_lists(m.branch_id)));

CREATE POLICY "waste_reasons: read own org" ON public.waste_reasons FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "waste_reasons: org admins add" ON public.waste_reasons FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'));
CREATE POLICY "waste_reasons: org admins change" ON public.waste_reasons FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'));

CREATE POLICY "production_batch_waste: read own org" ON public.production_batch_waste FOR SELECT USING (organization_id = public.get_my_org_id());


-- ------------------------------------------------------------
-- 6. Thrown away while making a batch: out of its raw store, costed apart
-- ------------------------------------------------------------
-- lines: [{ material_id, quantity, unit_id, reason_id }]
CREATE FUNCTION public.production_post_waste(p_batch uuid, p_lines jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  b      public.production_batches;
  wh     public.warehouses;
  mv     uuid;
  l      jsonb;
  mat    public.materials;
  factor numeric;
  q      numeric;
  m      record;
  fc     record;
BEGIN
  SELECT * INTO b FROM public.production_batches WHERE id = p_batch FOR UPDATE;
  SELECT * INTO wh FROM public.warehouses WHERE id = b.raw_warehouse_id;
  INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, created_by, production_batch_id)
  VALUES (b.organization_id, 'waste', b.branch_id, wh.id, b.batch_date, 'Thrown away making a batch', auth.uid(), b.id)
  RETURNING id INTO mv;
  FOR l IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    SELECT * INTO mat FROM public.materials WHERE id = nullif(l->>'material_id', '')::uuid AND organization_id = b.organization_id AND status = 'active'
      AND (branch_id IS NULL OR branch_id = b.branch_id);
    IF NOT FOUND THEN RAISE EXCEPTION 'Thrown away: material not found or not used at this branch' USING ERRCODE = '23514'; END IF;
    IF (l->>'unit_id')::uuid = mat.stock_unit_id THEN factor := 1;
    ELSE
      SELECT factor_to_stock_unit INTO factor FROM public.material_unit_conversions WHERE material_id = mat.id AND unit_id = (l->>'unit_id')::uuid;
      IF NOT FOUND THEN RAISE EXCEPTION 'Thrown away — %: use its stock unit or one of its listed units', mat.name USING ERRCODE = '23514'; END IF;
    END IF;
    q := nullif(l->>'quantity', '')::numeric;
    IF q IS NULL OR q <= 0 THEN RAISE EXCEPTION 'Thrown away — %: enter how much', mat.name USING ERRCODE = '23514'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.waste_reasons WHERE id = nullif(l->>'reason_id', '')::uuid AND organization_id = b.organization_id AND status = 'active') THEN
      RAISE EXCEPTION 'Thrown away — %: choose why', mat.name USING ERRCODE = '23514';
    END IF;
    INSERT INTO public.production_batch_waste (organization_id, batch_id, material_id, quantity, unit_id, stock_quantity, reason_id)
    VALUES (b.organization_id, b.id, mat.id, q, (l->>'unit_id')::uuid, q * factor, (l->>'reason_id')::uuid);
    PERFORM public.production_ledger_line(mv, 'waste', wh, mat.id, NULL, NULL, -(q * factor), mat.stock_unit_id, q, (l->>'unit_id')::uuid, b.batch_date, mat.name);
  END LOOP;
  UPDATE public.production_batches SET waste_movement_id = mv WHERE id = b.id;
  -- costed first in first out, like the batch (055); a material thrown away twice shares its cost by quantity
  FOR m IN SELECT material_id, sum(stock_quantity) AS total FROM public.production_batch_waste WHERE batch_id = b.id GROUP BY material_id LOOP
    SELECT * INTO fc FROM public.fifo_movement_cost(b.branch_id, m.material_id, mv);
    UPDATE public.production_batch_waste SET cost = round(fc.cost * stock_quantity / m.total, 2)
     WHERE batch_id = b.id AND material_id = m.material_id;
  END LOOP;
  RETURN mv;
END;
$$;
REVOKE ALL ON FUNCTION public.production_post_waste(uuid, jsonb) FROM PUBLIC, anon, authenticated;

-- live definition as of 048; team, machine, who worked and thrown away are added (056)
CREATE OR REPLACE FUNCTION public.record_production_batch(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  ocol    uuid;          -- a product's own colour in the mix (047)
  oline   uuid;          -- the order line it counts towards (048)
  team    public.production_teams;   -- who made it (056)
  mach    public.machines;           -- what it was made on (056)
  workers uuid[];                    -- who worked, when not the whole team (056)
  ol      record;
  org     uuid := public.get_my_org_id();
  today   date;
  bdate   date;
  raw     public.warehouses;
  cur     public.warehouses;
  main    public.products;
  prod    public.products;
  col     uuid := nullif(p->>'color_id', '')::uuid;
  rv      uuid := nullif(p->>'recipe_version_id', '')::uuid;
  bags    numeric := nullif(p->>'cement_bags', '')::numeric;
  others  boolean := coalesce((p->>'allow_other_products')::boolean, false);
  outs    jsonb;
  o       jsonb;
  band    record;
  bid     uuid;
  mv      uuid;
  l       jsonb;
  mat     public.materials;
  factor  numeric;
  std     numeric;
  bal     numeric;
  short   text := '';
  pname   text;
  total   int := 0;
  eq      numeric := 0;
  bmin    numeric := 0;
  bmax    numeric := 0;
  banded  boolean := true;
  seen    uuid[] := '{}';
  n       int := 0;
BEGIN
  IF org IS NULL OR auth.uid() IS NULL THEN RAISE EXCEPTION 'Not signed in to an organization' USING ERRCODE = '42501'; END IF;
  today := public.org_today(org);
  bdate := coalesce(nullif(p->>'batch_date', '')::date, today);
  IF bdate > today THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;

  SELECT * INTO raw FROM public.warehouses WHERE id = nullif(p->>'raw_warehouse_id', '')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND OR raw.type NOT IN ('raw_materials', 'general') THEN RAISE EXCEPTION 'Choose the store the materials come from' USING ERRCODE = '23514'; END IF;
  SELECT * INTO cur FROM public.warehouses WHERE id = nullif(p->>'curing_warehouse_id', '')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND OR cur.type <> 'wip' OR cur.branch_id <> raw.branch_id THEN
    RAISE EXCEPTION 'Choose the branch''s curing store' USING ERRCODE = '23514';
  END IF;
  IF NOT public.has_permission_at('production.create', raw.branch_id, NULL) THEN
    RAISE EXCEPTION 'You can''t record production at this branch' USING ERRCODE = '42501';
  END IF;
  IF others AND NOT public.has_permission_at('products.manage', raw.branch_id, NULL) THEN
    RAISE EXCEPTION 'Only the branch manager can allow other products in a batch' USING ERRCODE = '42501';
  END IF;
  IF bags IS NULL OR bags <= 0 THEN RAISE EXCEPTION 'Enter the bags of cement used' USING ERRCODE = '23514'; END IF;

  -- Who made it and on what (056): both required
  SELECT * INTO team FROM public.production_teams WHERE id = nullif(p->>'team_id', '')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND OR team.branch_id <> raw.branch_id THEN RAISE EXCEPTION 'Choose the team that made this batch' USING ERRCODE = '23514'; END IF;
  SELECT * INTO mach FROM public.machines WHERE id = nullif(p->>'machine_id', '')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND OR mach.branch_id <> raw.branch_id THEN RAISE EXCEPTION 'Choose the machine this batch was made on' USING ERRCODE = '23514'; END IF;
  -- who worked: only when it differs from the team (someone away, a helper from another team of the branch)
  IF jsonb_typeof(p->'worker_ids') = 'array' THEN
    SELECT array_agg(DISTINCT x::uuid) INTO workers FROM jsonb_array_elements_text(p->'worker_ids') x;
    IF workers IS NULL THEN RAISE EXCEPTION 'Tick at least one person who worked on this batch' USING ERRCODE = '23514'; END IF;
    IF EXISTS (SELECT 1 FROM unnest(workers) w WHERE NOT EXISTS (
         SELECT 1 FROM public.production_team_members m JOIN public.production_teams t ON t.id = m.team_id
          WHERE m.id = w AND t.branch_id = raw.branch_id AND t.organization_id = org)) THEN
      RAISE EXCEPTION 'Someone ticked isn''t in this branch''s teams' USING ERRCODE = '23514';
    END IF;
  END IF;

  -- The main product first
  outs := coalesce(p->'outputs', '[]'::jsonb);
  IF jsonb_array_length(outs) = 0 THEN RAISE EXCEPTION 'Enter the product cast and its pieces' USING ERRCODE = '23514'; END IF;
  SELECT coalesce((SELECT x FROM jsonb_array_elements(outs) x WHERE (x->>'primary')::boolean LIMIT 1), outs->0) INTO o;
  SELECT * INTO main FROM public.products WHERE id = nullif(o->>'product_id', '')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'Choose the product' USING ERRCODE = '23514'; END IF;
  IF public.product_is_coloured(main.id) THEN
    IF col IS NULL OR NOT public.product_color_ok(main.id, col) THEN
      RAISE EXCEPTION '%: choose one of its colours', main.canonical_name USING ERRCODE = '23514';
    END IF;
  ELSIF col IS NOT NULL THEN
    RAISE EXCEPTION '%: its category has no colours', main.canonical_name USING ERRCODE = '23514';
  END IF;

  -- The branch's active recipe for the main product's category + colour (kept for good)
  IF rv IS NULL THEN
    SELECT v.id INTO rv FROM public.recipe_versions v
    WHERE v.branch_id = raw.branch_id AND v.category_id = main.category_id AND v.color_id IS NOT DISTINCT FROM col AND v.status = 'active'
    ORDER BY EXISTS (SELECT 1 FROM public.recipe_version_products x WHERE x.recipe_version_id = v.id AND x.product_id = main.id) DESC,
             v.effective_date DESC NULLS LAST, v.version_number DESC
    LIMIT 1;
    IF rv IS NULL THEN
      RAISE EXCEPTION 'No active recipe for % % at this branch — add one under Recipes', main.canonical_name,
        coalesce((SELECT name FROM public.color_palette WHERE id = col), '') USING ERRCODE = '23514';
    END IF;
  ELSIF NOT EXISTS (SELECT 1 FROM public.recipe_versions v WHERE v.id = rv AND v.branch_id = raw.branch_id
                    AND v.category_id = main.category_id AND v.color_id IS NOT DISTINCT FROM col AND v.status = 'active') THEN
    RAISE EXCEPTION 'That recipe isn''t an active one for % at this branch', main.canonical_name USING ERRCODE = '23514';
  END IF;

  -- Materials: anything short is named, and nothing is recorded (the branch manager reviews the stock)
  FOR l IN SELECT * FROM jsonb_array_elements(coalesce(p->'materials', '[]'::jsonb)) LOOP
    SELECT * INTO mat FROM public.materials WHERE id = nullif(l->>'material_id', '')::uuid AND organization_id = org AND status = 'active'
      AND (branch_id IS NULL OR branch_id = raw.branch_id);
    IF NOT FOUND THEN RAISE EXCEPTION 'Material not found, inactive or not used at this branch' USING ERRCODE = '23514'; END IF;
    IF mat.stock_unit_id IS NULL THEN RAISE EXCEPTION '%: set its stock unit under Materials first', mat.name USING ERRCODE = '23514'; END IF;
    IF (l->>'unit_id')::uuid = mat.stock_unit_id THEN factor := 1;
    ELSE
      SELECT factor_to_stock_unit INTO factor FROM public.material_unit_conversions WHERE material_id = mat.id AND unit_id = (l->>'unit_id')::uuid;
      IF NOT FOUND THEN RAISE EXCEPTION '%: use its stock unit or one of its listed units', mat.name USING ERRCODE = '23514'; END IF;
    END IF;
    IF nullif(l->>'quantity', '')::numeric IS NULL OR (l->>'quantity')::numeric < 0 THEN
      RAISE EXCEPTION '%: enter a quantity of zero or more', mat.name USING ERRCODE = '23514';
    END IF;
    bal := public.inventory_balance_as_of(raw.id, mat.id, NULL, NULL, bdate);
    IF (l->>'quantity')::numeric * factor > bal + 1e-9 THEN
      short := short || format('%s%s needs %s %s, only %s %s in stock', CASE WHEN short = '' THEN '' ELSE '; ' END, mat.name,
        trim_scale(round((l->>'quantity')::numeric * factor, 4)), (SELECT u.symbol FROM public.units u WHERE u.id = mat.stock_unit_id),
        trim_scale(round(bal, 4)), (SELECT u.symbol FROM public.units u WHERE u.id = mat.stock_unit_id));
    END IF;
  END LOOP;
  IF short <> '' THEN
    RAISE EXCEPTION 'Not enough in % — %. The branch manager should check the stock (a receipt or a count) before this batch is recorded.',
      raw.name, short USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.production_batches (organization_id, branch_id, batch_date, product_id, color_id, recipe_version_id,
    raw_warehouse_id, curing_warehouse_id, cement_bags, pieces_cast, curing_until, notes, created_by,
    other_products_allowed_by, team_id, machine_id, worker_ids)
  VALUES (org, raw.branch_id, bdate, main.id, col, rv, raw.id, cur.id, bags, 0,
          bdate + (SELECT curing_days FROM public.organizations WHERE id = org),
          nullif(btrim(p->>'notes'), ''), auth.uid(), CASE WHEN others THEN auth.uid() END, team.id, mach.id, workers)
  RETURNING id INTO bid;

  -- Products cast: same recipe (category + colour) as the main one, unless allowed for this batch
  FOR o IN SELECT * FROM jsonb_array_elements(outs) LOOP
    n := n + 1;
    SELECT * INTO prod FROM public.products WHERE id = nullif(o->>'product_id', '')::uuid AND organization_id = org AND status = 'active';
    IF NOT FOUND THEN RAISE EXCEPTION 'Choose each product cast' USING ERRCODE = '23514'; END IF;
    IF prod.id = ANY (seen) THEN RAISE EXCEPTION '% appears twice — add its pieces together', prod.canonical_name USING ERRCODE = '23514'; END IF;
    seen := seen || prod.id;
    IF NOT EXISTS (SELECT 1 FROM public.branch_products WHERE branch_id = raw.branch_id AND product_id = prod.id AND status = 'active') THEN
      RAISE EXCEPTION '% isn''t in this branch''s product list — add it there first', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    IF prod.category_id <> main.category_id AND NOT others THEN
      RAISE EXCEPTION '% is a different product family from % — only the same recipe can share a mix (the branch manager can allow it for one batch)',
        prod.canonical_name, main.canonical_name USING ERRCODE = '23514';
    END IF;
    -- each product's own colour (047): the main product takes the mix's colour;
    -- a residual its own color_id, else the mix's
    ocol := CASE WHEN prod.id = main.id THEN col ELSE coalesce(nullif(o->>'color_id', '')::uuid, col) END;
    IF public.product_is_coloured(prod.id) THEN
      IF ocol IS NULL OR NOT public.product_color_ok(prod.id, ocol) THEN
        RAISE EXCEPTION '%: choose one of its colours', prod.canonical_name USING ERRCODE = '23514';
      END IF;
    ELSIF prod.id <> main.id AND nullif(o->>'color_id', '') IS NOT NULL THEN
      RAISE EXCEPTION '% has no colours', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    -- the production order it counts towards, if any (048): an open order of this branch, same product and colour
    oline := nullif(o->>'order_line_id', '')::uuid;
    IF oline IS NOT NULL THEN
      SELECT l.product_id, l.color_id, po.status, po.branch_id, po.order_no INTO ol
        FROM public.production_order_lines l JOIN public.production_orders po ON po.id = l.order_id
       WHERE l.id = oline AND l.organization_id = org;
      IF NOT FOUND THEN RAISE EXCEPTION '%: that production order isn''t available', prod.canonical_name USING ERRCODE = '23514'; END IF;
      IF ol.status <> 'open' THEN
        RAISE EXCEPTION '%: production order % is %', prod.canonical_name, ol.order_no, ol.status USING ERRCODE = '23514';
      END IF;
      IF ol.branch_id <> raw.branch_id OR ol.product_id <> prod.id
         OR ol.color_id IS DISTINCT FROM (CASE WHEN public.product_is_coloured(prod.id) THEN ocol END) THEN
        RAISE EXCEPTION '%: production order % is for a different product, colour or branch', prod.canonical_name, ol.order_no USING ERRCODE = '23514';
      END IF;
    END IF;
    IF nullif(o->>'pieces', '')::int IS NULL OR (o->>'pieces')::int < 0 THEN
      RAISE EXCEPTION '%: enter the pieces cast', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    SELECT * INTO band FROM public.product_yield_band(prod.id, raw.branch_id);
    INSERT INTO public.production_batch_outputs (organization_id, batch_id, product_id, color_id, is_primary, pieces_cast, yield_per_bag, yield_tolerance, order_line_id)
    VALUES (org, bid, prod.id, CASE WHEN public.product_is_coloured(prod.id) THEN ocol END,
            prod.id = main.id, (o->>'pieces')::int, band.average_yield_per_bag, band.yield_tolerance, oline);
    total := total + (o->>'pieces')::int;
    IF band.average_yield_per_bag IS NULL OR band.average_yield_per_bag <= 0 THEN banded := false;
    ELSE
      eq := eq + (o->>'pieces')::int / band.average_yield_per_bag;
      bmin := bmin + (o->>'pieces')::int / band.yield_max;
      bmax := bmax + CASE WHEN band.yield_min > 0 THEN (o->>'pieces')::int / band.yield_min ELSE 'Infinity'::numeric END;
    END IF;
  END LOOP;
  IF total = 0 THEN RAISE EXCEPTION 'Enter the pieces cast' USING ERRCODE = '23514'; END IF;
  UPDATE public.production_batches SET pieces_cast = total,
         theoretical_bags = CASE WHEN banded THEN eq END, bags_min = CASE WHEN banded THEN bmin END,
         bags_max = CASE WHEN banded AND bmax <> 'Infinity'::numeric THEN bmax END
  WHERE id = bid;

  -- Materials row by row (as 042)
  FOR l IN SELECT * FROM jsonb_array_elements(coalesce(p->'materials', '[]'::jsonb)) LOOP
    SELECT * INTO mat FROM public.materials WHERE id = (l->>'material_id')::uuid;
    IF coalesce(l->>'source', '') NOT IN ('counted', 'recipe') THEN RAISE EXCEPTION 'Say whether % was counted or taken from the recipe', mat.name USING ERRCODE = '23514'; END IF;
    IF (l->>'unit_id')::uuid = mat.stock_unit_id THEN factor := 1;
    ELSE SELECT factor_to_stock_unit INTO factor FROM public.material_unit_conversions WHERE material_id = mat.id AND unit_id = (l->>'unit_id')::uuid;
    END IF;
    SELECT ri.quantity * bags INTO std FROM public.recipe_items ri WHERE ri.recipe_version_id = rv AND ri.material_id = mat.id AND ri.unit_id = (l->>'unit_id')::uuid;
    INSERT INTO public.production_batch_materials (organization_id, batch_id, material_id, quantity, unit_id, stock_quantity, standard_quantity, source)
    VALUES (org, bid, mat.id, (l->>'quantity')::numeric, (l->>'unit_id')::uuid, (l->>'quantity')::numeric * factor, std, l->>'source');
  END LOOP;

  -- All products into curing, one line each (not sellable yet)
  INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, created_by, production_batch_id)
  VALUES (org, 'production_output', cur.branch_id, cur.id, bdate, 'Production batch — curing', auth.uid(), bid)
  RETURNING id INTO mv;
  PERFORM public.production_post_outputs(bid, mv, bdate);
  UPDATE public.production_batches SET output_movement_id = mv WHERE id = bid;

  IF coalesce((p->>'issue_materials')::boolean, true) AND EXISTS (SELECT 1 FROM public.production_batch_materials WHERE batch_id = bid) THEN
    PERFORM public.production_post_materials(bid);
  END IF;
  -- material thrown away making it (056): out of stock with its reason, costed apart
  IF jsonb_array_length(coalesce(p->'waste', '[]'::jsonb)) > 0 THEN PERFORM public.production_post_waste(bid, p->'waste'); END IF;

  -- Bags used outside the band the output implies: flagged, never corrected
  IF banded AND (bags < bmin OR (bmax <> 'Infinity'::numeric AND bags > bmax)) THEN
    SELECT string_agg(format('%s × %s', x.pieces_cast, pr.canonical_name), ' + ') INTO pname
    FROM public.production_batch_outputs x JOIN public.products pr ON pr.id = x.product_id WHERE x.batch_id = bid;
    INSERT INTO public.review_flags (organization_id, entity_type, entity_id, reason_code, reason, created_by)
    VALUES (org, 'production_batch', bid::text, 'yield_out_of_band',
      format('%s pieces (%s) on %s used %s bags — the products'' yields give %s bags (%s to %s with the tolerance). Check the mix, the count or the materials.',
             total, pname, bdate, bags, round(eq, 2), round(bmin, 2), CASE WHEN bmax = 'Infinity'::numeric THEN '—' ELSE round(bmax, 2)::text END),
      auth.uid());
  END IF;
  RETURN bid;
END;
$function$;

-- ------------------------------------------------------------
-- 7. Voiding a batch also gives back what it threw away
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.void_production_batch(p_batch uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  b public.production_batches;
BEGIN
  SELECT * INTO b FROM public.production_batches WHERE id = p_batch AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND OR b.status <> 'curing' THEN RAISE EXCEPTION 'Only a batch still curing can be voided' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission('inventory.adjust') THEN
    RAISE EXCEPTION 'Voiding a batch is a stock correction — an org admin does it' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN RAISE EXCEPTION 'Give a reason' USING ERRCODE = '23514'; END IF;
  IF b.output_movement_id IS NOT NULL THEN PERFORM public.reverse_inventory_movement(b.output_movement_id, 'Batch voided: ' || btrim(p_reason)); END IF;
  IF b.materials_movement_id IS NOT NULL THEN PERFORM public.reverse_inventory_movement(b.materials_movement_id, 'Batch voided: ' || btrim(p_reason)); END IF;
  IF b.waste_movement_id IS NOT NULL THEN PERFORM public.reverse_inventory_movement(b.waste_movement_id, 'Batch voided: ' || btrim(p_reason)); END IF;   -- 056
  UPDATE public.production_batches SET status = 'void', void_reason = btrim(p_reason) WHERE id = b.id;
  UPDATE public.review_flags SET status = 'dismissed', resolved_at = now(), resolved_by = auth.uid(), resolution_note = 'Batch voided'
  WHERE entity_type = 'production_batch' AND entity_id = b.id::text AND status = 'open';
END;
$$;


-- ------------------------------------------------------------
-- 8. Quality tags at release (the note goes in the release note)
-- ------------------------------------------------------------
CREATE FUNCTION public.set_batch_quality(p_batch uuid, p_tags text[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  b public.production_batches;
BEGIN
  SELECT * INTO b FROM public.production_batches WHERE id = p_batch AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND OR b.status = 'void' THEN RAISE EXCEPTION 'Batch not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('production.complete', b.branch_id, NULL) THEN
    RAISE EXCEPTION 'You can''t release production at this branch' USING ERRCODE = '42501';
  END IF;
  IF NOT (coalesce(p_tags, '{}') <@ ARRAY['Colour', 'Edges', 'Size', 'Strength', 'Surface']) THEN
    RAISE EXCEPTION 'Quality tags are Colour, Edges, Size, Strength and Surface' USING ERRCODE = '23514';
  END IF;
  UPDATE public.production_batches SET qc_tags = nullif(array(SELECT DISTINCT unnest(p_tags) ORDER BY 1), '{}') WHERE id = b.id;
END;
$$;
REVOKE ALL ON FUNCTION public.set_batch_quality(uuid, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_batch_quality(uuid, text[]) TO authenticated;
