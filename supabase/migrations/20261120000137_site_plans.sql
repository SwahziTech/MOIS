-- ============================================================
-- 137 — Site plans: a branch's ground plan and its areas
--
-- SwahziTech, 2026-11-20 (the user): a branch's site is drawn in MOIS —
-- its making places, curing places, ready-stock areas, open material areas,
-- buildings and gates, with the lanes between them. Each tenant draws its
-- own plan in the app; nothing of any tenant's layout lives in MOIS itself.
--
--   1. site_areas — the boxes on a branch's plan (name, kind, position and
--      size on a 680 × 500 plan, road at the top). A stock area may belong
--      to one of the branch's stores (an area of the Yard, say).
--   2. site_lanes — the routes drawn between them (main route or lane).
--   3. product_home_areas — where a product usually sits at a branch: its
--      home area (the user chose a home area per product over naming the
--      area on every movement).
--
-- Only the Technical admin draws and changes plans (system.manage); everyone
-- in the organisation can see them.
-- ============================================================

CREATE TABLE public.site_areas (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  name            text NOT NULL CHECK (btrim(name) <> ''),
  kind            text NOT NULL CHECK (kind IN ('making', 'curing', 'ready', 'material', 'building', 'gate', 'other')),
  warehouse_id    uuid REFERENCES public.warehouses(id) ON DELETE SET NULL,   -- the store this area is part of
  parent_id       uuid REFERENCES public.site_areas(id) ON DELETE SET NULL,   -- drawn inside another area (a machine in a building)
  x               numeric NOT NULL DEFAULT 0,
  y               numeric NOT NULL DEFAULT 0,
  w               numeric NOT NULL DEFAULT 80 CHECK (w > 0),
  h               numeric NOT NULL DEFAULT 40 CHECK (h > 0),
  shape           jsonb,                                                     -- optional outline points (an L-shaped area)
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_site_areas_branch ON public.site_areas (branch_id);
CREATE TRIGGER trg_site_areas_updated_at BEFORE UPDATE ON public.site_areas FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.site_lanes (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  kind            text NOT NULL DEFAULT 'lane' CHECK (kind IN ('road', 'main', 'lane')),
  points          jsonb NOT NULL CHECK (jsonb_typeof(points) = 'array' AND jsonb_array_length(points) >= 2),   -- [[x, y], …]
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_site_lanes_branch ON public.site_lanes (branch_id);

CREATE TABLE public.product_home_areas (
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  product_id      uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  area_id         uuid NOT NULL REFERENCES public.site_areas(id) ON DELETE CASCADE,
  PRIMARY KEY (branch_id, product_id)
);

-- A row's branch, store and parent must agree (same organisation and branch)
CREATE OR REPLACE FUNCTION public.check_site_area()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = NEW.branch_id AND organization_id = NEW.organization_id) THEN
    RAISE EXCEPTION 'That branch isn''t in this organisation' USING ERRCODE = '23514';
  END IF;
  IF NEW.warehouse_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.warehouses WHERE id = NEW.warehouse_id AND branch_id = NEW.branch_id) THEN
    RAISE EXCEPTION 'That store isn''t at this branch' USING ERRCODE = '23514';
  END IF;
  IF NEW.parent_id IS NOT NULL AND (NEW.parent_id = NEW.id OR NOT EXISTS (SELECT 1 FROM public.site_areas WHERE id = NEW.parent_id AND branch_id = NEW.branch_id)) THEN
    RAISE EXCEPTION 'An area sits inside another area of the same branch' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_site_areas_check BEFORE INSERT OR UPDATE ON public.site_areas FOR EACH ROW EXECUTE FUNCTION public.check_site_area();

CREATE OR REPLACE FUNCTION public.check_home_area()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.site_areas WHERE id = NEW.area_id AND branch_id = NEW.branch_id AND organization_id = NEW.organization_id)
     OR NOT EXISTS (SELECT 1 FROM public.products WHERE id = NEW.product_id AND organization_id = NEW.organization_id) THEN
    RAISE EXCEPTION 'That area isn''t on this branch''s plan' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_home_areas_check BEFORE INSERT OR UPDATE ON public.product_home_areas FOR EACH ROW EXECUTE FUNCTION public.check_home_area();

ALTER TABLE public.site_areas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.site_lanes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_home_areas ENABLE ROW LEVEL SECURITY;

CREATE POLICY "site_areas: read" ON public.site_areas FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "site_areas: tech admin" ON public.site_areas FOR ALL
  USING (organization_id = public.get_my_org_id() AND public.has_permission('system.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('system.manage'));
CREATE POLICY "site_lanes: read" ON public.site_lanes FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "site_lanes: tech admin" ON public.site_lanes FOR ALL
  USING (organization_id = public.get_my_org_id() AND public.has_permission('system.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('system.manage'));
CREATE POLICY "home_areas: read" ON public.product_home_areas FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "home_areas: tech admin" ON public.product_home_areas FOR ALL
  USING (organization_id = public.get_my_org_id() AND public.has_permission('system.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('system.manage'));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.site_areas, public.site_lanes, public.product_home_areas TO authenticated;

COMMENT ON TABLE public.site_areas IS 'A branch''s ground plan: its areas (making, curing, ready stock, open material areas, buildings, gates), drawn by the Technical admin on a 680 × 500 plan, road at the top.';
COMMENT ON TABLE public.site_lanes IS 'Routes drawn on a branch''s plan: the road outside, the main route, lanes.';
COMMENT ON TABLE public.product_home_areas IS 'Where a product usually sits at a branch (its home area on the site plan).';
