-- ============================================================
-- 071 — Staff, attendance and pay sheets (1e, full production cost — part 1)
--
-- SwahziTech, 2026-10-27, the user: casual labourers are paid a day rate at
-- the end of the week; employed staff (manager, secretary, supervisor, team
-- leaders, driver…) have a monthly salary paid every two weeks. A staff list
-- per branch, a daily attendance list, and pay sheets — weekly (casuals by
-- days worked) and fortnightly (half the monthly salary) — prepared, approved
-- and paid. A paid sheet becomes one Wages expense, so pay is never typed
-- twice. Labour enters product cost in a later step (costing).
--
-- Who sees pay: Technical admin/owner, director, branch manager and secretary
-- (the secretary enters most of it). Storekeepers don't.
--
-- Production team members (056) become staff: each existing member gets a
-- staff row (kind and pay left blank — never guessed) and new members are
-- linked by name. The tenant's staff and pay are entered in the app only.
-- ============================================================

INSERT INTO public.permissions (code, description, module) VALUES
  ('staff.view',      'See staff, attendance, pay rates and pay sheets', 'staff'),
  ('staff.manage',    'Add and change staff and their pay',              'staff'),
  ('payroll.record',  'Mark attendance and prepare pay sheets',          'staff'),
  ('payroll.approve', 'Approve pay sheets and mark them paid',           'staff')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code IN ('staff.view', 'staff.manage', 'payroll.record', 'payroll.approve')
WHERE r.is_system_role AND r.name IN ('owner', 'director', 'branch_manager')
ON CONFLICT DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code IN ('staff.view', 'staff.manage', 'payroll.record')
WHERE r.is_system_role AND r.name = 'secretary'
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------
-- 1. Staff (per branch)
-- ------------------------------------------------------------
CREATE TABLE public.staff (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id    uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id          uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  full_name          text NOT NULL CHECK (btrim(full_name) <> ''),
  phone              text,
  kind               text CHECK (kind IN ('employed', 'casual')),            -- NULL = not set yet
  job_title          text,                                                    -- manager, secretary, team leader, driver…
  team_id            uuid REFERENCES public.production_teams(id) ON DELETE RESTRICT,
  pay_basis          text CHECK (pay_basis IN ('daily', 'monthly')),          -- casual: a day rate; employed: a monthly salary
  pay_rate           numeric CHECK (pay_rate >= 0),                           -- NULL = not set yet
  pay_cycle          text CHECK (pay_cycle IN ('weekly', 'fortnightly', 'monthly')),
  in_production_cost boolean NOT NULL DEFAULT true,                           -- their pay is shared over production (costing)
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'left')),
  started_on         date,
  left_on            date,
  notes              text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_staff_name ON public.staff (branch_id, public.normalize_name(full_name));
CREATE INDEX idx_staff_branch ON public.staff (branch_id, status);
COMMENT ON TABLE public.staff IS 'Staff of a branch — employed and casual, with their pay (071).';
CREATE TRIGGER trg_staff_updated_at BEFORE UPDATE ON public.staff FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_staff_audit AFTER INSERT OR UPDATE OR DELETE ON public.staff FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('staff', 'id');
CREATE TRIGGER trg_staff_no_delete BEFORE DELETE ON public.staff FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('staff member');
ALTER TABLE public.staff ENABLE ROW LEVEL SECURITY;
CREATE POLICY "staff: pay viewers read" ON public.staff FOR SELECT
  USING (organization_id = public.get_my_org_id() AND public.has_permission_at('staff.view', branch_id, NULL));
CREATE POLICY "staff: managers add" ON public.staff FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_at('staff.manage', branch_id, NULL));
CREATE POLICY "staff: managers change" ON public.staff FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND public.has_permission_at('staff.manage', branch_id, NULL))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_at('staff.manage', branch_id, NULL));

-- team members are staff: link them (existing members get a staff row; kind and pay stay blank)
ALTER TABLE public.production_team_members ADD COLUMN staff_id uuid REFERENCES public.staff(id) ON DELETE RESTRICT;
INSERT INTO public.staff (organization_id, branch_id, full_name, team_id)
SELECT DISTINCT ON (t.branch_id, public.normalize_name(m.name)) m.organization_id, t.branch_id, btrim(m.name), t.id
FROM public.production_team_members m JOIN public.production_teams t ON t.id = m.team_id
ORDER BY t.branch_id, public.normalize_name(m.name), m.status, m.created_at
ON CONFLICT DO NOTHING;
UPDATE public.production_team_members m SET staff_id = s.id
FROM public.production_teams t, public.staff s
WHERE t.id = m.team_id AND s.branch_id = t.branch_id AND public.normalize_name(s.full_name) = public.normalize_name(m.name);

