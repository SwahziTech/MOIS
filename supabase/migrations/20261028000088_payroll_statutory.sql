-- ============================================================
-- 088 — Payroll: statutory deductions and payslips (Staff (HR) Part 2)
-- ============================================================
-- SwahziTech, 2026-10-28, the user: pay sheets with NSSF, PAYE, WCF and SDL
-- from a dated, editable rate table that the Technical admin or a director
-- confirms against TRA / NSSF / WCF before any deduction posts.
--
--   * statutory_rates: one row per code and start date. Pre-filled with the
--     commonly published Tanzania mainland figures, NOT confirmed ("to verify").
--     PAYE is monthly bands; the others a percent of gross pay.
--     SDL only from min_employees; whether casual labourers count is a setting
--     (count_casuals) — not known yet, ask TRA.
--   * staff.statutory: deductions apply (NULL = follows the kind: employed yes,
--     casual no).
--   * pay sheet lines: gross, NSSF (employee/employer), PAYE, WCF, SDL; the
--     amount is now the net pay: gross − NSSF − PAYE − other deductions.
--     PAYE is worked on the month: (gross − employee NSSF) × periods a month,
--     taxed by the bands, ÷ periods a month (2 for fortnightly, 4 for weekly).
--   * approving refuses while a rate used isn't confirmed.
--   * paying: the net pay is one Wages expense (paid); PAYE, NSSF, WCF and SDL
--     one "Statutory contributions" expense, owed until remitted.
--
-- Sheets already approved or paid keep their amounts (no deductions on them).
-- ============================================================

INSERT INTO public.permissions (code, description, module) VALUES
  ('payroll.rates', 'Set and confirm the statutory rates (PAYE, NSSF, WCF, SDL)', 'staff')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code = 'payroll.rates'
WHERE r.is_system_role AND r.name IN ('owner', 'director')
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------
-- 1. Statutory rates (dated)
-- ------------------------------------------------------------
CREATE TABLE public.statutory_rates (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  code            text NOT NULL CHECK (code IN ('paye', 'nssf_employee', 'nssf_employer', 'wcf', 'sdl')),
  effective_from  date NOT NULL,
  rate            numeric CHECK (rate >= 0 AND rate <= 100),   -- percent of gross pay (all but PAYE)
  bands           jsonb,                                        -- PAYE: monthly bands [{ "from": 0, "rate": 0 }, …]
  min_employees   integer CHECK (min_employees >= 0),           -- SDL: only from this many employees
  count_casuals   boolean NOT NULL DEFAULT false,               -- SDL: casual labourers count (ask TRA)
  notes           text,
  verified_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  verified_at     timestamptz,                                  -- NULL = to verify
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'void')),
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CHECK ((code = 'paye') = (bands IS NOT NULL)),
  CHECK (code = 'paye' OR rate IS NOT NULL)
);
CREATE UNIQUE INDEX uq_statutory_rates ON public.statutory_rates (organization_id, code, effective_from) WHERE status = 'active';
CREATE TRIGGER trg_statutory_rates_updated_at BEFORE UPDATE ON public.statutory_rates FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_statutory_rates_audit AFTER INSERT OR UPDATE OR DELETE ON public.statutory_rates FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('statutory_rate', 'id');
CREATE TRIGGER trg_statutory_rates_no_delete BEFORE DELETE ON public.statutory_rates FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('statutory rate');
ALTER TABLE public.statutory_rates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "statutory_rates: read own org" ON public.statutory_rates FOR SELECT USING (organization_id = public.get_my_org_id());
COMMENT ON TABLE public.statutory_rates IS 'PAYE bands and NSSF/WCF/SDL percents by start date; confirmed by the Technical admin or a director (088).';

