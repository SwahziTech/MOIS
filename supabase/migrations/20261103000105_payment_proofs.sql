-- ============================================================
-- 105 — Proof of payment, confirmed by a director
-- ============================================================
-- SwahziTech, 2026-11-03, the user: instead of sending receipts on the
-- WhatsApp group, each sale payment gets its proof in MOIS — one simple
-- step — and a director confirms it.
--   * Proof per payment: a photo or PDF (bank slip, receipt) and/or the
--     transaction SMS text. Due within 2 days of the payment (a reminder
--     for the secretary, branch manager and sales users until it is in).
--     Most money is cash at the office, banked later: the slip comes then.
--   * Directors confirm it, or query it with a note (the branch fixes the
--     proof and sends it again) — within 3 days of the payment date.
--   * A sale is fully approved when it is fully paid and every payment is
--     confirmed. Goods still leave up to the value paid (a check, not a gate).
--   * sales.confirm_payments: owner (technical admin) and directors.
--   * Files in the private bucket payment-proofs, at <org>/<branch>/<payment>/…
-- ============================================================

INSERT INTO public.permissions (code, description, module) VALUES
  ('sales.confirm_payments', 'Confirm or query the proof of sale payments', 'sales')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code = 'sales.confirm_payments'
WHERE r.is_system_role AND r.name IN ('owner', 'director')
ON CONFLICT DO NOTHING;

CREATE TABLE public.sale_payment_proofs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id),
  branch_id       uuid NOT NULL REFERENCES public.branches(id),
  payment_id      uuid NOT NULL UNIQUE REFERENCES public.sale_payments(id) ON DELETE CASCADE,
  file_path       text,
  file_name       text,
  sms_text        text,
  status          text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'confirmed', 'queried')),
  submitted_by    uuid REFERENCES public.profiles(id),
  submitted_at    timestamptz NOT NULL DEFAULT now(),
  reviewed_by     uuid REFERENCES public.profiles(id),
  reviewed_at     timestamptz,
  note            text,                        -- a director's query
  CHECK (file_path IS NOT NULL OR nullif(btrim(sms_text), '') IS NOT NULL)
);
CREATE INDEX idx_sale_payment_proofs_status ON public.sale_payment_proofs (organization_id, status);
COMMENT ON TABLE public.sale_payment_proofs IS 'The proof of a sale payment (photo/PDF and/or SMS text) and a director''s confirmation or query (105).';
CREATE TRIGGER trg_sale_payment_proofs_audit AFTER INSERT OR UPDATE OR DELETE ON public.sale_payment_proofs FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('sale_payment_proof', 'organization_id');
ALTER TABLE public.sale_payment_proofs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sale_payment_proofs: read with sales" ON public.sale_payment_proofs FOR SELECT TO authenticated
  USING (organization_id = public.get_my_org_id()
    AND (public.has_permission_at('sales.view', branch_id, NULL) OR public.has_permission_at('sales.confirm_payments', branch_id, NULL)));
REVOKE ALL ON public.sale_payment_proofs FROM PUBLIC, anon;
GRANT SELECT ON public.sale_payment_proofs TO authenticated;

