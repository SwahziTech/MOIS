-- ============================================================
-- 060 — Products enter stock on their production day; stock without a
-- production cost is estimated at its price without VAT (1e)
--
-- SwahziTech, 2026-10-25, the user:
--   * "the production date is the date that should be recorded as the
--     products enter the stock, just named curing until released, to get the
--     real qty that passed — to remove the date confusions": a release now
--     posts its stock moves (out of curing, the passed pieces into finished
--     goods, rejects away) on the batch's production day; released_on keeps
--     the day of the quality release. Releases already recorded are re-dated
--     the same way (a one-off correction of their dates only — quantities,
--     stores and products unchanged; the ledger's append-only guard is lifted
--     for this statement alone and put back).
--   * "all products should be valued by the price without VAT, even those
--     who haven't been produced yet — use that price for cost estimation,
--     differentiate the production cost from estimated costs": stock with no
--     production cost (opening stock, products never produced) is valued at
--     its price without VAT, marked estimated (replaces 058's first batch
--     cost); production cost stays the batch's material cost.
--   * the Costing page also shows every product's stock at its price
--     without VAT (sales value).
-- Keeps 059: a voided batch's pieces leave at that batch's own cost (its
-- reversal belongs to the batch), not the oldest stock's.
-- ============================================================

-- live definition as of 054; only the stock moves' date changes (060)
CREATE OR REPLACE FUNCTION public.release_production_batch(p_batch uuid, p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  mindays int;            -- the organization's minimum curing days (054)
  org     uuid := public.get_my_org_id();
  b       public.production_batches;
  cur     public.warehouses;
  fg      public.warehouses;
  rdate   date;
  x       record;
  e       jsonb;
  r       jsonb;
  passed  int;
  rejected int;
  mv      uuid;
BEGIN
  SELECT * INTO b FROM public.production_batches WHERE id = p_batch AND organization_id = org FOR UPDATE;
  IF NOT FOUND OR b.status <> 'curing' THEN RAISE EXCEPTION 'Batch not found or not curing' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('production.complete', b.branch_id, NULL) THEN
    RAISE EXCEPTION 'You can''t release production at this branch' USING ERRCODE = '42501';
  END IF;
  rdate := coalesce(nullif(p->>'release_date', '')::date, public.org_today(org));
  IF rdate < b.batch_date OR rdate > public.org_today(org) THEN RAISE EXCEPTION 'Release date must be between the batch date and today' USING ERRCODE = '23514'; END IF;
  -- 054: with a minimum curing period, release is refused before it and needs no reason after it;
  -- without one, an early release (before curing_until) still needs a reason
  mindays := (SELECT min_curing_days FROM public.organizations WHERE id = org);
  IF mindays IS NOT NULL AND rdate < b.batch_date + mindays THEN
    RAISE EXCEPTION 'A batch cures at least % days — this one can be released from %', mindays, b.batch_date + mindays USING ERRCODE = '23514';
  END IF;
  IF mindays IS NULL AND rdate < b.curing_until AND nullif(btrim(p->>'note'), '') IS NULL THEN
    RAISE EXCEPTION 'Curing runs until % — say why it is released early', b.curing_until USING ERRCODE = '23514';
  END IF;
  SELECT * INTO fg FROM public.warehouses WHERE id = nullif(p->>'fg_warehouse_id', '')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND OR fg.type <> 'finished_goods' OR fg.branch_id <> b.branch_id THEN
    RAISE EXCEPTION 'Choose the branch''s finished-goods store' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO cur FROM public.warehouses WHERE id = b.curing_warehouse_id;

  INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, notes, created_by, production_batch_id)
  VALUES (org, 'curing_release', b.branch_id, cur.id, b.batch_date /* 060: dated the production day */, 'Quality release', nullif(btrim(p->>'note'), ''), auth.uid(), b.id)
  RETURNING id INTO mv;

  FOR x IN SELECT o.*, pr.unit_id, pr.canonical_name || coalesce(' ' || cp.name, '') AS name
           FROM public.production_batch_outputs o JOIN public.products pr ON pr.id = o.product_id
           LEFT JOIN public.color_palette cp ON cp.id = o.color_id
           WHERE o.batch_id = b.id ORDER BY o.is_primary DESC, pr.canonical_name LOOP
    SELECT y INTO e FROM jsonb_array_elements(coalesce(p->'outputs', '[]'::jsonb)) y WHERE y->>'output_id' = x.id::text;
    IF e IS NULL THEN RAISE EXCEPTION '%: enter its passed and rejected pieces', x.name USING ERRCODE = '23514'; END IF;
    passed := nullif(e->>'pieces_passed', '')::int;
    IF passed IS NULL OR passed < 0 THEN RAISE EXCEPTION '%: enter the pieces that passed', x.name USING ERRCODE = '23514'; END IF;
    rejected := 0;
    FOR r IN SELECT * FROM jsonb_array_elements(coalesce(e->'rejects', '[]'::jsonb)) LOOP
      IF NOT EXISTS (SELECT 1 FROM public.reject_reasons WHERE id = nullif(r->>'reason_id', '')::uuid AND organization_id = org) THEN
        RAISE EXCEPTION 'Choose a reject reason from the list' USING ERRCODE = '23514';
      END IF;
      IF nullif(r->>'pieces', '')::int IS NULL OR (r->>'pieces')::int <= 0 THEN RAISE EXCEPTION 'Rejected pieces must be above zero' USING ERRCODE = '23514'; END IF;
      INSERT INTO public.production_batch_rejects (organization_id, batch_id, output_id, reason_id, pieces)
      VALUES (org, b.id, x.id, (r->>'reason_id')::uuid, (r->>'pieces')::int);
      rejected := rejected + (r->>'pieces')::int;
    END LOOP;
    IF passed + rejected <> x.pieces_cast THEN
      RAISE EXCEPTION '%: passed (%) and rejected (%) must add up to the % pieces cast', x.name, passed, rejected, x.pieces_cast USING ERRCODE = '23514';
    END IF;
    UPDATE public.production_batch_outputs SET pieces_passed = passed WHERE id = x.id;
    IF x.pieces_cast > 0 THEN
      PERFORM public.production_ledger_line(mv, 'curing_out', cur, NULL, x.product_id, x.color_id,
        -public.production_stock_qty(x.product_id, x.pieces_cast), x.unit_id, public.production_stock_qty(x.product_id, x.pieces_cast), x.unit_id, b.batch_date, x.name);
    END IF;
    IF passed > 0 THEN
      PERFORM public.production_ledger_line(mv, 'curing_in', fg, NULL, x.product_id, x.color_id,
        public.production_stock_qty(x.product_id, passed), x.unit_id, public.production_stock_qty(x.product_id, passed), x.unit_id, b.batch_date, x.name);
    END IF;
  END LOOP;

  UPDATE public.production_batches SET status = 'released', released_on = rdate, fg_warehouse_id = fg.id,
         release_movement_id = mv, release_note = nullif(btrim(p->>'note'), '')
  WHERE id = b.id;
  RETURN mv;
