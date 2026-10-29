-- ============================================================
-- 098 — Sidebar layout per role (Settings › Menu layout)
-- ============================================================
-- SwahziTech, 2026-10-30: the sidebar arranged by who is logged in —
-- directors, branch managers, secretaries… each their own order and
-- grouping, with exactly the same page names. The current sidebar is the
-- default; the Technical admin arranges each role (sections in order, pages
-- moved between sections, sections added, renamed or ungrouped, folded or
-- not). Role layout only — people don't rearrange their own. What anyone can
-- open is still decided by their permissions.
--   layout: { "sections": [ { "title": "Sales", "folded": false, "items": ["/sales", "/customers"] }, … ] }
--   (a section with an empty title shows its pages without a heading)
-- ============================================================

CREATE TABLE public.menu_layouts (
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  role_name       text NOT NULL,
  layout          jsonb NOT NULL CHECK (jsonb_typeof(layout -> 'sections') = 'array'),
  updated_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, role_name)
);
CREATE TRIGGER trg_menu_layouts_updated_at BEFORE UPDATE ON public.menu_layouts FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_menu_layouts_audit AFTER INSERT OR UPDATE OR DELETE ON public.menu_layouts FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('menu_layout', 'role_name');
ALTER TABLE public.menu_layouts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "menu_layouts: read own org" ON public.menu_layouts FOR SELECT USING (organization_id = public.get_my_org_id());
COMMENT ON TABLE public.menu_layouts IS 'The sidebar''s sections and page order for a role; the current sidebar when none (098).';

-- save a role's layout (Technical admin)
CREATE OR REPLACE FUNCTION public.set_menu_layout(p_role text, p_layout jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_permission('system.manage') THEN RAISE EXCEPTION 'Only the Technical admin arranges the menu' USING ERRCODE = '42501'; END IF;
  IF nullif(btrim(p_role), '') IS NULL OR NOT EXISTS (SELECT 1 FROM public.roles WHERE name = p_role) THEN RAISE EXCEPTION 'Choose the role' USING ERRCODE = '23514'; END IF;
  IF jsonb_typeof(p_layout -> 'sections') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'The layout needs its sections' USING ERRCODE = '23514'; END IF;
  INSERT INTO public.menu_layouts (organization_id, role_name, layout, updated_by)
  VALUES (public.get_my_org_id(), p_role, p_layout, auth.uid())
  ON CONFLICT (organization_id, role_name) DO UPDATE SET layout = EXCLUDED.layout, updated_by = EXCLUDED.updated_by;
END;
$$;

-- back to the current sidebar for a role
CREATE OR REPLACE FUNCTION public.reset_menu_layout(p_role text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_permission('system.manage') THEN RAISE EXCEPTION 'Only the Technical admin arranges the menu' USING ERRCODE = '42501'; END IF;
  DELETE FROM public.menu_layouts WHERE organization_id = public.get_my_org_id() AND role_name = p_role;
END;
$$;
REVOKE ALL ON FUNCTION public.set_menu_layout(text, jsonb), public.reset_menu_layout(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_menu_layout(text, jsonb), public.reset_menu_layout(text) TO authenticated;
