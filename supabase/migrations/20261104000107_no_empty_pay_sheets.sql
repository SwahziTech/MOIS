-- ============================================================
-- 107 — No empty pay sheets
-- ============================================================
-- SwahziTech, 2026-11-04, the user: "Stop making empty sheets". A pay sheet
-- with nobody on it showed as "to approve" on the director's dashboard.
--   * Preparing a pay sheet by hand for a period nobody worked is refused.
--   * A draft left with nobody on it (attendance unticked) is voided,
--     reason "Nobody on it"; a new tick later makes a fresh sheet.
--   * Drafts already empty are voided the same way, once.
-- Approving an empty sheet was already refused.
-- ============================================================

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
  -- nobody worked in the period: no sheet (107)
  IF NOT EXISTS (SELECT 1 FROM public.pay_sheet_lines WHERE sheet_id = sid) THEN
    RAISE EXCEPTION 'Nobody worked in that period — no pay sheet made' USING ERRCODE = '23514';
  END IF;
  RETURN sid;
END;
$$;

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
  -- left with nobody (attendance unticked): the draft goes, voided with its reason (107)
  IF NOT EXISTS (SELECT 1 FROM public.pay_sheet_lines WHERE sheet_id = p_sheet) THEN
    UPDATE public.pay_sheets SET status = 'void', void_reason = 'Nobody on it' WHERE id = p_sheet AND status = 'draft';
  END IF;
END;
$$;

UPDATE public.pay_sheets s SET status = 'void', void_reason = 'Nobody on it'
WHERE s.status = 'draft' AND NOT EXISTS (SELECT 1 FROM public.pay_sheet_lines l WHERE l.sheet_id = s.id);
