-- ============================================================
-- 034 — Roles: Technical admin, Director, branch roles (1b)
--
-- Decided with SwahziTech (2026-10-16).
--
-- Organisation level
--   Technical admin = the existing system role 'owner' (name kept: the
--     owner checks and one-off scripts rely on it). Everything, plus
--     technical/system configuration — the new permission system.manage —
--     and is the only role that can grant or remove the Technical admin
--     role itself.
--   Director (new) = every business permission org-wide, no system.manage:
--     all branches, approvals, business settings (timezone, default branch,
--     yield tolerance), colour pricing, branches and stores, and staffing
--     (users with business roles).
-- Branch level (given per branch)
--   Branch manager = catalogue, recipes, branch materials, proposes prices,
--     submits corrections; plus everything a secretary and storekeeper do.
--   Secretary (new) = sales and purchasing: receive goods, sales, invoices,
--     payments; views prices. No edits to catalogue, recipes, materials or
--     prices.
--   Storekeeper = receive, issue, transfer, count. No corrections: a count
--     by someone without stock-correction rights at that store goes to the
--     approval queue instead of posting its difference — the person
--     holding the stock never silently corrects the record.
-- sales_user and production_user are kept unchanged for later phases.
--
-- Rework: the eight original "owner can ..." policies (organizations,
-- branches, warehouses, roles, role_permissions, user_roles) checked the
-- owner role by name; they now check permissions. Organization settings
-- are split: business columns need org.manage, technical columns need
-- system.manage.
-- Known gap (accepted): prices are hidden from storekeepers on screen only;
-- the database still lets any member read them.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Permission for technical/system configuration
-- ------------------------------------------------------------
INSERT INTO public.permissions (code, description, module)
VALUES ('system.manage', 'Technical and system configuration; grant the Technical admin role', 'org')
ON CONFLICT (code) DO NOTHING;


-- ------------------------------------------------------------
-- 2. Roles in every organization that has the system roles
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.set_role_permissions(p_role uuid, p_codes text[], p_exact boolean)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_exact THEN
    DELETE FROM public.role_permissions rp USING public.permissions p
    WHERE rp.role_id = p_role AND rp.permission_id = p.id AND p.code <> ALL (p_codes);
  END IF;
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT p_role, p.id FROM public.permissions p WHERE p.code = ANY (p_codes)
  ON CONFLICT DO NOTHING;
END;
$$;

DO $$
DECLARE
  o   record;
  rid uuid;
BEGIN
  FOR o IN SELECT DISTINCT organization_id AS id FROM public.roles WHERE name = 'owner' AND is_system_role LOOP
    -- Technical admin: everything, including system.manage
    SELECT id INTO rid FROM public.roles WHERE organization_id = o.id AND name = 'owner' AND is_system_role;
    UPDATE public.roles SET description = 'Technical admin — everything, plus technical/system configuration; the only role that can grant Technical admin'
    WHERE id = rid;
    PERFORM pg_temp.set_role_permissions(rid, ARRAY(SELECT code FROM public.permissions), false);

    -- Director: every business permission org-wide, nothing technical
    INSERT INTO public.roles (organization_id, name, description, is_system_role)
    VALUES (o.id, 'director', 'Director — full business access across all branches: approvals, business settings, staffing; no technical configuration', true)
    ON CONFLICT DO NOTHING;
    SELECT id INTO rid FROM public.roles WHERE organization_id = o.id AND name = 'director';
    PERFORM pg_temp.set_role_permissions(rid, ARRAY(SELECT code FROM public.permissions WHERE code <> 'system.manage'), true);

    -- Branch manager: as before, plus the secretary's sales and purchasing
    SELECT id INTO rid FROM public.roles WHERE organization_id = o.id AND name = 'branch_manager' AND is_system_role;
    IF rid IS NOT NULL THEN
      UPDATE public.roles SET description = 'Branch manager — the branch''s catalogue, recipes and own materials; proposes prices and submits corrections; plus everything a secretary and storekeeper do'
      WHERE id = rid;
      PERFORM pg_temp.set_role_permissions(rid, ARRAY['invoices.create', 'payments.record', 'procurement.order', 'procurement.receive'], false);
    END IF;

    -- Secretary: sales and purchasing
    INSERT INTO public.roles (organization_id, name, description, is_system_role)
    VALUES (o.id, 'secretary', 'Secretary — sales and purchasing: receives goods, records sales, invoices and payments; views prices', true)
    ON CONFLICT DO NOTHING;
    SELECT id INTO rid FROM public.roles WHERE organization_id = o.id AND name = 'secretary';
    PERFORM pg_temp.set_role_permissions(rid, ARRAY['products.view', 'inventory.view', 'inventory.receive',
      'sales.view', 'sales.create', 'invoices.create', 'payments.record',
      'procurement.view', 'procurement.request', 'procurement.order', 'procurement.receive', 'reports.view'], true);

    -- Storekeeper: physical stock only (no catalogue or price screens)
    SELECT id INTO rid FROM public.roles WHERE organization_id = o.id AND name = 'storekeeper' AND is_system_role;
    IF rid IS NOT NULL THEN
      UPDATE public.roles SET description = 'Storekeeper — receives, issues, transfers and counts stock; corrections and count differences go to approval'
      WHERE id = rid;
      PERFORM pg_temp.set_role_permissions(rid, ARRAY['inventory.view', 'inventory.receive', 'inventory.issue', 'inventory.transfer', 'inventory.count'], true);
    END IF;
  END LOOP;
