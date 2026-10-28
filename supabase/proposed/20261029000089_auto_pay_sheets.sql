-- ============================================================
-- 089 — Pay sheets made automatically from attendance (Staff (HR) Part 2)
-- ============================================================
-- SwahziTech, 2026-10-29, the user: "The pay sheet should be automatic for
-- casuals and employees, depending on the attendance."
--
--   * Marking attendance (or changing someone's pay) keeps a draft pay sheet
--     for that pay period up to date: weekly Mon–Sun, every 2 weeks 1–15 and
--     16–end, monthly the month. No one prepares sheets by hand any more;
--     they are approved and paid as before (088).
--   * Everyone is paid by the days attended: casuals days × day rate;
--     employed days × salary ÷ working days a month (26 unless changed in
--     HR › Staff ⚙). Someone with no days in the period isn't on the sheet.
--   * Attendance can't change in a period whose pay sheet is approved or paid.
--   * Existing attendance of the last two months gets its sheets now.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Working days a month (a salary by the day)
-- ------------------------------------------------------------
CREATE TABLE public.payroll_settings (
  organization_id   uuid PRIMARY KEY REFERENCES public.organizations(id) ON DELETE CASCADE,
  work_days_a_month numeric NOT NULL DEFAULT 26 CHECK (work_days_a_month > 0 AND work_days_a_month <= 31),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_payroll_settings_updated_at BEFORE UPDATE ON public.payroll_settings FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_payroll_settings_audit AFTER INSERT OR UPDATE OR DELETE ON public.payroll_settings FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('payroll_settings', 'organization_id');
ALTER TABLE public.payroll_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "payroll_settings: read own org" ON public.payroll_settings FOR SELECT USING (organization_id = public.get_my_org_id());

CREATE OR REPLACE FUNCTION public.work_days_a_month(p_org uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce((SELECT work_days_a_month FROM public.payroll_settings WHERE organization_id = p_org), 26)
$$;

-- the pay period holding a day
CREATE OR REPLACE FUNCTION public.pay_period(p_cycle text, p_day date, OUT p_start date, OUT p_end date)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_cycle
           WHEN 'weekly' THEN p_day - (extract(isodow FROM p_day)::int - 1)
           WHEN 'fortnightly' THEN CASE WHEN extract(day FROM p_day) <= 15 THEN date_trunc('month', p_day)::date ELSE date_trunc('month', p_day)::date + 15 END
           ELSE date_trunc('month', p_day)::date END,
         CASE p_cycle
           WHEN 'weekly' THEN p_day - (extract(isodow FROM p_day)::int - 1) + 6
           WHEN 'fortnightly' THEN CASE WHEN extract(day FROM p_day) <= 15 THEN date_trunc('month', p_day)::date + 14 ELSE (date_trunc('month', p_day) + interval '1 month - 1 day')::date END
           ELSE (date_trunc('month', p_day) + interval '1 month - 1 day')::date END
$$;

-- ------------------------------------------------------------
-- 2. A sheet's lines: everyone by the days attended
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fill_pay_sheet_lines(p_sheet uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO public.pay_sheet_lines (organization_id, sheet_id, staff_id, pay_basis, days, rate, base, amount)
  SELECT ps.organization_id, ps.id, st.id, b.basis, d.days, st.pay_rate, x.base, x.base
  FROM public.pay_sheets ps
  JOIN public.staff st ON st.branch_id = ps.branch_id
  CROSS JOIN LATERAL (SELECT coalesce(st.pay_basis, CASE st.kind WHEN 'employed' THEN 'monthly' ELSE 'daily' END) AS basis,
                             coalesce(st.pay_cycle, CASE st.kind WHEN 'employed' THEN 'fortnightly' ELSE 'weekly' END) AS cycle) b
  JOIN LATERAL (SELECT sum(a.day_fraction) AS days FROM public.staff_attendance a
                WHERE a.staff_id = st.id AND a.work_date BETWEEN ps.period_start AND ps.period_end) d ON d.days > 0
  CROSS JOIN LATERAL (SELECT round(coalesce(d.days * st.pay_rate
                        / CASE b.basis WHEN 'daily' THEN 1 ELSE public.work_days_a_month(ps.organization_id) END, 0), 2) AS base) x
  WHERE ps.id = p_sheet
    AND b.cycle = ps.cycle;
  SELECT public.compute_pay_sheet(p_sheet);
$$;
REVOKE ALL ON FUNCTION public.fill_pay_sheet_lines(uuid) FROM PUBLIC, anon, authenticated;

-- re-read a draft from the staff list, attendance and rates (keeps additions, deductions and notes)
CREATE OR REPLACE FUNCTION public.refill_pay_sheet(p_sheet uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  keep jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.pay_sheets WHERE id = p_sheet AND status = 'draft') THEN RETURN; END IF;
  SELECT coalesce(jsonb_object_agg(staff_id, jsonb_build_object('a', additions, 'd', deductions, 'n', note)), '{}') INTO keep
  FROM public.pay_sheet_lines WHERE sheet_id = p_sheet;
  DELETE FROM public.pay_sheet_lines WHERE sheet_id = p_sheet;
  PERFORM public.fill_pay_sheet_lines(p_sheet);
  UPDATE public.pay_sheet_lines l SET additions = (keep->(l.staff_id::text)->>'a')::numeric, deductions = (keep->(l.staff_id::text)->>'d')::numeric,
         note = keep->(l.staff_id::text)->>'n'
  WHERE l.sheet_id = p_sheet AND keep ? l.staff_id::text;
  PERFORM public.compute_pay_sheet(p_sheet);
END;
$$;
REVOKE ALL ON FUNCTION public.refill_pay_sheet(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.refresh_pay_sheet(p_sheet uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s public.pay_sheets;
BEGIN
  SELECT * INTO s FROM public.pay_sheets WHERE id = p_sheet AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pay sheet not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('payroll.record', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change pay sheets at this branch' USING ERRCODE = '42501'; END IF;
  IF s.status <> 'draft' THEN RAISE EXCEPTION 'Only a draft pay sheet can change' USING ERRCODE = '23514'; END IF;
  PERFORM public.refill_pay_sheet(s.id);
END;
$$;

-- ------------------------------------------------------------
-- 3. Keep the period's draft sheet: found, made or refilled
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ensure_pay_sheet(p_org uuid, p_branch uuid, p_cycle text, p_day date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  per record;
  s   public.pay_sheets;
BEGIN
  SELECT * INTO s FROM public.pay_sheets
  WHERE branch_id = p_branch AND cycle = p_cycle AND status <> 'void' AND p_day BETWEEN period_start AND period_end
  ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    SELECT * INTO per FROM public.pay_period(p_cycle, p_day);
    -- a hand-made sheet overlapping the period keeps the day; otherwise a new draft
    IF EXISTS (SELECT 1 FROM public.pay_sheets WHERE branch_id = p_branch AND cycle = p_cycle AND status <> 'void'
               AND daterange(period_start, period_end, '[]') && daterange(per.p_start, per.p_end, '[]')) THEN RETURN; END IF;
    INSERT INTO public.pay_sheets (organization_id, branch_id, cycle, period_start, period_end, prepared_by, notes)
    VALUES (p_org, p_branch, p_cycle, per.p_start, per.p_end, auth.uid(), 'Made from attendance')
    RETURNING * INTO s;
  END IF;
  IF s.status = 'draft' THEN PERFORM public.refill_pay_sheet(s.id); END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.ensure_pay_sheet(uuid, uuid, text, date) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.cycle_of_staff(st public.staff)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(st.pay_cycle, CASE st.kind WHEN 'employed' THEN 'fortnightly' ELSE 'weekly' END)
$$;

-- attendance marked or cleared → that period's sheet
CREATE OR REPLACE FUNCTION public.attendance_pay_sheet()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  a  public.staff_attendance := coalesce(NEW, OLD);
  st public.staff;
BEGIN
  SELECT * INTO st FROM public.staff WHERE id = a.staff_id;
  PERFORM public.ensure_pay_sheet(st.organization_id, st.branch_id, public.cycle_of_staff(st), a.work_date);
  RETURN NULL;
END;
$$;
CREATE TRIGGER trg_attendance_pay_sheet AFTER INSERT OR UPDATE OR DELETE ON public.staff_attendance
  FOR EACH ROW EXECUTE FUNCTION public.attendance_pay_sheet();

-- someone's pay or kind changed → the drafts holding their days (old and new cycle)
CREATE OR REPLACE FUNCTION public.staff_pay_sheets()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d date;
BEGIN
  FOR d IN SELECT DISTINCT work_date FROM public.staff_attendance a
           WHERE a.staff_id = NEW.id AND a.work_date >= public.org_today(NEW.organization_id) - 62
             AND NOT EXISTS (SELECT 1 FROM public.pay_sheets s WHERE s.branch_id = NEW.branch_id AND s.status IN ('approved', 'paid')
                             AND a.work_date BETWEEN s.period_start AND s.period_end
                             AND s.cycle IN (public.cycle_of_staff(OLD), public.cycle_of_staff(NEW))) LOOP
    PERFORM public.ensure_pay_sheet(NEW.organization_id, NEW.branch_id, public.cycle_of_staff(NEW), d);
    IF public.cycle_of_staff(OLD) <> public.cycle_of_staff(NEW) THEN
      PERFORM public.ensure_pay_sheet(NEW.organization_id, NEW.branch_id, public.cycle_of_staff(OLD), d);
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;
CREATE TRIGGER trg_staff_pay_sheets AFTER UPDATE OF pay_rate, pay_basis, pay_cycle, kind, statutory ON public.staff
  FOR EACH ROW EXECUTE FUNCTION public.staff_pay_sheets();

-- working days a month (Technical admin / directors): drafts follow
CREATE OR REPLACE FUNCTION public.set_work_days_a_month(p_days numeric)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  sid uuid;
BEGIN
  IF NOT public.has_permission('payroll.rates') THEN RAISE EXCEPTION 'Only the Technical admin or a director changes this' USING ERRCODE = '42501'; END IF;
  IF p_days IS NULL OR p_days <= 0 OR p_days > 31 THEN RAISE EXCEPTION 'Enter the working days a month (1–31)' USING ERRCODE = '23514'; END IF;
  INSERT INTO public.payroll_settings (organization_id, work_days_a_month) VALUES (org, p_days)
  ON CONFLICT (organization_id) DO UPDATE SET work_days_a_month = EXCLUDED.work_days_a_month;
  FOR sid IN SELECT id FROM public.pay_sheets WHERE organization_id = org AND status = 'draft' LOOP
    PERFORM public.refill_pay_sheet(sid);
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.set_work_days_a_month(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_work_days_a_month(numeric) TO authenticated;

-- ------------------------------------------------------------
-- 4. Attendance: not in a period already approved or paid
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_attendance(p jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  st  public.staff;
  dt  date := nullif(p->>'work_date', '')::date;
  fr  numeric := coalesce(nullif(p->>'day_fraction', '')::numeric, 1);
BEGIN
  SELECT * INTO st FROM public.staff WHERE id = (p->>'staff_id')::uuid AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Staff member not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('payroll.record', st.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t mark attendance at this branch' USING ERRCODE = '42501'; END IF;
  IF dt IS NULL THEN RAISE EXCEPTION 'Choose the day' USING ERRCODE = '23514'; END IF;
  IF dt > public.org_today(st.organization_id) THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;
  IF fr NOT IN (0, 0.5, 1) THEN RAISE EXCEPTION 'A day is worked in full or half' USING ERRCODE = '23514'; END IF;
  IF EXISTS (SELECT 1 FROM public.pay_sheets s
             WHERE s.branch_id = st.branch_id AND s.status IN ('approved', 'paid') AND dt BETWEEN s.period_start AND s.period_end
               AND (s.cycle = public.cycle_of_staff(st)
                    OR EXISTS (SELECT 1 FROM public.pay_sheet_lines l WHERE l.sheet_id = s.id AND l.staff_id = st.id))) THEN
    RAISE EXCEPTION 'That day''s pay sheet is approved — attendance can''t change' USING ERRCODE = '23514';
  END IF;
  IF fr = 0 THEN
    DELETE FROM public.staff_attendance WHERE staff_id = st.id AND work_date = dt;
  ELSE
    INSERT INTO public.staff_attendance (organization_id, branch_id, staff_id, work_date, day_fraction, recorded_by)
    VALUES (st.organization_id, st.branch_id, st.id, dt, fr, auth.uid())
    ON CONFLICT (staff_id, work_date) DO UPDATE SET day_fraction = EXCLUDED.day_fraction, recorded_by = EXCLUDED.recorded_by;
  END IF;
END;
$$;

-- ------------------------------------------------------------
-- 5. Now: drafts refilled the new way; sheets for recent attendance
-- ------------------------------------------------------------
SELECT public.refill_pay_sheet(id) FROM public.pay_sheets WHERE status = 'draft';
SELECT public.ensure_pay_sheet(x.organization_id, x.branch_id, x.cycle, x.work_date)
FROM (SELECT DISTINCT ON (st.branch_id, public.cycle_of_staff(st), (public.pay_period(public.cycle_of_staff(st), a.work_date)).p_start)
             st.organization_id, st.branch_id, public.cycle_of_staff(st) AS cycle, a.work_date
      FROM public.staff_attendance a JOIN public.staff st ON st.id = a.staff_id
      WHERE a.work_date >= current_date - 62
      ORDER BY st.branch_id, public.cycle_of_staff(st), (public.pay_period(public.cycle_of_staff(st), a.work_date)).p_start, a.work_date) x;
