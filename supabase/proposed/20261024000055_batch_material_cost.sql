-- ============================================================
-- 055 — Material cost of a production batch (1d; margins and stock at
-- cost follow in 1e)
--
-- SwahziTech, 2026-10-24, the user: "the material cost should [be] the
-- cost per batch for all produced products, residual and main, they are
-- all counted into stock. so we should get each product material cost per
-- unit used (sqm or pcs)". Shared "by cement taken".
--
--   * a batch's materials are costed when they leave the store, first in
--     first out (052) at the full amount paid, VAT included (053): the
--     oldest stock's cost first;
--   * stock taken beyond what has a known cost is priced at the latest
--     cost in; with no cost known at all the material stays uncosted
--     (cost NULL) — never guessed;
--   * the cost is kept on the batch, so later prices don't rewrite it;
--   * it is shared among all products cast (main and residuals) by the
--     cement each takes: pieces ÷ its pieces per bag; when a product has no
--     pieces per bag, by pieces;
--   * each product gets its material cost per piece, and per m² where its
--     pieces per m² is known.
-- Batches already recorded are costed the same way from the ledger.
-- ============================================================

ALTER TABLE public.production_batch_materials
  ADD COLUMN cost numeric;                 -- first in first out, VAT included; NULL = no cost known
ALTER TABLE public.production_batches
  ADD COLUMN material_cost numeric,        -- Σ the materials' cost (the known ones)
  ADD COLUMN material_cost_complete boolean;   -- false when a material had no cost known
ALTER TABLE public.production_batch_outputs
  ADD COLUMN cement_share numeric,         -- its share of the mix (0–1), by cement taken
  ADD COLUMN material_cost numeric,        -- the batch's material cost × share
  ADD COLUMN cost_per_piece numeric,
  ADD COLUMN cost_per_sqm numeric;         -- per piece × pieces per m² (NULL when not known)
COMMENT ON COLUMN public.production_batch_materials.cost IS 'Cost of the stock used, first in first out, VAT included (055).';
COMMENT ON COLUMN public.production_batch_outputs.cement_share IS 'Share of the batch''s materials: pieces ÷ pieces per bag, over the batch (055).';


-- The cost of what one movement took out of a material's stock at a branch,
-- first in first out — the same layers as material_stock_value (052).
CREATE FUNCTION public.fifo_movement_cost(p_branch_id uuid, p_material_id uuid, p_movement_id uuid,
                                          OUT cost numeric, OUT quantity numeric, OUT uncosted_quantity numeric)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  r      record;
  lq     numeric[] := '{}';
  lc     numeric[] := '{}';
  head   int := 1;
  n      int := 0;
  need   numeric;
  take   numeric;
  c      numeric;
  latest numeric;