-- a member added later is linked to the staff member of that name, or becomes one
CREATE OR REPLACE FUNCTION public.link_team_member_staff()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  br  uuid;
  sid uuid;
BEGIN
  IF NEW.staff_id IS NOT NULL THEN RETURN NEW; END IF;
  SELECT branch_id INTO br FROM public.production_teams WHERE id = NEW.team_id;
  SELECT id INTO sid FROM public.staff WHERE branch_id = br AND public.normalize_name(full_name) = public.normalize_name(NEW.name);
  IF sid IS NULL THEN
    INSERT INTO public.staff (organization_id, branch_id, full_name, team_id)
    VALUES (NEW.organization_id, br, btrim(NEW.name), NEW.team_id) RETURNING id INTO sid;
  END IF;
  NEW.staff_id := sid;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_team_member_staff BEFORE INSERT OR UPDATE OF name ON public.production_team_members
  FOR EACH ROW EXECUTE FUNCTION public.link_team_member_staff();

-- ------------------------------------------------------------
-- 2. Attendance (a day worked; half days allowed)
-- ------------------------------------------------------------
CREATE TABLE public.staff_attendance (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  staff_id        uuid NOT NULL REFERENCES public.staff(id) ON DELETE RESTRICT,
  work_date       date NOT NULL,
  day_fraction    numeric NOT NULL DEFAULT 1 CHECK (day_fraction IN (0.5, 1)),
  recorded_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (staff_id, work_date)
);
CREATE INDEX idx_staff_attendance_day ON public.staff_attendance (branch_id, work_date);
CREATE TRIGGER trg_staff_attendance_audit AFTER INSERT OR UPDATE OR DELETE ON public.staff_attendance FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('staff_attendance', 'id');
ALTER TABLE public.staff_attendance ENABLE ROW LEVEL SECURITY;
CREATE POLICY "staff_attendance: pay viewers read" ON public.staff_attendance FOR SELECT
  USING (organization_id = public.get_my_org_id() AND public.has_permission_at('staff.view', branch_id, NULL));
-- written through set_attendance only

-- ------------------------------------------------------------
-- 3. Pay sheets
-- ------------------------------------------------------------
CREATE TABLE public.pay_sheets (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  cycle           text NOT NULL CHECK (cycle IN ('weekly', 'fortnightly', 'monthly')),
  period_start    date NOT NULL,
  period_end      date NOT NULL,
  status          text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'approved', 'paid', 'void')),
  total           numeric NOT NULL DEFAULT 0,
  notes           text,
  prepared_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  approved_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  approved_at     timestamptz,
  paid_on         date,
  paid_by         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  account_id      uuid REFERENCES public.payment_accounts(id) ON DELETE RESTRICT,
  expense_id      uuid REFERENCES public.expenses(id) ON DELETE RESTRICT,
  void_reason     text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (period_end >= period_start)
);
CREATE INDEX idx_pay_sheets_branch ON public.pay_sheets (branch_id, period_start DESC);
CREATE TRIGGER trg_pay_sheets_updated_at BEFORE UPDATE ON public.pay_sheets FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_pay_sheets_audit AFTER INSERT OR UPDATE OR DELETE ON public.pay_sheets FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('pay_sheet', 'id');
CREATE TRIGGER trg_pay_sheets_no_delete BEFORE DELETE ON public.pay_sheets FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('pay sheet');
ALTER TABLE public.pay_sheets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pay_sheets: pay viewers read" ON public.pay_sheets FOR SELECT
  USING (organization_id = public.get_my_org_id() AND public.has_permission_at('staff.view', branch_id, NULL));

