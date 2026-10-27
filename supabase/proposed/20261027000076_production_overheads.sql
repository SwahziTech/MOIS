-- ============================================================
-- 076 — Production overheads read into a batch's cost (1e)
--
-- SwahziTech, 2026-10-27: diesel, repairs, molds and other spending stay
-- where they are recorded — Purchases › Expenses. A category ticked "counts
-- in production cost" is pulled by Costing:
--   * an expense for a machine/line → shared over that machine's batches in
--     the expense's month, by cement bags;
--   * an expense for no machine → over all the branch's batches that month.
-- Electricity tokens (072, costed by the meter readings) and wages (labour,
-- the Staff/HR phase) are never counted here. Monthly for now; to be revisited
-- as it is tested. Nothing is written into production records.
-- ============================================================

ALTER TABLE public.expense_categories ADD COLUMN in_production_cost boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.expense_categories.in_production_cost IS 'Expenses of this category are production overheads, shared into batch cost (076).';
ALTER TABLE public.expenses ADD COLUMN machine_id uuid REFERENCES public.machines(id) ON DELETE RESTRICT;
COMMENT ON COLUMN public.expenses.machine_id IS 'The machine/line an expense is for (diesel for the press, a mold repair…); NULL = the whole branch (076).';

-- set or clear the machine an expense is for
CREATE OR REPLACE FUNCTION public.set_expense_machine(p_id uuid, p_machine uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ex public.expenses;
BEGIN
  SELECT * INTO ex FROM public.expenses WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND OR ex.status <> 'recorded' THEN RAISE EXCEPTION 'Expense not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.receive', ex.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change expenses at this branch' USING ERRCODE = '42501'; END IF;
  IF p_machine IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.machines WHERE id = p_machine AND branch_id = ex.branch_id) THEN
    RAISE EXCEPTION 'That machine is not at this branch' USING ERRCODE = '23514';
  END IF;
  UPDATE public.expenses SET machine_id = p_machine WHERE id = ex.id;
