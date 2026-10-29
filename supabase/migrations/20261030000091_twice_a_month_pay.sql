-- ============================================================
-- 091 — Twice-a-month pay: an advance first, deductions on the second
-- ============================================================
-- SwahziTech, 2026-10-30, the user: employees are paid twice a month — the
-- first payment is an advance (50%), the second is where the deductions
-- happen. "Do not hardcode these — they are company settings."
--
-- payroll_settings (089) gains, per organization:
--   * first_half_mode / first_half_pct: the first payment (1st–15th) is a %
--     of the monthly salary ('advance', 50 by default) or of what was earned
--     in the 1st–15th by attendance ('earned'); no deductions on it;
--   * month_pay_basis: the month's gross on the second payment — days
--     attended × salary ÷ working days ('attendance', default) or the full
--     salary ('salary'). The same basis is used on a monthly sheet.
-- The second payment (16th–end): gross = the month's pay; NSSF and PAYE on
-- that gross (taxed as a month); then − other deductions − the first payment
-- already made − advances/loans taken back. Lines carry their part
-- ('advance' / 'balance') and the first payment deducted.
-- Day-rate staff are unchanged (days × day rate on any sheet).
-- ============================================================

ALTER TABLE public.payroll_settings
  ADD COLUMN first_half_mode text NOT NULL DEFAULT 'advance' CHECK (first_half_mode IN ('advance', 'earned')),
  ADD COLUMN first_half_pct  numeric NOT NULL DEFAULT 50 CHECK (first_half_pct >= 0 AND first_half_pct <= 100),
  ADD COLUMN month_pay_basis text NOT NULL DEFAULT 'attendance' CHECK (month_pay_basis IN ('attendance', 'salary'));

ALTER TABLE public.pay_sheet_lines
  ADD COLUMN part          text CHECK (part IN ('advance', 'balance')),   -- twice-a-month salaried pay (091)
  ADD COLUMN first_payment numeric NOT NULL DEFAULT 0;                    -- the month's first payment, taken off the second
COMMENT ON COLUMN public.pay_sheet_lines.amount IS 'Net pay: gross − NSSF − PAYE − other deductions − first payment − advances taken back (091).';

-- ------------------------------------------------------------
-- 1. A sheet's lines, with the month split for salaried staff paid twice a month
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

  INSERT INTO public.pay_sheet_lines (organization_id, sheet_id, staff_id, pay_basis, days, rate, base, amount, part, first_payment)
  SELECT ps.organization_id, ps.id, st.id, b.basis, d.days, st.pay_rate, x.base, x.base, pt.part, x.first
  FROM public.staff st
  CROSS JOIN LATERAL (SELECT coalesce(st.pay_basis, CASE st.kind WHEN 'employed' THEN 'monthly' ELSE 'daily' END) AS basis,
                             coalesce(st.pay_cycle, CASE st.kind WHEN 'employed' THEN 'fortnightly' ELSE 'weekly' END) AS cycle) b
  LEFT JOIN LATERAL (SELECT sum(a.day_fraction) AS days FROM public.staff_attendance a
                     WHERE a.staff_id = st.id AND a.work_date BETWEEN ps.period_start AND ps.period_end) d ON true
  LEFT JOIN LATERAL (SELECT sum(a.day_fraction) AS days FROM public.staff_attendance a
                     WHERE a.staff_id = st.id AND a.work_date BETWEEN mstart AND ps.period_end) md ON true
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
      CASE WHEN pt.part = 'balance' THEN coalesce(fp.paid, 0) ELSE 0 END AS first) x
  WHERE st.branch_id = ps.branch_id
    AND b.cycle = ps.cycle
    AND (st.started_on IS NULL OR st.started_on <= ps.period_end)
    AND (st.status = 'active' OR st.left_on >= ps.period_start OR d.days > 0)
    AND (coalesce(d.days, 0) > 0
         OR (pt.part = 'advance' AND cfg.first_half_mode = 'advance')
         OR (b.basis = 'monthly' AND (pt.part = 'balance' OR ps.cycle = 'monthly')
             AND (cfg.month_pay_basis = 'salary' OR coalesce(md.days, 0) > 0 OR coalesce(fp.paid, 0) > 0)));
  PERFORM public.compute_pay_sheet(p_sheet);
