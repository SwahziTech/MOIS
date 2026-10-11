-- ============================================================
-- Migration 013: Security hardening (Phase 1a audit, 2026-10-11)
--
-- Fixes found while auditing migrations 001-012 against AGENTS.md §1
-- ("RLS is the authoritative boundary"). Each section names the hole
-- it closes. Review before `supabase db push`.
-- ============================================================


-- ------------------------------------------------------------
-- 1. permissions: RLS was never enabled (migration 006).
--    Verified on the live project: the public anon key could read
--    AND update this table. The policy in 012 had no effect because
--    RLS was off. Permissions are platform-defined and read-only
--    for every API role.
-- ------------------------------------------------------------
ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.permissions FROM anon, authenticated;


-- ------------------------------------------------------------
-- 2. is_org_owner() was not scoped to an organization.
--    It returned true if the caller was 'owner' in ANY org, and
--    never compared against the caller's current org.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_org_owner()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles ur
    JOIN public.roles r ON r.id = ur.role_id
    WHERE ur.user_id = auth.uid()
      AND ur.organization_id = public.get_my_org_id()
      AND r.organization_id  = ur.organization_id
      AND r.name = 'owner'
      AND r.is_system_role
  )
$$;


-- ------------------------------------------------------------
-- 3. profiles: a user could UPDATE their own organization_id.
--    Setting it to another org's id put them inside that tenant,
--    because every policy trusts get_my_org_id(). Users may still
--    edit their name/phone/avatar. Only the service role (seed,
--    future invite Edge Function) may change org membership or status.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.protect_profile_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- service_role (seed / server-side) and direct SQL (no JWT) are trusted
  IF auth.role() = 'service_role' OR auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
    RAISE EXCEPTION 'Organization membership cannot be changed from the client'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'Account status cannot be changed from the client'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_profiles_protect_columns
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.protect_profile_columns();

-- The signup trigger creates the profile; a client-side insert must not
-- be able to pre-set an organization.
DROP POLICY "profiles: insert own on signup" ON public.profiles;
CREATE POLICY "profiles: insert own on signup"
  ON public.profiles FOR INSERT
  WITH CHECK (id = auth.uid() AND organization_id IS NULL AND status = 'active');


-- ------------------------------------------------------------
-- 4. "owner can manage" FOR ALL policies checked is_org_owner() in
--    USING only. INSERT is evaluated against WITH CHECK alone, so ANY
--    member of the org could insert rows, including a user_roles row
--    granting themselves 'owner'. Recreate every one with the owner
--    check in WITH CHECK too.
-- ------------------------------------------------------------
DROP POLICY "roles: owner can manage" ON public.roles;
CREATE POLICY "roles: owner can manage"
  ON public.roles FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id() AND public.is_org_owner());

DROP POLICY "user_roles: owner can manage" ON public.user_roles;
CREATE POLICY "user_roles: owner can manage"
  ON public.user_roles FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id() AND public.is_org_owner());

DROP POLICY "units: owner can manage" ON public.units;
CREATE POLICY "units: owner can manage"
  ON public.units FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id() AND public.is_org_owner());

DROP POLICY "product_categories: owner can manage" ON public.product_categories;
CREATE POLICY "product_categories: owner can manage"
  ON public.product_categories FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id() AND public.is_org_owner());

DROP POLICY "products: owner can manage" ON public.products;
CREATE POLICY "products: owner can manage"
  ON public.products FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id() AND public.is_org_owner());

DROP POLICY "pricing: owner can manage" ON public.product_branch_pricing;
CREATE POLICY "pricing: owner can manage"
  ON public.product_branch_pricing FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id() AND public.is_org_owner());

DROP POLICY "color_rules: owner can manage" ON public.category_color_pricing_rules;
CREATE POLICY "color_rules: owner can manage"
  ON public.category_color_pricing_rules FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id() AND public.is_org_owner());

DROP POLICY "materials: owner can manage" ON public.materials;
CREATE POLICY "materials: owner can manage"
  ON public.materials FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id() AND public.is_org_owner());

DROP POLICY "recipe_versions: owner can manage" ON public.recipe_versions;
CREATE POLICY "recipe_versions: owner can manage"
  ON public.recipe_versions FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id() AND public.is_org_owner());

DROP POLICY "role_permissions: owner can manage" ON public.role_permissions;
CREATE POLICY "role_permissions: owner can manage"
  ON public.role_permissions FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.roles r
            WHERE r.id = role_id AND r.organization_id = public.get_my_org_id())
    AND public.is_org_owner()
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.roles r
            WHERE r.id = role_id AND r.organization_id = public.get_my_org_id())
    AND public.is_org_owner()
  );

