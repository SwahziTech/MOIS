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
--   4. site_zones — named groups of areas (Dodoma: Yard P, Yard C, Banda,
--      Yard V). A zone is a name and a text colour on the plan; the stores
--      stay as they are. An area belongs to a zone; a machine's products are
--      kept in its zone (machines.zone_id) unless a product has a home area.
--
-- Only the Technical admin draws and changes plans (system.manage); everyone
-- in the organisation can see them.
-- ============================================================

CREATE TABLE public.site_zones (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  name            text NOT NULL CHECK (btrim(name) <> ''),
  color           text NOT NULL DEFAULT 'teal' CHECK (color IN ('teal', 'blue', 'coral', 'purple', 'amber', 'pink', 'green', 'gray')),
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_site_zones_name ON public.site_zones (branch_id, public.normalize_name(name));

CREATE TABLE public.site_areas (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  name            text NOT NULL CHECK (btrim(name) <> ''),
  kind            text NOT NULL CHECK (kind IN ('making', 'curing', 'ready', 'material', 'building', 'gate', 'other')),
  warehouse_id    uuid REFERENCES public.warehouses(id) ON DELETE SET NULL,   -- the store this area is part of
  parent_id       uuid REFERENCES public.site_areas(id) ON DELETE SET NULL,   -- drawn inside another area (a machine in a building)
  zone_id         uuid REFERENCES public.site_zones(id) ON DELETE SET NULL,   -- the zone it belongs to (its text colour)
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
  IF NEW.zone_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.site_zones WHERE id = NEW.zone_id AND branch_id = NEW.branch_id) THEN
    RAISE EXCEPTION 'That zone isn''t at this branch' USING ERRCODE = '23514';
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

-- the zone a machine's products are kept in
ALTER TABLE public.machines ADD COLUMN zone_id uuid REFERENCES public.site_zones(id) ON DELETE SET NULL;
CREATE OR REPLACE FUNCTION public.check_machine_zone()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- only the Technical admin says where a machine's products are kept (site plans are theirs)
  IF NEW.zone_id IS DISTINCT FROM (CASE WHEN TG_OP = 'UPDATE' THEN OLD.zone_id END)
     AND auth.uid() IS NOT NULL AND NOT public.has_permission('system.manage') THEN
    RAISE EXCEPTION 'Only the Technical admin sets where a machine''s products are kept' USING ERRCODE = '42501';
  END IF;
  IF NEW.zone_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.site_zones WHERE id = NEW.zone_id AND branch_id = NEW.branch_id) THEN
    RAISE EXCEPTION 'That zone isn''t at this branch' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_machines_zone BEFORE INSERT OR UPDATE OF zone_id, branch_id ON public.machines FOR EACH ROW EXECUTE FUNCTION public.check_machine_zone();

-- where a product is kept at a branch: its home area's zone, else the zone of a machine it is made on
CREATE OR REPLACE FUNCTION public.product_zone(p_branch uuid, p_product uuid)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(
    (SELECT a.zone_id FROM public.product_home_areas h JOIN public.site_areas a ON a.id = h.area_id
      WHERE h.branch_id = p_branch AND h.product_id = p_product AND a.organization_id = public.get_my_org_id()),
    (SELECT m.zone_id FROM public.machine_products mp JOIN public.machines m ON m.id = mp.machine_id
      WHERE mp.product_id = p_product AND m.branch_id = p_branch AND m.zone_id IS NOT NULL AND m.status = 'active'
        AND m.organization_id = public.get_my_org_id() ORDER BY m.name LIMIT 1))
$$;
REVOKE ALL ON FUNCTION public.product_zone(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.product_zone(uuid, uuid) TO authenticated;

ALTER TABLE public.site_zones ENABLE ROW LEVEL SECURITY;
CREATE POLICY "site_zones: read" ON public.site_zones FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "site_zones: tech admin" ON public.site_zones FOR ALL
  USING (organization_id = public.get_my_org_id() AND public.has_permission('system.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('system.manage'));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.site_zones TO authenticated;
COMMENT ON TABLE public.site_zones IS 'Named groups of a branch''s site areas (a name and a text colour on the plan); the stores stay as they are.';

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
