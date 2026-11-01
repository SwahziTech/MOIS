-- ============================================================
-- 101 — Read helpers check the company
-- ============================================================
-- SwahziTech, 2026-11-01, from the separation check: these read-only helpers
-- run with full rights and answered for any id, whichever company it belonged
-- to, and some for people not signed in. A person now only gets an answer for
-- their own company; the helpers give the same empty answer otherwise. Server
-- work with no person behind it (auth.uid() empty) is unchanged. Signed-out
-- callers can no longer run them at all.
-- ============================================================

CREATE OR REPLACE FUNCTION public.may_read_org(p_org uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT auth.uid() IS NULL OR p_org = public.get_my_org_id()
$$;
COMMENT ON FUNCTION public.may_read_org(uuid) IS 'For SECURITY DEFINER helpers: the caller''s own company, or server work with no person behind it (101).';

CREATE OR REPLACE FUNCTION public.batch_labour_cost(p_batch uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT round(coalesce(
           (SELECT (d.wages + d.employer) * b.cement_bags / nullif((SELECT sum(x.cement_bags) FROM public.production_batches x
                                                      WHERE x.branch_id = b.branch_id AND x.batch_date = b.batch_date AND x.status <> 'void'), 0)
              FROM public.labour_days d WHERE d.branch_id = b.branch_id AND d.day = b.batch_date), 0), 2)
  FROM public.production_batches b WHERE b.id = p_batch AND b.status <> 'void' AND public.may_read_org(b.organization_id)
$function$;

CREATE OR REPLACE FUNCTION public.batch_overhead_cost(p_batch uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(round(sum(CASE WHEN m.bags > 0 THEN m.overheads * b.cement_bags / m.bags END), 2), 0)
  FROM public.production_batches b
  JOIN public.production_overhead_months m ON m.branch_id = b.branch_id AND m.month = date_trunc('month', b.batch_date)::date
                                         AND (m.machine_id IS NULL OR m.machine_id = b.machine_id)
  WHERE b.id = p_batch AND b.status <> 'void' AND public.may_read_org(b.organization_id)
$function$;

CREATE OR REPLACE FUNCTION public.batch_power_cost(p_batch uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN day.cost IS NULL OR bags.total IS NULL OR bags.total = 0 THEN 0
              ELSE round(day.cost * b.cement_bags / bags.total, 2) END
  FROM public.production_batches b
  JOIN public.power_meter_machines pm ON pm.machine_id = b.machine_id
  CROSS JOIN LATERAL (SELECT sum(u.cost) AS cost FROM public.power_use u
                      WHERE u.meter_id = pm.meter_id AND u.kind = 'day' AND u.day = b.batch_date) day
  CROSS JOIN LATERAL (SELECT sum(x.cement_bags) AS total FROM public.production_batches x
                      JOIN public.power_meter_machines q ON q.machine_id = x.machine_id AND q.meter_id = pm.meter_id
                      WHERE x.branch_id = b.branch_id AND x.batch_date = b.batch_date AND x.status <> 'void') bags
  WHERE b.id = p_batch AND b.status <> 'void' AND public.may_read_org(b.organization_id)
$function$;

CREATE OR REPLACE FUNCTION public.employer_on_pay_pct(p_org uuid, p_day date, p_statutory boolean)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r_nr  public.statutory_rates;
  r_wcf public.statutory_rates;
  r_sdl public.statutory_rates;
  pct   numeric := 0;
  heads integer;
BEGIN
  IF NOT public.may_read_org(p_org) THEN RETURN 0; END IF;
  SELECT * INTO r_nr FROM public.statutory_rates WHERE organization_id = p_org AND code = 'nssf_employer' AND status = 'active' AND effective_from <= p_day ORDER BY effective_from DESC LIMIT 1;
  SELECT * INTO r_wcf FROM public.statutory_rates WHERE organization_id = p_org AND code = 'wcf' AND status = 'active' AND effective_from <= p_day ORDER BY effective_from DESC LIMIT 1;
  SELECT * INTO r_sdl FROM public.statutory_rates WHERE organization_id = p_org AND code = 'sdl' AND status = 'active' AND effective_from <= p_day ORDER BY effective_from DESC LIMIT 1;
  IF p_statutory THEN pct := coalesce(r_nr.rate, 0) + coalesce(r_wcf.rate, 0); END IF;
  IF r_sdl.id IS NOT NULL AND (p_statutory OR r_sdl.count_casuals) THEN
    SELECT count(*) INTO heads FROM public.staff st
    WHERE st.organization_id = p_org AND (st.started_on IS NULL OR st.started_on <= p_day)
      AND (st.status = 'active' OR st.left_on >= p_day)
      AND (coalesce(st.statutory, st.kind = 'employed', false) OR r_sdl.count_casuals);
    IF heads >= coalesce(r_sdl.min_employees, 0) THEN pct := pct + r_sdl.rate; END IF;
  END IF;
  RETURN pct;
END;
$function$;

CREATE OR REPLACE FUNCTION public.is_category_group(p_category_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.product_categories WHERE parent_category_id = p_category_id AND public.may_read_org(organization_id))
$function$;

CREATE OR REPLACE FUNCTION public.is_technical_role(p_role_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.roles WHERE id = p_role_id AND name = 'owner' AND is_system_role AND public.may_read_org(organization_id))
$function$;

CREATE OR REPLACE FUNCTION public.material_stock_qty(p_material uuid, p_unit uuid, p_qty numeric)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN m.stock_unit_id = p_unit THEN p_qty ELSE p_qty * c.factor_to_stock_unit END
  FROM public.materials m
  LEFT JOIN public.material_unit_conversions c ON c.material_id = m.id AND c.unit_id = p_unit
  WHERE m.id = p_material AND public.may_read_org(m.organization_id)
$function$;

CREATE OR REPLACE FUNCTION public.org_today(p_org uuid)
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT (now() AT TIME ZONE coalesce((SELECT timezone FROM public.organizations WHERE id = p_org AND public.may_read_org(id)), 'UTC'))::date
$function$;

CREATE OR REPLACE FUNCTION public.power_fifo_cost(p_meter uuid, p_units numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  first_r record;
  open_price numeric;
  left_u numeric := greatest(coalesce(p_units, 0), 0);
  total numeric := 0;
  take numeric;
  k public.power_tokens;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.power_meters WHERE id = p_meter AND public.may_read_org(organization_id)) THEN RETURN NULL; END IF;
  IF left_u = 0 THEN RETURN 0; END IF;
  SELECT read_at, reading INTO first_r FROM public.power_readings WHERE meter_id = p_meter AND status = 'recorded' ORDER BY read_at LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  -- the units already on the meter: the token loaded before the first reading, else the first token
  SELECT public.power_token_unit_price(t) INTO open_price FROM public.power_tokens t WHERE meter_id = p_meter AND status = 'recorded' AND loaded_at <= first_r.read_at ORDER BY loaded_at DESC LIMIT 1;
  IF open_price IS NULL THEN
    SELECT public.power_token_unit_price(t) INTO open_price FROM public.power_tokens t WHERE meter_id = p_meter AND status = 'recorded' ORDER BY loaded_at LIMIT 1;
  END IF;
  take := least(left_u, first_r.reading);
  IF take > 0 THEN
    IF open_price IS NULL THEN RETURN NULL; END IF;
    total := total + take * open_price; left_u := left_u - take;
  END IF;
  FOR k IN SELECT * FROM public.power_tokens WHERE meter_id = p_meter AND status = 'recorded' AND loaded_at > first_r.read_at ORDER BY loaded_at, created_at LOOP
    EXIT WHEN left_u <= 0;
    take := least(left_u, k.units);
    total := total + take * public.power_token_unit_price(k); left_u := left_u - take;
  END LOOP;
  IF left_u > 0.0001 THEN RETURN NULL; END IF;   -- more used than was ever on the meter
  RETURN total;
END;
$function$;

CREATE OR REPLACE FUNCTION public.product_price_vat_rate(p_branch_id uuid, p_product_id uuid, p_color_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id AND public.may_read_org(organization_id)) THEN coalesce(
    (SELECT x.vat_rate FROM public.product_branch_pricing x WHERE x.product_id = p_product_id AND x.branch_id = p_branch_id
        AND x.color_id IS NOT DISTINCT FROM p_color_id AND x.is_available),
    (SELECT x.vat_rate FROM public.product_branch_pricing x WHERE x.product_id = p_product_id AND x.branch_id = p_branch_id
        AND x.color_id IS NULL AND x.is_available),
    (SELECT vat_rate FROM public.branches WHERE id = p_branch_id), 0) END
$function$;

CREATE OR REPLACE FUNCTION public.terms_days(p_org uuid, p_customer uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce((SELECT payment_days FROM public.customers WHERE id = p_customer AND public.may_read_org(organization_id)),
                  (SELECT default_payment_days FROM public.organizations WHERE id = p_org AND public.may_read_org(id)), 0)
$function$;

CREATE OR REPLACE FUNCTION public.work_days_a_month(p_org uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce((SELECT work_days_a_month FROM public.payroll_settings WHERE organization_id = p_org AND public.may_read_org(p_org)), 26)
$function$;

REVOKE ALL ON FUNCTION public.may_read_org(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.may_read_org(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.batch_labour_cost(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.batch_labour_cost(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.batch_overhead_cost(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.batch_overhead_cost(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.batch_power_cost(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.batch_power_cost(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.employer_on_pay_pct(uuid, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.employer_on_pay_pct(uuid, date, boolean) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.is_category_group(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_category_group(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.is_technical_role(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_technical_role(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.material_stock_qty(uuid, uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.material_stock_qty(uuid, uuid, numeric) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.org_today(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.org_today(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.power_fifo_cost(uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.power_fifo_cost(uuid, numeric) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.product_price_vat_rate(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.product_price_vat_rate(uuid, uuid, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.terms_days(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.terms_days(uuid, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.work_days_a_month(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.work_days_a_month(uuid) TO authenticated, service_role;
