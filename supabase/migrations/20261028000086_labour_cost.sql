-- ============================================================
-- 086 — Staff (HR) Part 1: NSSF number; labour read into a batch's cost
--
-- SwahziTech, 2026-10-28: HR holds the people (071: staff, attendance);
-- Costing pulls their pay into production cost:
--   * casual labourers — their day rate × the days marked in attendance,
--     shared over that day's batches at the branch by cement bags;
--   * employed staff whose pay is part of product cost (team leaders, …) —
--     the monthly salary shared over the month's batches by cement bags.
-- Office/running staff are unticked (in_production_cost = false) and stay out.
-- Pay sheets and statutory deductions come in Part 2, after the rates are
-- verified. Pay and names are entered in the app only.
-- ============================================================

ALTER TABLE public.staff ADD COLUMN nssf_no text;
COMMENT ON COLUMN public.staff.nssf_no IS 'NSSF membership number (086).';

-- a day's casual wages at a branch (production staff on a day rate, as marked in attendance)
CREATE OR REPLACE VIEW public.labour_days WITH (security_invoker = true) AS
SELECT a.organization_id, a.branch_id, a.work_date AS day,
       count(DISTINCT a.staff_id) AS people, sum(a.day_fraction) AS days,
       sum(a.day_fraction * s.pay_rate) AS wages,
       count(*) FILTER (WHERE s.pay_rate IS NULL) AS without_rate
FROM public.staff_attendance a JOIN public.staff s ON s.id = a.staff_id
WHERE coalesce(s.pay_basis, CASE s.kind WHEN 'employed' THEN 'monthly' ELSE 'daily' END) = 'daily' AND s.in_production_cost
GROUP BY 1, 2, 3;
GRANT SELECT ON public.labour_days TO authenticated;

-- a month's salaries of production staff at a branch (employed, on a monthly salary, in product cost)
CREATE OR REPLACE VIEW public.labour_months WITH (security_invoker = true) AS
SELECT s.organization_id, s.branch_id, mo.month,
       count(*) AS people, sum(s.pay_rate) AS salaries, count(*) FILTER (WHERE s.pay_rate IS NULL) AS without_rate
FROM public.staff s
CROSS JOIN LATERAL (SELECT generate_series(date_trunc('month', coalesce(s.started_on, '2026-01-01'::date)), date_trunc('month', coalesce(s.left_on, current_date)), interval '1 month')::date AS month) mo
WHERE coalesce(s.pay_basis, CASE s.kind WHEN 'employed' THEN 'monthly' ELSE 'daily' END) = 'monthly' AND s.in_production_cost
  AND (s.status = 'active' OR s.left_on IS NOT NULL)
GROUP BY 1, 2, 3;
GRANT SELECT ON public.labour_months TO authenticated;

-- A batch's share of labour: its day's casual wages and its month's production salaries, by cement bags
CREATE OR REPLACE FUNCTION public.batch_labour_cost(p_batch uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT round(coalesce(
           (SELECT d.wages * b.cement_bags / nullif((SELECT sum(x.cement_bags) FROM public.production_batches x
                                                      WHERE x.branch_id = b.branch_id AND x.batch_date = b.batch_date AND x.status <> 'void'), 0)
              FROM public.labour_days d WHERE d.branch_id = b.branch_id AND d.day = b.batch_date), 0)
         + coalesce(
           (SELECT mth.salaries * b.cement_bags / nullif((SELECT sum(x.cement_bags) FROM public.production_batches x
                                                          WHERE x.branch_id = b.branch_id AND date_trunc('month', x.batch_date) = date_trunc('month', b.batch_date) AND x.status <> 'void'), 0)
              FROM public.labour_months mth WHERE mth.branch_id = b.branch_id AND mth.month = date_trunc('month', b.batch_date)::date), 0), 2)
  FROM public.production_batches b WHERE b.id = p_batch AND b.status <> 'void'
$$;
REVOKE ALL ON FUNCTION public.batch_labour_cost(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.batch_labour_cost(uuid) TO authenticated;

-- A batch output's cost per stock unit: materials + its share (by cement taken) of electricity, overheads and labour
-- (replaces 076's; stock value, costing and sales margins all read it)
CREATE OR REPLACE FUNCTION public.output_cost_per_unit(p_output public.production_batch_outputs)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN p_output.material_cost IS NOT NULL AND p_output.pieces_cast > 0
              THEN (p_output.material_cost
                    + (coalesce(public.batch_power_cost(p_output.batch_id), 0) + coalesce(public.batch_overhead_cost(p_output.batch_id), 0)
                       + coalesce(public.batch_labour_cost(p_output.batch_id), 0))
                      * coalesce(p_output.cement_share, 0))
                   / nullif(public.production_stock_qty(p_output.product_id, p_output.pieces_cast), 0) END
$$;
