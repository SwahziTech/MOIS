-- ============================================================
-- 078 — Weekly operations cash: request, approvals, payment (1c/finance)
--
-- SwahziTech, 2026-10-28: each week a branch asks for the cash it needs
-- (wages, allowances, tools, loading, transport, fees, extra…). The request
-- is prepared by the secretary or branch manager, approved by the branch
-- manager and sent to the directors, approved by the directors (who may trim
-- lines), and paid to the branch's receiving account in one payment.
-- Last week's summary (cash in, what was spent, balance) is a report read
-- from what was recorded — expenses and purchase payments — not entered here.
-- A request is marked by the Saturday ending the week it is for. It can be
-- imported from the branch's Excel sheet or filled in MOIS, and exported.
-- Names, accounts and amounts are entered in the app only.
-- ============================================================

INSERT INTO public.permissions (code, description, module) VALUES
  ('cash.request',        'Prepare the weekly cash request', 'finance'),
  ('cash.branch_approve', 'Approve the weekly cash request and send it to the directors', 'finance'),
  ('cash.approve',        'Approve weekly cash requests and record the payment', 'finance')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code IN ('cash.request', 'cash.branch_approve', 'cash.approve')
WHERE r.is_system_role AND r.name IN ('owner', 'director')
ON CONFLICT DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code IN ('cash.request', 'cash.branch_approve')
WHERE r.is_system_role AND r.name = 'branch_manager'
ON CONFLICT DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code = 'cash.request'
WHERE r.is_system_role AND r.name = 'secretary'
ON CONFLICT DO NOTHING;

-- the account a branch receives its weekly cash into (number and name, printed on the request)
ALTER TABLE public.payment_accounts
  ADD COLUMN account_no   text,
  ADD COLUMN account_name text,
  ADD COLUMN receives_weekly_cash boolean NOT NULL DEFAULT false;

CREATE TABLE public.cash_requests (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id         uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  week_ending       date NOT NULL CHECK (extract(isodow FROM week_ending) = 6),   -- a Saturday
  status            text NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'with_directors', 'approved', 'rejected', 'paid', 'cancelled')),
  account_id        uuid REFERENCES public.payment_accounts(id) ON DELETE RESTRICT,   -- paid into
  opening_balance   numeric,            -- the first week's balance brought forward; later weeks carry it
  notes             text,
  source            text NOT NULL DEFAULT 'app' CHECK (source IN ('app', 'excel')),
  prepared_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  sent_by           uuid REFERENCES auth.users(id) ON DELETE SET NULL,   -- the branch manager who approved and sent it
  sent_at           timestamptz,
  decided_by        uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  decided_at        timestamptz,
  decision_note     text,
  paid_on           date,
  paid_amount       numeric CHECK (paid_amount >= 0),
  paid_reference    text,
  paid_by           uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_cash_requests_week ON public.cash_requests (branch_id, week_ending) WHERE status NOT IN ('cancelled', 'rejected');
CREATE TABLE public.cash_request_lines (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  request_id      uuid NOT NULL REFERENCES public.cash_requests(id) ON DELETE CASCADE,
  line_no         int  NOT NULL,
  description     text NOT NULL CHECK (btrim(description) <> ''),
  quantity        numeric,
  unit            text,                  -- as written: KG, PCS, SQM, LTR, BOX…
  amount          numeric NOT NULL CHECK (amount >= 0),            -- asked
  approved_amount numeric CHECK (approved_amount >= 0),            -- set by the directors (NULL = as asked)
  category_id     uuid REFERENCES public.expense_categories(id) ON DELETE SET NULL,
  note            text
);
CREATE INDEX idx_cash_requests_branch ON public.cash_requests (branch_id, week_ending DESC);
CREATE TRIGGER trg_cash_requests_updated_at BEFORE UPDATE ON public.cash_requests FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_cash_requests_audit AFTER INSERT OR UPDATE OR DELETE ON public.cash_requests FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('cash_request', 'id');
CREATE TRIGGER trg_cash_requests_no_delete BEFORE DELETE ON public.cash_requests FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('cash request');
CREATE TRIGGER trg_cash_request_lines_audit AFTER INSERT OR UPDATE OR DELETE ON public.cash_request_lines FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('cash_request_line', 'id');
ALTER TABLE public.cash_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_request_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cash_requests: who handle cash read" ON public.cash_requests FOR SELECT
  USING (organization_id = public.get_my_org_id() AND public.has_permission_at('cash.request', branch_id, NULL));
CREATE POLICY "cash_request_lines: who handle cash read" ON public.cash_request_lines FOR SELECT
  USING (organization_id = public.get_my_org_id()
         AND EXISTS (SELECT 1 FROM public.cash_requests r WHERE r.id = request_id AND public.has_permission_at('cash.request', r.branch_id, NULL)));

-- ------------------------------------------------------------
-- Save a draft — p: { id?, branch_id, week_ending, account_id?, opening_balance?, notes?, source?,
--                     lines: [{ description, quantity?, unit?, amount, category_id?, note? }] }
-- ------------------------------------------------------------
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
  IF nullif(p->>'account_id', '') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.payment_accounts WHERE id = (p->>'account_id')::uuid AND branch_id = br) THEN
    RAISE EXCEPTION 'Choose an account of this branch' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (SELECT 1 FROM public.cash_requests WHERE branch_id = br AND week_ending = wk AND status NOT IN ('cancelled', 'rejected') AND id IS DISTINCT FROM rid) THEN
    RAISE EXCEPTION 'There is already a request for the week ending %', wk USING ERRCODE = '23514';
  END IF;
  IF rid IS NULL THEN
    INSERT INTO public.cash_requests (organization_id, branch_id, week_ending, account_id, opening_balance, notes, source, prepared_by)
    VALUES (org, br, wk, nullif(p->>'account_id', '')::uuid, nullif(p->>'opening_balance', '')::numeric, nullif(btrim(p->>'notes'), ''),
            coalesce(nullif(p->>'source', ''), 'app'), auth.uid())
    RETURNING id INTO rid;
  ELSE
    UPDATE public.cash_requests SET week_ending = wk, account_id = nullif(p->>'account_id', '')::uuid,
           opening_balance = nullif(p->>'opening_balance', '')::numeric, notes = nullif(btrim(p->>'notes'), '') WHERE id = rid;
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

-- ------------------------------------------------------------
-- The steps: send (branch manager approves) → directors approve (may trim lines) or turn down → paid; cancel a draft
-- p for 'approve': { lines: [{ id, approved_amount }]?, note? } ; for 'pay': { paid_on, amount, reference?, account_id? }
-- ------------------------------------------------------------
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
           account_id = coalesce(nullif(p->>'account_id', '')::uuid, account_id), paid_by = auth.uid() WHERE id = r.id;
  ELSIF p_step = 'cancel' THEN
    IF r.status NOT IN ('draft', 'with_directors') THEN RAISE EXCEPTION 'It can''t be cancelled now' USING ERRCODE = '23514'; END IF;
    IF NOT public.has_permission_at('cash.request', r.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t cancel it' USING ERRCODE = '42501'; END IF;
    UPDATE public.cash_requests SET status = 'cancelled' WHERE id = r.id;
  ELSE
    RAISE EXCEPTION 'Unknown step' USING ERRCODE = '23514';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.save_cash_request(jsonb), public.cash_request_step(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_cash_request(jsonb), public.cash_request_step(uuid, text, jsonb) TO authenticated;
