-- ============================================================
-- 102 — Overtime, and a rest day that pays extra
-- ============================================================
-- SwahziTech, 2026-11-01, the user: the work week is Monday to Saturday. Sunday
-- is for emergencies only and pays double, for everyone. Other overtime is typed
-- by hand on the person, and counts automatically. These are company settings.
--   * payroll_settings.rest_day (0 = Sunday) and rest_day_rate (2 = double).
--   * staff_overtime — one line a day per person: a date, a note and an amount.
--     Secretary and Branch Manager (payroll.record) enter it.
--   * Ticking someone on the rest day suggests an overtime line at the rate
--     (it can be edited); that day no longer counts as a normal day's pay.
--   * Pay sheets: overtime is its own column, part of gross, so it is taxed.
--     Salaried staff paid twice a month get it on the month's last payment.
--   * Labour cost follows: a rest day costs its overtime, not a normal day.
-- Approved and paid sheets never change.
-- ============================================================

ALTER TABLE public.payroll_settings
  ADD COLUMN rest_day smallint NOT NULL DEFAULT 0 CHECK (rest_day BETWEEN 0 AND 6),
  ADD COLUMN rest_day_rate numeric NOT NULL DEFAULT 2 CHECK (rest_day_rate >= 1 AND rest_day_rate <= 10);
COMMENT ON COLUMN public.payroll_settings.rest_day IS 'Day of the week with no normal work, 0 = Sunday (102).';
COMMENT ON COLUMN public.payroll_settings.rest_day_rate IS 'Pay for working the rest day, in times a normal day (102).';

ALTER TABLE public.pay_sheet_lines ADD COLUMN overtime numeric NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.pay_sheet_lines.overtime IS 'Overtime in this payment, from staff_overtime; part of gross (102).';