CREATE TABLE public.pay_sheet_lines (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  sheet_id        uuid NOT NULL REFERENCES public.pay_sheets(id) ON DELETE CASCADE,
  staff_id        uuid NOT NULL REFERENCES public.staff(id) ON DELETE RESTRICT,
  pay_basis       text NOT NULL CHECK (pay_basis IN ('daily', 'monthly')),
  days            numeric,                         -- days worked (daily pay)
  rate            numeric CHECK (rate >= 0),       -- day rate, or the monthly salary
  base            numeric NOT NULL DEFAULT 0,      -- days × rate, or the salary's share for the period
  additions       numeric NOT NULL DEFAULT 0 CHECK (additions >= 0),    -- overtime, bonus…
  deductions      numeric NOT NULL DEFAULT 0 CHECK (deductions >= 0),   -- advances taken…
  amount          numeric NOT NULL DEFAULT 0,      -- base + additions − deductions
  note            text,
  UNIQUE (sheet_id, staff_id)
);
CREATE TRIGGER trg_pay_sheet_lines_audit AFTER INSERT OR UPDATE OR DELETE ON public.pay_sheet_lines FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('pay_sheet_line', 'id');
ALTER TABLE public.pay_sheet_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pay_sheet_lines: pay viewers read" ON public.pay_sheet_lines FOR SELECT
  USING (organization_id = public.get_my_org_id()
         AND EXISTS (SELECT 1 FROM public.pay_sheets s WHERE s.id = sheet_id AND public.has_permission_at('staff.view', s.branch_id, NULL)));

-- ------------------------------------------------------------
-- 4. Attendance: mark or clear a day (not once a sheet covering it is approved)
-- p: { staff_id, work_date, day_fraction? (1 | 0.5 | 0 = clear) }
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
  IF EXISTS (SELECT 1 FROM public.pay_sheet_lines l JOIN public.pay_sheets s ON s.id = l.sheet_id
             WHERE l.staff_id = st.id AND s.status IN ('approved', 'paid') AND dt BETWEEN s.period_start AND s.period_end) THEN
    RAISE EXCEPTION 'That day is on an approved pay sheet — it can''t change' USING ERRCODE = '23514';
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
-- 5. Prepare a pay sheet: a line for each staff member on that cycle
--    daily pay → days worked in the period × day rate (only when they worked)
--    monthly salary → the whole salary (monthly), half (fortnightly), a quarter (weekly)
--    kind/pay not set: employed → monthly salary, fortnightly; casual → day rate, weekly
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
  LEFT JOIN LATERAL (SELECT sum(a.day_fraction) AS days FROM public.staff_attendance a
                     WHERE a.staff_id = st.id AND a.work_date BETWEEN ps.period_start AND ps.period_end) d ON true
  CROSS JOIN LATERAL (SELECT round(coalesce(CASE b.basis WHEN 'daily' THEN coalesce(d.days, 0) * st.pay_rate
                        ELSE st.pay_rate * CASE ps.cycle WHEN 'monthly' THEN 1 WHEN 'fortnightly' THEN 0.5 ELSE 0.25 END END, 0), 2) AS base) x
  WHERE ps.id = p_sheet
    AND b.cycle = ps.cycle
    AND (st.started_on IS NULL OR st.started_on <= ps.period_end)
    AND (st.status = 'active' OR st.left_on >= ps.period_start OR d.days > 0)
    AND (b.basis = 'monthly' OR d.days > 0);
  UPDATE public.pay_sheets SET total = coalesce((SELECT sum(amount) FROM public.pay_sheet_lines WHERE sheet_id = p_sheet), 0) WHERE id = p_sheet;
$$;
REVOKE ALL ON FUNCTION public.fill_pay_sheet_lines(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.prepare_pay_sheet(p_branch uuid, p_cycle text, p_start date, p_end date)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  sid uuid;
BEGIN
  IF NOT public.has_permission_at('payroll.record', p_branch, NULL) THEN RAISE EXCEPTION 'You can''t prepare pay sheets at this branch' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch AND organization_id = org) THEN RAISE EXCEPTION 'Branch not found' USING ERRCODE = '23514'; END IF;
  IF p_cycle IS NULL OR p_cycle NOT IN ('weekly', 'fortnightly', 'monthly') THEN RAISE EXCEPTION 'Choose weekly, fortnightly or monthly' USING ERRCODE = '23514'; END IF;
  IF p_start IS NULL OR p_end IS NULL OR p_end < p_start THEN RAISE EXCEPTION 'Choose the period' USING ERRCODE = '23514'; END IF;
  IF EXISTS (SELECT 1 FROM public.pay_sheets WHERE branch_id = p_branch AND cycle = p_cycle AND status <> 'void'
             AND daterange(period_start, period_end, '[]') && daterange(p_start, p_end, '[]')) THEN
    RAISE EXCEPTION 'There is already a % pay sheet for part of that period', p_cycle USING ERRCODE = '23514';
  END IF;
  INSERT INTO public.pay_sheets (organization_id, branch_id, cycle, period_start, period_end, prepared_by)
  VALUES (org, p_branch, p_cycle, p_start, p_end, auth.uid()) RETURNING id INTO sid;
  PERFORM public.fill_pay_sheet_lines(sid);
  RETURN sid;