END;
$$;
REVOKE ALL ON FUNCTION public.fill_pay_sheet_lines(uuid) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- 2. Deductions: none on the advance; the second payment taxed as the month, less the first payment
-- ------------------------------------------------------------
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
  UPDATE public.pay_sheet_lines l SET statutory = coalesce(st.statutory, st.kind = 'employed', false) AND coalesce(l.part, '') <> 'advance', gross = l.base + l.additions
  FROM public.staff st WHERE st.id = l.staff_id AND l.sheet_id = s.id;

  -- SDL: the employer's staff over the period (all branches), casuals only when they count
  SELECT count(*) INTO heads FROM public.staff st
  WHERE st.organization_id = s.organization_id
    AND (st.started_on IS NULL OR st.started_on <= s.period_end)
    AND (st.status = 'active' OR st.left_on >= s.period_start)
    AND (coalesce(st.statutory, st.kind = 'employed', false) OR coalesce(r_sdl.count_casuals, false));
  sdl_on := r_sdl.id IS NOT NULL AND heads >= coalesce(r_sdl.min_employees, 0);

  UPDATE public.pay_sheet_lines l SET
    nssf_employee = CASE WHEN l.statutory THEN round(l.gross * coalesce(r_ne.rate, 0) / 100, 2) ELSE 0 END,
    nssf_employer = CASE WHEN l.statutory THEN round(l.gross * coalesce(r_nr.rate, 0) / 100, 2) ELSE 0 END,
    wcf           = CASE WHEN l.statutory THEN round(l.gross * coalesce(r_wcf.rate, 0) / 100, 2) ELSE 0 END,
    sdl           = CASE WHEN sdl_on AND (l.statutory OR r_sdl.count_casuals) THEN round(l.gross * r_sdl.rate / 100, 2) ELSE 0 END
  WHERE l.sheet_id = s.id;
  UPDATE public.pay_sheet_lines l SET
    -- the second payment's gross is the whole month: taxed as a month (091)
    paye = CASE WHEN l.statutory AND r_paye.id IS NOT NULL THEN round(public.paye_monthly((l.gross - l.nssf_employee) * CASE WHEN l.part = 'balance' THEN 1 ELSE per END, r_paye.bands)
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

-- a first-half sheet voided: the month's second half (a draft) no longer takes it off
CREATE OR REPLACE FUNCTION public.first_half_voided()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'void' AND OLD.status <> 'void' AND NEW.cycle = 'fortnightly' AND NEW.period_start = date_trunc('month', NEW.period_start)::date THEN
    PERFORM public.refill_pay_sheet(x.id) FROM public.pay_sheets x
    WHERE x.branch_id = NEW.branch_id AND x.cycle = 'fortnightly' AND x.status = 'draft' AND x.id <> NEW.id
      AND x.period_start > NEW.period_end AND date_trunc('month', x.period_start) = date_trunc('month', NEW.period_start);
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER trg_first_half_voided AFTER UPDATE OF status ON public.pay_sheets
  FOR EACH ROW EXECUTE FUNCTION public.first_half_voided();

-- ------------------------------------------------------------
-- 3. The company's pay settings (Technical admin / directors); drafts follow
-- p: { work_days_a_month?, first_half_mode?, first_half_pct?, month_pay_basis? }
-- ------------------------------------------------------------
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
  IF cur.work_days_a_month <= 0 OR cur.work_days_a_month > 31 THEN RAISE EXCEPTION 'Enter the working days a month (1–31)' USING ERRCODE = '23514'; END IF;
  IF cur.first_half_pct < 0 OR cur.first_half_pct > 100 THEN RAISE EXCEPTION 'The first payment is a percent (0–100)' USING ERRCODE = '23514'; END IF;
  UPDATE public.payroll_settings SET work_days_a_month = cur.work_days_a_month, first_half_mode = cur.first_half_mode,
         first_half_pct = cur.first_half_pct, month_pay_basis = cur.month_pay_basis
  WHERE organization_id = org;
  FOR sid IN SELECT id FROM public.pay_sheets WHERE organization_id = org AND status = 'draft' ORDER BY period_start LOOP
    PERFORM public.refill_pay_sheet(sid);
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.set_payroll_settings(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_payroll_settings(jsonb) TO authenticated;

-- now: drafts the new way, first halves before second halves
SELECT public.refill_pay_sheet(id) FROM (SELECT id FROM public.pay_sheets WHERE status = 'draft' ORDER BY period_start) x;
