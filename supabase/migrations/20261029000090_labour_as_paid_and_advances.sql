-- ============================================================
-- 090 — Labour cost as paid; advances and loans (Staff (HR) Part 2)
-- ============================================================
-- SwahziTech, 2026-10-29, the user chose before closing HR: labour cost =
-- pay sheets, statutory returns (read from paid sheets on the screen, no
-- change here) and advances & loans.
--
--   * Labour into product cost now follows attendance as the pay sheets do
--     (089): everyone in product cost, days × day rate, or days × salary ÷
--     working days a month; plus the employer's NSSF, WCF and SDL on that pay
--     (the rates in force that day, confirmed or not — a cost estimate).
--     A day's labour is shared over that day's batches by cement bags.
--     labour_days / labour_months are rebuilt; batch_labour_cost reads days only.
--   * staff_advances: an advance or loan given to a staff member (paid out as
--     a Wages expense that day). Each draft pay sheet takes it back — the
--     instalment, or all that's left — never more than the pay left after
--     NSSF, PAYE and other deductions. Recoveries on approved/paid sheets stay.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The employer's share on top of pay (NSSF, WCF, SDL), as a percent
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.employer_on_pay_pct(p_org uuid, p_day date, p_statutory boolean)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r_nr  public.statutory_rates;
  r_wcf public.statutory_rates;
  r_sdl public.statutory_rates;
  pct   numeric := 0;
  heads integer;
BEGIN
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
$$;

-- ------------------------------------------------------------
-- 2. Labour as paid: by day and by month (production staff only)
-- ------------------------------------------------------------
DROP VIEW IF EXISTS public.labour_months;
DROP VIEW IF EXISTS public.labour_days;

CREATE VIEW public.labour_pay_days WITH (security_invoker = true) AS
SELECT a.organization_id, a.branch_id, a.work_date, a.staff_id, a.day_fraction, x.basis,
       a.day_fraction * s.pay_rate / CASE x.basis WHEN 'daily' THEN 1 ELSE public.work_days_a_month(a.organization_id) END AS pay,
       s.pay_rate IS NULL AS without_rate,
       coalesce(s.statutory, s.kind = 'employed', false) AS statutory
FROM public.staff_attendance a
JOIN public.staff s ON s.id = a.staff_id
CROSS JOIN LATERAL (SELECT coalesce(s.pay_basis, CASE s.kind WHEN 'employed' THEN 'monthly' ELSE 'daily' END) AS basis) x
WHERE s.in_production_cost;
COMMENT ON VIEW public.labour_pay_days IS 'Each production staff member''s pay for a day attended, as the pay sheets work it (090).';
GRANT SELECT ON public.labour_pay_days TO authenticated;

CREATE VIEW public.labour_days WITH (security_invoker = true) AS
SELECT p.organization_id, p.branch_id, p.work_date AS day,
       count(DISTINCT p.staff_id) AS people, sum(p.day_fraction) AS days,
       round(coalesce(sum(p.pay), 0), 2) AS wages,
       round(coalesce(sum(p.pay * public.employer_on_pay_pct(p.organization_id, p.work_date, p.statutory) / 100), 0), 2) AS employer,
       round(coalesce(sum(p.pay) FILTER (WHERE p.basis = 'daily'), 0), 2) AS casual_wages,
       round(coalesce(sum(p.pay) FILTER (WHERE p.basis = 'monthly'), 0), 2) AS employed_wages,
       count(*) FILTER (WHERE p.without_rate) AS without_rate
FROM public.labour_pay_days p
GROUP BY 1, 2, 3;
GRANT SELECT ON public.labour_days TO authenticated;

CREATE VIEW public.labour_months WITH (security_invoker = true) AS
SELECT p.organization_id, p.branch_id, date_trunc('month', p.work_date)::date AS month,
       count(DISTINCT p.staff_id) AS people, sum(p.day_fraction) AS days,
       round(coalesce(sum(p.pay), 0), 2) AS wages,
       round(coalesce(sum(p.pay * public.employer_on_pay_pct(p.organization_id, p.work_date, p.statutory) / 100), 0), 2) AS employer,
       round(coalesce(sum(p.pay) FILTER (WHERE p.basis = 'daily'), 0), 2) AS casual_wages,
       round(coalesce(sum(p.pay) FILTER (WHERE p.basis = 'monthly'), 0), 2) AS employed_wages,
       count(DISTINCT p.staff_id) FILTER (WHERE p.without_rate) AS without_rate
FROM public.labour_pay_days p
GROUP BY 1, 2, 3;
GRANT SELECT ON public.labour_months TO authenticated;