BEGIN
  cost := 0; quantity := 0; uncosted_quantity := 0;
  FOR r IN
    SELECT t.quantity AS q, t.unit_cost, t.entered_quantity, t.movement_id, plc.cost_per_stock_unit AS bought
      FROM public.inventory_transactions t
      JOIN public.warehouses w ON w.id = t.warehouse_id
      LEFT JOIN public.purchase_line_costs plc ON plc.transaction_id = t.id
     WHERE t.material_id = p_material_id AND w.branch_id = p_branch_id
       AND NOT (t.transaction_type IN ('transfer_out', 'transfer_in') AND NOT EXISTS (
             SELECT 1 FROM public.inventory_transactions t2 JOIN public.warehouses w2 ON w2.id = t2.warehouse_id
              WHERE t2.movement_id = t.movement_id AND t2.id <> t.id AND w2.branch_id <> p_branch_id))
     ORDER BY t.transaction_date, t.seq
  LOOP
    IF r.q > 0 THEN
      c := coalesce(r.bought, CASE WHEN r.unit_cost IS NOT NULL AND r.q <> 0 THEN r.unit_cost * r.entered_quantity / r.q END, latest);
      n := n + 1; lq[n] := r.q; lc[n] := c;
      IF c IS NOT NULL THEN latest := c; END IF;
    ELSIF r.q < 0 THEN
      need := -r.q;
      IF r.movement_id = p_movement_id THEN quantity := quantity + need; END IF;
      WHILE need > 0 AND head <= n LOOP
        take := least(lq[head], need);
        IF r.movement_id = p_movement_id THEN
          IF lc[head] IS NULL THEN uncosted_quantity := uncosted_quantity + take; ELSE cost := cost + take * lc[head]; END IF;
        END IF;
        lq[head] := lq[head] - take;
        need := need - take;
        IF lq[head] <= 0 THEN head := head + 1; END IF;
      END LOOP;
      IF need > 0 THEN
        IF r.movement_id = p_movement_id THEN uncosted_quantity := uncosted_quantity + need; END IF;
        n := n + 1; lq[n] := -need; lc[n] := NULL; head := n;
      END IF;
    END IF;
  END LOOP;
  -- taken without a known cost: the latest cost in, when there is one
  IF uncosted_quantity > 0 AND latest IS NOT NULL THEN
    cost := cost + uncosted_quantity * latest; uncosted_quantity := 0;
  END IF;
  IF quantity > 0 AND uncosted_quantity >= quantity THEN cost := NULL; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.fifo_movement_cost(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fifo_movement_cost(uuid, uuid, uuid) TO authenticated;


-- Cost a batch from its materials movement and share it among its products
CREATE FUNCTION public.production_cost_batch(p_batch uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  b      public.production_batches;
  m      record;
  fc     record;
  total  numeric := 0;
  whole  boolean := true;
  byBag  boolean;
  weight numeric;
BEGIN
  SELECT * INTO b FROM public.production_batches WHERE id = p_batch;
  IF NOT FOUND OR b.materials_movement_id IS NULL THEN RETURN; END IF;

  FOR m IN SELECT bm.id, bm.material_id, bm.stock_quantity FROM public.production_batch_materials bm WHERE bm.batch_id = b.id LOOP
    IF m.stock_quantity = 0 THEN
      UPDATE public.production_batch_materials SET cost = 0 WHERE id = m.id;
      CONTINUE;
    END IF;
    SELECT * INTO fc FROM public.fifo_movement_cost(b.branch_id, m.material_id, b.materials_movement_id);
    -- part of the quantity without a cost: what is known is kept, the batch marked incomplete
    IF fc.cost IS NULL OR fc.uncosted_quantity > 0 THEN whole := false; END IF;
    UPDATE public.production_batch_materials SET cost = round(fc.cost, 2) WHERE id = m.id;
    total := total + coalesce(round(fc.cost, 2), 0);
  END LOOP;
  UPDATE public.production_batches SET material_cost = total, material_cost_complete = whole WHERE id = b.id;

  -- shares by cement taken; by pieces when a product has no pieces per bag
  byBag := NOT EXISTS (SELECT 1 FROM public.production_batch_outputs WHERE batch_id = b.id AND pieces_cast > 0
                       AND (yield_per_bag IS NULL OR yield_per_bag <= 0));
  SELECT sum(CASE WHEN byBag THEN pieces_cast / yield_per_bag ELSE pieces_cast END) INTO weight
    FROM public.production_batch_outputs WHERE batch_id = b.id AND pieces_cast > 0;
  UPDATE public.production_batch_outputs o SET
         cement_share = s.share,
         material_cost = round(total * s.share, 2),
         cost_per_piece = CASE WHEN o.pieces_cast > 0 THEN round(total * s.share / o.pieces_cast, 2) END,
         cost_per_sqm = CASE WHEN o.pieces_cast > 0 AND p.pcs_per_sqm > 0 THEN round(total * s.share / o.pieces_cast * p.pcs_per_sqm, 2) END
    FROM (SELECT x.id, CASE WHEN x.pieces_cast > 0 AND weight > 0
                            THEN (CASE WHEN byBag THEN x.pieces_cast / x.yield_per_bag ELSE x.pieces_cast END) / weight ELSE 0 END AS share
            FROM public.production_batch_outputs x WHERE x.batch_id = b.id) s,
         public.products p
   WHERE o.id = s.id AND p.id = o.product_id;
END;
$$;
REVOKE ALL ON FUNCTION public.production_cost_batch(uuid) FROM PUBLIC, anon, authenticated;


-- Costed as the materials leave the store (recorded with the batch, or issued later)
CREATE OR REPLACE FUNCTION public.production_post_materials(p_batch uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  b    public.production_batches;
  wh   public.warehouses;
  mv   uuid;
  m    record;
BEGIN
  SELECT * INTO b FROM public.production_batches WHERE id = p_batch FOR UPDATE;
  SELECT * INTO wh FROM public.warehouses WHERE id = b.raw_warehouse_id;
  INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, created_by, production_batch_id)
  VALUES (b.organization_id, 'production_use', b.branch_id, wh.id, b.batch_date, 'Production batch', auth.uid(), b.id)
  RETURNING id INTO mv;
  FOR m IN SELECT bm.*, mt.name, mt.stock_unit_id FROM public.production_batch_materials bm JOIN public.materials mt ON mt.id = bm.material_id
           WHERE bm.batch_id = b.id AND bm.stock_quantity > 0 LOOP
    PERFORM public.production_ledger_line(mv, 'production_use', wh, m.material_id, NULL, NULL, -m.stock_quantity,
      m.stock_unit_id, m.quantity, m.unit_id, b.batch_date, m.name);
  END LOOP;
  UPDATE public.production_batches SET materials_movement_id = mv WHERE id = b.id;
  PERFORM public.production_cost_batch(b.id);   -- 055
  RETURN mv;
END;
$$;
REVOKE ALL ON FUNCTION public.production_post_materials(uuid) FROM PUBLIC, anon, authenticated;


-- Batches already recorded, oldest first
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM public.production_batches WHERE materials_movement_id IS NOT NULL ORDER BY batch_date, created_at LOOP
    PERFORM public.production_cost_batch(r.id);
  END LOOP;
END;
$$;