CREATE OR REPLACE FUNCTION public.is_rest_day(p_org uuid, p_day date)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT extract(dow FROM p_day)::int = coalesce((SELECT rest_day FROM public.payroll_settings WHERE organization_id = p_org), 0)
$$;
REVOKE ALL ON FUNCTION public.is_rest_day(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_rest_day(uuid, date) TO authenticated, service_role;

CREATE TABLE public.staff_overtime (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id),
  branch_id       uuid NOT NULL REFERENCES public.branches(id),
  staff_id        uuid NOT NULL REFERENCES public.staff(id),
  work_date       date NOT NULL,
  kind            text NOT NULL DEFAULT 'other' CHECK (kind IN ('rest_day', 'other')),
  amount          numeric NOT NULL CHECK (amount >= 0),
  note            text,
  edited          boolean NOT NULL DEFAULT false,   -- a suggested rest day amount was changed by hand
  status          text NOT NULL DEFAULT 'recorded' CHECK (status IN ('recorded', 'void')),
  created_by      uuid REFERENCES public.profiles(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_staff_overtime_rest_day ON public.staff_overtime (staff_id, work_date) WHERE kind = 'rest_day' AND status = 'recorded';
CREATE INDEX idx_staff_overtime_staff ON public.staff_overtime (staff_id, work_date DESC);
COMMENT ON TABLE public.staff_overtime IS 'Overtime per person and day, entered by hand or suggested by a rest day tick; goes on the pay sheet (102).';
CREATE TRIGGER trg_staff_overtime_updated_at BEFORE UPDATE ON public.staff_overtime FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_staff_overtime_audit AFTER INSERT OR UPDATE OR DELETE ON public.staff_overtime FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('staff_overtime', 'organization_id');
CREATE TRIGGER trg_staff_overtime_no_delete BEFORE DELETE ON public.staff_overtime FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('overtime');
ALTER TABLE public.staff_overtime ENABLE ROW LEVEL SECURITY;
CREATE POLICY "staff_overtime: read with staff" ON public.staff_overtime FOR SELECT TO authenticated
  USING (organization_id = public.get_my_org_id() AND public.has_permission_at('staff.view', branch_id, NULL));
REVOKE ALL ON public.staff_overtime FROM PUBLIC, anon;
GRANT SELECT ON public.staff_overtime TO authenticated;

-- ------------------------------------------------------------
-- Overtime keeps the period's draft pay sheet up to date
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.overtime_pay_sheet()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  o  public.staff_overtime := coalesce(NEW, OLD);
  st public.staff;
  m  date;
  sid uuid;
BEGIN
  SELECT * INTO st FROM public.staff WHERE id = o.staff_id;
  PERFORM public.ensure_pay_sheet(st.organization_id, st.branch_id, public.cycle_of_staff(st), o.work_date);
  -- a salaried person's overtime lands on the month's last payment, whichever half the day is in
  IF public.cycle_of_staff(st) = 'fortnightly' THEN
    m := date_trunc('month', o.work_date)::date;
    FOR sid IN SELECT id FROM public.pay_sheets WHERE branch_id = st.branch_id AND cycle = 'fortnightly' AND status = 'draft' AND period_start > m AND period_start <= (m + interval '1 month')::date - 1 LOOP
      PERFORM public.refill_pay_sheet(sid);
    END LOOP;
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER trg_overtime_pay_sheet AFTER INSERT OR UPDATE ON public.staff_overtime
  FOR EACH ROW EXECUTE FUNCTION public.overtime_pay_sheet();

-- ------------------------------------------------------------
-- A rest day tick suggests its overtime; untick takes it away
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.attendance_rest_day()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  a    public.staff_attendance := coalesce(NEW, OLD);
  st   public.staff;
  rate numeric;
  pay  numeric;
BEGIN
  IF NOT public.is_rest_day(a.organization_id, a.work_date) THEN RETURN NULL; END IF;
  IF TG_OP = 'DELETE' THEN
    UPDATE public.staff_overtime SET status = 'void' WHERE staff_id = a.staff_id AND work_date = a.work_date AND kind = 'rest_day' AND status = 'recorded';
    RETURN NULL;
  END IF;
  SELECT * INTO st FROM public.staff WHERE id = a.staff_id;
  rate := coalesce((SELECT rest_day_rate FROM public.payroll_settings WHERE organization_id = a.organization_id), 2);
  pay := round(a.day_fraction * rate * coalesce(st.pay_rate, 0)
               / CASE coalesce(st.pay_basis, CASE st.kind WHEN 'employed' THEN 'monthly' ELSE 'daily' END) WHEN 'daily' THEN 1 ELSE public.work_days_a_month(a.organization_id) END, 2);
  INSERT INTO public.staff_overtime (organization_id, branch_id, staff_id, work_date, kind, amount, created_by)
  VALUES (a.organization_id, a.branch_id, a.staff_id, a.work_date, 'rest_day', pay, a.recorded_by)
  ON CONFLICT (staff_id, work_date) WHERE kind = 'rest_day' AND status = 'recorded'
  DO UPDATE SET amount = CASE WHEN public.staff_overtime.edited THEN public.staff_overtime.amount ELSE EXCLUDED.amount END;
  RETURN NULL;
END;
$$;
CREATE TRIGGER trg_attendance_rest_day AFTER INSERT OR UPDATE OR DELETE ON public.staff_attendance
  FOR EACH ROW EXECUTE FUNCTION public.attendance_rest_day();

-- ------------------------------------------------------------
-- Entering overtime by hand
-- p: { id?, staff_id, work_date, amount, note?, void? }
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_overtime(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  old public.staff_overtime;
  st  public.staff;
  dt  date := nullif(p->>'work_date', '')::date;
  amt numeric := nullif(p->>'amount', '')::numeric;
  new_id uuid;
BEGIN
  IF nullif(p->>'id', '') IS NOT NULL THEN
    SELECT * INTO old FROM public.staff_overtime WHERE id = (p->>'id')::uuid AND organization_id = public.get_my_org_id() AND status = 'recorded' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Overtime not found' USING ERRCODE = '23514'; END IF;
    p := p || jsonb_build_object('staff_id', old.staff_id);
    dt := coalesce(dt, old.work_date);
  END IF;
  SELECT * INTO st FROM public.staff WHERE id = (p->>'staff_id')::uuid AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Staff member not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('payroll.record', st.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t enter overtime at this branch' USING ERRCODE = '42501'; END IF;
  IF dt IS NULL THEN RAISE EXCEPTION 'Choose the day' USING ERRCODE = '23514'; END IF;
  IF dt > public.org_today(st.organization_id) THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;
  IF EXISTS (SELECT 1 FROM public.pay_sheets s
             WHERE s.branch_id = st.branch_id AND s.status IN ('approved', 'paid') AND dt BETWEEN s.period_start AND s.period_end
               AND (s.cycle = public.cycle_of_staff(st)
                    OR EXISTS (SELECT 1 FROM public.pay_sheet_lines l WHERE l.sheet_id = s.id AND l.staff_id = st.id))) THEN
    RAISE EXCEPTION 'That day''s pay sheet is approved — overtime can''t change' USING ERRCODE = '23514';
  END IF;
  IF coalesce((p->>'void')::boolean, false) THEN
    IF old.id IS NULL THEN RAISE EXCEPTION 'Overtime not found' USING ERRCODE = '23514'; END IF;
    IF old.kind = 'rest_day' THEN RAISE EXCEPTION 'Untick the day on attendance to remove this' USING ERRCODE = '23514'; END IF;
    UPDATE public.staff_overtime SET status = 'void' WHERE id = old.id;
    RETURN old.id;
  END IF;
  IF amt IS NULL OR amt < 0 THEN RAISE EXCEPTION 'Enter the amount' USING ERRCODE = '23514'; END IF;
  IF old.id IS NOT NULL THEN
    IF old.kind = 'rest_day' AND dt <> old.work_date THEN RAISE EXCEPTION 'A rest day''s date comes from attendance' USING ERRCODE = '23514'; END IF;
    UPDATE public.staff_overtime SET amount = round(amt, 2), work_date = dt, note = nullif(btrim(p->>'note'), ''), edited = true WHERE id = old.id;
    RETURN old.id;
  END IF;
  IF public.is_rest_day(st.organization_id, dt) THEN RAISE EXCEPTION 'Tick the person on attendance for this day; the overtime appears here to adjust' USING ERRCODE = '23514'; END IF;
  INSERT INTO public.staff_overtime (organization_id, branch_id, staff_id, work_date, amount, note, created_by)
  VALUES (st.organization_id, st.branch_id, st.id, dt, round(amt, 2), nullif(btrim(p->>'note'), ''), auth.uid())
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;
REVOKE ALL ON FUNCTION public.save_overtime(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_overtime(jsonb) TO authenticated;

-- ------------------------------------------------------------
-- Pay sheets: rest days aren't normal days; overtime goes on the line
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fill_pay_sheet_lines(p_sheet uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ps     public.pay_sheets;
  cfg    public.payroll_settings;
  wd     numeric;
  mstart date;
  half   text;
BEGIN
  SELECT * INTO ps FROM public.pay_sheets WHERE id = p_sheet;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO cfg FROM public.payroll_settings WHERE organization_id = ps.organization_id;
  cfg.first_half_mode := coalesce(cfg.first_half_mode, 'advance');
  cfg.first_half_pct  := coalesce(cfg.first_half_pct, 50);
  cfg.month_pay_basis := coalesce(cfg.month_pay_basis, 'attendance');
  wd := public.work_days_a_month(ps.organization_id);
  mstart := date_trunc('month', ps.period_start)::date;
  half := CASE WHEN ps.cycle <> 'fortnightly' THEN NULL
               WHEN ps.period_start = mstart AND ps.period_end < (mstart + interval '1 month')::date - 1 THEN 'first'
               WHEN ps.period_start > mstart AND date_trunc('month', ps.period_end)::date = mstart THEN 'second' END;

  INSERT INTO public.pay_sheet_lines (organization_id, sheet_id, staff_id, pay_basis, days, rate, base, amount, part, first_payment, overtime)
  SELECT ps.organization_id, ps.id, st.id, b.basis, d.days, st.pay_rate, x.base, x.base, pt.part, x.first, x.ot
  FROM public.staff st
  CROSS JOIN LATERAL (SELECT coalesce(st.pay_basis, CASE st.kind WHEN 'employed' THEN 'monthly' ELSE 'daily' END) AS basis,
                             coalesce(st.pay_cycle, CASE st.kind WHEN 'employed' THEN 'fortnightly' ELSE 'weekly' END) AS cycle) b
  LEFT JOIN LATERAL (SELECT sum(a.day_fraction) AS days FROM public.staff_attendance a
                     WHERE a.staff_id = st.id AND a.work_date BETWEEN ps.period_start AND ps.period_end AND NOT public.is_rest_day(ps.organization_id, a.work_date)) d ON true
  LEFT JOIN LATERAL (SELECT sum(a.day_fraction) AS days FROM public.staff_attendance a
                     WHERE a.staff_id = st.id AND a.work_date BETWEEN mstart AND ps.period_end AND NOT public.is_rest_day(ps.organization_id, a.work_date)) md ON true
  -- overtime: on the month's last payment for salaried staff paid twice a month (none on the advance), else in the period
  LEFT JOIN LATERAL (SELECT sum(o.amount) AS amount FROM public.staff_overtime o
                     WHERE o.staff_id = st.id AND o.status = 'recorded'
                       AND o.work_date BETWEEN CASE WHEN half = 'second' THEN mstart ELSE ps.period_start END AND ps.period_end) ot ON true
  LEFT JOIN LATERAL (SELECT sum(l.amount) AS paid FROM public.pay_sheet_lines l JOIN public.pay_sheets f ON f.id = l.sheet_id
                     WHERE l.staff_id = st.id AND l.part = 'advance' AND f.id <> ps.id AND f.branch_id = ps.branch_id AND f.cycle = 'fortnightly'
                       AND f.status <> 'void' AND f.period_start = mstart) fp ON true
  CROSS JOIN LATERAL (SELECT CASE WHEN b.basis = 'monthly' AND half = 'first' THEN 'advance'
                                  WHEN b.basis = 'monthly' AND half = 'second' THEN 'balance' END AS part) pt
  CROSS JOIN LATERAL (SELECT
      round(coalesce(CASE
        WHEN b.basis = 'daily' THEN coalesce(d.days, 0) * st.pay_rate
        WHEN pt.part = 'advance' THEN cfg.first_half_pct / 100
             * CASE cfg.first_half_mode WHEN 'advance' THEN st.pay_rate ELSE coalesce(d.days, 0) * st.pay_rate / wd END
        WHEN pt.part = 'balance' OR ps.cycle = 'monthly' THEN
             CASE cfg.month_pay_basis WHEN 'salary' THEN st.pay_rate
                  ELSE coalesce(CASE WHEN pt.part = 'balance' THEN md.days ELSE d.days END, 0) * st.pay_rate / wd END
        ELSE coalesce(d.days, 0) * st.pay_rate / wd END, 0), 2) AS base,
      CASE WHEN pt.part = 'balance' THEN coalesce(fp.paid, 0) ELSE 0 END AS first,
      CASE WHEN pt.part = 'advance' THEN 0 ELSE coalesce(ot.amount, 0) END AS ot) x
  WHERE st.branch_id = ps.branch_id
    AND b.cycle = ps.cycle
    AND (st.started_on IS NULL OR st.started_on <= ps.period_end)
    AND (st.status = 'active' OR st.left_on >= ps.period_start OR d.days > 0)
    AND (coalesce(d.days, 0) > 0
         OR (coalesce(ot.amount, 0) > 0 AND coalesce(pt.part, '') <> 'advance')
         OR (pt.part = 'advance' AND cfg.first_half_mode = 'advance')
         OR (b.basis = 'monthly' AND (pt.part = 'balance' OR ps.cycle = 'monthly')
             AND (cfg.month_pay_basis = 'salary' OR coalesce(md.days, 0) > 0 OR coalesce(fp.paid, 0) > 0)));
  PERFORM public.compute_pay_sheet(p_sheet);
END;
$$;
REVOKE ALL ON FUNCTION public.fill_pay_sheet_lines(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.compute_pay_sheet(p_sheet uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s       public.pay_sheets;
  per     numeric;
  r_paye  public.statutory_rates;
  r_ne    public.statutory_rates;
  r_nr    public.statutory_rates;
  r_wcf   public.statutory_rates;
  r_sdl   public.statutory_rates;
  heads   integer;
  sdl_on  boolean;
  unver   text[] := '{}';
  ln      public.pay_sheet_lines;
  adv     record;
  avail   numeric;
  took    numeric;
  t       numeric;
BEGIN
  SELECT * INTO s FROM public.pay_sheets WHERE id = p_sheet;
  IF NOT FOUND OR s.status <> 'draft' THEN RETURN; END IF;
  per := CASE s.cycle WHEN 'monthly' THEN 1 WHEN 'fortnightly' THEN 2 ELSE 4 END;   -- periods a month
  SELECT * INTO r_paye FROM public.statutory_rates WHERE organization_id = s.organization_id AND code = 'paye' AND status = 'active' AND effective_from <= s.period_end ORDER BY effective_from DESC LIMIT 1;
  SELECT * INTO r_ne FROM public.statutory_rates WHERE organization_id = s.organization_id AND code = 'nssf_employee' AND status = 'active' AND effective_from <= s.period_end ORDER BY effective_from DESC LIMIT 1;
  SELECT * INTO r_nr FROM public.statutory_rates WHERE organization_id = s.organization_id AND code = 'nssf_employer' AND status = 'active' AND effective_from <= s.period_end ORDER BY effective_from DESC LIMIT 1;
  SELECT * INTO r_wcf FROM public.statutory_rates WHERE organization_id = s.organization_id AND code = 'wcf' AND status = 'active' AND effective_from <= s.period_end ORDER BY effective_from DESC LIMIT 1;
  SELECT * INTO r_sdl FROM public.statutory_rates WHERE organization_id = s.organization_id AND code = 'sdl' AND status = 'active' AND effective_from <= s.period_end ORDER BY effective_from DESC LIMIT 1;

  -- the first payment of the month (an advance) carries no deductions (091)
  UPDATE public.pay_sheet_lines l SET statutory = coalesce(st.statutory, st.kind = 'employed', false) AND coalesce(l.part, '') <> 'advance', gross = l.base + l.additions + l.overtime
  FROM public.staff st WHERE st.id = l.staff_id AND l.sheet_id = s.id;

  -- SDL: the employer's staff over the period (all branches), casuals only when they count
  SELECT count(*) INTO heads FROM public.staff st
  WHERE st.organization_id = s.organization_id
    AND (st.started_on IS NULL OR st.started_on <= s.period_end)
    AND (st.status = 'active' OR st.left_on >= s.period_start)
    AND (coalesce(st.statutory, st.kind = 'employed', false) OR coalesce(r_sdl.count_casuals, false));
  sdl_on := r_sdl.id IS NOT NULL AND heads >= coalesce(r_sdl.min_employees, 0);

  UPDATE public.pay_sheet_lines l SET
    -- NSSF: on the monthly salary, whatever was earned (099); taken on the month's last payment
    nssf_employee = CASE WHEN l.statutory THEN round((CASE WHEN l.pay_basis = 'monthly' AND l.rate IS NOT NULL AND (l.part = 'balance' OR s.cycle = 'monthly') THEN l.rate ELSE l.gross END) * coalesce(r_ne.rate, 0) / 100, 2) ELSE 0 END,
    nssf_employer = CASE WHEN l.statutory THEN round((CASE WHEN l.pay_basis = 'monthly' AND l.rate IS NOT NULL AND (l.part = 'balance' OR s.cycle = 'monthly') THEN l.rate ELSE l.gross END) * coalesce(r_nr.rate, 0) / 100, 2) ELSE 0 END,
    wcf           = CASE WHEN l.statutory THEN round(l.gross * coalesce(r_wcf.rate, 0) / 100, 2) ELSE 0 END,
    sdl           = CASE WHEN sdl_on AND (l.statutory OR r_sdl.count_casuals) THEN round(l.gross * r_sdl.rate / 100, 2) ELSE 0 END
  WHERE l.sheet_id = s.id;
  UPDATE public.pay_sheet_lines l SET
    -- the second payment's gross is the whole month: taxed as a month (091)
    paye = CASE WHEN l.statutory AND r_paye.id IS NOT NULL THEN round(public.paye_monthly(greatest(l.gross - l.nssf_employee, 0) * CASE WHEN l.part = 'balance' THEN 1 ELSE per END, r_paye.bands)
                                                                     / CASE WHEN l.part = 'balance' THEN 1 ELSE per END, 2) ELSE 0 END
  WHERE l.sheet_id = s.id;
  -- advances and loans (090): the oldest first, an instalment a sheet (or all that's left), never more than the pay left
  DELETE FROM public.pay_sheet_advance_recoveries WHERE sheet_id = s.id;
  FOR ln IN SELECT * FROM public.pay_sheet_lines WHERE sheet_id = s.id LOOP
    avail := greatest(ln.gross - ln.nssf_employee - ln.paye - ln.deductions - ln.first_payment, 0);
    took := 0;
    FOR adv IN SELECT a.id, a.installment,
                      a.amount - coalesce((SELECT sum(r.amount) FROM public.pay_sheet_advance_recoveries r JOIN public.pay_sheets ps ON ps.id = r.sheet_id
                                           WHERE r.advance_id = a.id AND ps.status <> 'void'), 0) AS left_amt
               FROM public.staff_advances a
               WHERE a.staff_id = ln.staff_id AND a.status = 'active' AND a.given_on <= s.period_end
               ORDER BY a.given_on, a.created_at LOOP
      EXIT WHEN avail - took <= 0;
      t := round(least(coalesce(adv.installment, adv.left_amt), adv.left_amt, avail - took), 2);
      IF t > 0 THEN
        INSERT INTO public.pay_sheet_advance_recoveries (organization_id, sheet_id, line_id, advance_id, amount)
        VALUES (s.organization_id, s.id, ln.id, adv.id, t);
        took := took + t;
      END IF;
    END LOOP;
    UPDATE public.pay_sheet_lines SET advance_deductions = took WHERE id = ln.id;
  END LOOP;
  UPDATE public.pay_sheet_lines l SET amount = greatest(l.gross - l.nssf_employee - l.paye - l.deductions - l.first_payment - l.advance_deductions, 0) WHERE l.sheet_id = s.id;

  -- the rates that touched this sheet and aren't confirmed
  IF EXISTS (SELECT 1 FROM public.pay_sheet_lines WHERE sheet_id = s.id AND statutory) THEN
    unver := array_remove(ARRAY[
      CASE WHEN r_paye.id IS NOT NULL AND r_paye.verified_at IS NULL THEN 'paye' END,
      CASE WHEN r_ne.id IS NOT NULL AND r_ne.verified_at IS NULL THEN 'nssf_employee' END,
      CASE WHEN r_nr.id IS NOT NULL AND r_nr.verified_at IS NULL THEN 'nssf_employer' END,
      CASE WHEN r_wcf.id IS NOT NULL AND r_wcf.verified_at IS NULL THEN 'wcf' END], NULL);
  END IF;
  IF EXISTS (SELECT 1 FROM public.pay_sheet_lines WHERE sheet_id = s.id AND sdl > 0) AND r_sdl.verified_at IS NULL THEN unver := unver || 'sdl'; END IF;

  UPDATE public.pay_sheets SET
    total = coalesce((SELECT sum(amount) FROM public.pay_sheet_lines WHERE sheet_id = s.id), 0),
    gross_total = coalesce((SELECT sum(gross) FROM public.pay_sheet_lines WHERE sheet_id = s.id), 0),
    employee_statutory = coalesce((SELECT sum(nssf_employee + paye) FROM public.pay_sheet_lines WHERE sheet_id = s.id), 0),
    employer_statutory = coalesce((SELECT sum(nssf_employer + wcf + sdl) FROM public.pay_sheet_lines WHERE sheet_id = s.id), 0),
    rates_unverified = unver
  WHERE id = s.id;
  -- a first half changed: the month's second half (a draft) takes the new first payment
  IF s.cycle = 'fortnightly' AND s.period_start = date_trunc('month', s.period_start)::date THEN
    PERFORM public.refill_pay_sheet(x.id) FROM public.pay_sheets x
    WHERE x.branch_id = s.branch_id AND x.cycle = 'fortnightly' AND x.status = 'draft' AND x.id <> s.id
      AND x.period_start > s.period_end AND date_trunc('month', x.period_start) = date_trunc('month', s.period_start);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.compute_pay_sheet(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.set_payroll_settings(p jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  cur public.payroll_settings;
  sid uuid;
BEGIN
  IF NOT public.has_permission('payroll.rates') THEN RAISE EXCEPTION 'Only the Technical admin or a director changes pay settings' USING ERRCODE = '42501'; END IF;
  INSERT INTO public.payroll_settings (organization_id) VALUES (org) ON CONFLICT (organization_id) DO NOTHING;
  SELECT * INTO cur FROM public.payroll_settings WHERE organization_id = org FOR UPDATE;
  cur.work_days_a_month := coalesce(nullif(p->>'work_days_a_month', '')::numeric, cur.work_days_a_month);
  cur.first_half_mode   := coalesce(nullif(p->>'first_half_mode', ''), cur.first_half_mode);
  cur.first_half_pct    := coalesce(nullif(p->>'first_half_pct', '')::numeric, cur.first_half_pct);
  cur.month_pay_basis   := coalesce(nullif(p->>'month_pay_basis', ''), cur.month_pay_basis);
  cur.rest_day_rate     := coalesce(nullif(p->>'rest_day_rate', '')::numeric, cur.rest_day_rate);
  IF cur.work_days_a_month <= 0 OR cur.work_days_a_month > 31 THEN RAISE EXCEPTION 'Enter the working days a month (1–31)' USING ERRCODE = '23514'; END IF;
  IF cur.rest_day_rate < 1 OR cur.rest_day_rate > 10 THEN RAISE EXCEPTION 'The rest day rate is times a normal day (1–10)' USING ERRCODE = '23514'; END IF;
  IF cur.first_half_pct < 0 OR cur.first_half_pct > 100 THEN RAISE EXCEPTION 'The first payment is a percent (0–100)' USING ERRCODE = '23514'; END IF;
  UPDATE public.payroll_settings SET work_days_a_month = cur.work_days_a_month, first_half_mode = cur.first_half_mode,
         first_half_pct = cur.first_half_pct, month_pay_basis = cur.month_pay_basis, rest_day_rate = cur.rest_day_rate
  WHERE organization_id = org;
  FOR sid IN SELECT id FROM public.pay_sheets WHERE organization_id = org AND status = 'draft' ORDER BY period_start LOOP
    PERFORM public.refill_pay_sheet(sid);
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.set_payroll_settings(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_payroll_settings(jsonb) TO authenticated;

-- ------------------------------------------------------------
-- Labour cost: a rest day costs its overtime; other overtime adds to the day
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.labour_pay_days WITH (security_invoker = true) AS
SELECT a.organization_id, a.branch_id, a.work_date, a.staff_id, a.day_fraction, x.basis,
       CASE WHEN public.is_rest_day(a.organization_id, a.work_date) THEN 0
            ELSE a.day_fraction * s.pay_rate / CASE x.basis WHEN 'daily' THEN 1 ELSE public.work_days_a_month(a.organization_id) END END
         + coalesce((SELECT sum(o.amount) FROM public.staff_overtime o WHERE o.staff_id = a.staff_id AND o.work_date = a.work_date AND o.status = 'recorded'), 0) AS pay,
       s.pay_rate IS NULL AS without_rate,
       coalesce(s.statutory, s.kind = 'employed', false) AS statutory
FROM public.staff_attendance a
JOIN public.staff s ON s.id = a.staff_id
CROSS JOIN LATERAL (SELECT coalesce(s.pay_basis, CASE s.kind WHEN 'employed' THEN 'monthly' ELSE 'daily' END) AS basis) x
WHERE s.in_production_cost;

-- now: rest days already ticked get their overtime; drafts recalculated, oldest first
INSERT INTO public.staff_overtime (organization_id, branch_id, staff_id, work_date, kind, amount, created_by)
SELECT a.organization_id, a.branch_id, a.staff_id, a.work_date, 'rest_day',
       round(a.day_fraction * 2 * coalesce(s.pay_rate, 0) / CASE coalesce(s.pay_basis, CASE s.kind WHEN 'employed' THEN 'monthly' ELSE 'daily' END) WHEN 'daily' THEN 1 ELSE public.work_days_a_month(a.organization_id) END, 2),
       a.recorded_by
FROM public.staff_attendance a JOIN public.staff s ON s.id = a.staff_id
WHERE public.is_rest_day(a.organization_id, a.work_date)
  AND NOT EXISTS (SELECT 1 FROM public.pay_sheets ps JOIN public.pay_sheet_lines l ON l.sheet_id = ps.id
                  WHERE l.staff_id = a.staff_id AND ps.status IN ('approved', 'paid') AND a.work_date BETWEEN ps.period_start AND ps.period_end);
SELECT public.refill_pay_sheet(id) FROM (SELECT id FROM public.pay_sheets WHERE status = 'draft' ORDER BY period_start) x;