-- A batch's share of its day's labour (pay + employer's share), by cement bags
CREATE OR REPLACE FUNCTION public.batch_labour_cost(p_batch uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT round(coalesce(
           (SELECT (d.wages + d.employer) * b.cement_bags / nullif((SELECT sum(x.cement_bags) FROM public.production_batches x
                                                      WHERE x.branch_id = b.branch_id AND x.batch_date = b.batch_date AND x.status <> 'void'), 0)
              FROM public.labour_days d WHERE d.branch_id = b.branch_id AND d.day = b.batch_date), 0), 2)
  FROM public.production_batches b WHERE b.id = p_batch AND b.status <> 'void'
$$;
REVOKE ALL ON FUNCTION public.batch_labour_cost(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.batch_labour_cost(uuid) TO authenticated;

-- ------------------------------------------------------------
-- 3. Advances and loans
-- ------------------------------------------------------------
CREATE TABLE public.staff_advances (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  staff_id        uuid NOT NULL REFERENCES public.staff(id) ON DELETE RESTRICT,
  given_on        date NOT NULL,
  amount          numeric NOT NULL CHECK (amount > 0),
  installment     numeric CHECK (installment > 0),    -- taken back a pay sheet; NULL = all at once
  reason          text,
  account_id      uuid REFERENCES public.payment_accounts(id) ON DELETE RESTRICT,
  expense_id      uuid REFERENCES public.expenses(id) ON DELETE RESTRICT,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'void')),
  void_reason     text,
  recorded_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CHECK ((status = 'void') = (void_reason IS NOT NULL))
);
CREATE INDEX idx_staff_advances_staff ON public.staff_advances (staff_id, given_on);
CREATE TRIGGER trg_staff_advances_updated_at BEFORE UPDATE ON public.staff_advances FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_staff_advances_audit AFTER INSERT OR UPDATE OR DELETE ON public.staff_advances FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('staff_advance', 'id');
CREATE TRIGGER trg_staff_advances_no_delete BEFORE DELETE ON public.staff_advances FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('advance');
ALTER TABLE public.staff_advances ENABLE ROW LEVEL SECURITY;
CREATE POLICY "staff_advances: pay viewers read" ON public.staff_advances FOR SELECT
  USING (organization_id = public.get_my_org_id() AND public.has_permission_at('staff.view', branch_id, NULL));
COMMENT ON TABLE public.staff_advances IS 'Advances and loans to staff, taken back on pay sheets (090).';

CREATE TABLE public.pay_sheet_advance_recoveries (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  sheet_id        uuid NOT NULL REFERENCES public.pay_sheets(id) ON DELETE CASCADE,
  line_id         uuid NOT NULL REFERENCES public.pay_sheet_lines(id) ON DELETE CASCADE,
  advance_id      uuid NOT NULL REFERENCES public.staff_advances(id) ON DELETE RESTRICT,
  amount          numeric NOT NULL CHECK (amount > 0)
);
CREATE INDEX idx_advance_recoveries_advance ON public.pay_sheet_advance_recoveries (advance_id);
CREATE INDEX idx_advance_recoveries_sheet ON public.pay_sheet_advance_recoveries (sheet_id);
ALTER TABLE public.pay_sheet_advance_recoveries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pay_sheet_advance_recoveries: pay viewers read" ON public.pay_sheet_advance_recoveries FOR SELECT
  USING (organization_id = public.get_my_org_id()
         AND EXISTS (SELECT 1 FROM public.pay_sheets s WHERE s.id = sheet_id AND public.has_permission_at('staff.view', s.branch_id, NULL)));

ALTER TABLE public.pay_sheet_lines ADD COLUMN advance_deductions numeric NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.pay_sheet_lines.amount IS 'Net pay: gross − NSSF − PAYE − other deductions − advances taken back (090).';

-- what's left of each advance (taken back on sheets that aren't void)
CREATE OR REPLACE VIEW public.staff_advance_balances WITH (security_invoker = true) AS
SELECT a.id, a.organization_id, a.branch_id, a.staff_id, a.given_on, a.amount, a.installment, a.reason, a.status,
       coalesce(sum(r.amount) FILTER (WHERE ps.status IN ('approved', 'paid')), 0) AS recovered,
       coalesce(sum(r.amount) FILTER (WHERE ps.status = 'draft'), 0) AS on_drafts,
       a.amount - coalesce(sum(r.amount) FILTER (WHERE ps.status IN ('approved', 'paid')), 0) AS outstanding
FROM public.staff_advances a
LEFT JOIN public.pay_sheet_advance_recoveries r ON r.advance_id = a.id
LEFT JOIN public.pay_sheets ps ON ps.id = r.sheet_id
GROUP BY a.id;
GRANT SELECT ON public.staff_advance_balances TO authenticated;

