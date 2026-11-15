-- ============================================================
-- 122 — Expense categories are one word, everywhere
-- ============================================================
-- SwahziTech, 2026-11-15 (the user): category names are single words so they fit a sheet's
-- column. Existing two-word names are renamed in every organization; payroll files PAYE/NSSF/
-- WCF/SDL under 'Statutory' (it still finds an older 'Statutory contributions'); and the table
-- refuses a name with a space from now on.
-- ============================================================

-- the known two-word names → one word (only where that word is not taken already)
UPDATE public.expense_categories c SET name = v.new
  FROM (VALUES ('Electricity (LUKU)', 'Electricity'), ('Office tools', 'Office'), ('Spare parts', 'Spares'),
               ('General expenses', 'Expense'), ('General', 'Expense'), ('Statutory contributions', 'Statutory')) AS v(old, new)
 WHERE public.normalize_name(c.name) = public.normalize_name(v.old)
   AND NOT EXISTS (SELECT 1 FROM public.expense_categories x WHERE x.organization_id = c.organization_id AND public.normalize_name(x.name) = public.normalize_name(v.new));
-- anything else with a space: the words joined ("Fuel costs" → "FuelCosts"), or with its id's start when that is taken
UPDATE public.expense_categories c SET name = CASE
    WHEN NOT EXISTS (SELECT 1 FROM public.expense_categories x WHERE x.organization_id = c.organization_id AND x.id <> c.id
                      AND public.normalize_name(x.name) = public.normalize_name(replace(initcap(c.name), ' ', '')))
      THEN replace(initcap(regexp_replace(btrim(c.name), '[^[:alnum:] ]', '', 'g')), ' ', '')
    ELSE replace(initcap(regexp_replace(btrim(c.name), '[^[:alnum:] ]', '', 'g')), ' ', '') || left(c.id::text, 4) END
 WHERE c.name ~ '\s';

ALTER TABLE public.expense_categories ADD CONSTRAINT expense_categories_one_word CHECK (btrim(name) !~ '\s');

-- payroll (088): the statutory deductions go under 'Statutory'
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
    SELECT id INTO scat FROM public.expense_categories WHERE organization_id = s.organization_id AND public.normalize_name(name) IN (public.normalize_name('Statutory'), public.normalize_name('Statutory contributions')) ORDER BY public.normalize_name(name) = public.normalize_name('Statutory') DESC LIMIT 1;
    IF scat IS NULL THEN
      INSERT INTO public.expense_categories (organization_id, name) VALUES (s.organization_id, 'Statutory') RETURNING id INTO scat;
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