END;
$$;

-- ------------------------------------------------------------
-- 6. Change a draft sheet's line: additions, deductions, note; refresh from attendance
-- p: { additions?, deductions?, note? }
-- ------------------------------------------------------------
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
  IF l.base + ad - de < 0 THEN RAISE EXCEPTION 'Deductions can''t be more than the pay' USING ERRCODE = '23514'; END IF;
  UPDATE public.pay_sheet_lines SET additions = ad, deductions = de, amount = base + ad - de,
         note = CASE WHEN p ? 'note' THEN nullif(btrim(p->>'note'), '') ELSE note END
  WHERE id = l.id;
  UPDATE public.pay_sheets SET total = (SELECT sum(amount) FROM public.pay_sheet_lines WHERE sheet_id = s.id) WHERE id = s.id;
END;
$$;

-- Re-read a draft from the staff list and attendance (keeps additions, deductions and notes)
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
  UPDATE public.pay_sheet_lines SET amount = greatest(base + additions - deductions, 0) WHERE sheet_id = s.id;
  UPDATE public.pay_sheets SET total = coalesce((SELECT sum(amount) FROM public.pay_sheet_lines WHERE sheet_id = s.id), 0) WHERE id = s.id;
END;
$$;

-- ------------------------------------------------------------
-- 7. Approve, pay, void
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
  UPDATE public.pay_sheets SET status = 'approved', approved_by = auth.uid(), approved_at = now() WHERE id = s.id;
END;
$$;

-- p: { paid_on?, account_id? } — the paid sheet becomes one Wages expense
CREATE OR REPLACE FUNCTION public.pay_pay_sheet(p_sheet uuid, p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s   public.pay_sheets;
  acc public.payment_accounts;
  cat uuid;
  dt  date;
  eid uuid;
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
  SELECT id INTO cat FROM public.expense_categories WHERE organization_id = s.organization_id AND public.normalize_name(name) = public.normalize_name('Wages');
  IF cat IS NULL THEN
    INSERT INTO public.expense_categories (organization_id, name) VALUES (s.organization_id, 'Wages') RETURNING id INTO cat;
  END IF;
  INSERT INTO public.expenses (organization_id, branch_id, expense_date, category_id, description, amount, amount_paid, payment_method, paid_on, notes, created_by)
  VALUES (s.organization_id, s.branch_id, s.period_end, cat,
          initcap(s.cycle) || ' pay ' || to_char(s.period_start, 'YYYY-MM-DD') || ' to ' || to_char(s.period_end, 'YYYY-MM-DD'),
          s.total, s.total, coalesce(acc.kind, 'cash'), dt, 'From pay sheet ' || s.id, auth.uid())
  RETURNING id INTO eid;
  UPDATE public.pay_sheets SET status = 'paid', paid_on = dt, paid_by = auth.uid(), account_id = acc.id, expense_id = eid WHERE id = s.id;
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
  IF s.expense_id IS NOT NULL THEN
    UPDATE public.expenses SET status = 'void', void_reason = 'Pay sheet voided: ' || btrim(p_reason) WHERE id = s.expense_id;
  END IF;
  UPDATE public.pay_sheets SET status = 'void', void_reason = btrim(p_reason) WHERE id = s.id;
END;
$$;

REVOKE ALL ON FUNCTION public.set_attendance(jsonb), public.prepare_pay_sheet(uuid, text, date, date), public.update_pay_sheet_line(uuid, jsonb),
  public.refresh_pay_sheet(uuid), public.approve_pay_sheet(uuid), public.pay_pay_sheet(uuid, jsonb), public.void_pay_sheet(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_attendance(jsonb), public.prepare_pay_sheet(uuid, text, date, date), public.update_pay_sheet_line(uuid, jsonb),
  public.refresh_pay_sheet(uuid), public.approve_pay_sheet(uuid), public.pay_pay_sheet(uuid, jsonb), public.void_pay_sheet(uuid, text) TO authenticated;