-- ------------------------------------------------------------
-- 4. A draft's deductions now take back advances
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

  UPDATE public.pay_sheet_lines l SET statutory = coalesce(st.statutory, st.kind = 'employed', false), gross = l.base + l.additions
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
    paye = CASE WHEN l.statutory AND r_paye.id IS NOT NULL THEN round(public.paye_monthly((l.gross - l.nssf_employee) * per, r_paye.bands) / per, 2) ELSE 0 END
  WHERE l.sheet_id = s.id;
  -- advances and loans (090): the oldest first, an instalment a sheet (or all that's left), never more than the pay left
  DELETE FROM public.pay_sheet_advance_recoveries WHERE sheet_id = s.id;
  FOR ln IN SELECT * FROM public.pay_sheet_lines WHERE sheet_id = s.id LOOP
    avail := greatest(ln.gross - ln.nssf_employee - ln.paye - ln.deductions, 0);
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
  UPDATE public.pay_sheet_lines l SET amount = greatest(l.gross - l.nssf_employee - l.paye - l.deductions - l.advance_deductions, 0) WHERE l.sheet_id = s.id;

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
END;
$$;
REVOKE ALL ON FUNCTION public.compute_pay_sheet(uuid) FROM PUBLIC, anon, authenticated;

-- p: { staff_id, given_on?, amount, installment?, reason?, account_id? } — paid out as a Wages expense that day
CREATE OR REPLACE FUNCTION public.record_staff_advance(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  st  public.staff;
  acc public.payment_accounts;
  dt  date := nullif(p->>'given_on', '')::date;
  amt numeric := round(nullif(p->>'amount', '')::numeric, 2);
  ins numeric := round(nullif(p->>'installment', '')::numeric, 2);
  cat uuid;
  eid uuid;
  aid uuid;
BEGIN
  SELECT * INTO st FROM public.staff WHERE id = (p->>'staff_id')::uuid AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Staff member not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('payroll.record', st.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t record advances at this branch' USING ERRCODE = '42501'; END IF;
  dt := coalesce(dt, public.org_today(st.organization_id));
  IF dt > public.org_today(st.organization_id) THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;
  IF amt IS NULL OR amt <= 0 THEN RAISE EXCEPTION 'Enter the amount given' USING ERRCODE = '23514'; END IF;
  IF ins IS NOT NULL AND (ins <= 0 OR ins > amt) THEN RAISE EXCEPTION 'The instalment is between 0 and the amount' USING ERRCODE = '23514'; END IF;
  IF nullif(p->>'account_id', '') IS NOT NULL THEN
    SELECT * INTO acc FROM public.payment_accounts WHERE id = (p->>'account_id')::uuid AND branch_id = st.branch_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Choose the account it was paid from' USING ERRCODE = '23514'; END IF;
  END IF;
  SELECT id INTO cat FROM public.expense_categories WHERE organization_id = st.organization_id AND public.normalize_name(name) = public.normalize_name('Wages');
  IF cat IS NULL THEN
    INSERT INTO public.expense_categories (organization_id, name) VALUES (st.organization_id, 'Wages') RETURNING id INTO cat;
  END IF;
  INSERT INTO public.expenses (organization_id, branch_id, expense_date, category_id, description, amount, amount_paid, payment_method, paid_on, notes, created_by)
  VALUES (st.organization_id, st.branch_id, dt, cat, 'Advance to ' || st.full_name, amt, amt, coalesce(acc.kind, 'cash'), dt,
          'Advance or loan, taken back on pay sheets' || coalesce(' — ' || nullif(btrim(p->>'reason'), ''), ''), auth.uid())
  RETURNING id INTO eid;
  INSERT INTO public.staff_advances (organization_id, branch_id, staff_id, given_on, amount, installment, reason, account_id, expense_id, recorded_by)
  VALUES (st.organization_id, st.branch_id, st.id, dt, amt, ins, nullif(btrim(p->>'reason'), ''), acc.id, eid, auth.uid())
  RETURNING id INTO aid;
  PERFORM public.compute_pay_sheet(id) FROM public.pay_sheets WHERE branch_id = st.branch_id AND status = 'draft';
  RETURN aid;
END;
$$;

-- void a mistaken advance: only while nothing of it is on an approved or paid sheet
CREATE OR REPLACE FUNCTION public.void_staff_advance(p_advance uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  a public.staff_advances;
BEGIN
  SELECT * INTO a FROM public.staff_advances WHERE id = p_advance AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND OR a.status = 'void' THEN RAISE EXCEPTION 'Advance not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('payroll.approve', a.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t void advances at this branch' USING ERRCODE = '42501'; END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN RAISE EXCEPTION 'Give the reason' USING ERRCODE = '23514'; END IF;
  IF EXISTS (SELECT 1 FROM public.pay_sheet_advance_recoveries r JOIN public.pay_sheets s ON s.id = r.sheet_id
             WHERE r.advance_id = a.id AND s.status IN ('approved', 'paid')) THEN
    RAISE EXCEPTION 'Part of it is already taken back on an approved pay sheet — it can''t be voided' USING ERRCODE = '23514';
  END IF;
  UPDATE public.staff_advances SET status = 'void', void_reason = btrim(p_reason) WHERE id = a.id;
  IF a.expense_id IS NOT NULL THEN
    UPDATE public.expenses SET status = 'void', void_reason = 'Advance voided: ' || btrim(p_reason) WHERE id = a.expense_id AND status <> 'void';
  END IF;
  PERFORM public.compute_pay_sheet(id) FROM public.pay_sheets WHERE branch_id = a.branch_id AND status = 'draft';
END;
$$;

REVOKE ALL ON FUNCTION public.record_staff_advance(jsonb), public.void_staff_advance(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_staff_advance(jsonb), public.void_staff_advance(uuid, text) TO authenticated;
