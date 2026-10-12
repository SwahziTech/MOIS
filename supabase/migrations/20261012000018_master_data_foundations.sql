-- ============================================================
-- Migration 018: Master-data foundations (Phase 1a.1, step 1)
--
-- Generic to ANY master-data entity (products, materials, recipes, prices,
-- categories, palette, units, ...), not built around one of them:
--   1. has_permission(code) — master-data writes need the matching
--      permission from an ORG-WIDE role grant (build-plan 1a.1: org admins,
--      not branch managers). Replaces the owner-only write policies.
--   2. audit_log + audit_row_change() — every insert/update/delete on a
--      master table records who, what field, old value, new value, when.
--      Enforced by triggers, so no screen or script can skip it.
--   3. review_flags — "needs review" markers on any entity, several per
--      entity, each opened and resolved with an audit trail.
--   4. prevent_hard_delete() — master records are deactivated, never
--      deleted, by app users (server-side scripts are exempt).
--   5. status on product_categories and units, so every entity can be
--      deactivated the same way.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Permission check
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.has_permission(code text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles ur
    JOIN public.roles r             ON r.id = ur.role_id
    JOIN public.role_permissions rp ON rp.role_id = r.id
    JOIN public.permissions p       ON p.id = rp.permission_id
    WHERE ur.user_id = auth.uid()
      AND ur.organization_id = public.get_my_org_id()
      AND r.organization_id = ur.organization_id
      AND ur.branch_id IS NULL      -- org-wide grants only: master data is
      AND ur.warehouse_id IS NULL   -- shared by every branch
      AND p.code = has_permission.code
  )
$$;

COMMENT ON FUNCTION public.has_permission(text)
  IS 'True if the caller holds this permission through an org-wide (not branch/warehouse-scoped) role in their active organization.';