-- The proof of a payment: added, or replaced while not yet confirmed (a queried one goes back to waiting)
CREATE OR REPLACE FUNCTION public.submit_payment_proof(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org  uuid := public.get_my_org_id();
  pay  public.sale_payments;
  s    public.sales;
  old  public.sale_payment_proofs;
  fp   text := nullif(btrim(p->>'file_path'), '');
  txt  text := nullif(btrim(p->>'sms_text'), '');
  rid  uuid;
BEGIN
  SELECT * INTO pay FROM public.sale_payments WHERE id = nullif(p->>'payment_id', '')::uuid AND organization_id = org;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found' USING ERRCODE = '23514'; END IF;
  SELECT * INTO s FROM public.sales WHERE id = pay.sale_id;
  IF NOT public.has_permission_at('sales.create', s.branch_id, NULL) THEN
    RAISE EXCEPTION 'You can''t add proof of payment at this branch' USING ERRCODE = '42501';
  END IF;
  IF fp IS NULL AND txt IS NULL THEN RAISE EXCEPTION 'Add the photo or paste the SMS' USING ERRCODE = '23514'; END IF;
  IF fp IS NOT NULL AND fp NOT LIKE org::text || '/' || s.branch_id::text || '/%' THEN
    RAISE EXCEPTION 'That file belongs elsewhere' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO old FROM public.sale_payment_proofs WHERE payment_id = pay.id FOR UPDATE;
  IF old.status = 'confirmed' THEN RAISE EXCEPTION 'This payment is already confirmed' USING ERRCODE = '23514'; END IF;
  IF old.id IS NULL THEN
    INSERT INTO public.sale_payment_proofs (organization_id, branch_id, payment_id, file_path, file_name, sms_text, submitted_by)
    VALUES (org, s.branch_id, pay.id, fp, nullif(btrim(p->>'file_name'), ''), txt, auth.uid())
    RETURNING id INTO rid;
  ELSE
    UPDATE public.sale_payment_proofs SET file_path = coalesce(fp, file_path), file_name = CASE WHEN fp IS NOT NULL THEN nullif(btrim(p->>'file_name'), '') ELSE file_name END,
           sms_text = coalesce(txt, sms_text), status = 'waiting', submitted_by = auth.uid(), submitted_at = now()
     WHERE id = old.id RETURNING id INTO rid;
  END IF;
  RETURN rid;
END;
$$;
REVOKE ALL ON FUNCTION public.submit_payment_proof(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_payment_proof(jsonb) TO authenticated;

-- A director confirms the proof, or queries it with a note
CREATE OR REPLACE FUNCTION public.review_payment_proof(p_payment uuid, p_action text, p_note text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  pr public.sale_payment_proofs;
BEGIN
  SELECT * INTO pr FROM public.sale_payment_proofs WHERE payment_id = p_payment AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No proof has been added for this payment yet' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('sales.confirm_payments', pr.branch_id, NULL) THEN
    RAISE EXCEPTION 'Only a director can confirm payments' USING ERRCODE = '42501';
  END IF;
  IF p_action = 'confirm' THEN
    UPDATE public.sale_payment_proofs SET status = 'confirmed', reviewed_by = auth.uid(), reviewed_at = now(), note = NULL WHERE id = pr.id;
  ELSIF p_action = 'query' THEN
    IF nullif(btrim(p_note), '') IS NULL THEN RAISE EXCEPTION 'Say what is wrong with the proof' USING ERRCODE = '23514'; END IF;
    UPDATE public.sale_payment_proofs SET status = 'queried', reviewed_by = auth.uid(), reviewed_at = now(), note = btrim(p_note) WHERE id = pr.id;
  ELSE
    RAISE EXCEPTION 'Confirm or query' USING ERRCODE = '23514';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.review_payment_proof(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_payment_proof(uuid, text, text) TO authenticated;

-- The files: a private bucket, foldered <org>/<branch>/<payment>/<file>
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('payment-proofs', 'payment-proofs', false, 10485760, ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'application/pdf'])
ON CONFLICT (id) DO NOTHING;
CREATE POLICY "payment-proofs: read with sales" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'payment-proofs'
    AND split_part(name, '/', 1) = public.get_my_org_id()::text
    AND (public.has_permission_at('sales.view', public.report_file_branch(name), NULL)
      OR public.has_permission_at('sales.confirm_payments', public.report_file_branch(name), NULL)));
CREATE POLICY "payment-proofs: add with sales" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'payment-proofs'
    AND split_part(name, '/', 1) = public.get_my_org_id()::text
    AND public.has_permission_at('sales.create', public.report_file_branch(name), NULL));
