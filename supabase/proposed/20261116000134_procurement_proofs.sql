-- ============================================================
-- 134 — Proof of payment on purchases and expenses
-- ============================================================
-- SwahziTech, 2026-11-16 (the user): "for purchases and expenses introduce the add proof icon; once rows
-- are open the user can add proof of payments." Whoever records purchases (procurement.receive) or the
-- directors (finance.pay) attach a slip photo / PDF or the SMS to a purchase or an expense. Kept beside
-- the directors' own proofs (106); the files go to the payment-proofs store under '<org>/<branch>/procurement/'.
-- ============================================================

CREATE TABLE public.procurement_proofs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  kind            text NOT NULL CHECK (kind IN ('purchase', 'expense')),
  ref_id          uuid NOT NULL,                 -- the purchase or the expense
  paid_on         date,
  amount          numeric CHECK (amount >= 0),
  file_path       text,
  file_name       text,
  sms_text        text,
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (file_path IS NOT NULL OR nullif(btrim(sms_text), '') IS NOT NULL)
);
CREATE INDEX idx_procurement_proofs_ref ON public.procurement_proofs (ref_id);
CREATE TRIGGER trg_procurement_proofs_audit AFTER INSERT OR UPDATE OR DELETE ON public.procurement_proofs FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('procurement_proof', 'organization_id');
ALTER TABLE public.procurement_proofs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "procurement_proofs: read" ON public.procurement_proofs FOR SELECT
  USING (organization_id = public.get_my_org_id()
         AND (public.has_permission_at('procurement.view', branch_id, NULL) OR public.can_see_director_payments(branch_id)));

CREATE OR REPLACE FUNCTION public.add_procurement_proof(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  k   text := p->>'kind';
  ref uuid := nullif(p->>'ref_id', '')::uuid;
  br  uuid;
  rid uuid;
BEGIN
  IF k = 'purchase' THEN SELECT branch_id INTO br FROM public.purchases WHERE id = ref AND organization_id = org;
  ELSIF k = 'expense' THEN SELECT branch_id INTO br FROM public.expenses WHERE id = ref AND organization_id = org;
  ELSE RAISE EXCEPTION 'A purchase or an expense' USING ERRCODE = '23514'; END IF;
  IF br IS NULL THEN RAISE EXCEPTION 'Not found' USING ERRCODE = '23514'; END IF;
  IF NOT (public.has_permission_at('procurement.receive', br, NULL) OR public.has_permission_at('finance.pay', br, NULL)) THEN
    RAISE EXCEPTION 'You can''t add proofs at this branch' USING ERRCODE = '42501';
  END IF;
  IF nullif(p->>'file_path', '') IS NULL AND nullif(btrim(p->>'sms_text'), '') IS NULL THEN
    RAISE EXCEPTION 'Add the proof: a photo, a PDF or the SMS' USING ERRCODE = '23514';
  END IF;
  INSERT INTO public.procurement_proofs (organization_id, branch_id, kind, ref_id, paid_on, amount, file_path, file_name, sms_text, created_by)
  VALUES (org, br, k, ref, nullif(p->>'paid_on', '')::date, nullif(p->>'amount', '')::numeric, nullif(p->>'file_path', ''),
          nullif(p->>'file_name', ''), nullif(btrim(p->>'sms_text'), ''), auth.uid())
  RETURNING id INTO rid;
  RETURN rid;
END;
$$;
REVOKE ALL ON FUNCTION public.add_procurement_proof(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_procurement_proof(jsonb) TO authenticated;

-- the file store: '<org>/<branch>/procurement/…' in payment-proofs is for purchase / expense proofs
CREATE OR REPLACE FUNCTION public.file_access(p_key text, p_write boolean DEFAULT false)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  bucket text := split_part(p_key, '/', 1);
  name   text := substr(p_key, length(split_part(p_key, '/', 1)) + 2);
  br     uuid;
BEGIN
  IF auth.uid() IS NULL OR p_key IS NULL OR p_key LIKE '%..%' OR p_key LIKE '%//%' THEN RETURN false; END IF;
  IF split_part(name, '/', 1) IS DISTINCT FROM public.get_my_org_id()::text THEN RETURN false; END IF;
  br := public.report_file_branch(name);
  IF br IS NULL THEN RETURN false; END IF;
  -- 134: purchase / expense proofs
  IF bucket = 'payment-proofs' AND split_part(name, '/', 3) = 'procurement' THEN
    RETURN CASE WHEN p_write THEN public.has_permission_at('procurement.receive', br, NULL) OR public.has_permission_at('finance.pay', br, NULL)
                ELSE public.has_permission_at('procurement.view', br, NULL) OR public.can_see_director_payments(br) END;
  END IF;
  RETURN CASE bucket
    WHEN 'payment-proofs' THEN CASE WHEN p_write THEN public.has_permission_at('sales.create', br, NULL)
      ELSE public.has_permission_at('sales.view', br, NULL) OR public.has_permission_at('sales.confirm_payments', br, NULL) END
    WHEN 'director-proofs' THEN CASE WHEN p_write THEN public.has_permission_at('finance.pay', br, NULL)
      ELSE public.can_see_director_payments(br) END
    WHEN 'report-photos' THEN public.has_permission_at(CASE WHEN p_write THEN 'production.create' ELSE 'production.view' END, br, NULL)
    WHEN 'delivery-proofs' THEN public.has_permission_at(CASE WHEN p_write THEN 'sales.create' ELSE 'sales.view' END, br, NULL)
    ELSE false
  END;
END;
$$;
