-- ============================================================
-- 052 — Material stock value, first in first out (1c/1d)
--
-- SwahziTech, 2026-10-24 (changes the 16 Oct rule "average cost from
-- purchases only, no cost for opening stock"):
--   * opening stock is valued at the cost entered with it (the opening
--     balance's unit cost — per unit it was counted in, e.g. per Pipa);
--   * each purchase adds stock at its own landed cost (price + share of
--     transport, VAT excluded when shown separately — 035);
--   * stock going out (production, issues, counts down) takes the OLDEST
--     stock first, so a price change only affects the new stock;
--   * the value is what is left, layer by layer: "keep the earlier stock at
--     its cost, add the new stock at the new cost".
-- Stock that comes back without a known cost (a count up, an adjustment up,
-- a reversal) takes the cost of the latest stock in. Moves between stores of
-- the same branch don't change the branch's layers.
--
-- material_stock_value(branch, material [, as of]) →
--   on_hand, value, unit_cost (value ÷ costed quantity), uncosted_quantity,
--   last_cost (latest cost in), layers [{date, quantity, cost}] oldest first.
-- material_average_cost (035) stays for history; screens use this.
-- ============================================================

CREATE FUNCTION public.material_stock_value(p_branch_id uuid, p_material_id uuid, p_as_of date DEFAULT NULL)
RETURNS TABLE (on_hand numeric, value numeric, unit_cost numeric, uncosted_quantity numeric, last_cost numeric, layers jsonb)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  r      record;
  lq     numeric[] := '{}';   -- layer quantities (stock unit)
  lc     numeric[] := '{}';   -- layer cost per stock unit (NULL = unknown)
  ld     date[]    := '{}';   -- layer dates
  head   int := 1;            -- oldest layer still holding stock
  n      int := 0;
  need   numeric;
  take   numeric;
  cost   numeric;
  latest numeric;
BEGIN
  FOR r IN
    SELECT t.quantity, t.transaction_type, t.unit_cost, t.entered_quantity, t.transaction_date, plc.cost_per_stock_unit AS bought
      FROM public.inventory_transactions t
      JOIN public.warehouses w ON w.id = t.warehouse_id
      LEFT JOIN public.purchase_line_costs plc ON plc.transaction_id = t.id
     WHERE t.material_id = p_material_id AND w.branch_id = p_branch_id
       AND (p_as_of IS NULL OR t.transaction_date <= p_as_of)
       -- a move between this branch's own stores changes nothing here
       AND NOT (t.transaction_type IN ('transfer_out', 'transfer_in') AND NOT EXISTS (
             SELECT 1 FROM public.inventory_transactions t2 JOIN public.warehouses w2 ON w2.id = t2.warehouse_id
              WHERE t2.movement_id = t.movement_id AND t2.id <> t.id AND w2.branch_id <> p_branch_id))
     ORDER BY t.transaction_date, t.seq
  LOOP
    IF r.quantity > 0 THEN
      cost := coalesce(r.bought,
                       CASE WHEN r.unit_cost IS NOT NULL AND r.quantity <> 0 THEN r.unit_cost * r.entered_quantity / r.quantity END,
                       latest);
      n := n + 1;
      lq[n] := r.quantity; lc[n] := cost; ld[n] := r.transaction_date;
      IF cost IS NOT NULL THEN latest := cost; END IF;
    ELSIF r.quantity < 0 THEN
      need := -r.quantity;
      WHILE need > 0 AND head <= n LOOP
        take := least(lq[head], need);
        lq[head] := lq[head] - take;
        need := need - take;
        IF lq[head] <= 0 THEN head := head + 1; END IF;
      END LOOP;
      IF need > 0 THEN            -- more out than in: carried as negative, uncosted
        n := n + 1; lq[n] := -need; lc[n] := NULL; ld[n] := r.transaction_date; head := n;
      END IF;
    END IF;
  END LOOP;

  on_hand := 0; value := 0; uncosted_quantity := 0; layers := '[]'::jsonb;
  FOR i IN head .. n LOOP
    CONTINUE WHEN lq[i] = 0;
    on_hand := on_hand + lq[i];
    IF lc[i] IS NULL THEN uncosted_quantity := uncosted_quantity + lq[i];
    ELSE value := value + lq[i] * lc[i]; END IF;
    layers := layers || jsonb_build_object('date', ld[i], 'quantity', lq[i], 'cost', lc[i]);
  END LOOP;
  unit_cost := CASE WHEN on_hand - uncosted_quantity > 0 THEN value / (on_hand - uncosted_quantity) END;
  last_cost := latest;
  IF on_hand - uncosted_quantity <= 0 THEN value := NULL; END IF;
  RETURN NEXT;
END;
$$;
GRANT EXECUTE ON FUNCTION public.material_stock_value(uuid, uuid, date) TO authenticated;
COMMENT ON FUNCTION public.material_stock_value(uuid, uuid, date)
  IS 'First in, first out: opening cost and purchase landed cost layers, oldest used first; value of what is left (052).';
