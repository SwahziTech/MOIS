-- ============================================================
-- 115 — Casual wages through the weekly cash request (2026-11-09, the user)
-- ============================================================
--   * Casuals' weeks run Sunday to Saturday: work done in a week is paid from
--     the cash requested on its Saturday (Sunday is for emergencies only, so the
--     money is never asked in advance). Weekly pay sheets follow.
--   * The branch manager approves the casuals' sheet; on approval its net total
--     becomes a line of that Saturday's weekly cash request ("Casual wages · …"),
--     made if there is none yet. The line follows the sheet and can't be typed over.
--   * The branch manager marks the sheet paid; the wages leave the branch's cash.
--   * Directors see casual sheets read-only (screen); salary sheets are unchanged.
-- ============================================================

-- 1. weekly periods: Sunday to Saturday
CREATE OR REPLACE FUNCTION public.pay_period(p_cycle text, p_day date, OUT p_start date, OUT p_end date)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_cycle
           WHEN 'weekly' THEN p_day - extract(dow FROM p_day)::int
           WHEN 'fortnightly' THEN CASE WHEN extract(day FROM p_day) <= 15 THEN date_trunc('month', p_day)::date ELSE date_trunc('month', p_day)::date + 15 END
           ELSE date_trunc('month', p_day)::date END,
         CASE p_cycle
           WHEN 'weekly' THEN p_day - extract(dow FROM p_day)::int + 6
           WHEN 'fortnightly' THEN CASE WHEN extract(day FROM p_day) <= 15 THEN date_trunc('month', p_day)::date + 14 ELSE (date_trunc('month', p_day) + interval '1 month - 1 day')::date END
           ELSE (date_trunc('month', p_day) + interval '1 month - 1 day')::date END
$$;

-- 2. the casual wages line of a request, tied to its pay sheet
ALTER TABLE public.cash_request_lines ADD COLUMN IF NOT EXISTS pay_sheet_id uuid REFERENCES public.pay_sheets(id) ON DELETE SET NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_cash_request_lines_sheet ON public.cash_request_lines (pay_sheet_id) WHERE pay_sheet_id IS NOT NULL;
COMMENT ON COLUMN public.cash_request_lines.pay_sheet_id IS 'The casuals'' weekly pay sheet this line asks for (115).';

CREATE OR REPLACE FUNCTION public.save_cash_request(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  rid uuid := nullif(p->>'id', '')::uuid;
  r   public.cash_requests;
  br  uuid := nullif(p->>'branch_id', '')::uuid;
  wk  date := nullif(p->>'week_ending', '')::date;
  x   jsonb;
  n   int := 0;
BEGIN
  IF rid IS NOT NULL THEN
    SELECT * INTO r FROM public.cash_requests WHERE id = rid AND organization_id = org FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Request not found' USING ERRCODE = '23514'; END IF;
    IF r.status <> 'draft' THEN RAISE EXCEPTION 'Only a draft can be changed — it has been sent' USING ERRCODE = '23514'; END IF;
    br := r.branch_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = br AND organization_id = org) THEN RAISE EXCEPTION 'Branch not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('cash.request', br, NULL) THEN RAISE EXCEPTION 'You can''t prepare cash requests at this branch' USING ERRCODE = '42501'; END IF;
  IF wk IS NULL OR extract(isodow FROM wk) <> 6 THEN RAISE EXCEPTION 'Choose the Saturday the week ends' USING ERRCODE = '23514'; END IF;
  IF (jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines') = 0)
     AND NOT EXISTS (SELECT 1 FROM public.cash_request_lines WHERE request_id = rid AND pay_sheet_id IS NOT NULL) THEN
    RAISE EXCEPTION 'Add what is needed' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (SELECT 1 FROM public.cash_requests WHERE branch_id = br AND week_ending = wk AND status NOT IN ('cancelled', 'rejected') AND id IS DISTINCT FROM rid) THEN
    RAISE EXCEPTION 'There is already a request for the week ending %', wk USING ERRCODE = '23514';
  END IF;
  IF rid IS NULL THEN
    INSERT INTO public.cash_requests (organization_id, branch_id, week_ending, pay_bank, pay_account_no, pay_account_name, opening_balance, notes, source, prepared_by)
    VALUES (org, br, wk, nullif(btrim(p->>'pay_bank'), ''), nullif(btrim(p->>'pay_account_no'), ''), nullif(btrim(p->>'pay_account_name'), ''),
            nullif(p->>'opening_balance', '')::numeric, nullif(btrim(p->>'notes'), ''), coalesce(nullif(p->>'source', ''), 'app'), auth.uid())
    RETURNING id INTO rid;
  ELSE
    UPDATE public.cash_requests SET week_ending = wk, pay_bank = nullif(btrim(p->>'pay_bank'), ''), pay_account_no = nullif(btrim(p->>'pay_account_no'), ''),
           pay_account_name = nullif(btrim(p->>'pay_account_name'), ''), opening_balance = nullif(p->>'opening_balance', '')::numeric,
           notes = nullif(btrim(p->>'notes'), '') WHERE id = rid;
    DELETE FROM public.cash_request_lines WHERE request_id = rid AND pay_sheet_id IS NULL;   -- the casual wages line stays (115)
  END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p->'lines', '[]'::jsonb)) LOOP
    n := n + 1;
    IF nullif(btrim(x->>'description'), '') IS NULL THEN RAISE EXCEPTION 'Line %: say what it is for', n USING ERRCODE = '23514'; END IF;
    IF nullif(x->>'amount', '')::numeric IS NULL OR (x->>'amount')::numeric < 0 THEN RAISE EXCEPTION 'Line %: enter the amount', n USING ERRCODE = '23514'; END IF;
    INSERT INTO public.cash_request_lines (organization_id, request_id, line_no, description, quantity, unit, amount, category_id, note)
    VALUES (org, rid, n, btrim(x->>'description'), nullif(x->>'quantity', '')::numeric, nullif(btrim(x->>'unit'), ''), round((x->>'amount')::numeric, 2),
            nullif(x->>'category_id', '')::uuid, nullif(btrim(x->>'note'), ''));
  END LOOP;
  RETURN rid;
