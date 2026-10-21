-- ============================================================
-- 045 — Capacity planner (1d)
--
-- Decided with SwahziTech (2026-10-21):
--   * Capacity belongs to a branch and a product:
--       molds            — vibro: one cast-and-cure per mold per day, so
--                          the mold count is the day's ceiling in pieces
--                          (AGENTS.md §3);
--       bags per day     — press: a range of cement bags a day for that
--                          product (a typical range, not a hard ceiling);
--       neither          — capacity not defined (e.g. steel-cast culverts,
--                          posts): planned without a limit.
--     The branch manager keeps the branch's figures.
--   * The planner is a calculator by default; an org admin can switch the
--     organization to "plan & compare": a day's plan is saved and set
--     against what was actually cast.
-- ============================================================

CREATE TABLE public.branch_product_capacity (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id        uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  product_id       uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  molds            int CHECK (molds > 0),
  bags_per_day_min numeric CHECK (bags_per_day_min > 0),
  bags_per_day_max numeric CHECK (bags_per_day_max > 0),
  notes            text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (branch_id, product_id),
  CHECK (bags_per_day_min IS NULL OR bags_per_day_max IS NULL OR bags_per_day_min <= bags_per_day_max)
);
COMMENT ON TABLE public.branch_product_capacity
  IS 'A branch''s daily capacity for a product: molds (vibro, one cast per mold per day) or bags of cement a day (press). Neither = not defined.';
CREATE TRIGGER trg_branch_product_capacity_updated_at BEFORE UPDATE ON public.branch_product_capacity
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_branch_product_capacity_audit AFTER INSERT OR UPDATE OR DELETE ON public.branch_product_capacity
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('branch_product_capacity', 'id');
CREATE TRIGGER trg_branch_product_capacity_branch_org BEFORE INSERT OR UPDATE ON public.branch_product_capacity
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('branches', 'branch_id');

ALTER TABLE public.branch_product_capacity ENABLE ROW LEVEL SECURITY;
CREATE POLICY "branch_product_capacity: read own org" ON public.branch_product_capacity FOR SELECT
  USING (organization_id = public.get_my_org_id());
CREATE POLICY "branch_product_capacity: branch managers add" ON public.branch_product_capacity FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_at('products.manage', branch_id, NULL));
CREATE POLICY "branch_product_capacity: branch managers change" ON public.branch_product_capacity FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND public.has_permission_at('products.manage', branch_id, NULL))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_at('products.manage', branch_id, NULL));
CREATE POLICY "branch_product_capacity: branch managers remove" ON public.branch_product_capacity FOR DELETE
  USING (organization_id = public.get_my_org_id() AND public.has_permission_at('products.manage', branch_id, NULL));


-- Planner mode, an organization setting (org admins: org.manage)
ALTER TABLE public.organizations ADD COLUMN planner_mode text NOT NULL DEFAULT 'calculator'
  CHECK (planner_mode IN ('calculator', 'plan_compare'));
COMMENT ON COLUMN public.organizations.planner_mode
  IS 'calculator = what-if only, nothing saved; plan_compare = a day''s plan is saved and compared with production.';


-- A day's plan (plan & compare mode)
CREATE TABLE public.production_plans (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  plan_date       date NOT NULL,
  notes           text,
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (branch_id, plan_date)
);
CREATE TABLE public.production_plan_lines (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  plan_id         uuid NOT NULL REFERENCES public.production_plans(id) ON DELETE CASCADE,
  product_id      uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  color_id        uuid REFERENCES public.color_palette(id) ON DELETE RESTRICT,
  pieces          int NOT NULL CHECK (pieces > 0)
);
CREATE UNIQUE INDEX uq_production_plan_lines ON public.production_plan_lines (plan_id, product_id, coalesce(color_id, '00000000-0000-0000-0000-000000000000'::uuid));
CREATE TRIGGER trg_production_plans_updated_at BEFORE UPDATE ON public.production_plans
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_production_plans_audit AFTER INSERT OR UPDATE OR DELETE ON public.production_plans
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('production_plan', 'id');
CREATE TRIGGER trg_production_plan_lines_audit AFTER INSERT OR UPDATE OR DELETE ON public.production_plan_lines
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('production_plan_line', 'id');
ALTER TABLE public.production_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.production_plan_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "production_plans: read own org" ON public.production_plans FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "production_plan_lines: read own org" ON public.production_plan_lines FOR SELECT USING (organization_id = public.get_my_org_id());

-- Save a day's plan (replaces that day's lines); whoever records production at the branch
-- p: { branch_id, plan_date, notes?, lines: [{ product_id, color_id?, pieces }] }
CREATE OR REPLACE FUNCTION public.save_production_plan(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  br  uuid := nullif(p->>'branch_id', '')::uuid;
  d   date := nullif(p->>'plan_date', '')::date;
  pid uuid;
  l   jsonb;
BEGIN
  IF org IS NULL OR auth.uid() IS NULL THEN RAISE EXCEPTION 'Not signed in to an organization' USING ERRCODE = '42501'; END IF;
  IF (SELECT planner_mode FROM public.organizations WHERE id = org) <> 'plan_compare' THEN
    RAISE EXCEPTION 'Saving plans is off — an admin can turn on "plan & compare" in Settings' USING ERRCODE = '23514';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = br AND organization_id = org) THEN RAISE EXCEPTION 'Branch not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('production.create', br, NULL) THEN
    RAISE EXCEPTION 'You can''t plan production at this branch' USING ERRCODE = '42501';
  END IF;
  IF d IS NULL THEN RAISE EXCEPTION 'Choose the day' USING ERRCODE = '23514'; END IF;

  INSERT INTO public.production_plans (organization_id, branch_id, plan_date, notes, created_by)
  VALUES (org, br, d, nullif(btrim(p->>'notes'), ''), auth.uid())
  ON CONFLICT (branch_id, plan_date) DO UPDATE SET notes = EXCLUDED.notes
  RETURNING id INTO pid;
  DELETE FROM public.production_plan_lines WHERE plan_id = pid;
  FOR l IN SELECT * FROM jsonb_array_elements(coalesce(p->'lines', '[]'::jsonb)) LOOP
    IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = nullif(l->>'product_id', '')::uuid AND organization_id = org) THEN
      RAISE EXCEPTION 'Product not found' USING ERRCODE = '23514';
    END IF;
    IF nullif(l->>'pieces', '')::int IS NULL OR (l->>'pieces')::int <= 0 THEN CONTINUE; END IF;
    INSERT INTO public.production_plan_lines (organization_id, plan_id, product_id, color_id, pieces)
    VALUES (org, pid, (l->>'product_id')::uuid, nullif(l->>'color_id', '')::uuid, (l->>'pieces')::int);
  END LOOP;
  RETURN pid;
END;
$$;
REVOKE ALL ON FUNCTION public.save_production_plan(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_production_plan(jsonb) TO authenticated;
