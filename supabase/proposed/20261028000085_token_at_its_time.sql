-- ============================================================
-- 085 — LUKU tokens: entered whenever, refused only when entered twice
--
-- SwahziTech, 2026-10-28: LUKU may be bought one day and its token entered
-- days later. So:
--   * a reading is never refused for a token not recorded yet — the stretch
--     the meter went up in shows "token missing" and is not costed until it is;
--   * a token places itself: where the readings first went up after it was
--     bought, else after the latest reading; its expense is dated the day it
--     was bought;
--   * the only refusal is a double entry: the same token number, the same
--     receipt, or the same meter, units, amount and day bought.
-- ============================================================

CREATE OR REPLACE VIEW public.power_use WITH (security_invoker = true) AS
WITH r AS (
  SELECT r.id AS reading_id, r.organization_id, r.branch_id, r.meter_id, m.name AS meter_name,
         p.read_on AS from_on, p.slot AS from_slot, r.read_on AS to_on, r.slot AS to_slot, p.read_at AS from_at, r.read_at AS to_at,
         CASE WHEN p.slot = 'morning' AND r.slot = 'evening' AND p.read_on = r.read_on THEN 'day'
              WHEN p.slot = 'evening' AND r.slot = 'morning' AND r.read_on = p.read_on + 1 THEN 'night'
              ELSE 'gap' END AS kind,
         -- a night belongs to the day it follows
         CASE WHEN p.slot = 'evening' AND r.slot = 'morning' AND r.read_on = p.read_on + 1 THEN p.read_on ELSE r.read_on END AS day,
         p.reading AS from_reading, r.reading AS to_reading, t.loaded AS units_loaded,
         p.reading + t.loaded - r.reading AS units_used,
         -- units used since the first reading, before and after this stretch (oldest token first)
         f.reading + tc.loaded_before - p.reading AS used_before,
         f.reading + tc.loaded_before + t.loaded - r.reading AS used_after
  FROM public.power_readings r
  JOIN public.power_meters m ON m.id = r.meter_id
  JOIN LATERAL (SELECT read_on, slot, read_at, reading FROM public.power_readings x
                WHERE x.meter_id = r.meter_id AND x.status = 'recorded' AND x.read_at < r.read_at
                ORDER BY x.read_at DESC LIMIT 1) p ON true
  JOIN LATERAL (SELECT read_at, reading FROM public.power_readings x
                WHERE x.meter_id = r.meter_id AND x.status = 'recorded' ORDER BY x.read_at LIMIT 1) f ON true
  CROSS JOIN LATERAL (SELECT coalesce(sum(units), 0) AS loaded FROM public.power_tokens k
                      WHERE k.meter_id = r.meter_id AND k.status = 'recorded' AND k.loaded_at > p.read_at AND k.loaded_at <= r.read_at) t
  CROSS JOIN LATERAL (SELECT coalesce(sum(units), 0) AS loaded_before FROM public.power_tokens k
                      WHERE k.meter_id = r.meter_id AND k.status = 'recorded' AND k.loaded_at > f.read_at AND k.loaded_at <= p.read_at) tc
  WHERE r.status = 'recorded'
)
SELECT reading_id, organization_id, branch_id, meter_id, meter_name, kind, day, from_on, from_slot, to_on, to_slot, from_at, to_at,
       from_reading, units_loaded, to_reading, units_used,
       CASE WHEN units_used >= 0 THEN round(public.power_fifo_cost(meter_id, used_after) - public.power_fifo_cost(meter_id, used_before), 2) END AS cost,
       units_used < 0 AS token_missing   -- the meter went up with no token recorded yet (085)
FROM r;
COMMENT ON VIEW public.power_use IS 'Electricity used on a meter between two readings — day, night or gap — oldest token first; a stretch the meter went up in with no token recorded is token_missing and not costed (085).';
GRANT SELECT ON public.power_use TO authenticated;

