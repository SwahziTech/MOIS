-- ============================================================
-- 058 — Product costing (1e): finished stock at cost, price without VAT,
-- and each product's margin
--
-- SwahziTech, 2026-10-25, the user:
--   * products are valued like materials (052): first in first out — each
--     batch's pieces at that batch's material cost per stock unit (055);
--     rejected pieces and a voided batch leave at their own batch's cost
--     (rejects never re-cost a batch);
--   * opening finished stock has no cost entered: it takes the product's
--     FIRST batch cost at the branch (same colour, else any colour), marked
--     as such (estimated_quantity) — "first batch cost, marked";
--   * margin = price WITHOUT VAT − cost (sales VAT goes to the revenue
--     authority; the cost stays the full amount paid, VAT included — 053);
--   * expenses (power, diesel, labour) are not shared yet — later, once
--     they are entered.
--
-- product_stock_value(branch, product, colour [, as of]) →
--   on_hand, value, unit_cost, uncosted_quantity, estimated_quantity,
--   last_cost, layers [{date, quantity, cost, batch, estimated}]
-- product_price_ex_vat(branch, product, colour) → price per stock unit
--   without VAT, and where it came from
-- product_costing(branch) → per product and colour the branch has made or
--   holds: stock at cost, the latest batch's cost, price without VAT
-- ============================================================

-- A batch output's material cost per stock unit (m² or piece)
CREATE FUNCTION public.output_cost_per_unit(p_output public.production_batch_outputs)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN p_output.material_cost IS NOT NULL AND p_output.pieces_cast > 0
              THEN p_output.material_cost / nullif(public.production_stock_qty(p_output.product_id, p_output.pieces_cast), 0) END
$$;
REVOKE ALL ON FUNCTION public.output_cost_per_unit(public.production_batch_outputs) FROM PUBLIC, anon, authenticated;

