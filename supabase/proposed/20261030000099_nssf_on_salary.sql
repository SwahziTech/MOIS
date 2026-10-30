-- ============================================================
-- 099 — NSSF on the monthly salary
-- ============================================================
-- SwahziTech, 2026-10-30, the user: NSSF is a fixed share (10%, from the
-- statutory rates) of the monthly salary for all employees, deducted on the
-- end-of-month payment — not a share of what was earned by attendance.
--   * compute_pay_sheet: employee and employer NSSF on the salary for a
--     salaried month-end line; day-rate staff unchanged. WCF and SDL stay on
--     gross. PAYE on gross less NSSF, never below nothing. Net never below 0.
--   * update_pay_sheet_line: NSSF alone may exceed a short month's pay; only
--     the other deductions typed are refused when there is no pay left for them.
-- Drafts recalculate now; approved and paid sheets never change.
-- ============================================================

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

CREATE OR REPLACE FUNCTION public.update_pay_sheet_line(p_line uuid, p jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  l   public.pay_sheet_lines;
  s   public.pay_sheets;
  ad  numeric;
  de  numeric;
BEGIN
  SELECT * INTO l FROM public.pay_sheet_lines WHERE id = p_line AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Line not found' USING ERRCODE = '23514'; END IF;
  SELECT * INTO s FROM public.pay_sheets WHERE id = l.sheet_id FOR UPDATE;
  IF NOT public.has_permission_at('payroll.record', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change pay sheets at this branch' USING ERRCODE = '42501'; END IF;
  IF s.status <> 'draft' THEN RAISE EXCEPTION 'Only a draft pay sheet can change' USING ERRCODE = '23514'; END IF;
  ad := round(coalesce(nullif(p->>'additions', '')::numeric, l.additions), 2);
  de := round(coalesce(nullif(p->>'deductions', '')::numeric, l.deductions), 2);
  IF ad < 0 OR de < 0 THEN RAISE EXCEPTION 'Amounts can''t be negative' USING ERRCODE = '23514'; END IF;
  UPDATE public.pay_sheet_lines SET additions = ad, deductions = de,
         note = CASE WHEN p ? 'note' THEN nullif(btrim(p->>'note'), '') ELSE note END
  WHERE id = l.id;
  PERFORM public.compute_pay_sheet(s.id);
  SELECT * INTO l FROM public.pay_sheet_lines WHERE id = l.id;
  IF l.deductions > 0 AND l.gross - l.nssf_employee - l.paye - l.deductions < 0 THEN RAISE EXCEPTION 'Deductions can''t be more than the pay' USING ERRCODE = '23514'; END IF;
END;
$$;

-- now: drafts the new way, first halves before second halves
SELECT public.compute_pay_sheet(id) FROM (SELECT id FROM public.pay_sheets WHERE status = 'draft' ORDER BY period_start) x;
