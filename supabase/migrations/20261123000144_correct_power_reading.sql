-- ============================================================
-- 144 — The technical admin corrects a meter reading
--
-- SwahziTech, 2026-11-23 (the user): "If wrong dates/reading were entered, the
-- tech admin should be able to edit." A recorded reading is never changed in
-- place: the old one is voided ("Corrected") and the right one recorded, so
-- the history keeps both. Day, morning/evening and units can all change.
-- Technical admin only (system.manage); others still void and re-enter.
--
-- correct_power_reading(p_id, p): p = { read_on, slot, reading }
-- ============================================================

CREATE FUNCTION public.correct_power_reading(p_id uuid, p jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  r   public.power_readings;
  m   public.power_meters;
  dt  date := coalesce(nullif(p->>'read_on', '')::date, NULL);
  sl  text := nullif(p->>'slot', '');
  val numeric := nullif(p->>'reading', '')::numeric;
  tz  text;
  at  timestamptz;
  nid uuid;
BEGIN
  SELECT * INTO r FROM public.power_readings WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reading not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('system.manage', r.branch_id, NULL) THEN
    RAISE EXCEPTION 'Only the technical admin corrects meter readings' USING ERRCODE = '42501';
  END IF;
  IF r.status <> 'recorded' THEN RAISE EXCEPTION 'That reading is void' USING ERRCODE = '23514'; END IF;
  dt := coalesce(dt, r.read_on); sl := coalesce(sl, r.slot); val := coalesce(val, r.reading);
  IF sl NOT IN ('morning', 'evening') THEN RAISE EXCEPTION 'Morning or evening?' USING ERRCODE = '23514'; END IF;
  IF val < 0 THEN RAISE EXCEPTION 'Units left can''t be negative' USING ERRCODE = '23514'; END IF;
  IF dt = r.read_on AND sl = r.slot AND val = r.reading THEN RETURN r.id; END IF;   -- nothing changed

  SELECT * INTO m FROM public.power_meters WHERE id = r.meter_id;
  SELECT coalesce(timezone, 'UTC') INTO tz FROM public.organizations WHERE id = r.organization_id;
  -- same time of day as before when only the day moves; else 07:00 / 18:00 (as record_power_readings)
  at := CASE WHEN sl = r.slot THEN ((dt + (r.read_at AT TIME ZONE tz)::time)::timestamp AT TIME ZONE tz)
             ELSE ((dt + CASE sl WHEN 'morning' THEN time '07:00' ELSE time '18:00' END)::timestamp AT TIME ZONE tz) END;
  IF at > now() + interval '5 minutes' THEN RAISE EXCEPTION '% % is still to come', m.name, sl USING ERRCODE = '23514'; END IF;

  UPDATE public.power_readings SET status = 'void', void_reason = 'Corrected' WHERE id = r.id;
  IF EXISTS (SELECT 1 FROM public.power_readings WHERE meter_id = r.meter_id AND read_on = dt AND slot = sl AND status = 'recorded') THEN
    RAISE EXCEPTION '% already has its % reading for % — correct or void that one', m.name, sl, dt USING ERRCODE = '23514';
  END IF;
  IF sl = 'evening' AND EXISTS (SELECT 1 FROM public.power_readings WHERE meter_id = r.meter_id AND read_on = dt AND slot = 'morning' AND status = 'recorded' AND read_at >= at) THEN
    RAISE EXCEPTION 'The evening reading must come after the morning''s' USING ERRCODE = '23514';
  END IF;
  IF sl = 'morning' AND EXISTS (SELECT 1 FROM public.power_readings WHERE meter_id = r.meter_id AND read_on = dt AND slot = 'evening' AND status = 'recorded' AND read_at <= at) THEN
    RAISE EXCEPTION 'The morning reading must come before the evening''s' USING ERRCODE = '23514';
  END IF;
  INSERT INTO public.power_readings (organization_id, branch_id, meter_id, read_on, slot, read_at, reading, note, created_by)
  VALUES (r.organization_id, r.branch_id, r.meter_id, dt, sl, at, val, r.note, auth.uid())
  RETURNING id INTO nid;
  RETURN nid;
END;
$fn$;
REVOKE ALL ON FUNCTION public.correct_power_reading(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_power_reading(uuid, jsonb) TO authenticated;
