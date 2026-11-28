-- ============================================================
-- 146 — weekly cash: the printed layout travels with the report (2026-11-28, the user)
--   The preview / PDF / print use the column widths the preparer gave the sheets on screen. Kept with the
--   request, so a director opening it on another device prints the same layout.
--   * cash_requests.print_widths — { lw: { table, cols[] }, req: { table, cols[] } } as fractions of the page
--   * set_cash_request_widths(id, widths) — who prepares the weekly cash at that branch; layout only
-- ============================================================

ALTER TABLE public.cash_requests ADD COLUMN IF NOT EXISTS print_widths jsonb;

CREATE OR REPLACE FUNCTION public.set_cash_request_widths(p_id uuid, p_widths jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r public.cash_requests;
BEGIN
  SELECT * INTO r FROM public.cash_requests WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('cash.request', r.branch_id, NULL) THEN
    RAISE EXCEPTION 'You can''t change weekly cash at this branch' USING ERRCODE = '42501';
  END IF;
  IF p_widths IS NOT NULL AND jsonb_typeof(p_widths) <> 'object' THEN
    RAISE EXCEPTION 'Widths must be an object' USING ERRCODE = '22023';
  END IF;
  IF r.print_widths IS NOT DISTINCT FROM p_widths THEN RETURN; END IF;   -- unchanged: no audit row
  UPDATE public.cash_requests SET print_widths = p_widths WHERE id = p_id;
END;
$$;

REVOKE ALL ON FUNCTION public.set_cash_request_widths(uuid, jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.set_cash_request_widths(uuid, jsonb) TO authenticated;