CREATE OR REPLACE VIEW public.power_daily WITH (security_invoker = true) AS
WITH d AS (
  SELECT organization_id, branch_id, meter_id, meter_name, day,
         sum(units_used) FILTER (WHERE kind = 'day' AND NOT token_missing)   AS day_units,
         sum(cost)       FILTER (WHERE kind = 'day')   AS day_cost,
         sum(units_used) FILTER (WHERE kind = 'night' AND NOT token_missing) AS night_units,
         sum(cost)       FILTER (WHERE kind = 'night') AS night_cost,
         sum(units_used) FILTER (WHERE kind = 'gap' AND NOT token_missing)   AS gap_units,
         sum(cost)       FILTER (WHERE kind = 'gap')   AS gap_cost,
         bool_or(token_missing) AS token_missing
  FROM public.power_use GROUP BY 1, 2, 3, 4, 5
)
SELECT d.organization_id, d.branch_id, d.meter_id, d.meter_name, d.day, d.day_units, d.day_cost, d.night_units, d.night_cost, d.gap_units, d.gap_cost,
       p.batches, p.cement_bags,
       CASE WHEN p.cement_bags > 0 AND d.day_units IS NOT NULL THEN round(d.day_units / p.cement_bags, 3) END AS units_per_bag,
       d.token_missing
FROM d
LEFT JOIN LATERAL (SELECT count(*) AS batches, sum(b.cement_bags) AS cement_bags
                   FROM public.production_batches b JOIN public.power_meter_machines pm ON pm.machine_id = b.machine_id AND pm.meter_id = d.meter_id
                   WHERE b.branch_id = d.branch_id AND b.batch_date = d.day AND b.status <> 'void') p ON true;
COMMENT ON VIEW public.power_daily IS 'Per meter and day: day use, the night after, gaps, and the cement bags its machines took (072).';
GRANT SELECT ON public.power_daily TO authenticated;

CREATE OR REPLACE FUNCTION public.record_power_readings(p jsonb)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  dt   date := nullif(p->>'read_on', '')::date;
  x    jsonb;
  m    public.power_meters;
  tz   text;
  sl   text;
  val  numeric;
  at   timestamptz;
  n    int := 0;
BEGIN
  IF dt IS NULL THEN RAISE EXCEPTION 'Choose the day' USING ERRCODE = '23514'; END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p->'readings', '[]'::jsonb)) LOOP
    val := nullif(x->>'reading', '')::numeric;
    CONTINUE WHEN val IS NULL;
    SELECT * INTO m FROM public.power_meters WHERE id = (x->>'meter_id')::uuid AND organization_id = public.get_my_org_id();
    IF NOT FOUND THEN RAISE EXCEPTION 'Meter not found' USING ERRCODE = '23514'; END IF;
    IF NOT (public.has_permission_at('procurement.receive', m.branch_id, NULL) OR public.has_permission_at('production.create', m.branch_id, NULL)) THEN
      RAISE EXCEPTION 'You can''t record meter readings at this branch' USING ERRCODE = '42501';
    END IF;
    sl := x->>'slot';
    IF sl IS NULL OR sl NOT IN ('morning', 'evening') THEN RAISE EXCEPTION 'Morning or evening?' USING ERRCODE = '23514'; END IF;
    IF val < 0 THEN RAISE EXCEPTION 'Units left can''t be negative' USING ERRCODE = '23514'; END IF;
    SELECT coalesce(timezone, 'UTC') INTO tz FROM public.organizations WHERE id = m.organization_id;
    -- the time read: as given, else 07:00 in the morning and 18:00 in the evening
    at := ((dt + coalesce(nullif(x->>'time', '')::time, CASE sl WHEN 'morning' THEN time '07:00' ELSE time '18:00' END))::timestamp AT TIME ZONE tz);
    IF at > now() + interval '5 minutes' THEN RAISE EXCEPTION '% % is still to come', m.name, CASE sl WHEN 'morning' THEN 'morning' ELSE 'evening' END USING ERRCODE = '23514'; END IF;
    IF EXISTS (SELECT 1 FROM public.power_readings WHERE meter_id = m.id AND read_on = dt AND slot = sl AND status = 'recorded') THEN
      RAISE EXCEPTION '% already has its % reading for %', m.name, sl, dt USING ERRCODE = '23514';
    END IF;
    IF sl = 'evening' AND EXISTS (SELECT 1 FROM public.power_readings WHERE meter_id = m.id AND read_on = dt AND slot = 'morning' AND status = 'recorded' AND read_at >= at) THEN
      RAISE EXCEPTION 'The evening reading must come after the morning''s' USING ERRCODE = '23514';
    END IF;
    -- never refused for a token not recorded yet: that stretch shows "token missing" until it is (085)
    INSERT INTO public.power_readings (organization_id, branch_id, meter_id, read_on, slot, read_at, reading, note, created_by)
    VALUES (m.organization_id, m.branch_id, m.id, dt, sl, at, val, nullif(btrim(x->>'note'), ''), auth.uid());
    n := n + 1;
  END LOOP;
  IF n = 0 THEN RAISE EXCEPTION 'Enter at least one reading' USING ERRCODE = '23514'; END IF;
  RETURN n;
