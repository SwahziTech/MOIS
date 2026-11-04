-- ============================================================
-- 106 — What directors pay, with its proof, seen by the branch
-- ============================================================
-- SwahziTech, 2026-11-04, the user: directors pay almost everything —
-- suppliers, bills and expenses, weekly cash, salaries. One Pay window: they
-- choose what is paid (or type it), the amount, the account and the proof
-- (photo/PDF or the SMS) — required, with the payment. The branch manager,
-- the secretary and the other directors mark it Seen, so everyone knows the
-- order or request is paid.
--   * director_payments: kind (supplier, expense, weekly_cash, salaries,
--     other), the thing paid (a purchase, expense, weekly request or pay
--     sheet) or a typed description, amount, account, date, proof.
--     The payment itself goes through MOIS's own step first (supplier
--     payment, weekly cash 'pay', paying the pay sheet); this keeps the proof.
--   * director_payment_seen: who has seen it, and when.
--   * finance.pay: owner (technical admin) and directors post them.
--   * Files in the private bucket director-proofs, at <org>/<branch>/dp/<file>.
-- ============================================================

INSERT INTO public.permissions (code, description, module) VALUES
  ('finance.pay', 'Record what the directors pay, with its proof', 'finance')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code = 'finance.pay'
WHERE r.is_system_role AND r.name IN ('owner', 'director')
ON CONFLICT DO NOTHING;

-- who sees what directors pay at a branch: directors, the branch manager, the secretary
CREATE OR REPLACE FUNCTION public.can_see_director_payments(p_branch uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.has_permission_at('finance.pay', p_branch, NULL) OR public.has_permission_at('finance.view', p_branch, NULL)
      OR public.has_permission_at('cash.request', p_branch, NULL) OR public.has_permission_at('sales.create', p_branch, NULL)
$$;
REVOKE ALL ON FUNCTION public.can_see_director_payments(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_see_director_payments(uuid) TO authenticated;

CREATE TABLE public.director_payments (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id),
  branch_id       uuid NOT NULL REFERENCES public.branches(id),
  kind            text NOT NULL CHECK (kind IN ('supplier', 'expense', 'weekly_cash', 'salaries', 'other')),
  ref_id          uuid,                        -- the purchase, expense, weekly request or pay sheet paid
  description     text,
  amount          numeric NOT NULL CHECK (amount > 0),
  account_id      uuid REFERENCES public.payment_accounts(id),
  paid_on         date NOT NULL,
  file_path       text,
  file_name       text,
  sms_text        text,
  created_by      uuid REFERENCES public.profiles(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (file_path IS NOT NULL OR nullif(btrim(sms_text), '') IS NOT NULL),
  CHECK (kind = 'other' OR ref_id IS NOT NULL OR nullif(btrim(description), '') IS NOT NULL)
);
CREATE INDEX idx_director_payments_branch ON public.director_payments (branch_id, paid_on DESC);
COMMENT ON TABLE public.director_payments IS 'What directors pay (supplier, expense, weekly cash, salaries, other) with the proof; seen by the branch (106).';
CREATE TRIGGER trg_director_payments_audit AFTER INSERT OR UPDATE OR DELETE ON public.director_payments FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('director_payment', 'organization_id');
CREATE TRIGGER trg_director_payments_no_delete BEFORE DELETE ON public.director_payments FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('director payment');
ALTER TABLE public.director_payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "director_payments: read" ON public.director_payments FOR SELECT TO authenticated
  USING (organization_id = public.get_my_org_id() AND public.can_see_director_payments(branch_id));
REVOKE ALL ON public.director_payments FROM PUBLIC, anon;
GRANT SELECT ON public.director_payments TO authenticated;

CREATE TABLE public.director_payment_seen (
  payment_id      uuid NOT NULL REFERENCES public.director_payments(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES public.profiles(id),
  organization_id uuid NOT NULL REFERENCES public.organizations(id),
  seen_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (payment_id, user_id)
);
ALTER TABLE public.director_payment_seen ENABLE ROW LEVEL SECURITY;
CREATE POLICY "director_payment_seen: read" ON public.director_payment_seen FOR SELECT TO authenticated
  USING (organization_id = public.get_my_org_id());
REVOKE ALL ON public.director_payment_seen FROM PUBLIC, anon;
GRANT SELECT ON public.director_payment_seen TO authenticated;

-- A director's payment and its proof (the payment itself already went through MOIS's own step)
CREATE OR REPLACE FUNCTION public.post_director_payment(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org  uuid := public.get_my_org_id();
  br   uuid := nullif(p->>'branch_id', '')::uuid;
  k    text := p->>'kind';
  ref  uuid := nullif(p->>'ref_id', '')::uuid;
  fp   text := nullif(btrim(p->>'file_path'), '');
  txt  text := nullif(btrim(p->>'sms_text'), '');
  amt  numeric := round(nullif(p->>'amount', '')::numeric, 2);
  dt   date := nullif(p->>'paid_on', '')::date;
  acc  uuid := nullif(p->>'account_id', '')::uuid;
  rid  uuid;
BEGIN
  IF br IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = br AND organization_id = org) THEN
    RAISE EXCEPTION 'Choose the branch' USING ERRCODE = '23514';
  END IF;
  IF NOT public.has_permission_at('finance.pay', br, NULL) THEN RAISE EXCEPTION 'Only directors record these payments' USING ERRCODE = '42501'; END IF;
  IF k IS NULL OR k NOT IN ('supplier', 'expense', 'weekly_cash', 'salaries', 'other') THEN RAISE EXCEPTION 'Choose what is paid' USING ERRCODE = '23514'; END IF;
  IF amt IS NULL OR amt <= 0 THEN RAISE EXCEPTION 'Enter the amount' USING ERRCODE = '23514'; END IF;
  IF dt IS NULL OR dt > public.org_today(org) THEN RAISE EXCEPTION 'Choose the date it was paid' USING ERRCODE = '23514'; END IF;
  IF fp IS NULL AND txt IS NULL THEN RAISE EXCEPTION 'Add the proof: a photo or the SMS' USING ERRCODE = '23514'; END IF;
  IF fp IS NOT NULL AND fp NOT LIKE org::text || '/' || br::text || '/%' THEN RAISE EXCEPTION 'That file belongs elsewhere' USING ERRCODE = '42501'; END IF;
  IF acc IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.payment_accounts WHERE id = acc AND organization_id = org) THEN
    RAISE EXCEPTION 'Account not found' USING ERRCODE = '23514';
  END IF;
  -- the thing paid belongs to this company and branch
  IF k = 'supplier' AND NOT EXISTS (SELECT 1 FROM public.purchases WHERE id = ref AND organization_id = org AND branch_id = br) THEN
    RAISE EXCEPTION 'Choose the purchase' USING ERRCODE = '23514';
  ELSIF k = 'expense' AND ref IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.expenses WHERE id = ref AND organization_id = org AND branch_id = br) THEN
    RAISE EXCEPTION 'Expense not found' USING ERRCODE = '23514';
  ELSIF k = 'weekly_cash' AND NOT EXISTS (SELECT 1 FROM public.cash_requests WHERE id = ref AND organization_id = org AND branch_id = br) THEN
    RAISE EXCEPTION 'Choose the weekly request' USING ERRCODE = '23514';
  ELSIF k = 'salaries' AND NOT EXISTS (SELECT 1 FROM public.pay_sheets WHERE id = ref AND organization_id = org AND branch_id = br) THEN
    RAISE EXCEPTION 'Choose the pay sheet' USING ERRCODE = '23514';
  ELSIF k IN ('expense', 'other') AND ref IS NULL AND nullif(btrim(p->>'description'), '') IS NULL THEN
    RAISE EXCEPTION 'Write what was paid' USING ERRCODE = '23514';
  END IF;
  INSERT INTO public.director_payments (organization_id, branch_id, kind, ref_id, description, amount, account_id, paid_on, file_path, file_name, sms_text, created_by)
  VALUES (org, br, k, ref, nullif(btrim(p->>'description'), ''), amt, acc, dt, fp, nullif(btrim(p->>'file_name'), ''), txt, auth.uid())
  RETURNING id INTO rid;
  -- the director who paid has seen it
  INSERT INTO public.director_payment_seen (payment_id, user_id, organization_id) VALUES (rid, auth.uid(), org);
  RETURN rid;
