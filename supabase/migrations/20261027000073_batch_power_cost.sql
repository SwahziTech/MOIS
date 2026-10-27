-- ============================================================
-- 073 — Costing reads electricity into a batch's cost (1e)
--
-- SwahziTech, 2026-10-27: production pages stay raw materials only; Costing
-- pulls from where things are recorded. A batch's electricity is its meter's
-- day use (072: morning → evening) that day, shared over the day's batches on
-- that meter's machines by cement bags. Nights (lights) and gaps are never
-- charged. Nothing is written into production records — it is read when a
-- cost is asked for. Labour comes from the Staff (HR) phase.
-- ============================================================

-- A batch's share of its meter's day use
CREATE FUNCTION public.batch_power_cost(p_batch uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT CASE WHEN day.cost IS NULL OR bags.total IS NULL OR bags.total = 0 THEN 0
              ELSE round(day.cost * b.cement_bags / bags.total, 2) END
  FROM public.production_batches b
  JOIN public.power_meter_machines pm ON pm.machine_id = b.machine_id
  CROSS JOIN LATERAL (SELECT sum(u.cost) AS cost FROM public.power_use u
                      WHERE u.meter_id = pm.meter_id AND u.kind = 'day' AND u.day = b.batch_date) day
  CROSS JOIN LATERAL (SELECT sum(x.cement_bags) AS total FROM public.production_batches x
                      JOIN public.power_meter_machines q ON q.machine_id = x.machine_id AND q.meter_id = pm.meter_id
                      WHERE x.branch_id = b.branch_id AND x.batch_date = b.batch_date AND x.status <> 'void') bags
  WHERE b.id = p_batch AND b.status <> 'void'
$$;
REVOKE ALL ON FUNCTION public.batch_power_cost(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.batch_power_cost(uuid) TO authenticated;

-- A batch output's cost per stock unit: materials + its share (by cement taken) of the batch's electricity
-- (replaces 058's; stock value, costing and sales margins all read it)
CREATE OR REPLACE FUNCTION public.output_cost_per_unit(p_output public.production_batch_outputs)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN p_output.material_cost IS NOT NULL AND p_output.pieces_cast > 0
              THEN (p_output.material_cost + coalesce(public.batch_power_cost(p_output.batch_id), 0) * coalesce(p_output.cement_share, 0))
                   / nullif(public.production_stock_qty(p_output.product_id, p_output.pieces_cast), 0) END
$$;
