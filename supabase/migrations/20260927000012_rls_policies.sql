-- ============================================================
-- Migration 012: All RLS Policies
--
-- Philosophy (from AGENTS.md):
--   RLS is the authoritative security boundary.
--   Frontend WHERE clauses are UX convenience only, never security.
--   Every tenant table uses get_my_org_id() so the check is
--   evaluated server-side, once per query, not once per row.
-- ============================================================

-- ============================================================
-- organizations
-- Users can only see the org they belong to.
-- Only platform admins can create orgs (handled by service role in seed).
-- ============================================================
CREATE POLICY "org: read own org"
  ON public.organizations FOR SELECT
  USING (public.is_member_of(id));

-- Org owners can update their own org settings
CREATE POLICY "org: owner can update"
  ON public.organizations FOR UPDATE
  USING (public.is_member_of(id) AND public.is_org_owner())
  WITH CHECK (public.is_member_of(id) AND public.is_org_owner());

-- ============================================================
-- profiles
-- ============================================================
-- Users can read their own profile always
CREATE POLICY "profiles: read own"
  ON public.profiles FOR SELECT
  USING (id = auth.uid());

-- Users in the same org can see each other (for user management UI)
CREATE POLICY "profiles: read same org"
  ON public.profiles FOR SELECT
  USING (organization_id = public.get_my_org_id());

-- Users can update their own profile only
CREATE POLICY "profiles: update own"
  ON public.profiles FOR UPDATE
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- Service role (seed script) can insert profiles
-- (Automatic via trigger; anon insert disabled)
CREATE POLICY "profiles: insert own on signup"
  ON public.profiles FOR INSERT
  WITH CHECK (id = auth.uid());

-- ============================================================
-- branches
-- ============================================================
CREATE POLICY "branches: read own org"
  ON public.branches FOR SELECT
  USING (organization_id = public.get_my_org_id());

CREATE POLICY "branches: owner can insert"
  ON public.branches FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.is_org_owner());

CREATE POLICY "branches: owner can update"
  ON public.branches FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id());

-- ============================================================
-- warehouses
-- ============================================================
CREATE POLICY "warehouses: read own org"
  ON public.warehouses FOR SELECT
  USING (organization_id = public.get_my_org_id());

CREATE POLICY "warehouses: owner can insert"
  ON public.warehouses FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.is_org_owner());

CREATE POLICY "warehouses: owner can update"
  ON public.warehouses FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id());

-- ============================================================
-- roles
-- ============================================================
CREATE POLICY "roles: read own org"
  ON public.roles FOR SELECT
  USING (organization_id = public.get_my_org_id());

CREATE POLICY "roles: owner can manage"
  ON public.roles FOR ALL
  USING (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id());

-- ============================================================
-- permissions (platform-wide, readable by all authenticated users)
-- ============================================================
CREATE POLICY "permissions: read by authenticated"
  ON public.permissions FOR SELECT
  TO authenticated
  USING (true);

-- ============================================================
-- role_permissions
-- ============================================================
CREATE POLICY "role_permissions: read own org roles"
  ON public.role_permissions FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.roles r
      WHERE r.id = role_id AND r.organization_id = public.get_my_org_id()
    )
  );

CREATE POLICY "role_permissions: owner can manage"
  ON public.role_permissions FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.roles r
      WHERE r.id = role_id AND r.organization_id = public.get_my_org_id()
    ) AND public.is_org_owner()
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.roles r
      WHERE r.id = role_id AND r.organization_id = public.get_my_org_id()
    )
  );

-- ============================================================
-- user_roles
-- ============================================================
CREATE POLICY "user_roles: read own org"
  ON public.user_roles FOR SELECT
  USING (organization_id = public.get_my_org_id());

CREATE POLICY "user_roles: owner can manage"
  ON public.user_roles FOR ALL
  USING (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id());

-- ============================================================
-- units
-- ============================================================
CREATE POLICY "units: read own org"
  ON public.units FOR SELECT
  USING (organization_id = public.get_my_org_id());

CREATE POLICY "units: owner can manage"
  ON public.units FOR ALL
  USING (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id());

-- ============================================================
-- product_categories
-- ============================================================
CREATE POLICY "product_categories: read own org"
  ON public.product_categories FOR SELECT
  USING (organization_id = public.get_my_org_id());

CREATE POLICY "product_categories: owner can manage"
  ON public.product_categories FOR ALL
  USING (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id());

-- ============================================================
-- products
-- ============================================================
CREATE POLICY "products: read own org"
  ON public.products FOR SELECT
  USING (organization_id = public.get_my_org_id());

CREATE POLICY "products: owner can manage"
  ON public.products FOR ALL
  USING (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id());

-- ============================================================
-- product_branch_pricing
-- ============================================================
CREATE POLICY "pricing: read own org"
  ON public.product_branch_pricing FOR SELECT
  USING (organization_id = public.get_my_org_id());

CREATE POLICY "pricing: owner can manage"
  ON public.product_branch_pricing FOR ALL
  USING (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id());

-- ============================================================
-- category_color_pricing_rules
-- ============================================================
CREATE POLICY "color_rules: read own org"
  ON public.category_color_pricing_rules FOR SELECT
  USING (organization_id = public.get_my_org_id());

CREATE POLICY "color_rules: owner can manage"
  ON public.category_color_pricing_rules FOR ALL
  USING (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id());

-- ============================================================
-- materials
-- ============================================================
CREATE POLICY "materials: read own org"
  ON public.materials FOR SELECT
  USING (organization_id = public.get_my_org_id());

CREATE POLICY "materials: owner can manage"
  ON public.materials FOR ALL
  USING (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id());

-- ============================================================
-- recipe_versions
-- ============================================================
CREATE POLICY "recipe_versions: read own org"
  ON public.recipe_versions FOR SELECT
  USING (organization_id = public.get_my_org_id());

CREATE POLICY "recipe_versions: owner can manage"
  ON public.recipe_versions FOR ALL
  USING (organization_id = public.get_my_org_id() AND public.is_org_owner())
  WITH CHECK (organization_id = public.get_my_org_id());

-- ============================================================
-- recipe_items
-- ============================================================
CREATE POLICY "recipe_items: read own org"
  ON public.recipe_items FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.recipe_versions rv
      WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id()
    )
  );

CREATE POLICY "recipe_items: owner can manage"
  ON public.recipe_items FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.recipe_versions rv
      WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id()
    ) AND public.is_org_owner()
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.recipe_versions rv
      WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id()
    )
  );

-- ============================================================
-- recipe_version_products
-- ============================================================
CREATE POLICY "rvp: read own org"
  ON public.recipe_version_products FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.recipe_versions rv
      WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id()
    )
  );

CREATE POLICY "rvp: owner can manage"
  ON public.recipe_version_products FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.recipe_versions rv
      WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id()
    ) AND public.is_org_owner()
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.recipe_versions rv
      WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id()
    )
  );
