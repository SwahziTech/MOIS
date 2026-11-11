-- ============================================================
-- 117 — Files on Cloudflare R2; a photo with the proof of delivery
-- ============================================================
-- SwahziTech, 2026-11-11 (build-plan "Cloudflare", parts 3 and 4; PRD 10.9, 6.38):
--   * Files move from Supabase Storage to one private R2 bucket. A file's R2 key is
--     '<bucket>/<path>' with the path exactly as stored today ('<org>/<branch>/…'),
--     so no saved file_path changes.
--   * The file service (a Cloudflare Worker, web/worker) asks file_access() with the
--     person's own sign-in before it hands out a short-lived link to read or write a file.
--     file_access() applies the same rules as the storage policies (103, 105, 106):
--     the person's company, the file's branch, and the permission for that kind of file.
--   * Deliveries: a photo can go with the proof of delivery (e.g. the signed delivery note),
--     in 'delivery-proofs' — seen with sales, added by those who confirm deliveries.
-- The Supabase Storage buckets and their files stay until the move is checked.
-- ============================================================

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
COMMENT ON FUNCTION public.file_access(text, boolean) IS
  'May the signed-in person read (or write) this R2 file? Key = <bucket>/<org>/<branch>/…; same rules as the storage policies (117).';
REVOKE ALL ON FUNCTION public.file_access(text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.file_access(text, boolean) TO authenticated;

-- the photo with the proof of delivery
ALTER TABLE public.sale_deliveries
  ADD COLUMN pod_file_path text,   -- '<org>/<branch>/<delivery>/<time>.jpg' in delivery-proofs
  ADD COLUMN pod_file_name text;   -- the name it downloads as

CREATE OR REPLACE FUNCTION public.confirm_delivery(p_delivery uuid, p jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d  public.sale_deliveries;
  br uuid;
  at timestamptz := coalesce(nullif(p->>'delivered_at', '')::timestamptz, now());
  fp text := nullif(btrim(p->>'pod_file_path'), '');
BEGIN
  SELECT * INTO d FROM public.sale_deliveries WHERE id = p_delivery AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Delivery not found' USING ERRCODE = '23514'; END IF;
  SELECT branch_id INTO br FROM public.sales WHERE id = d.sale_id;
  IF NOT public.has_permission_at('sales.create', br, NULL) THEN RAISE EXCEPTION 'You can''t confirm deliveries at this branch' USING ERRCODE = '42501'; END IF;
  IF d.status = 'delivered' THEN RAISE EXCEPTION 'It is already delivered' USING ERRCODE = '23514'; END IF;
  IF nullif(btrim(p->>'received_by'), '') IS NULL THEN RAISE EXCEPTION 'Enter who received the goods' USING ERRCODE = '23514'; END IF;
  IF at > now() + interval '5 minutes' THEN RAISE EXCEPTION 'The time can''t be in the future' USING ERRCODE = '23514'; END IF;
  IF at < d.dispatched_at THEN RAISE EXCEPTION 'It can''t arrive before it left' USING ERRCODE = '23514'; END IF;
  -- the photo must sit under this company and this sale's branch
  IF fp IS NOT NULL AND (split_part(fp, '/', 1) <> d.organization_id::text OR public.report_file_branch(fp) IS DISTINCT FROM br) THEN
    RAISE EXCEPTION 'The photo was not saved for this delivery' USING ERRCODE = '23514';
  END IF;
  UPDATE public.sale_deliveries SET status = 'delivered', delivered_at = at, pod_received_by = btrim(p->>'received_by'),
         pod_note = nullif(btrim(p->>'note'), ''), confirmed_by = auth.uid(),
         pod_file_path = fp, pod_file_name = CASE WHEN fp IS NULL THEN NULL ELSE nullif(btrim(p->>'pod_file_name'), '') END
  WHERE id = d.id;
END;
$$;