-- ------------------------------------------------------------
-- 2. Audit trail
-- ------------------------------------------------------------
CREATE TABLE public.audit_log (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  organization_id uuid NOT NULL,        -- no FK: the record outlives what it describes
  entity_type     text NOT NULL,        -- 'product', 'material', 'product_price', ...
  entity_id       text NOT NULL,        -- id, or 'a|b' for composite keys
  action          text NOT NULL CHECK (action IN ('insert', 'update', 'delete')),
  field           text,                 -- set for updates (one row per changed field)
  old_value       jsonb,
  new_value       jsonb,
  changed_by      uuid,                 -- auth user; NULL for server-side scripts
  changed_via     text NOT NULL CHECK (changed_via IN ('app', 'service', 'sql')),
  changed_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_entity ON public.audit_log (organization_id, entity_type, entity_id, changed_at DESC);
CREATE INDEX idx_audit_org_time ON public.audit_log (organization_id, changed_at DESC);

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

-- Readable by org admins; written only by the trigger; immutable.
CREATE POLICY "audit_log: admins read own org"
  ON public.audit_log FOR SELECT
  USING (organization_id = public.get_my_org_id() AND public.has_permission('org.manage'));

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.audit_log FROM anon, authenticated;

COMMENT ON TABLE public.audit_log
  IS 'Immutable change history for master data (PRD §6.42, §10.15). Written only by audit_row_change().';

-- TG_ARGV[0] = entity type label; TG_ARGV[1] = key column(s), default 'id'
CREATE OR REPLACE FUNCTION public.audit_row_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  entity  text   := TG_ARGV[0];
  keys    text[] := string_to_array(coalesce(TG_ARGV[1], 'id'), ',');
  old_row jsonb  := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
  new_row jsonb  := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
  rec     jsonb  := coalesce(new_row, old_row);
  via     text   := CASE WHEN auth.role() = 'service_role' THEN 'service'
                         WHEN auth.uid() IS NULL THEN 'sql'
                         ELSE 'app' END;
  org     uuid;
  eid     text;
  k       text;
BEGIN
  SELECT string_agg(rec ->> key, '|' ORDER BY ord) INTO eid
  FROM unnest(keys) WITH ORDINALITY AS t(key, ord);

  -- Organization of the row (child tables without organization_id resolve
  -- it through their parent)
  org := CASE WHEN TG_TABLE_NAME = 'organizations' THEN (rec ->> 'id')::uuid
              ELSE (rec ->> 'organization_id')::uuid END;
  IF org IS NULL AND rec ? 'recipe_version_id' THEN
    SELECT organization_id INTO org FROM public.recipe_versions WHERE id = (rec ->> 'recipe_version_id')::uuid;
  END IF;
  IF org IS NULL AND rec ? 'role_id' THEN
    SELECT organization_id INTO org FROM public.roles WHERE id = (rec ->> 'role_id')::uuid;
  END IF;
  IF org IS NULL THEN
    RETURN coalesce(NEW, OLD);   -- not tenant data (e.g. a profile before it joins an org)
  END IF;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.audit_log (organization_id, entity_type, entity_id, action, new_value, changed_by, changed_via)
    VALUES (org, entity, eid, 'insert', new_row, auth.uid(), via);
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO public.audit_log (organization_id, entity_type, entity_id, action, old_value, changed_by, changed_via)
    VALUES (org, entity, eid, 'delete', old_row, auth.uid(), via);
  ELSE
    FOR k IN SELECT jsonb_object_keys(new_row) LOOP
      CONTINUE WHEN k IN ('updated_at', 'created_at');
      IF (old_row -> k) IS DISTINCT FROM (new_row -> k) THEN
        INSERT INTO public.audit_log (organization_id, entity_type, entity_id, action, field, old_value, new_value, changed_by, changed_via)
        VALUES (org, entity, eid, 'update', k, old_row -> k, new_row -> k, auth.uid(), via);
      END IF;
    END LOOP;
  END IF;

  RETURN coalesce(NEW, OLD);
END;
$$;


-- ------------------------------------------------------------
-- 3. Review flags
-- ------------------------------------------------------------
CREATE TABLE public.review_flags (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  entity_type     text NOT NULL,       -- same labels as audit_log.entity_type
  entity_id       text NOT NULL,
  reason_code     text NOT NULL,       -- e.g. 'possible_duplicate', 'missing_unit'
  reason          text NOT NULL,       -- human explanation shown to the admin
  status          text NOT NULL DEFAULT 'open'
                    CHECK (status IN ('open', 'resolved', 'dismissed')),
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  resolved_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  resolved_at     timestamptz,
  resolution_note text,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CHECK ((status = 'open') = (resolved_at IS NULL))
);

-- One OPEN flag per entity per reason
CREATE UNIQUE INDEX uq_review_flags_open
  ON public.review_flags (organization_id, entity_type, entity_id, reason_code)
  WHERE status = 'open';
CREATE INDEX idx_review_flags_entity ON public.review_flags (organization_id, entity_type, entity_id);

CREATE TRIGGER trg_review_flags_updated_at
  BEFORE UPDATE ON public.review_flags
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.review_flags ENABLE ROW LEVEL SECURITY;

CREATE POLICY "review_flags: read own org"
  ON public.review_flags FOR SELECT
  USING (organization_id = public.get_my_org_id());

CREATE POLICY "review_flags: master-data admins write"
  ON public.review_flags FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id()
              AND (public.has_permission('products.manage') OR public.has_permission('materials.manage')));

CREATE POLICY "review_flags: master-data admins update"
  ON public.review_flags FOR UPDATE
  USING      (organization_id = public.get_my_org_id()
              AND (public.has_permission('products.manage') OR public.has_permission('materials.manage')))
  WITH CHECK (organization_id = public.get_my_org_id()
              AND (public.has_permission('products.manage') OR public.has_permission('materials.manage')));

COMMENT ON TABLE public.review_flags
  IS '"Needs review" markers on any master-data entity (entity_type + entity_id). Resolved or dismissed, never deleted.';


-- ------------------------------------------------------------
-- 4. Deactivate, never delete (app users); server-side scripts exempt
-- ------------------------------------------------------------
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
  RAISE EXCEPTION '% records cannot be deleted — deactivate them instead', TG_ARGV[0]
    USING ERRCODE = '42501';
END;
$$;


-- ------------------------------------------------------------
-- 5. Status on entities that had none
-- ------------------------------------------------------------
ALTER TABLE public.product_categories
  ADD COLUMN status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive'));
ALTER TABLE public.units
  ADD COLUMN status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive'));