END;
$function$;

-- A release is posted on the production day by rule, not a back-dated correction:
-- whoever may release does so without approval (live definition as of 034)
CREATE OR REPLACE FUNCTION public.check_corrective_movement_approved()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE corrective boolean;
BEGIN
  IF auth.uid() IS NULL                                            -- server-side scripts
     OR NEW.movement_type = 'reclassification'                     -- product admins only (028)
     OR NEW.movement_type = 'curing_release'                       -- a quality release: dated the production day by rule (060)
     OR public.has_permission('inventory.adjust')                  -- org-wide admin
     OR coalesce(current_setting('mois.approved_change', true), '') = 'on' THEN
    RETURN NEW;
  END IF;
  corrective := NEW.movement_type IN ('adjustment', 'opening_balance', 'reversal')
             OR NEW.movement_date < public.org_today(NEW.organization_id)
             -- a count's difference is a correction unless the counter may correct stock here (034)
             OR (NEW.movement_type = 'count' AND NOT public.has_permission_at('inventory.adjust', NEW.branch_id, NEW.warehouse_id));
  IF NOT corrective THEN RETURN NEW; END IF;
  RAISE EXCEPTION 'Corrections, backdated entries and count differences need an admin''s approval — submit this for approval instead'
    USING ERRCODE = '42501';
END;
$$;

-- Releases already recorded: their stock moves dated the production day
ALTER TABLE public.inventory_movements DISABLE TRIGGER trg_inv_mov_append_only;
ALTER TABLE public.inventory_transactions DISABLE TRIGGER trg_inv_tx_append_only;
UPDATE public.inventory_transactions t SET transaction_date = b.batch_date
  FROM public.production_batches b
 WHERE t.movement_id = b.release_movement_id AND t.transaction_date <> b.batch_date;
UPDATE public.inventory_movements m SET movement_date = b.batch_date
  FROM public.production_batches b
 WHERE m.id = b.release_movement_id AND m.movement_date <> b.batch_date;
ALTER TABLE public.inventory_transactions ENABLE TRIGGER trg_inv_tx_append_only;
ALTER TABLE public.inventory_movements ENABLE TRIGGER trg_inv_mov_append_only;