END;
$$;
REVOKE ALL ON FUNCTION public.set_expense_machine(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_expense_machine(uuid, uuid) TO authenticated;

-- the overhead expenses: a ticked category, recorded, not a LUKU token, not a pay sheet
CREATE OR REPLACE VIEW public.production_overhead_expenses WITH (security_invoker = true) AS
SELECT e.id, e.organization_id, e.branch_id, e.expense_date, date_trunc('month', e.expense_date)::date AS month,
       e.machine_id, e.category_id, c.name AS category, e.description, e.amount
FROM public.expenses e
JOIN public.expense_categories c ON c.id = e.category_id AND c.in_production_cost
WHERE e.status = 'recorded'
  AND NOT EXISTS (SELECT 1 FROM public.power_tokens k WHERE k.expense_id = e.id)
  AND NOT EXISTS (SELECT 1 FROM public.pay_sheets s WHERE s.expense_id = e.id);
GRANT SELECT ON public.production_overhead_expenses TO authenticated;

-- per branch, month and machine (NULL = the whole branch): overheads, the cement bags they are shared over, a bag's share
CREATE OR REPLACE VIEW public.production_overhead_months WITH (security_invoker = true) AS
WITH o AS (
  SELECT organization_id, branch_id, month, machine_id, sum(amount) AS overheads, count(*) AS expenses
  FROM public.production_overhead_expenses GROUP BY 1, 2, 3, 4
)
SELECT o.*, b.bags, b.batches, CASE WHEN b.bags > 0 THEN round(o.overheads / b.bags, 2) END AS per_bag
FROM o
CROSS JOIN LATERAL (SELECT sum(x.cement_bags) AS bags, count(*) AS batches FROM public.production_batches x
                    WHERE x.branch_id = o.branch_id AND x.status <> 'void'
                      AND date_trunc('month', x.batch_date)::date = o.month
                      AND (o.machine_id IS NULL OR x.machine_id = o.machine_id)) b;
GRANT SELECT ON public.production_overhead_months TO authenticated;

-- A batch's share of the overheads of its month: its machine's, and the whole branch's
CREATE FUNCTION public.batch_overhead_cost(p_batch uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT coalesce(round(sum(CASE WHEN m.bags > 0 THEN m.overheads * b.cement_bags / m.bags END), 2), 0)
  FROM public.production_batches b
  JOIN public.production_overhead_months m ON m.branch_id = b.branch_id AND m.month = date_trunc('month', b.batch_date)::date
                                         AND (m.machine_id IS NULL OR m.machine_id = b.machine_id)
  WHERE b.id = p_batch AND b.status <> 'void'
$$;
REVOKE ALL ON FUNCTION public.batch_overhead_cost(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.batch_overhead_cost(uuid) TO authenticated;

-- A batch output's cost per stock unit: materials + its share (by cement taken) of electricity and overheads
-- (replaces 073's; stock value, costing and sales margins all read it)
CREATE OR REPLACE FUNCTION public.output_cost_per_unit(p_output public.production_batch_outputs)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN p_output.material_cost IS NOT NULL AND p_output.pieces_cast > 0
              THEN (p_output.material_cost
                    + (coalesce(public.batch_power_cost(p_output.batch_id), 0) + coalesce(public.batch_overhead_cost(p_output.batch_id), 0))
                      * coalesce(p_output.cement_share, 0))
                   / nullif(public.production_stock_qty(p_output.product_id, p_output.pieces_cast), 0) END
$$;

-- ------------------------------------------------------------
-- A token goes to the existing electricity category ("Electricity (LUKU)" counts) — as 074, the lookup widened
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_power_token(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  m   public.power_meters;
  at  timestamptz := coalesce(nullif(p->>'loaded_at', '')::timestamptz, now());
  un  numeric := nullif(p->>'units', '')::numeric;
  amt numeric := round(nullif(p->>'amount', '')::numeric, 2);
  vat numeric := round(nullif(p->>'vat_amount', '')::numeric, 2);
  ew  numeric := round(nullif(p->>'ewura_levy', '')::numeric, 2);
  rea numeric := round(nullif(p->>'rea_levy', '')::numeric, 2);
  dbt numeric := round(nullif(p->>'debt_deducted', '')::numeric, 2);
  cat uuid;
  eid uuid;
  tid uuid;
  dt  date;
BEGIN
  SELECT * INTO m FROM public.power_meters WHERE id = (p->>'meter_id')::uuid AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Meter not found' USING ERRCODE = '23514'; END IF;
  IF NOT (public.has_permission_at('procurement.receive', m.branch_id, NULL) OR public.has_permission_at('production.create', m.branch_id, NULL)) THEN
    RAISE EXCEPTION 'You can''t record tokens at this branch' USING ERRCODE = '42501';
  END IF;
  IF un IS NULL OR un <= 0 THEN RAISE EXCEPTION 'Enter the units bought' USING ERRCODE = '23514'; END IF;
  IF amt IS NULL OR amt < 0 THEN RAISE EXCEPTION 'Enter what was paid' USING ERRCODE = '23514'; END IF;
  IF least(coalesce(vat, 0), coalesce(ew, 0), coalesce(rea, 0), coalesce(dbt, 0)) < 0 THEN RAISE EXCEPTION 'The receipt''s figures can''t be negative' USING ERRCODE = '23514'; END IF;
  IF coalesce(vat, 0) + coalesce(ew, 0) + coalesce(rea, 0) + coalesce(dbt, 0) > amt + 0.004 THEN
    RAISE EXCEPTION 'VAT, levies and debt add up to more than was paid' USING ERRCODE = '23514';
  END IF;
  IF at > now() + interval '5 minutes' THEN RAISE EXCEPTION 'The time can''t be in the future' USING ERRCODE = '23514'; END IF;
  -- a token before a later reading would change that reading's use
  IF EXISTS (SELECT 1 FROM public.power_readings WHERE meter_id = m.id AND status = 'recorded' AND read_at >= at) THEN
    RAISE EXCEPTION 'There are readings after that time — enter the token at the time it was loaded, before those readings, or void them first' USING ERRCODE = '23514';
  END IF;
  dt := (at AT TIME ZONE coalesce((SELECT timezone FROM public.organizations WHERE id = m.organization_id), 'UTC'))::date;
  -- the branch's electricity category, whatever it is called after 'Electricity' (e.g. 'Electricity (LUKU)')
  SELECT id INTO cat FROM public.expense_categories WHERE organization_id = m.organization_id AND public.normalize_name(name) LIKE public.normalize_name('Electricity') || '%'
   ORDER BY (public.normalize_name(name) = public.normalize_name('Electricity')) DESC, (status = 'active') DESC, created_at LIMIT 1;
  IF cat IS NULL THEN
    INSERT INTO public.expense_categories (organization_id, name) VALUES (m.organization_id, 'Electricity') RETURNING id INTO cat;
  END IF;
  INSERT INTO public.expenses (organization_id, branch_id, expense_date, category_id, description, quantity, unit_price, amount, amount_paid,
                               vat_amount, payment_method, paid_on, notes, created_by)
  VALUES (m.organization_id, m.branch_id, dt, cat, 'LUKU token — ' || m.name, un, round(amt / un, 4), amt, amt, vat,
          coalesce(nullif(btrim(p->>'paid_from'), ''), 'cash'), dt,
          nullif(concat_ws(' · ', nullif(btrim(p->>'token_no'), ''),
                           CASE WHEN dbt > 0 THEN 'old debt ' || dbt END,
                           nullif(btrim(p->>'receipt_ref'), '')), ''), auth.uid())
  RETURNING id INTO eid;
  INSERT INTO public.power_tokens (organization_id, branch_id, meter_id, loaded_at, units, amount, token_no, expense_id, created_by,
                                   vat_amount, ewura_levy, rea_levy, debt_deducted, receipt_ref)
  VALUES (m.organization_id, m.branch_id, m.id, at, un, amt, nullif(btrim(p->>'token_no'), ''), eid, auth.uid(),
          vat, ew, rea, dbt, nullif(btrim(p->>'receipt_ref'), ''))
  RETURNING id INTO tid;
  RETURN tid;
END;
$$;