-- ------------------------------------------------------------
-- 6. Attach audit + no-delete to the existing master tables
-- ------------------------------------------------------------
DO $$
DECLARE t record;
BEGIN
  -- table, entity label, key columns, deactivate-only?
  FOR t IN SELECT * FROM (VALUES
    ('organizations',                'organization',           'id',                         false),
    ('branches',                     'branch',                 'id',                         true),
    ('warehouses',                   'warehouse',              'id',                         true),
    ('profiles',                     'profile',                'id',                         false),
    ('roles',                        'role',                   'id',                         false),
    ('role_permissions',             'role_permission',        'role_id,permission_id',      false),
    ('user_roles',                   'user_role',              'id',                         false),
    ('units',                        'unit',                   'id',                         true),
    ('color_palette',                'color',                  'id',                         true),
    ('product_categories',           'product_category',       'id',                         true),
    ('product_category_colors',      'product_category_color', 'category_id,color_id',       false),
    ('products',                     'product',                'id',                         true),
    ('materials',                    'material',               'id',                         true),
    ('recipe_versions',              'recipe_version',         'id',                         true),
    ('recipe_items',                 'recipe_item',            'id',                         false),
    ('recipe_version_products',      'recipe_product',         'recipe_version_id,product_id', false),
    ('product_branch_pricing',       'product_price',          'id',                         true),
    ('category_color_pricing_rules', 'color_pricing_rule',     'id',                         true),
    ('category_color_price_items',   'color_price',            'rule_id,color_id',           false),
    ('review_flags',                 'review_flag',            'id',                         true)
  ) AS v(tbl, entity, keys, no_delete)
  LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_%s_audit AFTER INSERT OR UPDATE OR DELETE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION public.audit_row_change(%L, %L)',
      t.tbl, t.tbl, t.entity, t.keys);
    IF t.no_delete THEN
      EXECUTE format(
        'CREATE TRIGGER trg_%s_no_delete BEFORE DELETE ON public.%I '
        'FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete(%L)',
        t.tbl, t.tbl, t.entity);
    END IF;
  END LOOP;
END $$;


-- ------------------------------------------------------------
-- 7. Master-data writes: matching permission instead of owner-only
-- ------------------------------------------------------------
-- products.manage: products, categories, palette, recipes, prices
DROP POLICY "products: owner can manage" ON public.products;
CREATE POLICY "products: admins can manage" ON public.products FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'));

DROP POLICY "product_categories: owner can manage" ON public.product_categories;
CREATE POLICY "product_categories: admins can manage" ON public.product_categories FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'));

DROP POLICY "color_palette: owner can manage" ON public.color_palette;
CREATE POLICY "color_palette: admins can manage" ON public.color_palette FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'));

DROP POLICY "pcc: owner can manage" ON public.product_category_colors;
CREATE POLICY "pcc: admins can manage" ON public.product_category_colors FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'));

DROP POLICY "recipe_versions: owner can manage" ON public.recipe_versions;
CREATE POLICY "recipe_versions: admins can manage" ON public.recipe_versions FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'));

DROP POLICY "recipe_items: owner can manage" ON public.recipe_items;
CREATE POLICY "recipe_items: admins can manage" ON public.recipe_items FOR ALL
  USING (EXISTS (SELECT 1 FROM public.recipe_versions rv
                 WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id())
         AND public.has_permission('products.manage'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.recipe_versions rv
                      WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id())
              AND public.has_permission('products.manage'));

DROP POLICY "rvp: owner can manage" ON public.recipe_version_products;
CREATE POLICY "rvp: admins can manage" ON public.recipe_version_products FOR ALL
  USING (EXISTS (SELECT 1 FROM public.recipe_versions rv
                 WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id())
         AND public.has_permission('products.manage'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.recipe_versions rv
                      WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id())
              AND public.has_permission('products.manage'));

DROP POLICY "pricing: owner can manage" ON public.product_branch_pricing;
CREATE POLICY "pricing: admins can manage" ON public.product_branch_pricing FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'));

DROP POLICY "color_rules: owner can manage" ON public.category_color_pricing_rules;
CREATE POLICY "color_rules: admins can manage" ON public.category_color_pricing_rules FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'));

DROP POLICY "ccpi: owner can manage" ON public.category_color_price_items;
CREATE POLICY "ccpi: admins can manage" ON public.category_color_price_items FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'));

-- materials.manage: materials (material tables in migration 019 follow suit)
DROP POLICY "materials: owner can manage" ON public.materials;
CREATE POLICY "materials: admins can manage" ON public.materials FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('materials.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('materials.manage'));

-- units are shared by products and materials
DROP POLICY "units: owner can manage" ON public.units;
CREATE POLICY "units: admins can manage" ON public.units FOR ALL
  USING      (organization_id = public.get_my_org_id()
              AND (public.has_permission('products.manage') OR public.has_permission('materials.manage')))
  WITH CHECK (organization_id = public.get_my_org_id()
              AND (public.has_permission('products.manage') OR public.has_permission('materials.manage')));
