-- ============================================================
-- 116 — Dashboard tabs per role (Settings › Dashboard layout), 2026-11-10, the user
-- ============================================================
-- The Technical admin arranges each role's dashboard: which tabs it has and in
-- what order (Director view, Overview, HR, Attendance, Sales, Production,
-- Purchases, Inventory, Setup). No row = the built-in set for the role. What a
-- person can open on a tab still follows their permissions.
--   tabs: ["overview", "sales", "production", …]
-- ============================================================

CREATE TABLE public.dashboard_layouts (
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  role_name       text NOT NULL,
  tabs            jsonb NOT NULL CHECK (jsonb_typeof(tabs) = 'array'),
  updated_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, role_name)
);
CREATE TRIGGER trg_dashboard_layouts_updated_at BEFORE UPDATE ON public.dashboard_layouts FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_dashboard_layouts_audit AFTER INSERT OR UPDATE OR DELETE ON public.dashboard_layouts FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('dashboard_layout', 'role_name');
ALTER TABLE public.dashboard_layouts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "dashboard_layouts: read own org" ON public.dashboard_layouts FOR SELECT USING (organization_id = public.get_my_org_id());
REVOKE ALL ON public.dashboard_layouts FROM PUBLIC, anon;
GRANT SELECT ON public.dashboard_layouts TO authenticated;
COMMENT ON TABLE public.dashboard_layouts IS 'A role''s dashboard tabs in order; the built-in set when none (116).';

CREATE OR REPLACE FUNCTION public.set_dashboard_layout(p_role text, p_tabs jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_permission('system.manage') THEN RAISE EXCEPTION 'Only the Technical admin arranges dashboards' USING ERRCODE = '42501'; END IF;
  IF nullif(btrim(p_role), '') IS NULL OR NOT EXISTS (SELECT 1 FROM public.roles WHERE name = p_role) THEN RAISE EXCEPTION 'Choose the role' USING ERRCODE = '23514'; END IF;
  IF jsonb_typeof(p_tabs) IS DISTINCT FROM 'array' OR jsonb_array_length(p_tabs) = 0 THEN RAISE EXCEPTION 'Keep at least one tab' USING ERRCODE = '23514'; END IF;
  INSERT INTO public.dashboard_layouts (organization_id, role_name, tabs, updated_by)
  VALUES (public.get_my_org_id(), p_role, p_tabs, auth.uid())
  ON CONFLICT (organization_id, role_name) DO UPDATE SET tabs = EXCLUDED.tabs, updated_by = EXCLUDED.updated_by;
END;
$$;
CREATE OR REPLACE FUNCTION public.reset_dashboard_layout(p_role text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_permission('system.manage') THEN RAISE EXCEPTION 'Only the Technical admin arranges dashboards' USING ERRCODE = '42501'; END IF;
  DELETE FROM public.dashboard_layouts WHERE organization_id = public.get_my_org_id() AND role_name = p_role;
END;
$$;
REVOKE ALL ON FUNCTION public.set_dashboard_layout(text, jsonb), public.reset_dashboard_layout(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_dashboard_layout(text, jsonb), public.reset_dashboard_layout(text) TO authenticated;
