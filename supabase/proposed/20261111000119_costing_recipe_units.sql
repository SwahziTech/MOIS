-- ============================================================
-- 119 — Advanced costing fix: the recipe quantity in the stock unit (corrects 118)
-- ============================================================
-- 119 (2026-11-11): 118 compared the recipe quantity (in the unit entered, e.g. wheelbarrows)
-- with the quantity used in the stock unit (e.g. trips) — fixed below. Otherwise the same as 118.
--
-- SwahziTech, 2026-11-11 ("finish advanced costing"; chose: cost breakdown + trend,
-- standard vs actual, profit by product/customer with rejects & waste):
--
-- costing_outputs(branch, from, to) → one row per batch output made in the period:
--   * its share of the batch (cement_share) and so its cement bags;
--   * pieces cast, passed (once released), the yield expected (yield a bag × its bags);
--   * its full cost in four parts — materials (055, oldest stock first, VAT included),
--     labour (090), electricity (073), production overheads (076) — the same parts and the
--     same sharing (by cement) as output_cost_per_unit(), so the parts add up to it;
--   * its materials: what was used, what the recipe called for, and their cost.
-- Costing works out standards (the last 3 months), variances and trends from these rows.
-- Nothing is written; no stored figure changes.
-- Seen by those who see costing (products.manage) or the finances (finance.view) at the branch.
-- ============================================================

CREATE OR REPLACE FUNCTION public.costing_outputs(p_branch uuid, p_from date, p_to date)
RETURNS TABLE (
  output_id uuid, batch_id uuid, batch_date date, status text, product_id uuid, color_id uuid, is_primary boolean,
  cement_share numeric, bags numeric, pieces_cast integer, pieces_passed integer, yield_per_bag numeric,
  qty_cast numeric, qty_passed numeric, qty_expected numeric,
  material numeric, labour numeric, power numeric, overhead numeric,
  materials jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch AND organization_id = public.get_my_org_id()) THEN RETURN; END IF;
  IF NOT (public.has_permission_at('products.manage', p_branch, NULL) OR public.has_permission_at('finance.view', p_branch, NULL)) THEN
    RAISE EXCEPTION 'You can''t see costing at this branch' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT o.id, b.id, b.batch_date, b.status, o.product_id, o.color_id, o.is_primary,
         coalesce(o.cement_share, 0), b.cement_bags * coalesce(o.cement_share, 0), o.pieces_cast, o.pieces_passed, o.yield_per_bag,
         public.production_stock_qty(o.product_id, o.pieces_cast),
         CASE WHEN o.pieces_passed IS NULL THEN NULL ELSE public.production_stock_qty(o.product_id, o.pieces_passed) END,
         CASE WHEN o.yield_per_bag IS NULL THEN NULL
              ELSE public.production_stock_qty(o.product_id, o.yield_per_bag * b.cement_bags * coalesce(o.cement_share, 0)) END,
         o.material_cost,
         coalesce(public.batch_labour_cost(b.id), 0) * coalesce(o.cement_share, 0),
         coalesce(public.batch_power_cost(b.id), 0) * coalesce(o.cement_share, 0),
         coalesce(public.batch_overhead_cost(b.id), 0) * coalesce(o.cement_share, 0),
         (SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'material_id', m.material_id,
                   'used', m.stock_quantity * coalesce(o.cement_share, 0),
                   -- 119: standard_quantity is in the unit entered (like quantity); stock_quantity ÷ quantity puts it in the stock unit
                   'recipe', m.standard_quantity * coalesce(m.stock_quantity / nullif(m.quantity, 0), 1) * coalesce(o.cement_share, 0),
                   'cost', m.cost * coalesce(o.cement_share, 0))), '[]'::jsonb)
            FROM public.production_batch_materials m WHERE m.batch_id = b.id)
    FROM public.production_batches b
    JOIN public.production_batch_outputs o ON o.batch_id = b.id
   WHERE b.branch_id = p_branch AND b.organization_id = public.get_my_org_id()
     AND b.status <> 'void' AND b.batch_date BETWEEN p_from AND p_to
   ORDER BY b.batch_date, b.created_at, o.is_primary DESC;
END;
$$;
COMMENT ON FUNCTION public.costing_outputs(uuid, date, date) IS
  'Batch outputs at a branch in a period with full cost in parts (materials, labour, electricity, overheads), materials used vs recipe, yield and rejects (118).';
REVOKE ALL ON FUNCTION public.costing_outputs(uuid, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.costing_outputs(uuid, date, date) TO authenticated;