END $$;


-- ------------------------------------------------------------
-- 3. Permission checks instead of "is owner"
-- ------------------------------------------------------------
-- Organization settings: business columns with org.manage (Directors and
-- the Technical admin); technical columns with system.manage only
DROP POLICY "org: owner can update" ON public.organizations;
CREATE POLICY "org: settings by org admins" ON public.organizations FOR UPDATE
  USING      (public.is_member_of(id) AND public.has_permission('org.manage'))
  WITH CHECK (public.is_member_of(id) AND public.has_permission('org.manage'));

CREATE OR REPLACE FUNCTION public.protect_org_technical_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.has_permission('system.manage')
     AND (NEW.name, NEW.legal_name, NEW.logo_url, NEW.brand_config, NEW.status, NEW.currency_code)
         IS DISTINCT FROM (OLD.name, OLD.legal_name, OLD.logo_url, OLD.brand_config, OLD.status, OLD.currency_code) THEN
    RAISE EXCEPTION 'Only the Technical admin can change the organization''s name, branding, currency or status'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_organizations_technical_columns BEFORE UPDATE ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION public.protect_org_technical_columns();

DROP POLICY "branches: owner can insert" ON public.branches;
DROP POLICY "branches: owner can update" ON public.branches;
CREATE POLICY "branches: managed with branches.manage" ON public.branches FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('branches.manage'));
CREATE POLICY "branches: updated with branches.manage" ON public.branches FOR UPDATE
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('branches.manage'))
  WITH CHECK (organization_id = public.get_my_org_id());

DROP POLICY "warehouses: owner can insert" ON public.warehouses;
DROP POLICY "warehouses: owner can update" ON public.warehouses;
CREATE POLICY "warehouses: managed with warehouses.manage" ON public.warehouses FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('warehouses.manage'));
CREATE POLICY "warehouses: updated with warehouses.manage" ON public.warehouses FOR UPDATE
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('warehouses.manage'))
  WITH CHECK (organization_id = public.get_my_org_id());

-- What each role may do is system configuration
DROP POLICY "roles: owner can manage" ON public.roles;
CREATE POLICY "roles: technical admin manages" ON public.roles FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('system.manage'))
  WITH CHECK (organization_id = public.get_my_org_id());

DROP POLICY "role_permissions: owner can manage" ON public.role_permissions;
CREATE POLICY "role_permissions: technical admin manages" ON public.role_permissions FOR ALL
  USING (EXISTS (SELECT 1 FROM public.roles r WHERE r.id = role_id AND r.organization_id = public.get_my_org_id())
         AND public.has_permission('system.manage'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.roles r WHERE r.id = role_id AND r.organization_id = public.get_my_org_id())
              AND public.has_permission('system.manage'));

-- Who has which role is staffing (users.manage, org-wide) — except the
-- Technical admin role, which only a Technical admin grants or removes
CREATE OR REPLACE FUNCTION public.is_technical_role(p_role_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.roles WHERE id = p_role_id AND name = 'owner' AND is_system_role)
$$;

