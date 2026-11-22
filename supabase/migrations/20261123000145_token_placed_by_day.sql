-- ============================================================
-- 145 — A LUKU token is placed by the day, not the guessed clock time
--
-- SwahziTech, 2026-11-23 (the user: "this is not right"): a token bought at
-- 07:53 was already in that morning's reading (the meter rose overnight), but
-- readings are stamped 07:00 / 18:00 by default, so the token landed after
-- the morning reading and the day's use came out as day use + the token.
-- record_power_token (085) now looks for the stretch the meter went up in
-- from the day it was bought, and places the token inside that stretch.
-- (Tokens already recorded are moved one by one, outside this file.)
-- ============================================================

CREATE OR REPLACE FUNCTION public.record_power_token(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  went_out timestamptz;
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
  -- by DAY, not clock time (145): a reading's time is a guess (07:00 / 18:00), so a token bought at 07:53 may already be in
  -- that morning's reading; it goes inside the stretch the meter went up in, never after it
  SELECT u.from_at, u.to_at INTO went_in, went_out FROM public.power_use u
   WHERE u.meter_id = m.id AND u.token_missing AND u.to_on >= (bought AT TIME ZONE tz)::date ORDER BY u.to_at LIMIT 1;
  IF went_in IS NOT NULL THEN
    at := least(greatest(bought, went_in + interval '1 minute'), went_out - interval '1 minute');
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
$function$
;
