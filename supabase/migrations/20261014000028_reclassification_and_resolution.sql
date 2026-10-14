-- ============================================================
-- 028 — Reclassifying stock, and resolving product identity (1b)
--
-- So Stumarcot's own admin can settle "which product is this really?"
-- without a developer, after the stock has already been recorded:
--
--   reclassify_stock()        moves stock from one product to another in
--                             the same store on a chosen date (a
--                             'reclassification' movement: out of one, into
--                             the other) — nothing is edited or deleted;
--                             it can be reversed like any movement.
--   resolve_product_identity()  the one call behind the Review queue's
--                             choices for a product whose identity is open
--                             (an import placeholder or a possible duplicate):
--       same_as  → it is really product X: move all its stock to X, retire
--                  it, and record "this name = X" for good
--       split    → its stock is really several products: move each part
--       keep     → it is a product in its own right (optionally "and it is
--                  NOT A or B", so those are never suggested again)
--     and closes its open identity flags with a note.
-- ============================================================

ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_movement_type_check;
ALTER TABLE public.inventory_movements ADD CONSTRAINT inventory_movements_movement_type_check
  CHECK (movement_type IN ('opening_balance', 'receipt', 'issue', 'transfer', 'adjustment', 'count', 'reversal', 'reclassification'));
ALTER TABLE public.inventory_transactions DROP CONSTRAINT inventory_transactions_transaction_type_check;
ALTER TABLE public.inventory_transactions ADD CONSTRAINT inventory_transactions_transaction_type_check
  CHECK (transaction_type IN ('opening_balance', 'receipt', 'issue', 'transfer_out', 'transfer_in', 'adjustment', 'count', 'reversal', 'reclassification'));


-- ------------------------------------------------------------
-- reclassify_stock
-- ------------------------------------------------------------
-- p: { date?, reason, reference?,
--      lines: [{ warehouse_id, from_product_id, to_product_id, color_id?, to_color_id?, quantity }] }
-- quantity is in the products' stock unit (both must be stocked in the same unit).
CREATE OR REPLACE FUNCTION public.reclassify_stock(p jsonb)
RETURNS uuid[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org     uuid := public.get_my_org_id();
  uid     uuid := auth.uid();
  today   date;
  mdate   date;
  line    jsonb;
  wh      public.warehouses;
  wh_label text;
  fp      public.products;
  tp      public.products;
  fcol    uuid;
  tcol    uuid;
  qty     numeric;
  mov     uuid;
  movs    jsonb := '{}';     -- warehouse id → movement id
  ids     uuid[] := '{}';
  fname   text;
  tname   text;
BEGIN
  IF uid IS NULL OR org IS NULL THEN
    RAISE EXCEPTION 'Sign in to record stock movements' USING ERRCODE = '42501';
  END IF;
  today := public.org_today(org);
  mdate := coalesce(nullif(p->>'date', '')::date, today);
  IF mdate > today THEN
    RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514';
  END IF;
  IF nullif(btrim(p->>'reason'), '') IS NULL THEN
    RAISE EXCEPTION 'Say why the stock is being moved to another product' USING ERRCODE = '23514';
  END IF;
  IF jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines') = 0 THEN
    RAISE EXCEPTION 'Nothing to move' USING ERRCODE = '23514';
  END IF;

  FOR line IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    SELECT * INTO wh FROM public.warehouses WHERE id = (line->>'warehouse_id')::uuid AND organization_id = org;
    IF NOT FOUND THEN RAISE EXCEPTION 'Store not found' USING ERRCODE = '23514'; END IF;
    wh_label := (SELECT b.name FROM public.branches b WHERE b.id = wh.branch_id) || ' — ' || wh.name;
    IF NOT public.has_permission_at('inventory.adjust', wh.branch_id, wh.id) THEN
      RAISE EXCEPTION 'You don''t have permission to move stock between products at %', wh_label USING ERRCODE = '42501';
    END IF;

    SELECT * INTO fp FROM public.products WHERE id = (line->>'from_product_id')::uuid AND organization_id = org;
    SELECT * INTO tp FROM public.products WHERE id = (line->>'to_product_id')::uuid AND organization_id = org AND status = 'active';
    IF fp.id IS NULL OR tp.id IS NULL THEN RAISE EXCEPTION 'Product not found (the one receiving stock must be active)' USING ERRCODE = '23514'; END IF;
    IF fp.id = tp.id THEN RAISE EXCEPTION '%: choose a different product to move the stock to', fp.canonical_name USING ERRCODE = '23514'; END IF;
    IF fp.unit_id <> tp.unit_id THEN
      RAISE EXCEPTION '% and % are counted in different units, so stock can''t be moved between them', fp.canonical_name, tp.canonical_name
        USING ERRCODE = '23514';
    END IF;

    fcol := nullif(line->>'color_id', '')::uuid;
    tcol := coalesce(nullif(line->>'to_color_id', '')::uuid, fcol);
    IF EXISTS (SELECT 1 FROM public.product_category_colors WHERE category_id = tp.category_id) THEN
      IF tcol IS NULL OR NOT EXISTS (SELECT 1 FROM public.product_category_colors WHERE category_id = tp.category_id AND color_id = tcol) THEN
        RAISE EXCEPTION '%: choose one of its colours for the stock', tp.canonical_name USING ERRCODE = '23514';
      END IF;
    ELSE
      tcol := NULL;
    END IF;

    qty := (line->>'quantity')::numeric;
    IF qty IS NULL OR qty <= 0 THEN RAISE EXCEPTION 'Enter how much to move' USING ERRCODE = '23514'; END IF;

    fname := fp.canonical_name || coalesce(' ' || (SELECT name FROM public.color_palette WHERE id = fcol), '');
    tname := tp.canonical_name || coalesce(' ' || (SELECT name FROM public.color_palette WHERE id = tcol), '');
    PERFORM public.inventory_lock_item(wh.id, NULL, fp.id, fcol);
    PERFORM public.inventory_lock_item(wh.id, NULL, tp.id, tcol);
    PERFORM public.inventory_check_after_opening(wh.id, NULL, fp.id, fcol, mdate, fname, wh_label);
    PERFORM public.inventory_check_after_opening(wh.id, NULL, tp.id, tcol, mdate, tname, wh_label);
    PERFORM public.inventory_check_outflow(wh.id, NULL, fp.id, fcol, mdate, -qty, fname, wh_label);

    mov := nullif(movs->>wh.id::text, '')::uuid;
    IF mov IS NULL THEN
      INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, reference, created_by)
      VALUES (org, 'reclassification', wh.branch_id, wh.id, mdate, btrim(p->>'reason'), nullif(btrim(p->>'reference'), ''), uid)
      RETURNING id INTO mov;
      movs := movs || jsonb_build_object(wh.id::text, mov);
      ids := ids || mov;
    END IF;

    INSERT INTO public.inventory_transactions
      (organization_id, movement_id, transaction_type, branch_id, warehouse_id, product_id, color_id,
       quantity, stock_unit_id, entered_quantity, entered_unit_id, transaction_date, created_by)
    VALUES
      (org, mov, 'reclassification', wh.branch_id, wh.id, fp.id, fcol, -qty, fp.unit_id, qty, fp.unit_id, mdate, uid),
      (org, mov, 'reclassification', wh.branch_id, wh.id, tp.id, tcol,  qty, tp.unit_id, qty, tp.unit_id, mdate, uid);
  END LOOP;

  RETURN ids;
END;
$$;


-- ------------------------------------------------------------
-- resolve_product_identity
-- ------------------------------------------------------------
-- p: { choice: 'same_as' | 'split' | 'keep',
--      target_product_id,                         -- same_as
--      allocations: [{ warehouse_id, color_id, product_id, to_color_id?, quantity }],   -- split
--      not_products: [product ids],               -- keep (optional)
--      date?, note? }
CREATE OR REPLACE FUNCTION public.resolve_product_identity(p_product_id uuid, p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org      uuid := public.get_my_org_id();
  uid      uuid := auth.uid();
  who      text;
  prod     public.products;
  target   public.products;
  choice   text := p->>'choice';
  mdate    date;
  lines    jsonb := '[]';
  b        record;
  alloc    numeric;
  movs     uuid[] := '{}';
  d        public.identity_decisions;
  new_id   uuid;
  names    text;
  note     text;
  x        uuid;
BEGIN
  IF uid IS NULL OR org IS NULL OR NOT public.has_permission('products.manage') THEN
    RAISE EXCEPTION 'Only product admins can settle what a product really is' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO prod FROM public.products WHERE id = p_product_id AND organization_id = org FOR UPDATE;
  IF NOT FOUND OR prod.status <> 'active' THEN
    RAISE EXCEPTION 'Product not found or already retired' USING ERRCODE = '23514';
  END IF;
  who := coalesce((SELECT nullif(btrim(concat_ws(' ', first_name, last_name)), '') FROM public.profiles WHERE id = uid),
                  (SELECT email FROM public.profiles WHERE id = uid), 'a user');
  -- Stock is moved as it stood at its first recorded date unless told otherwise
  mdate := coalesce(nullif(p->>'date', '')::date,
                    (SELECT min(transaction_date) FROM public.inventory_transactions WHERE product_id = prod.id),
                    public.org_today(org));

  IF choice = 'same_as' THEN
    SELECT * INTO target FROM public.products WHERE id = (p->>'target_product_id')::uuid AND organization_id = org AND status = 'active';
    IF NOT FOUND OR target.id = prod.id THEN
      RAISE EXCEPTION 'Choose the product it really is' USING ERRCODE = '23514';
    END IF;
    FOR b IN SELECT warehouse_id, color_id, sum(quantity) AS qty FROM public.inventory_transactions
             WHERE product_id = prod.id AND transaction_date <= mdate GROUP BY 1, 2 HAVING sum(quantity) > 0 LOOP
      lines := lines || jsonb_build_object('warehouse_id', b.warehouse_id, 'from_product_id', prod.id, 'to_product_id', target.id,
                                           'color_id', b.color_id, 'quantity', b.qty);
    END LOOP;
    note := prod.canonical_name || ' is ' || target.canonical_name;

  ELSIF choice = 'split' THEN
    IF jsonb_typeof(p->'allocations') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'allocations') = 0 THEN
      RAISE EXCEPTION 'Say how the stock divides between the products' USING ERRCODE = '23514';
    END IF;
    -- every store/colour holding stock must be fully divided, exactly
    FOR b IN SELECT warehouse_id, color_id, sum(quantity) AS qty FROM public.inventory_transactions
             WHERE product_id = prod.id AND transaction_date <= mdate GROUP BY 1, 2 HAVING sum(quantity) <> 0 LOOP
      SELECT coalesce(sum((a->>'quantity')::numeric), 0) INTO alloc FROM jsonb_array_elements(p->'allocations') a
      WHERE (a->>'warehouse_id')::uuid = b.warehouse_id AND nullif(a->>'color_id', '')::uuid IS NOT DISTINCT FROM b.color_id;
      IF alloc <> b.qty THEN
        RAISE EXCEPTION 'The parts add up to %, but % has % in that store — they must add up exactly',
          trim_scale(alloc), prod.canonical_name, trim_scale(b.qty) USING ERRCODE = '23514';
      END IF;
    END LOOP;
    FOR b IN SELECT a FROM jsonb_array_elements(p->'allocations') a LOOP
      IF (b.a->>'quantity')::numeric > 0 THEN
        lines := lines || jsonb_build_object('warehouse_id', b.a->>'warehouse_id', 'from_product_id', prod.id,
                                             'to_product_id', b.a->>'product_id', 'color_id', nullif(b.a->>'color_id', ''),
                                             'to_color_id', nullif(b.a->>'to_color_id', ''), 'quantity', (b.a->>'quantity')::numeric);
      END IF;
    END LOOP;
    SELECT string_agg(DISTINCT pr.canonical_name, ' and ') INTO names FROM public.products pr
    WHERE pr.id IN (SELECT (a->>'product_id')::uuid FROM jsonb_array_elements(p->'allocations') a);
    note := prod.canonical_name || ' was split between ' || names;

  ELSIF choice = 'keep' THEN
    note := prod.canonical_name || ' is a product in its own right';
  ELSE
    RAISE EXCEPTION 'Unknown choice' USING ERRCODE = '23514';
  END IF;

  IF nullif(btrim(p->>'note'), '') IS NOT NULL THEN note := note || ' — ' || btrim(p->>'note'); END IF;

  -- 1. Move the stock
  IF jsonb_array_length(lines) > 0 THEN
    movs := public.reclassify_stock(jsonb_build_object('date', mdate, 'reason', note, 'lines', lines));
  END IF;

  -- 2. Retire the product that turned out not to be one (keep: stays)
  IF choice IN ('same_as', 'split') THEN
    UPDATE public.products SET status = 'inactive',
           notes = coalesce(notes || E'\n', '') || 'Retired ' || to_char(public.org_today(org), 'YYYY-MM-DD') || ' by ' || who || ': ' || note || '.'
    WHERE id = prod.id;
  END IF;

  -- 3. Decisions: every standing answer that pointed at this product
  FOR d IN SELECT * FROM public.identity_decisions WHERE organization_id = org AND status = 'active'
           AND product_id = prod.id AND decision IN ('same_as', 'new_record') LOOP
    IF choice = 'same_as' THEN
      PERFORM public.correct_identity_decision(d.id, jsonb_build_object('decision', 'same_as', 'product_id', target.id), note);
    ELSIF choice = 'split' THEN
      PERFORM public.revoke_identity_decision(d.id, note || '. Count these products separately on future sheets.');
    END IF;
  END LOOP;
  IF choice = 'same_as' AND NOT EXISTS (SELECT 1 FROM public.identity_decisions WHERE organization_id = org AND status = 'active'
       AND subject_type = 'product' AND context_normalized = '' AND term_normalized = public.normalize_name(prod.canonical_name)) THEN
    INSERT INTO public.identity_decisions (organization_id, subject_type, term, decision, product_id, evidence, source, decided_by, decided_by_label)
    VALUES (org, 'product', prod.canonical_name, 'same_as', target.id, note, 'review_queue', uid, who);
  END IF;
  IF choice = 'keep' THEN
    FOR x IN SELECT value::uuid FROM jsonb_array_elements_text(coalesce(p->'not_products', '[]'::jsonb)) LOOP
      IF NOT EXISTS (SELECT 1 FROM public.identity_decisions WHERE organization_id = org AND status = 'active' AND decision = 'distinct_from'
                     AND subject_type = 'product' AND term_normalized = public.normalize_name(prod.canonical_name) AND product_id = x) THEN
        INSERT INTO public.identity_decisions (organization_id, subject_type, term, decision, product_id, evidence, source, decided_by, decided_by_label)
        SELECT org, 'product', prod.canonical_name, 'distinct_from', pr.id, note || ' (not ' || pr.canonical_name || ')', 'review_queue', uid, who
        FROM public.products pr WHERE pr.id = x AND pr.organization_id = org;
      END IF;
    END LOOP;
  END IF;

  -- 4. Close its open identity flags
  UPDATE public.review_flags SET status = 'resolved', resolved_at = now(), resolved_by = uid, resolution_note = note
  WHERE organization_id = org AND entity_type = 'product' AND entity_id = prod.id::text AND status = 'open'
    AND reason_code IN ('import_placeholder', 'unresolved_identity', 'possible_duplicate');

  RETURN jsonb_build_object('movements', to_jsonb(movs), 'note', note);
END;
$$;

REVOKE ALL ON FUNCTION public.reclassify_stock(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resolve_product_identity(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reclassify_stock(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_product_identity(uuid, jsonb) TO authenticated;