-- The usual figures, to verify (commonly published, Tanzania mainland)
CREATE OR REPLACE FUNCTION public.fill_usual_statutory_rates(p_org uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO public.statutory_rates (organization_id, code, effective_from, rate, bands, min_employees, notes)
  SELECT p_org, x.code, x.d::date, x.rate, x.bands, x.mine, x.notes
  FROM (VALUES
    ('paye', '2024-07-01', NULL::numeric,
     '[{"from":0,"rate":0},{"from":270000,"rate":8},{"from":520000,"rate":20},{"from":760000,"rate":25},{"from":1000000,"rate":30}]'::jsonb, NULL::integer,
     'Resident employee, a month. Usual published bands — confirm with TRA.'),
    ('nssf_employee', '2024-07-01', 10, NULL, NULL, 'Employee share of gross pay — confirm with NSSF.'),
    ('nssf_employer', '2024-07-01', 10, NULL, NULL, 'Employer share of gross pay — confirm with NSSF.'),
    ('wcf',           '2024-07-01', 0.5, NULL, NULL, 'Employer, private sector — some sources say 0.6%. Confirm with WCF.'),
    ('sdl',           '2024-07-01', 3.5, NULL, 10, 'Employer, from 10 employees — some sources say 4%. Whether casuals count: ask TRA.')
  ) AS x(code, d, rate, bands, mine, notes)
  WHERE NOT EXISTS (SELECT 1 FROM public.statutory_rates r WHERE r.organization_id = p_org AND r.code = x.code AND r.status = 'active');
$$;
REVOKE ALL ON FUNCTION public.fill_usual_statutory_rates(uuid) FROM PUBLIC, anon, authenticated;
SELECT public.fill_usual_statutory_rates(id) FROM public.organizations;

-- an organisation without rates (added later) fills the usual ones from HR › Staff ⚙
CREATE OR REPLACE FUNCTION public.fill_my_statutory_rates()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_permission('payroll.rates') THEN RAISE EXCEPTION 'Only the Technical admin or a director sets statutory rates' USING ERRCODE = '42501'; END IF;
  PERFORM public.fill_usual_statutory_rates(public.get_my_org_id());
END;
$$;
REVOKE ALL ON FUNCTION public.fill_my_statutory_rates() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fill_my_statutory_rates() TO authenticated;

-- p: { id?, code, effective_from, rate?, bands?, min_employees?, count_casuals?, notes? } — a changed rate is to verify again
CREATE OR REPLACE FUNCTION public.save_statutory_rate(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org  uuid := public.get_my_org_id();
  rid  uuid := nullif(p->>'id', '')::uuid;
  cd   text := p->>'code';
  dt   date := nullif(p->>'effective_from', '')::date;
  rt   numeric := nullif(p->>'rate', '')::numeric;
  bd   jsonb := CASE WHEN jsonb_typeof(p->'bands') = 'array' THEN p->'bands' END;
  old  public.statutory_rates;
BEGIN
  IF NOT public.has_permission('payroll.rates') THEN RAISE EXCEPTION 'Only the Technical admin or a director sets statutory rates' USING ERRCODE = '42501'; END IF;
  IF rid IS NOT NULL THEN
    SELECT * INTO old FROM public.statutory_rates WHERE id = rid AND organization_id = org AND status = 'active' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Rate not found' USING ERRCODE = '23514'; END IF;
    cd := old.code;
  END IF;
  IF cd IS NULL OR cd NOT IN ('paye', 'nssf_employee', 'nssf_employer', 'wcf', 'sdl') THEN RAISE EXCEPTION 'Choose what the rate is for' USING ERRCODE = '23514'; END IF;
  IF dt IS NULL THEN RAISE EXCEPTION 'Enter the date it applies from' USING ERRCODE = '23514'; END IF;
  IF cd = 'paye' THEN
    IF bd IS NULL OR jsonb_array_length(bd) = 0 THEN RAISE EXCEPTION 'Enter the PAYE bands' USING ERRCODE = '23514'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(bd) b WHERE (b->>'from') IS NULL OR (b->>'rate') IS NULL
               OR (b->>'from')::numeric < 0 OR (b->>'rate')::numeric < 0 OR (b->>'rate')::numeric > 100) THEN
      RAISE EXCEPTION 'Each band needs a starting amount and a percent (0–100)' USING ERRCODE = '23514';
    END IF;
    SELECT jsonb_agg(jsonb_build_object('from', (b->>'from')::numeric, 'rate', (b->>'rate')::numeric) ORDER BY (b->>'from')::numeric) INTO bd FROM jsonb_array_elements(bd) b;
    IF (bd->0->>'from')::numeric <> 0 THEN RAISE EXCEPTION 'The first band starts at 0' USING ERRCODE = '23514'; END IF;
    rt := NULL;
  ELSE
    IF rt IS NULL OR rt < 0 OR rt > 100 THEN RAISE EXCEPTION 'Enter the percent (0–100)' USING ERRCODE = '23514'; END IF;
    bd := NULL;
  END IF;
  IF rid IS NULL THEN
    INSERT INTO public.statutory_rates (organization_id, code, effective_from, rate, bands, min_employees, count_casuals, notes, created_by)
    VALUES (org, cd, dt, rt, bd, CASE WHEN cd = 'sdl' THEN nullif(p->>'min_employees', '')::integer END,
            cd = 'sdl' AND coalesce((p->>'count_casuals')::boolean, false), nullif(btrim(p->>'notes'), ''), auth.uid())
    RETURNING id INTO rid;
  ELSE
    UPDATE public.statutory_rates SET effective_from = dt, rate = rt, bands = bd,
           min_employees = CASE WHEN cd = 'sdl' THEN nullif(p->>'min_employees', '')::integer END,
           count_casuals = cd = 'sdl' AND coalesce((p->>'count_casuals')::boolean, false),
           notes = CASE WHEN p ? 'notes' THEN nullif(btrim(p->>'notes'), '') ELSE notes END,
           verified_by = NULL, verified_at = NULL
    WHERE id = rid;
  END IF;
  RETURN rid;
END;
$$;

-- confirm (p_ok) or take back a confirmation
CREATE OR REPLACE FUNCTION public.verify_statutory_rate(p_rate uuid, p_ok boolean DEFAULT true)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_permission('payroll.rates') THEN RAISE EXCEPTION 'Only the Technical admin or a director confirms statutory rates' USING ERRCODE = '42501'; END IF;
  UPDATE public.statutory_rates SET verified_by = CASE WHEN p_ok THEN auth.uid() END, verified_at = CASE WHEN p_ok THEN now() END
  WHERE id = p_rate AND organization_id = public.get_my_org_id() AND status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'Rate not found' USING ERRCODE = '23514'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.void_statutory_rate(p_rate uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_permission('payroll.rates') THEN RAISE EXCEPTION 'Only the Technical admin or a director changes statutory rates' USING ERRCODE = '42501'; END IF;
  UPDATE public.statutory_rates SET status = 'void' WHERE id = p_rate AND organization_id = public.get_my_org_id() AND status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'Rate not found' USING ERRCODE = '23514'; END IF;
END;
$$;

-- PAYE on a month's taxable pay, by bands [{from, rate}]
CREATE OR REPLACE FUNCTION public.paye_monthly(p_taxable numeric, p_bands jsonb)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT coalesce(sum(greatest(least(greatest(p_taxable, 0), coalesce(x.nxt, 'Infinity'::numeric)) - x.fr, 0) * x.rate / 100), 0)
  FROM (SELECT (b->>'from')::numeric AS fr, (b->>'rate')::numeric AS rate,
               lead((b->>'from')::numeric) OVER (ORDER BY (b->>'from')::numeric) AS nxt
        FROM jsonb_array_elements(p_bands) b) x
$$;

-- ------------------------------------------------------------
-- 2. Who has deductions; what a line and a sheet hold
-- ------------------------------------------------------------
ALTER TABLE public.staff ADD COLUMN statutory boolean;   -- NULL = follows the kind (employed yes, casual no)
COMMENT ON COLUMN public.staff.statutory IS 'NSSF/PAYE/WCF/SDL apply; NULL = employed yes, casual no (088).';

ALTER TABLE public.pay_sheet_lines
  ADD COLUMN statutory     boolean NOT NULL DEFAULT false,
  ADD COLUMN gross         numeric NOT NULL DEFAULT 0,   -- base + additions
  ADD COLUMN nssf_employee numeric NOT NULL DEFAULT 0,
  ADD COLUMN paye          numeric NOT NULL DEFAULT 0,
  ADD COLUMN nssf_employer numeric NOT NULL DEFAULT 0,
  ADD COLUMN wcf           numeric NOT NULL DEFAULT 0,
  ADD COLUMN sdl           numeric NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.pay_sheet_lines.amount IS 'Net pay: gross − NSSF − PAYE − other deductions (088).';
UPDATE public.pay_sheet_lines SET gross = base + additions;

ALTER TABLE public.pay_sheets
  ADD COLUMN gross_total          numeric NOT NULL DEFAULT 0,
  ADD COLUMN employee_statutory   numeric NOT NULL DEFAULT 0,   -- NSSF + PAYE taken from pay
  ADD COLUMN employer_statutory   numeric NOT NULL DEFAULT 0,   -- NSSF + WCF + SDL on top of pay
  ADD COLUMN rates_unverified     text[] NOT NULL DEFAULT '{}', -- codes used that aren't confirmed
  ADD COLUMN statutory_expense_id uuid REFERENCES public.expenses(id) ON DELETE RESTRICT;
UPDATE public.pay_sheets s SET gross_total = coalesce((SELECT sum(gross) FROM public.pay_sheet_lines WHERE sheet_id = s.id), 0);

-- ------------------------------------------------------------
-- 3. Work out a draft sheet's deductions and totals
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
  UPDATE public.pay_sheet_lines l SET amount = greatest(l.gross - l.nssf_employee - l.paye - l.deductions, 0) WHERE l.sheet_id = s.id;

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

-- a sheet's lines from the staff list and attendance (071), then its deductions
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
  LEFT JOIN LATERAL (SELECT sum(a.day_fraction) AS days FROM public.staff_attendance a
                     WHERE a.staff_id = st.id AND a.work_date BETWEEN ps.period_start AND ps.period_end) d ON true
  CROSS JOIN LATERAL (SELECT round(coalesce(CASE b.basis WHEN 'daily' THEN coalesce(d.days, 0) * st.pay_rate
                        ELSE st.pay_rate * CASE ps.cycle WHEN 'monthly' THEN 1 WHEN 'fortnightly' THEN 0.5 ELSE 0.25 END END, 0), 2) AS base) x
  WHERE ps.id = p_sheet
    AND b.cycle = ps.cycle
    AND (st.started_on IS NULL OR st.started_on <= ps.period_end)
    AND (st.status = 'active' OR st.left_on >= ps.period_start OR d.days > 0)
    AND (b.basis = 'monthly' OR d.days > 0);
  SELECT public.compute_pay_sheet(p_sheet);
$$;
REVOKE ALL ON FUNCTION public.fill_pay_sheet_lines(uuid) FROM PUBLIC, anon, authenticated;

-- p: { additions?, deductions?, note? } — other deductions (advances…); NSSF and PAYE are worked out
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
  IF l.gross - l.nssf_employee - l.paye - l.deductions < 0 THEN RAISE EXCEPTION 'Deductions can''t be more than the pay' USING ERRCODE = '23514'; END IF;
END;
$$;

-- Re-read a draft from the staff list, attendance and rates (keeps additions, deductions and notes)
CREATE OR REPLACE FUNCTION public.refresh_pay_sheet(p_sheet uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s    public.pay_sheets;
  keep jsonb;
BEGIN
  SELECT * INTO s FROM public.pay_sheets WHERE id = p_sheet AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pay sheet not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('payroll.record', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change pay sheets at this branch' USING ERRCODE = '42501'; END IF;
  IF s.status <> 'draft' THEN RAISE EXCEPTION 'Only a draft pay sheet can change' USING ERRCODE = '23514'; END IF;
  SELECT coalesce(jsonb_object_agg(staff_id, jsonb_build_object('a', additions, 'd', deductions, 'n', note)), '{}') INTO keep
  FROM public.pay_sheet_lines WHERE sheet_id = s.id;
  DELETE FROM public.pay_sheet_lines WHERE sheet_id = s.id;
  PERFORM public.fill_pay_sheet_lines(s.id);
  UPDATE public.pay_sheet_lines l SET additions = (keep->(l.staff_id::text)->>'a')::numeric, deductions = (keep->(l.staff_id::text)->>'d')::numeric,
         note = keep->(l.staff_id::text)->>'n'
  WHERE l.sheet_id = s.id AND keep ? l.staff_id::text;
  PERFORM public.compute_pay_sheet(s.id);
END;
$$;

-- ------------------------------------------------------------
-- 4. Approve (rates confirmed), pay (two expenses), void
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_pay_sheet(p_sheet uuid)
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
  IF NOT public.has_permission_at('payroll.approve', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t approve pay sheets at this branch' USING ERRCODE = '42501'; END IF;
  IF s.status <> 'draft' THEN RAISE EXCEPTION 'Only a draft pay sheet can be approved' USING ERRCODE = '23514'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pay_sheet_lines WHERE sheet_id = s.id) THEN RAISE EXCEPTION 'The pay sheet has no one on it' USING ERRCODE = '23514'; END IF;
  IF EXISTS (SELECT 1 FROM public.pay_sheet_lines WHERE sheet_id = s.id AND rate IS NULL) THEN
    RAISE EXCEPTION 'Set the pay of everyone on the sheet first (Staff)' USING ERRCODE = '23514';
  END IF;
  PERFORM public.compute_pay_sheet(s.id);   -- rates may have been confirmed or changed since
  SELECT * INTO s FROM public.pay_sheets WHERE id = s.id;
  IF cardinality(s.rates_unverified) > 0 THEN
    RAISE EXCEPTION 'The statutory rates used aren''t confirmed yet (%) — the Technical admin or a director confirms them in HR › Staff ⚙',
      array_to_string(s.rates_unverified, ', ') USING ERRCODE = '23514';
  END IF;
  UPDATE public.pay_sheets SET status = 'approved', approved_by = auth.uid(), approved_at = now() WHERE id = s.id;
END;
$$;

-- p: { paid_on?, account_id? } — net pay: one Wages expense; PAYE/NSSF/WCF/SDL: one Statutory contributions expense, owed
CREATE OR REPLACE FUNCTION public.pay_pay_sheet(p_sheet uuid, p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s    public.pay_sheets;
  acc  public.payment_accounts;
  cat  uuid;
  scat uuid;
  dt   date;
  eid  uuid;
  sid  uuid;
  per  text;
  br   record;
BEGIN
  SELECT * INTO s FROM public.pay_sheets WHERE id = p_sheet AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pay sheet not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('payroll.approve', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t pay pay sheets at this branch' USING ERRCODE = '42501'; END IF;
  IF s.status <> 'approved' THEN RAISE EXCEPTION 'Approve the pay sheet first' USING ERRCODE = '23514'; END IF;
  dt := coalesce(nullif(p->>'paid_on', '')::date, public.org_today(s.organization_id));
  IF dt > public.org_today(s.organization_id) THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;
  IF nullif(p->>'account_id', '') IS NOT NULL THEN
    SELECT * INTO acc FROM public.payment_accounts WHERE id = (p->>'account_id')::uuid AND branch_id = s.branch_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Choose the account it was paid from' USING ERRCODE = '23514'; END IF;
  END IF;
  per := to_char(s.period_start, 'YYYY-MM-DD') || ' to ' || to_char(s.period_end, 'YYYY-MM-DD');
  SELECT id INTO cat FROM public.expense_categories WHERE organization_id = s.organization_id AND public.normalize_name(name) = public.normalize_name('Wages');
  IF cat IS NULL THEN
    INSERT INTO public.expense_categories (organization_id, name) VALUES (s.organization_id, 'Wages') RETURNING id INTO cat;
  END IF;
  INSERT INTO public.expenses (organization_id, branch_id, expense_date, category_id, description, amount, amount_paid, payment_method, paid_on, notes, created_by)
  VALUES (s.organization_id, s.branch_id, s.period_end, cat, initcap(s.cycle) || ' pay ' || per,
          s.total, s.total, coalesce(acc.kind, 'cash'), dt, 'From pay sheet ' || s.id, auth.uid())
  RETURNING id INTO eid;
  IF s.employee_statutory + s.employer_statutory > 0 THEN
    SELECT id INTO scat FROM public.expense_categories WHERE organization_id = s.organization_id AND public.normalize_name(name) = public.normalize_name('Statutory contributions');
    IF scat IS NULL THEN
      INSERT INTO public.expense_categories (organization_id, name) VALUES (s.organization_id, 'Statutory contributions') RETURNING id INTO scat;
    END IF;
    SELECT sum(paye) AS paye, sum(nssf_employee + nssf_employer) AS nssf, sum(wcf) AS wcf, sum(sdl) AS sdl INTO br
    FROM public.pay_sheet_lines WHERE sheet_id = s.id;
    INSERT INTO public.expenses (organization_id, branch_id, expense_date, category_id, description, amount, amount_paid, notes, created_by)
    VALUES (s.organization_id, s.branch_id, s.period_end, scat, 'PAYE, NSSF, WCF, SDL on ' || s.cycle || ' pay ' || per,
            s.employee_statutory + s.employer_statutory, 0,
            format('From pay sheet %s — PAYE %s · NSSF %s · WCF %s · SDL %s. Owed until remitted.', s.id, br.paye, br.nssf, br.wcf, br.sdl), auth.uid())
    RETURNING id INTO sid;
  END IF;
  UPDATE public.pay_sheets SET status = 'paid', paid_on = dt, paid_by = auth.uid(), account_id = acc.id, expense_id = eid, statutory_expense_id = sid WHERE id = s.id;
  RETURN eid;
END;
$$;

CREATE OR REPLACE FUNCTION public.void_pay_sheet(p_sheet uuid, p_reason text)
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
  IF s.status = 'void' THEN RAISE EXCEPTION 'Already void' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at(CASE WHEN s.status = 'draft' THEN 'payroll.record' ELSE 'payroll.approve' END, s.branch_id, NULL) THEN
    RAISE EXCEPTION 'You can''t void this pay sheet' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN RAISE EXCEPTION 'Give the reason' USING ERRCODE = '23514'; END IF;
  UPDATE public.expenses SET status = 'void', void_reason = 'Pay sheet voided: ' || btrim(p_reason)
  WHERE id IN (s.expense_id, s.statutory_expense_id) AND status <> 'void';
  UPDATE public.pay_sheets SET status = 'void', void_reason = btrim(p_reason) WHERE id = s.id;
END;
$$;

REVOKE ALL ON FUNCTION public.save_statutory_rate(jsonb), public.verify_statutory_rate(uuid, boolean), public.void_statutory_rate(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_statutory_rate(jsonb), public.verify_statutory_rate(uuid, boolean), public.void_statutory_rate(uuid) TO authenticated;

-- draft sheets: work out their deductions now
SELECT public.compute_pay_sheet(id) FROM public.pay_sheets WHERE status = 'draft';
