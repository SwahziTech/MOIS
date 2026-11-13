-- ============================================================
-- 121 — Weekly cash: only what was paid from the weekly cash; last week as on the sheet
-- ============================================================
-- SwahziTech, 2026-11-13: the weekly sheet is the operations cash the directors send to the
-- branch. Cement, sand and other buying paid by the directors is not on it. So each payment
-- says where the money came from:
--   * expenses.from_weekly_cash, purchase_payments.from_weekly_cash — paid from the branch's
--     weekly cash (true) or by the directors / a bank (false). Chosen on the forms; existing
--     records start as false and can be ticked in from the weekly sheet.
--   * set_weekly_cash(kind, id, on) — sets it ('expense', 'purchase_payment', or 'purchase' for
--     all of a purchase's payments); whoever records purchases or prepares the weekly cash.
--   * cash_requests.last_week — the first week in MOIS: last week's summary kept exactly as on the
--     imported sheet { rows: [{ date, description, qty, cash_in, cash_out, balance }] }; from
--     the next week MOIS builds it from its own records.
-- ============================================================

ALTER TABLE public.expenses ADD COLUMN from_weekly_cash boolean NOT NULL DEFAULT false;
ALTER TABLE public.purchase_payments ADD COLUMN from_weekly_cash boolean NOT NULL DEFAULT false;
ALTER TABLE public.cash_requests ADD COLUMN last_week jsonb;
COMMENT ON COLUMN public.expenses.from_weekly_cash IS 'Paid from the branch''s weekly operations cash (121) — counted on the weekly sheet.';
COMMENT ON COLUMN public.purchase_payments.from_weekly_cash IS 'Paid from the branch''s weekly operations cash (121) — counted on the weekly sheet.';
COMMENT ON COLUMN public.cash_requests.last_week IS 'First week in MOIS: last week''s summary as on the imported sheet (121).';

CREATE OR REPLACE FUNCTION public.set_weekly_cash(p_kind text, p_id uuid, p_on boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  br  uuid;
BEGIN
  IF p_kind = 'expense' THEN
    SELECT branch_id INTO br FROM public.expenses WHERE id = p_id AND organization_id = org;
  ELSIF p_kind IN ('purchase_payment', 'purchase') THEN
    SELECT pu.branch_id INTO br FROM public.purchases pu
      WHERE pu.organization_id = org
        AND pu.id = CASE WHEN p_kind = 'purchase' THEN p_id ELSE (SELECT purchase_id FROM public.purchase_payments WHERE id = p_id) END;
  ELSE
    RAISE EXCEPTION 'Unknown kind' USING ERRCODE = '23514';
  END IF;
  IF br IS NULL THEN RAISE EXCEPTION 'Not found' USING ERRCODE = '23514'; END IF;
  IF NOT (public.has_permission_at('procurement.receive', br, NULL) OR public.has_permission_at('cash.request', br, NULL)) THEN
    RAISE EXCEPTION 'You can''t change this at this branch' USING ERRCODE = '42501';
  END IF;
  IF p_kind = 'expense' THEN UPDATE public.expenses SET from_weekly_cash = coalesce(p_on, false) WHERE id = p_id;
  ELSIF p_kind = 'purchase' THEN UPDATE public.purchase_payments SET from_weekly_cash = coalesce(p_on, false) WHERE purchase_id = p_id;
  ELSE UPDATE public.purchase_payments SET from_weekly_cash = coalesce(p_on, false) WHERE id = p_id; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.set_weekly_cash(text, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_weekly_cash(text, uuid, boolean) TO authenticated;

-- save_cash_request (115), now keeping last_week
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
    INSERT INTO public.cash_requests (organization_id, branch_id, week_ending, pay_bank, pay_account_no, pay_account_name, opening_balance, notes, source, prepared_by, last_week)
    VALUES (org, br, wk, nullif(btrim(p->>'pay_bank'), ''), nullif(btrim(p->>'pay_account_no'), ''), nullif(btrim(p->>'pay_account_name'), ''),
            nullif(p->>'opening_balance', '')::numeric, nullif(btrim(p->>'notes'), ''), coalesce(nullif(p->>'source', ''), 'app'), auth.uid(),
            CASE WHEN jsonb_typeof(p->'last_week') = 'object' THEN p->'last_week' END)
    RETURNING id INTO rid;
  ELSE
    UPDATE public.cash_requests SET week_ending = wk, pay_bank = nullif(btrim(p->>'pay_bank'), ''), pay_account_no = nullif(btrim(p->>'pay_account_no'), ''),
           pay_account_name = nullif(btrim(p->>'pay_account_name'), ''), opening_balance = nullif(p->>'opening_balance', '')::numeric,
           notes = nullif(btrim(p->>'notes'), ''),
           last_week = CASE WHEN p ? 'last_week' THEN CASE WHEN jsonb_typeof(p->'last_week') = 'object' THEN p->'last_week' END ELSE last_week END
     WHERE id = rid;
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