END;
$$;
REVOKE ALL ON FUNCTION public.post_director_payment(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_director_payment(jsonb) TO authenticated;

-- Seen: the branch manager, the secretary, another director
CREATE OR REPLACE FUNCTION public.mark_director_payment_seen(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d public.director_payments;
BEGIN
  SELECT * INTO d FROM public.director_payments WHERE id = p_id AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.can_see_director_payments(d.branch_id) THEN RAISE EXCEPTION 'You can''t see this payment' USING ERRCODE = '42501'; END IF;
  INSERT INTO public.director_payment_seen (payment_id, user_id, organization_id) VALUES (d.id, auth.uid(), d.organization_id)
  ON CONFLICT (payment_id, user_id) DO NOTHING;
END;
$$;
REVOKE ALL ON FUNCTION public.mark_director_payment_seen(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_director_payment_seen(uuid) TO authenticated;

-- The files
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('director-proofs', 'director-proofs', false, 10485760, ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'application/pdf'])
ON CONFLICT (id) DO NOTHING;
CREATE POLICY "director-proofs: read" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'director-proofs'
    AND split_part(name, '/', 1) = public.get_my_org_id()::text
    AND public.can_see_director_payments(public.report_file_branch(name)));
CREATE POLICY "director-proofs: add" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'director-proofs'
    AND split_part(name, '/', 1) = public.get_my_org_id()::text
    AND public.has_permission_at('finance.pay', public.report_file_branch(name), NULL));