-- Stock at cost: production cost per batch, estimates at the price without VAT
DROP FUNCTION public.product_costing(uuid);
DROP FUNCTION public.product_stock_value(uuid, uuid, uuid, date);
DROP FUNCTION public.product_first_cost(uuid, uuid, uuid);

CREATE FUNCTION public.product_stock_value(p_branch_id uuid, p_product_id uuid, p_color_id uuid, p_as_of date DEFAULT NULL)
RETURNS TABLE (on_hand numeric, value numeric, unit_cost numeric, uncosted_quantity numeric, estimated_quantity numeric, estimated_value numeric,
               last_cost numeric, price numeric, layers jsonb)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r      record;
  lq     numeric[] := '{}';   -- layer quantities (stock unit)
  lc     numeric[] := '{}';   -- cost per stock unit (NULL = unknown)
  ld     date[]    := '{}';
  lb     uuid[]    := '{}';   -- the batch a layer came from
  le     boolean[] := '{}';   -- estimated at the price without VAT (no production cost)
  ls     text[]    := '{}';   -- curing (cast, not released yet) or released
  n      int := 0;
  need   numeric;
  take   numeric;
  cost   numeric;
  est    boolean;
  latest numeric;
  est_price numeric;
  o      public.production_batch_outputs;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id AND organization_id = public.get_my_org_id()) THEN RETURN; END IF;
  est_price := (SELECT x.price FROM public.product_price_ex_vat(p_branch_id, p_product_id, p_color_id) x);
  FOR r IN
    SELECT t.quantity AS q, t.transaction_type AS tt, t.unit_cost, t.entered_quantity, t.transaction_date,
           -- a reversal belongs to the batch of what it reverses (a voided batch)
           coalesce(m.production_batch_id, (SELECT r0.production_batch_id FROM public.inventory_movements r0 WHERE r0.id = m.reverses_movement_id)) AS batch
      FROM public.inventory_transactions t
      JOIN public.warehouses w ON w.id = t.warehouse_id
      JOIN public.inventory_movements m ON m.id = t.movement_id
     WHERE t.product_id = p_product_id AND t.color_id IS NOT DISTINCT FROM p_color_id AND w.branch_id = p_branch_id
       AND (p_as_of IS NULL OR t.transaction_date <= p_as_of)
       -- a move between this branch's own stores changes nothing here
       AND NOT (t.transaction_type IN ('transfer_out', 'transfer_in') AND NOT EXISTS (
             SELECT 1 FROM public.inventory_transactions t2 JOIN public.warehouses w2 ON w2.id = t2.warehouse_id
              WHERE t2.movement_id = t.movement_id AND t2.id <> t.id AND w2.branch_id <> p_branch_id))
     ORDER BY t.transaction_date, t.seq
  LOOP
    IF r.q > 0 THEN
      est := false; cost := NULL;
      IF r.batch IS NOT NULL AND r.tt IN ('production_output', 'curing_in') THEN
        -- a batch's pieces carry the batch's cost (cast, or passed at release)
        SELECT * INTO o FROM public.production_batch_outputs x WHERE x.batch_id = r.batch AND x.product_id = p_product_id
           AND x.color_id IS NOT DISTINCT FROM p_color_id LIMIT 1;
        cost := public.output_cost_per_unit(o);
      ELSIF r.tt = 'opening_balance' AND r.unit_cost IS NOT NULL THEN
        cost := r.unit_cost * r.entered_quantity / r.q;
      END IF;
      -- no production cost: the latest production cost for stock coming back (a count up …); else the price without VAT, estimated
      IF cost IS NULL AND r.tt <> 'opening_balance' THEN cost := latest; END IF;
      IF cost IS NULL AND est_price IS NOT NULL THEN cost := est_price; est := true; END IF;
      n := n + 1;
      lq[n] := r.q; lc[n] := cost; ld[n] := r.transaction_date; lb[n] := CASE WHEN r.tt IN ('production_output', 'curing_in') THEN r.batch END; le[n] := est;
      ls[n] := CASE r.tt WHEN 'production_output' THEN 'curing' WHEN 'curing_in' THEN 'released' END;
      IF cost IS NOT NULL AND NOT est THEN latest := cost; END IF;
    ELSIF r.q < 0 THEN
      need := -r.q;
      -- a batch's own pieces leave first (released from curing, rejects, a voided batch); then the oldest
      IF r.batch IS NOT NULL THEN
        FOR i IN 1 .. n LOOP
          EXIT WHEN need <= 0;
          CONTINUE WHEN lb[i] IS DISTINCT FROM r.batch OR lq[i] <= 0;
          take := least(lq[i], need); lq[i] := lq[i] - take; need := need - take;
        END LOOP;
      END IF;
      FOR i IN 1 .. n LOOP
        EXIT WHEN need <= 0;
        CONTINUE WHEN lq[i] <= 0;
        take := least(lq[i], need); lq[i] := lq[i] - take; need := need - take;
      END LOOP;
      IF need > 0 THEN            -- more out than in: carried as negative, uncosted
        n := n + 1; lq[n] := -need; lc[n] := NULL; ld[n] := r.transaction_date; lb[n] := NULL; le[n] := false; ls[n] := NULL;
      END IF;
    END IF;
  END LOOP;

  on_hand := 0; value := 0; uncosted_quantity := 0; estimated_quantity := 0; estimated_value := 0; layers := '[]'::jsonb;
  FOR i IN 1 .. n LOOP
    CONTINUE WHEN lq[i] = 0;
    on_hand := on_hand + lq[i];
    IF lc[i] IS NULL THEN uncosted_quantity := uncosted_quantity + lq[i];
    ELSE value := value + lq[i] * lc[i]; END IF;
    IF le[i] THEN estimated_quantity := estimated_quantity + lq[i]; estimated_value := estimated_value + lq[i] * lc[i]; END IF;
    layers := layers || jsonb_build_object('date', ld[i], 'quantity', lq[i], 'cost', lc[i], 'batch', lb[i], 'stage', ls[i], 'estimated', le[i]);
  END LOOP;
  unit_cost := CASE WHEN on_hand - uncosted_quantity > 0 THEN value / (on_hand - uncosted_quantity) END;
  last_cost := latest;
  price := est_price;
  IF on_hand - uncosted_quantity <= 0 THEN value := NULL; END IF;
  RETURN NEXT;
