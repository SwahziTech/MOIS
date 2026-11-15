-- ============================================================
-- 123 — Weekly cash: remove an import that is not wanted; use a cancelled one again
-- ============================================================
-- SwahziTech, 2026-11-15 (the user): as with the other imports, the person sees the imported
-- weekly sheets and can delete one or use it again.
--   * delete_cash_request(id) — removes a CANCELLED request that never reached the directors (the user:
--     "only the cancelled"). Who prepares the weekly cash at that branch. Not one that carries the
--     casuals' wages from an approved pay sheet (that stays on record). The audit log keeps a copy.
--   * reopen_cash_request(id) — a cancelled request back to draft, to use again; only when the
--     week has no other live request.
-- Records that went to the directors stay as they are (cancel / turn down keep them).
-- ============================================================

-- the delete guard (068) lets this one function through
CREATE OR REPLACE FUNCTION public.prevent_hard_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.role() = 'service_role' OR auth.uid() IS NULL THEN
    RETURN OLD;
  END IF;
  -- 068: a sale correction may remove a wrong payment (set only inside apply_sale_correction)
  IF TG_TABLE_NAME = 'sale_payments' AND coalesce(current_setting('mois.sale_correction', true), '') = 'on' THEN
    RETURN OLD;
  END IF;
  -- 123: an unwanted weekly cash import (set only inside delete_cash_request)
  IF TG_TABLE_NAME = 'cash_requests' AND coalesce(current_setting('mois.cash_request_delete', true), '') = 'on' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION '% records cannot be deleted — deactivate them instead', TG_ARGV[0]
    USING ERRCODE = '42501';
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_cash_request(p_id uuid)
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
    RAISE EXCEPTION 'You can''t delete weekly cash at this branch' USING ERRCODE = '42501';
  END IF;
  IF r.status <> 'cancelled' OR r.sent_by IS NOT NULL THEN
    RAISE EXCEPTION 'Only a cancelled request that never went to the directors can be deleted' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (SELECT 1 FROM public.cash_request_lines WHERE request_id = p_id AND pay_sheet_id IS NOT NULL) THEN
    RAISE EXCEPTION 'This request carries the casuals'' wages from their pay sheet — it stays on record' USING ERRCODE = '23514';
  END IF;
  PERFORM set_config('mois.cash_request_delete', 'on', true);
  DELETE FROM public.cash_requests WHERE id = p_id;   -- its lines go with it
  PERFORM set_config('mois.cash_request_delete', '', true);
END;
$$;
REVOKE ALL ON FUNCTION public.delete_cash_request(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_cash_request(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.reopen_cash_request(p_id uuid)
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
  IF r.status <> 'cancelled' THEN RAISE EXCEPTION 'Only a cancelled request can be used again' USING ERRCODE = '23514'; END IF;
  IF EXISTS (SELECT 1 FROM public.cash_requests WHERE branch_id = r.branch_id AND week_ending = r.week_ending AND id <> r.id AND status NOT IN ('cancelled', 'rejected')) THEN
    RAISE EXCEPTION 'The week of % already has a request — delete or cancel that one first', to_char(r.week_ending, 'DD Mon YYYY') USING ERRCODE = '23505';
  END IF;
  UPDATE public.cash_requests SET status = 'draft', sent_by = NULL, sent_at = NULL, decided_by = NULL, decided_at = NULL, decision_note = NULL WHERE id = p_id;
END;
$$;
REVOKE ALL ON FUNCTION public.reopen_cash_request(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reopen_cash_request(uuid) TO authenticated;