END;
$$;

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
  tz  text;
  bought timestamptz;
  went_in timestamptz;
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
  SELECT coalesce(timezone, 'UTC') INTO tz FROM public.organizations WHERE id = m.organization_id;
  -- the same token entered twice: its number, its receipt, or the same meter, units, amount and day
  IF nullif(btrim(p->>'token_no'), '') IS NOT NULL AND EXISTS (SELECT 1 FROM public.power_tokens WHERE meter_id = m.id AND status = 'recorded'
       AND regexp_replace(coalesce(token_no, ''), '[^0-9]', '', 'g') = regexp_replace(p->>'token_no', '[^0-9]', '', 'g')) THEN
    RAISE EXCEPTION 'This token number is already recorded for %', m.name USING ERRCODE = '23505';
  END IF;
  IF nullif(btrim(p->>'receipt_ref'), '') IS NOT NULL AND EXISTS (SELECT 1 FROM public.power_tokens WHERE meter_id = m.id AND status = 'recorded'
       AND btrim(coalesce(receipt_ref, '')) = btrim(p->>'receipt_ref')) THEN
    RAISE EXCEPTION 'This receipt is already recorded for %', m.name USING ERRCODE = '23505';
  END IF;
  IF EXISTS (SELECT 1 FROM public.power_tokens k JOIN public.expenses e ON e.id = k.expense_id
              WHERE k.meter_id = m.id AND k.status = 'recorded' AND k.units = un AND k.amount = amt AND e.expense_date = (at AT TIME ZONE tz)::date) THEN
    RAISE EXCEPTION 'A token of % units for % bought that day is already recorded — is it the same one?', un, amt USING ERRCODE = '23505';
  END IF;
  -- "at" is when it was bought; it went on the meter where the readings first went up after that with no token recorded,
  -- else after the latest reading — so a token may be entered days after it was bought or loaded
  bought := at;
  SELECT u.from_at INTO went_in FROM public.power_use u
   WHERE u.meter_id = m.id AND u.token_missing AND u.to_at > bought ORDER BY u.to_at LIMIT 1;
  IF went_in IS NOT NULL THEN
    at := greatest(bought, went_in + interval '1 minute');
  ELSE
    at := greatest(bought, coalesce((SELECT max(read_at) FROM public.power_readings WHERE meter_id = m.id AND status = 'recorded') + interval '1 minute', bought));
  END IF;
  at := least(at, now());
  dt := (bought AT TIME ZONE tz)::date;   -- the expense: the day it was bought
  cat := public.electricity_category(m.organization_id);   -- e.g. 'Electricity (LUKU)' (081)
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