END;
$$;
REVOKE ALL ON FUNCTION public.product_stock_value(uuid, uuid, uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.product_stock_value(uuid, uuid, uuid, date) TO authenticated;
COMMENT ON FUNCTION public.product_stock_value(uuid, uuid, uuid, date)
  IS 'Finished stock at cost, first in first out: each batch''s pieces at its material cost; stock with no production cost estimated at the price without VAT (060).';

CREATE FUNCTION public.product_costing(p_branch_id uuid)
RETURNS TABLE (product_id uuid, color_id uuid, on_hand numeric, value numeric, unit_cost numeric, uncosted_quantity numeric,
               estimated_quantity numeric, estimated_value numeric, sales_value numeric,
               last_batch_cost numeric, last_batch_date date, batches int, price_ex_vat numeric, price_source text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH items AS (
    SELECT DISTINCT t.product_id, t.color_id FROM public.inventory_transactions t JOIN public.warehouses w ON w.id = t.warehouse_id
     WHERE w.branch_id = p_branch_id AND t.product_id IS NOT NULL AND t.organization_id = public.get_my_org_id()
  ), last AS (
    SELECT DISTINCT ON (o.product_id, o.color_id) o.product_id, o.color_id, public.output_cost_per_unit(o) AS cost, b.batch_date
      FROM public.production_batch_outputs o JOIN public.production_batches b ON b.id = o.batch_id
     WHERE b.branch_id = p_branch_id AND b.status <> 'void' AND o.material_cost IS NOT NULL AND o.pieces_cast > 0
     ORDER BY o.product_id, o.color_id, b.batch_date DESC, b.created_at DESC
  ), counts AS (
    SELECT o.product_id, o.color_id, count(*)::int AS n FROM public.production_batch_outputs o JOIN public.production_batches b ON b.id = o.batch_id
     WHERE b.branch_id = p_branch_id AND b.status <> 'void' GROUP BY 1, 2
  )
  SELECT i.product_id, i.color_id, v.on_hand, v.value, v.unit_cost, v.uncosted_quantity, v.estimated_quantity, v.estimated_value,
         CASE WHEN pr.price IS NOT NULL THEN v.on_hand * pr.price END,
         l.cost, l.batch_date, coalesce(c.n, 0), pr.price, pr.source
    FROM items i
    CROSS JOIN LATERAL public.product_stock_value(p_branch_id, i.product_id, i.color_id) v
    LEFT JOIN last l ON l.product_id = i.product_id AND l.color_id IS NOT DISTINCT FROM i.color_id
    LEFT JOIN counts c ON c.product_id = i.product_id AND c.color_id IS NOT DISTINCT FROM i.color_id
    CROSS JOIN LATERAL public.product_price_ex_vat(p_branch_id, i.product_id, i.color_id) pr
$$;
REVOKE ALL ON FUNCTION public.product_costing(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.product_costing(uuid) TO authenticated;
COMMENT ON FUNCTION public.product_costing(uuid)
  IS 'Per product and colour at a branch: stock at cost (production + estimated), stock at the price without VAT, the latest batch cost, the price (060).';
