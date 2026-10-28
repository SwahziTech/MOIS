-- ============================================================
-- 085 — A LUKU token is recorded at the time it was loaded, even when
--       readings were already taken after it
--
-- SwahziTech, 2026-10-28: a token bought on the 26th at 11:22 was refused
-- because that evening's reading was already in MOIS. Recording it at its
-- real time is right: a token only adds units, so no later reading becomes
-- impossible, and the stretch it falls in is worked out with it (072 view).
-- Voiding a token that later readings rely on is still refused (072).
-- As 074, without that refusal; the category is the branch's electricity one (081).
-- ============================================================

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
  nxt record;
  prv record;
  ld  numeric;
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
  -- recorded at the time it was really loaded, even with readings after it: a token only adds units,
  -- so every later reading stays possible and that stretch's use comes out right (085)
  -- …but the reading after it must show the units went up; if it did not, the token went in after that reading
  SELECT read_at, reading INTO nxt FROM public.power_readings WHERE meter_id = m.id AND status = 'recorded' AND read_at >= at ORDER BY read_at LIMIT 1;
  IF FOUND THEN
    SELECT read_at, reading INTO prv FROM public.power_readings WHERE meter_id = m.id AND status = 'recorded' AND read_at < at ORDER BY read_at DESC LIMIT 1;
    IF FOUND THEN
      SELECT coalesce(sum(units), 0) INTO ld FROM public.power_tokens WHERE meter_id = m.id AND status = 'recorded' AND loaded_at > prv.read_at AND loaded_at <= nxt.read_at;
      IF nxt.reading <= prv.reading + ld + 0.0001 THEN
        RAISE EXCEPTION 'The reading after that time (% on %) does not show these units going in — if the token was loaded after that reading, set the time after it',
          nxt.reading, to_char(nxt.read_at AT TIME ZONE coalesce((SELECT timezone FROM public.organizations WHERE id = m.organization_id), 'UTC'), 'YYYY-MM-DD HH24:MI') USING ERRCODE = '23514';
      END IF;
    END IF;
  END IF;
  dt := (at AT TIME ZONE coalesce((SELECT timezone FROM public.organizations WHERE id = m.organization_id), 'UTC'))::date;
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
