-- ============================================================
-- 124 — An expense's date, changed from the weekly cash sheet
-- ============================================================
-- SwahziTech, 2026-11-16 (the user): the spending items of an imported weekly cash sheet are
-- recorded as expenses when the branch manager posts it; their dates are often not on the sheet.
-- Changing an item's Date in "Last week's spending" moves the expense it recorded to that day.
--   * set_expense_date(id, date) — the expense's date (and its paid date, when paid). Only a
--     recorded expense, not after today; whoever may change expenses at that branch
--     (procurement.receive, as for editing and voiding them).
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_expense_date(p_id uuid, p_date date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ex public.expenses;
BEGIN
  SELECT * INTO ex FROM public.expenses WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND OR ex.status <> 'recorded' THEN RAISE EXCEPTION 'Expense not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.receive', ex.branch_id, NULL) THEN
    RAISE EXCEPTION 'You can''t change expenses at this branch' USING ERRCODE = '42501';
  END IF;
  IF p_date IS NULL OR p_date > public.org_today(ex.organization_id) THEN
    RAISE EXCEPTION 'Choose a date up to today' USING ERRCODE = '23514';
  END IF;
  UPDATE public.expenses SET expense_date = p_date, paid_on = CASE WHEN paid_on IS NOT NULL THEN p_date END WHERE id = p_id;
END;
$$;
REVOKE ALL ON FUNCTION public.set_expense_date(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_expense_date(uuid, date) TO authenticated;