END;
$$;


-- 3. an approved casual sheet goes on its Saturday's request; un-approved, it comes off
CREATE OR REPLACE FUNCTION public.casual_wages_to_cash_request()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rq  public.cash_requests;
  tot numeric;
  cat uuid;
  ln  int;
BEGIN
  IF NEW.cycle <> 'weekly' OR NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NULL; END IF;
  IF NEW.status = 'approved' THEN
    SELECT * INTO rq FROM public.cash_requests
     WHERE branch_id = NEW.branch_id AND week_ending = NEW.period_end AND status NOT IN ('cancelled', 'rejected') FOR UPDATE;
    IF FOUND AND rq.status <> 'draft' THEN
      RAISE EXCEPTION 'The weekly cash request for % has already been sent — the casual wages can''t be added to it', to_char(NEW.period_end, 'DD Mon YYYY') USING ERRCODE = '23514';
    END IF;
    IF NOT FOUND THEN
      INSERT INTO public.cash_requests (organization_id, branch_id, week_ending, prepared_by, notes)
      VALUES (NEW.organization_id, NEW.branch_id, NEW.period_end, auth.uid(), 'Started from the casuals'' pay sheet')
      RETURNING * INTO rq;
    END IF;
    SELECT coalesce(sum(amount), 0) INTO tot FROM public.pay_sheet_lines WHERE sheet_id = NEW.id;
    SELECT id INTO cat FROM public.expense_categories WHERE organization_id = NEW.organization_id AND name ILIKE 'wages' LIMIT 1;
    SELECT coalesce(min(line_no), 1) - 1 INTO ln FROM public.cash_request_lines WHERE request_id = rq.id;
    INSERT INTO public.cash_request_lines (organization_id, request_id, line_no, description, amount, category_id, pay_sheet_id)
    VALUES (NEW.organization_id, rq.id, ln, 'Casual wages · ' || to_char(NEW.period_start, 'DD Mon') || ' – ' || to_char(NEW.period_end, 'DD Mon YYYY'), round(tot, 2), cat, NEW.id)
    ON CONFLICT (pay_sheet_id) WHERE pay_sheet_id IS NOT NULL DO UPDATE SET amount = EXCLUDED.amount, request_id = EXCLUDED.request_id;
  ELSIF OLD.status = 'approved' AND NEW.status IN ('draft', 'void') THEN
    DELETE FROM public.cash_request_lines l USING public.cash_requests r
     WHERE l.pay_sheet_id = NEW.id AND r.id = l.request_id AND r.status = 'draft';
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS trg_casual_wages_to_cash_request ON public.pay_sheets;
CREATE TRIGGER trg_casual_wages_to_cash_request AFTER UPDATE OF status ON public.pay_sheets
  FOR EACH ROW EXECUTE FUNCTION public.casual_wages_to_cash_request();

-- 4. one-off: weekly draft sheets made Monday to Sunday are remade Sunday to Saturday from attendance
DO $$
DECLARE r record;
BEGIN
  UPDATE public.pay_sheets SET status = 'void', notes = coalesce(notes || ' · ', '') || 'Remade Sunday to Saturday (115)'
   WHERE cycle = 'weekly' AND status = 'draft' AND extract(dow FROM period_start) <> 0;
  FOR r IN
    SELECT DISTINCT st.organization_id, st.branch_id, a.work_date
      FROM public.staff_attendance a JOIN public.staff st ON st.id = a.staff_id
     WHERE public.cycle_of_staff(st) = 'weekly' AND a.work_date >= DATE '2026-11-01'
       AND NOT EXISTS (SELECT 1 FROM public.pay_sheets s WHERE s.branch_id = st.branch_id AND s.cycle = 'weekly'
                         AND s.status IN ('approved', 'paid') AND a.work_date BETWEEN s.period_start AND s.period_end)
  LOOP
    PERFORM public.ensure_pay_sheet(r.organization_id, r.branch_id, 'weekly', r.work_date);
  END LOOP;
END;
$$;