DROP POLICY "user_roles: owner can manage" ON public.user_roles;
CREATE POLICY "user_roles: staffing with users.manage" ON public.user_roles FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('users.manage')
              AND (NOT public.is_technical_role(role_id) OR public.has_permission('system.manage')))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('users.manage')
              AND (NOT public.is_technical_role(role_id) OR public.has_permission('system.manage')));


-- ------------------------------------------------------------
-- 4. Counts by someone without correction rights go to approval
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_corrective_movement_approved()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE corrective boolean;
BEGIN
  IF auth.uid() IS NULL                                            -- server-side scripts
     OR NEW.movement_type = 'reclassification'                     -- product admins only (028)
     OR public.has_permission('inventory.adjust')                  -- org-wide admin
     OR coalesce(current_setting('mois.approved_change', true), '') = 'on' THEN
    RETURN NEW;
  END IF;
  corrective := NEW.movement_type IN ('adjustment', 'opening_balance', 'reversal')
             OR NEW.movement_date < public.org_today(NEW.organization_id)
             -- a count's difference is a correction unless the counter may correct stock here (034)
             OR (NEW.movement_type = 'count' AND NOT public.has_permission_at('inventory.adjust', NEW.branch_id, NEW.warehouse_id));
  IF NOT corrective THEN RETURN NEW; END IF;
  RAISE EXCEPTION 'Corrections, backdated entries and count differences need an admin''s approval — submit this for approval instead'
    USING ERRCODE = '42501';
END;
$$;

-- request_change(): same as 033, except a count can be submitted by
-- whoever may count at that store
CREATE OR REPLACE FUNCTION public.request_change(p_kind text, p_branch_id uuid, p_payload jsonb, p_summary text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org    uuid := public.get_my_org_id();
  br     uuid;
  wh     uuid;
  new_id uuid;
BEGIN
  IF org IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not signed in to an organization' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_summary), '') IS NULL THEN
    RAISE EXCEPTION 'Describe the change' USING ERRCODE = '23514';
  END IF;

  IF p_kind = 'price' THEN
    br := p_branch_id;
    IF jsonb_typeof(p_payload->'rows') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'rows') = 0 THEN
      RAISE EXCEPTION 'No price to change' USING ERRCODE = '23514';
    END IF;
    IF NOT public.has_permission_at('products.manage', br, NULL) THEN
      RAISE EXCEPTION 'You can''t change prices at this branch' USING ERRCODE = '42501';
    END IF;
  ELSIF p_kind IN ('stock_movement', 'stock_reversal', 'stock_import') THEN
    -- the store decides the branch; never trust the caller's branch
    wh := CASE p_kind
            WHEN 'stock_movement' THEN nullif(p_payload->>'warehouse_id', '')::uuid
            WHEN 'stock_reversal' THEN (SELECT warehouse_id FROM public.inventory_movements
                                        WHERE id = nullif(p_payload->>'movement_id', '')::uuid AND organization_id = org)
            ELSE nullif(p_payload->'batch'->'movements'->0->>'warehouse_id', '')::uuid END;
    SELECT branch_id INTO br FROM public.warehouses WHERE id = wh AND organization_id = org;
    IF br IS NULL THEN RAISE EXCEPTION 'Store not found' USING ERRCODE = '23514'; END IF;
    IF p_kind = 'stock_import' AND EXISTS (
         SELECT 1 FROM jsonb_array_elements(p_payload->'batch'->'movements') m
         WHERE (SELECT branch_id FROM public.warehouses WHERE id = nullif(m->>'warehouse_id', '')::uuid) IS DISTINCT FROM br) THEN
      RAISE EXCEPTION 'One import goes to one branch' USING ERRCODE = '23514';
    END IF;
    IF p_kind = 'stock_movement' AND p_payload->>'type' = 'count' THEN
      IF NOT public.has_permission_at('inventory.count', br, wh) THEN
        RAISE EXCEPTION 'You can''t count stock at this store' USING ERRCODE = '42501';
      END IF;
    ELSIF NOT public.has_permission_at('inventory.adjust', br, wh) THEN
      RAISE EXCEPTION 'You can''t correct stock at this store' USING ERRCODE = '42501';
    END IF;
  ELSE
    RAISE EXCEPTION 'Unknown kind of change' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.pending_changes (organization_id, branch_id, kind, summary, payload, requested_by)
  VALUES (org, br, p_kind, btrim(p_summary), p_payload, auth.uid())
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;
