-- ============================================================
-- 103 — Uploaded reports: the photo is kept with the day
-- ============================================================
-- SwahziTech, 2026-11-03, the user: a report can come in two ways, typed in the
-- screens or uploaded. An uploaded report (photo or PDF) is read, the person
-- checks it and types what is missing, then it is saved as normal entries.
-- The photo stays with the branch and day it reports on.
--   * report_uploads — one row a file: branch, report day, kind, the file in
--     storage, the text it was read as, who uploaded it.
--   * Storage bucket report-photos (private), files at <org>/<branch>/<day>/…
--     Read with production.view at the branch; added with production.create
--     (Branch Manager, and the Secretary once that role exists).
--   * Files and rows are never changed or deleted.
-- Reading a photo by AI comes later; for now the text is pasted.
-- ============================================================

CREATE TABLE public.report_uploads (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id),
  branch_id       uuid NOT NULL REFERENCES public.branches(id),
  report_date     date NOT NULL,
  kind            text NOT NULL CHECK (kind IN ('production', 'sales', 'stock', 'past_sales')),
  file_path       text,
  file_name       text,
  report_text     text,
  created_by      uuid REFERENCES public.profiles(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (file_path IS NOT NULL OR report_text IS NOT NULL)
);
CREATE INDEX idx_report_uploads_day ON public.report_uploads (branch_id, report_date DESC);
COMMENT ON TABLE public.report_uploads IS 'Reports uploaded as a photo or PDF (and the text read from them), kept with the branch and day (103).';
CREATE TRIGGER trg_report_uploads_audit AFTER INSERT OR UPDATE OR DELETE ON public.report_uploads FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('report_uploads', 'organization_id');
CREATE TRIGGER trg_report_uploads_no_delete BEFORE DELETE ON public.report_uploads FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('uploaded report');
ALTER TABLE public.report_uploads ENABLE ROW LEVEL SECURITY;
CREATE POLICY "report_uploads: read with production" ON public.report_uploads FOR SELECT TO authenticated
  USING (organization_id = public.get_my_org_id() AND public.has_permission_at('production.view', branch_id, NULL));
REVOKE ALL ON public.report_uploads FROM PUBLIC, anon;
GRANT SELECT ON public.report_uploads TO authenticated;

-- An uploaded report: its file (already in storage) and/or its text
CREATE OR REPLACE FUNCTION public.record_report_upload(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org  uuid := public.get_my_org_id();
  br   public.branches;
  dt   date := nullif(p->>'report_date', '')::date;
  fp   text := nullif(trim(p->>'file_path'), '');
  txt  text := nullif(trim(p->>'report_text'), '');
  new_id uuid;
BEGIN
  SELECT * INTO br FROM public.branches WHERE id = nullif(p->>'branch_id', '')::uuid AND organization_id = org;
  IF NOT FOUND THEN RAISE EXCEPTION 'Branch not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('production.create', br.id, NULL) THEN
    RAISE EXCEPTION 'You can''t upload reports at this branch' USING ERRCODE = '42501';
  END IF;
  IF dt IS NULL THEN RAISE EXCEPTION 'Choose the day of the report' USING ERRCODE = '23514'; END IF;
  IF dt > public.org_today(org) THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;
  IF fp IS NULL AND txt IS NULL THEN RAISE EXCEPTION 'Add the photo or the report text' USING ERRCODE = '23514'; END IF;
  -- the file must sit in this company's and branch's folder
  IF fp IS NOT NULL AND fp NOT LIKE org::text || '/' || br.id::text || '/%' THEN
    RAISE EXCEPTION 'That file belongs elsewhere' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.report_uploads (organization_id, branch_id, report_date, kind, file_path, file_name, report_text, created_by)
  VALUES (org, br.id, dt, coalesce(nullif(p->>'kind', ''), 'production'), fp, nullif(trim(p->>'file_name'), ''), txt, auth.uid())
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;
REVOKE ALL ON FUNCTION public.record_report_upload(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_report_upload(jsonb) TO authenticated;

-- ------------------------------------------------------------
-- The files: a private bucket, foldered <org>/<branch>/<day>/<file>
-- ------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('report-photos', 'report-photos', false, 10485760, ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'application/pdf'])
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.report_file_branch(p_name text)
RETURNS uuid
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE parts text[] := string_to_array(p_name, '/');
BEGIN
  IF array_length(parts, 1) < 4 OR parts[2] !~ '^[0-9a-f-]{36}$' THEN RETURN NULL; END IF;
  RETURN parts[2]::uuid;
END;
$$;

CREATE POLICY "report-photos: read with production" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'report-photos'
    AND split_part(name, '/', 1) = public.get_my_org_id()::text
    AND public.has_permission_at('production.view', public.report_file_branch(name), NULL));
CREATE POLICY "report-photos: add with production" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'report-photos'
    AND split_part(name, '/', 1) = public.get_my_org_id()::text
    AND public.has_permission_at('production.create', public.report_file_branch(name), NULL));