-- The first batch cost of a product at a branch (same colour first), for stock with no cost entered
CREATE FUNCTION public.product_first_cost(p_branch_id uuid, p_product_id uuid, p_color_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.output_cost_per_unit(o)
    FROM public.production_batch_outputs o JOIN public.production_batches b ON b.id = o.batch_id
   WHERE b.branch_id = p_branch_id AND o.product_id = p_product_id AND b.status <> 'void' AND o.material_cost IS NOT NULL AND o.pieces_cast > 0
   ORDER BY (o.color_id IS NOT DISTINCT FROM p_color_id) DESC, b.batch_date, b.created_at
   LIMIT 1
$$;
REVOKE ALL ON FUNCTION public.product_first_cost(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;


CREATE FUNCTION public.product_stock_value(p_branch_id uuid, p_product_id uuid, p_color_id uuid, p_as_of date DEFAULT NULL)
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
    SELECT t.quantity AS q, t.transaction_type AS tt, t.unit_cost, t.entered_quantity, t.transaction_date, m.production_batch_id AS batch
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
        n := n + 1; lq[n] := -need; lc[n] := NULL; ld[n] := r.transaction_date; lb[n] := NULL; le[n] := false;
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
    layers := layers || jsonb_build_object('date', ld[i], 'quantity', lq[i], 'cost', lc[i], 'batch', lb[i], 'estimated', le[i]);
  END LOOP;
  unit_cost := CASE WHEN on_hand - uncosted_quantity > 0 THEN value / (on_hand - uncosted_quantity) END;
  last_cost := latest;
  IF on_hand - uncosted_quantity <= 0 THEN value := NULL; END IF;
  RETURN NEXT;
END;
$$;
REVOKE ALL ON FUNCTION public.product_stock_value(uuid, uuid, uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.product_stock_value(uuid, uuid, uuid, date) TO authenticated;
COMMENT ON FUNCTION public.product_stock_value(uuid, uuid, uuid, date)
  IS 'Finished stock at cost, first in first out: each batch''s pieces at its material cost; opening stock at the first batch cost, marked (058).';


-- The price of a product and colour at a branch, per stock unit, WITHOUT VAT:
--   its own price row for that colour; else the base row, with the
--   category's colour rule (added to the base m² price, or a price per m²);
--   m² prices are entered with VAT and are taken off at the branch's VAT rate.
CREATE FUNCTION public.product_price_ex_vat(p_branch_id uuid, p_product_id uuid, p_color_id uuid, OUT price numeric, OUT source text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p     public.products;
  prow  public.product_branch_pricing;
  rule  public.category_color_pricing_rules;
  amt   numeric;
  vat   numeric;
  sqm   boolean;
  incl  numeric;
BEGIN
  SELECT * INTO p FROM public.products WHERE id = p_product_id AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RETURN; END IF;
  SELECT upper(u.symbol) = 'SQM' INTO sqm FROM public.units u WHERE u.id = p.unit_id;
  SELECT coalesce(vat_rate, 0) INTO vat FROM public.branches WHERE id = p_branch_id;

  SELECT * INTO prow FROM public.product_branch_pricing x WHERE x.product_id = p_product_id AND x.branch_id = p_branch_id
     AND x.color_id IS NOT DISTINCT FROM p_color_id AND x.is_available;
  IF FOUND THEN source := 'price list';
  ELSE
    SELECT * INTO prow FROM public.product_branch_pricing x WHERE x.product_id = p_product_id AND x.branch_id = p_branch_id AND x.color_id IS NULL AND x.is_available;
    IF NOT FOUND THEN RETURN; END IF;
    source := 'price list';
    IF p_color_id IS NOT NULL THEN
      SELECT * INTO rule FROM public.category_color_pricing_rules cr WHERE cr.branch_id = p_branch_id
         AND cr.category_id IN (p.category_id, (SELECT parent_category_id FROM public.product_categories WHERE id = p.category_id))
       ORDER BY (cr.category_id = p.category_id) DESC LIMIT 1;
      IF FOUND AND rule.base_color_id IS DISTINCT FROM p_color_id THEN
        SELECT amount INTO amt FROM public.category_color_price_items WHERE rule_id = rule.id AND color_id = p_color_id;
        IF amt IS NULL THEN price := NULL; source := 'no price for this colour'; RETURN; END IF;
        incl := CASE WHEN rule.pricing_type = 'absolute_price_per_sqmt' THEN amt ELSE prow.price_per_sqm_inclusive + amt END;
        IF incl IS NULL THEN source := 'no price for this colour'; RETURN; END IF;
        price := CASE WHEN sqm THEN incl ELSE incl / nullif(prow.pcs_per_sqm_at_pricing, 0) END / (1 + vat / 100);
        source := 'colour rule';
        RETURN;
      END IF;
    END IF;
  END IF;
  IF sqm THEN
    price := coalesce(prow.price_per_sqm_inclusive / (1 + vat / 100),
                      prow.price_per_unit_exclusive * nullif(prow.pcs_per_sqm_at_pricing, 0));
  ELSE
    price := coalesce(prow.price_per_unit_exclusive, prow.price_per_unit_inclusive / (1 + vat / 100));
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.product_price_ex_vat(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.product_price_ex_vat(uuid, uuid, uuid) TO authenticated;


-- Every product and colour the branch has made or holds: stock at cost, the latest batch's cost, the price without VAT
CREATE FUNCTION public.product_costing(p_branch_id uuid)
RETURNS TABLE (product_id uuid, color_id uuid, on_hand numeric, value numeric, unit_cost numeric, uncosted_quantity numeric,
               estimated_quantity numeric, last_batch_cost numeric, last_batch_date date, batches int, price_ex_vat numeric, price_source text)
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
  SELECT i.product_id, i.color_id, v.on_hand, v.value, v.unit_cost, v.uncosted_quantity, v.estimated_quantity,
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
  IS 'Per product and colour at a branch: finished stock at cost, the latest batch cost per stock unit, the price without VAT (058). Margin = price − cost.';
