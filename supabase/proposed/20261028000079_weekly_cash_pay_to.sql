-- ============================================================
-- 079 — Weekly cash: where it is paid, on the request itself
--
-- SwahziTech, 2026-10-28: the account the branch is paid into belongs to the
-- weekly cash request, not to Sales — written at the end of the request (bank,
-- account number, account name) and carried from the previous week's. The
-- columns 078 added to the sales receiving accounts are removed.
-- ============================================================

ALTER TABLE public.cash_requests
  ADD COLUMN pay_bank         text,
  ADD COLUMN pay_account_no   text,
  ADD COLUMN pay_account_name text;
UPDATE public.cash_requests r SET pay_bank = a.name, pay_account_no = a.account_no, pay_account_name = a.account_name
FROM public.payment_accounts a WHERE a.id = r.account_id;
ALTER TABLE public.cash_requests DROP COLUMN account_id;
ALTER TABLE public.payment_accounts DROP COLUMN account_no, DROP COLUMN account_name, DROP COLUMN receives_weekly_cash;

-- as 078, with the pay-to details in place of a sales account
-- p: { id?, branch_id, week_ending, pay_bank?, pay_account_no?, pay_account_name?, opening_balance?, notes?, source?, lines: [...] }
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
  IF jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines') = 0 THEN RAISE EXCEPTION 'Add what is needed' USING ERRCODE = '23514'; END IF;
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
    DELETE FROM public.cash_request_lines WHERE request_id = rid;
  END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
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

-- the payment step no longer names a sales account (078's took account_id); the rest as 078
CREATE OR REPLACE FUNCTION public.cash_request_step(p_id uuid, p_step text, p jsonb DEFAULT '{}'::jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r public.cash_requests;
  x jsonb;
  amt numeric;
BEGIN
  SELECT * INTO r FROM public.cash_requests WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Request not found' USING ERRCODE = '23514'; END IF;
  IF p_step = 'send' THEN
    IF r.status <> 'draft' THEN RAISE EXCEPTION 'Only a draft can be sent' USING ERRCODE = '23514'; END IF;
    IF NOT public.has_permission_at('cash.branch_approve', r.branch_id, NULL) THEN RAISE EXCEPTION 'The branch manager approves and sends it' USING ERRCODE = '42501'; END IF;
    UPDATE public.cash_requests SET status = 'with_directors', sent_by = auth.uid(), sent_at = now() WHERE id = r.id;
  ELSIF p_step = 'back_to_draft' THEN
    IF r.status <> 'with_directors' THEN RAISE EXCEPTION 'Only a request with the directors can come back' USING ERRCODE = '23514'; END IF;
    IF NOT (public.has_permission_at('cash.branch_approve', r.branch_id, NULL) OR public.has_permission_at('cash.approve', r.branch_id, NULL)) THEN
      RAISE EXCEPTION 'You can''t take it back' USING ERRCODE = '42501';
    END IF;
    UPDATE public.cash_requests SET status = 'draft', decision_note = coalesce(nullif(btrim(p->>'note'), ''), decision_note) WHERE id = r.id;
  ELSIF p_step IN ('approve', 'reject') THEN
    IF r.status <> 'with_directors' THEN RAISE EXCEPTION 'It is not with the directors' USING ERRCODE = '23514'; END IF;
    IF NOT public.has_permission_at('cash.approve', r.branch_id, NULL) THEN RAISE EXCEPTION 'Only directors approve weekly cash' USING ERRCODE = '42501'; END IF;
    IF p_step = 'reject' AND nullif(btrim(p->>'note'), '') IS NULL THEN RAISE EXCEPTION 'Say why it is turned down' USING ERRCODE = '23514'; END IF;
    IF p_step = 'approve' AND jsonb_typeof(p->'lines') = 'array' THEN
      FOR x IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
        amt := nullif(x->>'approved_amount', '')::numeric;
        IF amt IS NOT NULL AND amt < 0 THEN RAISE EXCEPTION 'An approved amount can''t be negative' USING ERRCODE = '23514'; END IF;
        UPDATE public.cash_request_lines SET approved_amount = amt WHERE id = (x->>'id')::uuid AND request_id = r.id;
      END LOOP;
    END IF;
    UPDATE public.cash_requests SET status = CASE WHEN p_step = 'approve' THEN 'approved' ELSE 'rejected' END,
           decided_by = auth.uid(), decided_at = now(), decision_note = nullif(btrim(p->>'note'), '') WHERE id = r.id;
  ELSIF p_step = 'pay' THEN
    IF r.status <> 'approved' THEN RAISE EXCEPTION 'Approve it first' USING ERRCODE = '23514'; END IF;
    IF NOT public.has_permission_at('cash.approve', r.branch_id, NULL) THEN RAISE EXCEPTION 'Only directors record the payment' USING ERRCODE = '42501'; END IF;
    amt := round(nullif(p->>'amount', '')::numeric, 2);
    IF amt IS NULL OR amt <= 0 THEN RAISE EXCEPTION 'Enter the amount sent' USING ERRCODE = '23514'; END IF;
    IF nullif(p->>'paid_on', '')::date IS NULL OR (p->>'paid_on')::date > public.org_today(r.organization_id) THEN RAISE EXCEPTION 'Choose the date it was sent' USING ERRCODE = '23514'; END IF;
    UPDATE public.cash_requests SET status = 'paid', paid_on = (p->>'paid_on')::date, paid_amount = amt, paid_reference = nullif(btrim(p->>'reference'), ''),
           paid_by = auth.uid() WHERE id = r.id;
  ELSIF p_step = 'cancel' THEN
    IF r.status NOT IN ('draft', 'with_directors') THEN RAISE EXCEPTION 'It can''t be cancelled now' USING ERRCODE = '23514'; END IF;
    IF NOT public.has_permission_at('cash.request', r.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t cancel it' USING ERRCODE = '42501'; END IF;
    UPDATE public.cash_requests SET status = 'cancelled' WHERE id = r.id;
  ELSE
    RAISE EXCEPTION 'Unknown step' USING ERRCODE = '23514';
  END IF;
END;
$$;