DROP POLICY "recipe_items: owner can manage" ON public.recipe_items;
CREATE POLICY "recipe_items: owner can manage"
  ON public.recipe_items FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.recipe_versions rv
            WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id())
    AND public.is_org_owner()
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.recipe_versions rv
            WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id())
    AND public.is_org_owner()
  );

DROP POLICY "rvp: owner can manage" ON public.recipe_version_products;
CREATE POLICY "rvp: owner can manage"
  ON public.recipe_version_products FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.recipe_versions rv
            WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id())
    AND public.is_org_owner()
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.recipe_versions rv
            WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id())
    AND public.is_org_owner()
  );


-- ------------------------------------------------------------
-- 5. user_roles could reference a role, branch, warehouse or user
--    belonging to a DIFFERENT organization (nothing tied them to
--    user_roles.organization_id).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_user_role_scope()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.roles
                 WHERE id = NEW.role_id AND organization_id = NEW.organization_id) THEN
    RAISE EXCEPTION 'Role does not belong to this organization' USING ERRCODE = '23514';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.profiles
                 WHERE id = NEW.user_id AND organization_id = NEW.organization_id) THEN
    RAISE EXCEPTION 'User is not a member of this organization' USING ERRCODE = '23514';
  END IF;

  IF NEW.branch_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.branches
       WHERE id = NEW.branch_id AND organization_id = NEW.organization_id) THEN
    RAISE EXCEPTION 'Branch does not belong to this organization' USING ERRCODE = '23514';
  END IF;

  IF NEW.warehouse_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.warehouses
       WHERE id = NEW.warehouse_id AND organization_id = NEW.organization_id) THEN
    RAISE EXCEPTION 'Warehouse does not belong to this organization' USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_user_roles_scope
  BEFORE INSERT OR UPDATE ON public.user_roles
  FOR EACH ROW EXECUTE FUNCTION public.check_user_role_scope();


-- ------------------------------------------------------------
-- 6. user_roles.user_id referenced auth.users only, so PostgREST could
--    not embed user_roles under profiles. Verified live: the Users page
--    query failed with PGRST200. Every auth user has a profile (signup
--    trigger), so the extra FK is safe.
-- ------------------------------------------------------------
ALTER TABLE public.user_roles
  ADD CONSTRAINT fk_user_roles_profile
  FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


-- ------------------------------------------------------------
-- 7. UNIQUE constraints over nullable columns treated NULLs as
--    distinct, so they never fired for:
--      - product_branch_pricing (product, branch, color=NULL): every
--        row the seed writes has color NULL, so re-running the seed
--        duplicated prices
--      - user_roles (..., branch_id=NULL, warehouse_id=NULL): org-wide
--        role grants could be duplicated
--    Remove exact duplicates (keep the oldest row) and switch to
--    NULLS NOT DISTINCT (PostgreSQL 15+).
-- ------------------------------------------------------------
DELETE FROM public.product_branch_pricing a
USING public.product_branch_pricing b
WHERE a.product_id = b.product_id
  AND a.branch_id  = b.branch_id
  AND a.color IS NOT DISTINCT FROM b.color
  AND (a.created_at, a.id) > (b.created_at, b.id);

DELETE FROM public.user_roles a
USING public.user_roles b
WHERE a.user_id = b.user_id
  AND a.role_id = b.role_id
  AND a.organization_id = b.organization_id
  AND a.branch_id    IS NOT DISTINCT FROM b.branch_id
  AND a.warehouse_id IS NOT DISTINCT FROM b.warehouse_id
  AND (a.created_at, a.id) > (b.created_at, b.id);

-- Drop the old auto-named UNIQUE constraints by column set (names are
-- auto-generated / truncated, so look them up rather than hardcode).
DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT con.conname, con.conrelid::regclass AS tbl
    FROM pg_constraint con
    WHERE con.contype = 'u'
      AND (
        (con.conrelid = 'public.product_branch_pricing'::regclass
          AND con.conkey::int[] @> ARRAY(
                SELECT attnum::int FROM pg_attribute
                WHERE attrelid = 'public.product_branch_pricing'::regclass
                  AND attname IN ('product_id','branch_id','color')))
        OR
        (con.conrelid = 'public.user_roles'::regclass
          AND con.conkey::int[] @> ARRAY(
                SELECT attnum::int FROM pg_attribute
                WHERE attrelid = 'public.user_roles'::regclass
                  AND attname IN ('user_id','role_id','organization_id','branch_id','warehouse_id')))
      )
  LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', c.tbl, c.conname);
  END LOOP;
END;
$$;

ALTER TABLE public.product_branch_pricing
  ADD CONSTRAINT product_branch_pricing_unique
  UNIQUE NULLS NOT DISTINCT (product_id, branch_id, color);

ALTER TABLE public.user_roles
  ADD CONSTRAINT user_roles_unique
  UNIQUE NULLS NOT DISTINCT (user_id, role_id, organization_id, branch_id, warehouse_id);
