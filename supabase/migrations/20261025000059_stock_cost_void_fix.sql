-- ============================================================
-- 059 — Finished stock at cost: a voided batch's pieces leave at their own
-- cost; layers say the day a batch was made (1e)
--
-- SwahziTech, 2026-10-25 (the user asked about 22 Oct rows in a product's
-- stock at cost): a void reverses the batch's movements with 'reversal'
-- movements that carry no batch — so 058 took the voided pieces from the
-- oldest stock (opening) instead of from the batch, leaving the void's
-- pieces valued. A reversal now belongs to the batch of the movement it
-- reverses. Each batch layer also carries the day it was made ('made');
-- its date stays the day it entered (release, for FIFO order).
-- ============================================================

CREATE OR REPLACE FUNCTION public.product_stock_value(p_branch_id uuid, p_product_id uuid, p_color_id uuid, p_as_of date DEFAULT NULL)
RETURNS TABLE (on_hand numeric, value numeric, unit_cost numeric, uncosted_quantity numeric, estimated_quantity numeric, last_cost numeric, layers jsonb)
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
  lm     date[]    := '{}';   -- the day that batch was made (059)
  le     boolean[] := '{}';   -- costed from the first batch (opening stock)
  n      int := 0;
  need   numeric;
  take   numeric;
  cost   numeric;
  est    boolean;
  latest numeric;
  first  numeric;
  o      public.production_batch_outputs;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id AND organization_id = public.get_my_org_id()) THEN RETURN; END IF;
  first := public.product_first_cost(p_branch_id, p_product_id, p_color_id);
  FOR r IN
    SELECT t.quantity AS q, t.transaction_type AS tt, t.unit_cost, t.entered_quantity, t.transaction_date,
           -- a reversal belongs to the batch of what it reverses (a voided batch) — 059
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
      ELSIF r.tt = 'opening_balance' THEN
        IF r.unit_cost IS NOT NULL THEN cost := r.unit_cost * r.entered_quantity / r.q;
        ELSE cost := first; est := first IS NOT NULL;
        END IF;
      END IF;
      cost := coalesce(cost, latest);
      n := n + 1;
      lq[n] := r.q; lc[n] := cost; ld[n] := r.transaction_date; lb[n] := CASE WHEN r.tt IN ('production_output', 'curing_in') THEN r.batch END; le[n] := est;
      lm[n] := (SELECT batch_date FROM public.production_batches WHERE id = lb[n]);
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
        n := n + 1; lq[n] := -need; lc[n] := NULL; ld[n] := r.transaction_date; lb[n] := NULL; le[n] := false; lm[n] := NULL;
      END IF;
    END IF;
  END LOOP;

  on_hand := 0; value := 0; uncosted_quantity := 0; estimated_quantity := 0; layers := '[]'::jsonb;
  FOR i IN 1 .. n LOOP
    CONTINUE WHEN lq[i] = 0;
    on_hand := on_hand + lq[i];
    IF lc[i] IS NULL THEN uncosted_quantity := uncosted_quantity + lq[i];
    ELSE value := value + lq[i] * lc[i]; END IF;
    IF le[i] THEN estimated_quantity := estimated_quantity + lq[i]; END IF;
    layers := layers || jsonb_build_object('date', ld[i], 'quantity', lq[i], 'cost', lc[i], 'batch', lb[i], 'made', lm[i], 'estimated', le[i]);
  END LOOP;
  unit_cost := CASE WHEN on_hand - uncosted_quantity > 0 THEN value / (on_hand - uncosted_quantity) END;
  last_cost := latest;
  IF on_hand - uncosted_quantity <= 0 THEN value := NULL; END IF;
  RETURN NEXT;
END;
$$;
REVOKE ALL ON FUNCTION public.product_stock_value(uuid, uuid, uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.product_stock_value(uuid, uuid, uuid, date) TO authenticated;
