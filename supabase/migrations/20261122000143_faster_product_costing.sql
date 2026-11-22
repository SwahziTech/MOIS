-- ============================================================
-- 143 — Costing loads faster (same figures)
--
-- SwahziTech, 2026-11-22: the Costing page took ~6 s and timed out (8 s limit)
-- when other pages loaded at the same time. Two repeats removed:
--   1. product_stock_value works a batch's cost out once — its cast and its
--      release carried the same cost but were each worked out.
--   2. product_costing's latest batch cost: the newest batch a product is
--      picked first, then costed (it costed every batch, then kept one).
-- Checked on the live data inside a rolled-back transaction: identical
-- values, 5.7 s → 2.3 s.
-- ============================================================

CREATE OR REPLACE FUNCTION public.product_stock_value(p_branch_id uuid, p_product_id uuid, p_color_id uuid, p_as_of date DEFAULT NULL::date)
 RETURNS TABLE(on_hand numeric, value numeric, unit_cost numeric, uncosted_quantity numeric, estimated_quantity numeric, estimated_value numeric, last_cost numeric, price numeric, layers jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  bc     jsonb := '{}';   -- batch → cost per unit, worked out once (143)
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
     WHERE t.product_id = p_product_id AND t.color_id IS NOT DISTINCT FROM p_color_id AND w.branch_id = p_branch_id AND w.type <> 'rejects'
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
        -- worked out once a batch (143): its cast and its release carry the same cost
        IF bc ? r.batch::text THEN cost := (bc ->> r.batch::text)::numeric;
        ELSE
          SELECT * INTO o FROM public.production_batch_outputs x WHERE x.batch_id = r.batch AND x.product_id = p_product_id
             AND x.color_id IS NOT DISTINCT FROM p_color_id LIMIT 1;
          cost := public.output_cost_per_unit(o);
          bc := bc || jsonb_build_object(r.batch::text, cost);
        END IF;
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
$function$
;

CREATE OR REPLACE FUNCTION public.product_costing(p_branch_id uuid)
 RETURNS TABLE(product_id uuid, color_id uuid, on_hand numeric, value numeric, unit_cost numeric, uncosted_quantity numeric, estimated_quantity numeric, estimated_value numeric, sales_value numeric, last_batch_cost numeric, last_batch_date date, batches integer, price_ex_vat numeric, price_source text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH items AS (
    SELECT DISTINCT t.product_id, t.color_id FROM public.inventory_transactions t JOIN public.warehouses w ON w.id = t.warehouse_id
     WHERE w.branch_id = p_branch_id AND t.product_id IS NOT NULL AND t.organization_id = public.get_my_org_id()
  ), newest AS (   -- the newest batch a product first, then its cost (143: costed once a product, not for every batch)
    SELECT DISTINCT ON (o.product_id, o.color_id) o AS out, b.batch_date
      FROM public.production_batch_outputs o JOIN public.production_batches b ON b.id = o.batch_id
     WHERE b.branch_id = p_branch_id AND b.status <> 'void' AND o.material_cost IS NOT NULL AND o.pieces_cast > 0
     ORDER BY o.product_id, o.color_id, b.batch_date DESC, b.created_at DESC
  ), last AS MATERIALIZED (
    SELECT (n.out).product_id, (n.out).color_id, public.output_cost_per_unit(n.out) AS cost, n.batch_date FROM newest n
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
$function$
;
