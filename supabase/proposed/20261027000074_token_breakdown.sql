-- ============================================================
-- 074 — A LUKU token's receipt breakdown (1e)
--
-- SwahziTech, 2026-10-27: a token records what its receipt shows — VAT,
-- the EWURA and REA levies, and any old debt the vendor took off the amount.
-- The figures are typed from the receipt (never worked out here). VAT goes on
-- the Electricity expense (input VAT). An old debt paid with the token is
-- electricity of an earlier period, so it is not part of these units' price:
-- the units are priced at (amount − debt) ÷ units, oldest token first.
-- ============================================================

ALTER TABLE public.power_tokens
  ADD COLUMN vat_amount    numeric CHECK (vat_amount >= 0),
  ADD COLUMN ewura_levy    numeric CHECK (ewura_levy >= 0),
  ADD COLUMN rea_levy      numeric CHECK (rea_levy >= 0),
  ADD COLUMN debt_deducted numeric CHECK (debt_deducted >= 0),
  ADD COLUMN receipt_ref   text;                 -- the vendor's transaction / receipt reference
COMMENT ON COLUMN public.power_tokens.debt_deducted IS 'Old debt taken off the amount by the vendor — not part of these units'' price (074).';

-- the price of a token's units: what was paid less any old debt
CREATE OR REPLACE FUNCTION public.power_token_unit_price(k public.power_tokens)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT greatest(k.amount - coalesce(k.debt_deducted, 0), 0) / k.units
$$;

-- as in 072, priced without the old debt
CREATE OR REPLACE FUNCTION public.power_fifo_cost(p_meter uuid, p_units numeric)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  first_r record;
  open_price numeric;
  left_u numeric := greatest(coalesce(p_units, 0), 0);
  total numeric := 0;
  take numeric;
  k public.power_tokens;
BEGIN
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
$$;

-- Load a token — p: { meter_id, units, amount, loaded_at?, token_no?, paid_from?,
--                     vat_amount?, ewura_levy?, rea_levy?, debt_deducted?, receipt_ref? }
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
  SELECT id INTO cat FROM public.expense_categories WHERE organization_id = m.organization_id AND public.normalize_name(name) = public.normalize_name('Electricity');
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
