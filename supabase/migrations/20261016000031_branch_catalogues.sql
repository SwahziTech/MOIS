-- ============================================================
-- 031 — Branch catalogues, branch recipes, size specs (1b)
--         PROPOSED — not applied. Dry-run on a live snapshot first.
--
-- Until now one org-wide product list and one org-wide recipe per
-- category + colour were assumed, with only prices varying by branch.
-- Branches don't all carry the same products, and their mixing ratios can
-- differ. Decided with SwahziTech (2026-10-16):
--
--   1. A product stays one shared identity (name, category, stock unit,
--      size, strength). What a branch SELLS is its own catalogue:
--      branch_products, one row per product the branch carries. No row =
--      not carried there. Same identity lets stock move between branches
--      and reports add up across them.
--   2. Recipes belong to a branch: one active recipe per branch + category
--      + colour/variant (AGENTS.md §3's sharing across molds still holds,
--      within a branch). A branch can start from another branch's recipe
--      (copy_recipe_to_branch); the copy is independent afterwards.
--   3. Pieces per m² and average yield per bag come from size + strength
--      (product_size_specs), shared by every design of that size; a branch
--      can override the yield. Yield is a quality-control EXPECTATION with
--      a ± tolerance — never a formula for posting output. Actual output is
--      what gets recorded; 1d compares it to the band and flags outliers.
--   4. Existing data is kept, not deleted: each organization's existing
--      products and recipes become its default branch's (Stumarcot:
--      Dodoma); every existing price row also puts that product in that
--      branch's catalogue (Mwanza, Dar es Salaam).
--   5. Suppliers are recorded per purchase only (receipts already carry
--      supplier_id). Fixed per-material sources are retired.
--   6. Branch managers may edit their own branch's catalogue and recipes:
--      products.manage granted to the branch_manager role — through a
--      branch-scoped grant, so has_permission() (org-wide) is unaffected.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Branch catalogues
-- ------------------------------------------------------------
CREATE TABLE public.branch_products (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  product_id      uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  -- how the product got into this catalogue
  source          text NOT NULL DEFAULT 'app'
                    CHECK (source IN ('app', 'existing_catalogue', 'price_list', 'price', 'stock', 'merge')),
  notes           text,
  created_by      uuid REFERENCES auth.users(id) DEFAULT auth.uid(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (branch_id, product_id)
);

CREATE INDEX idx_branch_products_org     ON public.branch_products(organization_id);
CREATE INDEX idx_branch_products_product ON public.branch_products(product_id);

CREATE TRIGGER trg_branch_products_updated_at BEFORE UPDATE ON public.branch_products
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_branch_products_branch_org BEFORE INSERT OR UPDATE ON public.branch_products
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('branches', 'branch_id');
CREATE TRIGGER trg_branch_products_product_org BEFORE INSERT OR UPDATE ON public.branch_products
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('products', 'product_id');
CREATE TRIGGER trg_branch_products_audit AFTER INSERT OR UPDATE OR DELETE ON public.branch_products
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('branch_product', 'id');
CREATE TRIGGER trg_branch_products_no_delete BEFORE DELETE ON public.branch_products
  FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('branch_product');

ALTER TABLE public.branch_products ENABLE ROW LEVEL SECURITY;
CREATE POLICY "branch_products: read own org" ON public.branch_products FOR SELECT
  USING (organization_id = public.get_my_org_id());
CREATE POLICY "branch_products: managers of the branch" ON public.branch_products FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission_at('products.manage', branch_id, NULL))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_at('products.manage', branch_id, NULL));

COMMENT ON TABLE public.branch_products
  IS 'A branch''s own catalogue: one row per product it carries. No row = not carried there. The product itself (name, size, unit) is shared.';

-- A branch manager adding a product nobody else has creates its identity
-- too (renaming/editing shared identities stays org-admin only)
CREATE POLICY "products: branch managers add" ON public.products FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_anywhere('products.manage'));


-- ------------------------------------------------------------
-- 2. Recipes belong to a branch
-- ------------------------------------------------------------
ALTER TABLE public.recipe_versions
  ADD COLUMN branch_id uuid REFERENCES public.branches(id) ON DELETE RESTRICT,
  ADD COLUMN copied_from_version_id uuid REFERENCES public.recipe_versions(id);

COMMENT ON COLUMN public.recipe_versions.copied_from_version_id
  IS 'Provenance only: the recipe (possibly another branch''s) this one started from. Not a link — this copy is edited independently.';


-- ------------------------------------------------------------
-- 3. Existing data becomes the default branch's
-- ------------------------------------------------------------
DO $$
DECLARE
  o    record;
  home uuid;
BEGIN
  FOR o IN SELECT id, default_branch_id FROM public.organizations LOOP
    home := o.default_branch_id;
    IF home IS NULL AND (SELECT count(*) FROM public.branches WHERE organization_id = o.id) = 1 THEN
      SELECT id INTO home FROM public.branches WHERE organization_id = o.id;
    END IF;
    IF home IS NULL THEN
      IF EXISTS (SELECT 1 FROM public.products WHERE organization_id = o.id)
         OR EXISTS (SELECT 1 FROM public.recipe_versions WHERE organization_id = o.id) THEN
        RAISE EXCEPTION 'Organization % has products or recipes but no default branch — set organizations.default_branch_id first', o.id;
      END IF;
      CONTINUE;
    END IF;

    -- its catalogue so far, as the default branch's catalogue
    INSERT INTO public.branch_products (organization_id, branch_id, product_id, status, source, created_by)
    SELECT o.id, home, p.id, p.status, 'existing_catalogue', NULL
    FROM public.products p WHERE p.organization_id = o.id;

    -- its recipes (current and archived), as the default branch's recipes
    UPDATE public.recipe_versions SET branch_id = home WHERE organization_id = o.id;
  END LOOP;
END $$;

-- Every existing price row: that branch sells the product
INSERT INTO public.branch_products (organization_id, branch_id, product_id, status, source, created_by)
SELECT pb.organization_id, pb.branch_id, pb.product_id,
       CASE WHEN bool_and(p.status = 'active') AND bool_or(pb.is_available) THEN 'active' ELSE 'inactive' END,
       'price_list', NULL
FROM public.product_branch_pricing pb
JOIN public.products p ON p.id = pb.product_id
GROUP BY pb.organization_id, pb.branch_id, pb.product_id
ON CONFLICT (branch_id, product_id) DO NOTHING;

-- Default-branch products that the price list sells elsewhere but not
-- there: ask the branch to confirm it really carries them
INSERT INTO public.review_flags (organization_id, entity_type, entity_id, reason_code, reason)
SELECT bp.organization_id, 'branch_product', bp.id::text, 'unconfirmed_branch_carriage',
       format('%s is in %s''s product list because it was in the original catalogue, but the price list only sells it in %s. '
              'Does %s sell %s? If not, mark it as not carried in %s.',
              p.canonical_name, b.name,
              (SELECT string_agg(DISTINCT ob.name, ' and ') FROM public.product_branch_pricing x JOIN public.branches ob ON ob.id = x.branch_id
               WHERE x.product_id = p.id),
              b.name, p.canonical_name, b.name)
FROM public.branch_products bp
JOIN public.products p ON p.id = bp.product_id
JOIN public.branches b ON b.id = bp.branch_id
WHERE bp.source = 'existing_catalogue' AND p.status = 'active'
  AND NOT EXISTS (SELECT 1 FROM public.product_branch_pricing x WHERE x.product_id = p.id AND x.branch_id = bp.branch_id)
  AND EXISTS     (SELECT 1 FROM public.product_branch_pricing x WHERE x.product_id = p.id AND x.branch_id <> bp.branch_id);

ALTER TABLE public.recipe_versions ALTER COLUMN branch_id SET NOT NULL;
CREATE INDEX idx_recipe_versions_branch ON public.recipe_versions(branch_id);
CREATE TRIGGER trg_recipe_versions_branch_org BEFORE INSERT OR UPDATE ON public.recipe_versions
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('branches', 'branch_id');

ALTER TABLE public.recipe_versions DROP CONSTRAINT recipe_versions_unique;
ALTER TABLE public.recipe_versions
  ADD CONSTRAINT recipe_versions_unique
  UNIQUE NULLS NOT DISTINCT (organization_id, branch_id, category_id, color_id, variant_label, version_number);
DROP INDEX public.uq_recipe_versions_one_active;
CREATE UNIQUE INDEX uq_recipe_versions_one_active
  ON public.recipe_versions (organization_id, branch_id, category_id, color_id, variant_label)
  NULLS NOT DISTINCT
  WHERE status = 'active';

-- Saved versions stay frozen — now including their branch and provenance
-- (rows created in this transaction may still be finished off)
CREATE OR REPLACE FUNCTION public.freeze_recipe_version_keys()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF auth.role() = 'service_role' OR auth.uid() IS NULL OR public.recipe_version_is_new(NEW.id) THEN RETURN NEW; END IF;
  IF (NEW.branch_id, NEW.category_id, NEW.color_id, NEW.variant_label, NEW.version_number, NEW.effective_date, NEW.copied_from_version_id)
     IS DISTINCT FROM
     (OLD.branch_id, OLD.category_id, OLD.color_id, OLD.variant_label, OLD.version_number, OLD.effective_date, OLD.copied_from_version_id) THEN
    RAISE EXCEPTION 'A saved recipe cannot be edited — save a new version instead'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

-- Recipe writes: product admins of the recipe's branch
DROP POLICY "recipe_versions: admins can manage" ON public.recipe_versions;
CREATE POLICY "recipe_versions: managers of the branch" ON public.recipe_versions FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission_at('products.manage', branch_id, NULL))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_at('products.manage', branch_id, NULL));

DROP POLICY "recipe_items: admins can manage" ON public.recipe_items;
CREATE POLICY "recipe_items: managers of the branch" ON public.recipe_items FOR ALL
  USING (EXISTS (SELECT 1 FROM public.recipe_versions rv
                 WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id()
                   AND public.has_permission_at('products.manage', rv.branch_id, NULL)))
  WITH CHECK (EXISTS (SELECT 1 FROM public.recipe_versions rv
                      WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id()
                        AND public.has_permission_at('products.manage', rv.branch_id, NULL)));

DROP POLICY "rvp: admins can manage" ON public.recipe_version_products;
CREATE POLICY "rvp: managers of the branch" ON public.recipe_version_products FOR ALL
  USING (EXISTS (SELECT 1 FROM public.recipe_versions rv
                 WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id()
                   AND public.has_permission_at('products.manage', rv.branch_id, NULL)))
  WITH CHECK (EXISTS (SELECT 1 FROM public.recipe_versions rv
                      WHERE rv.id = recipe_version_id AND rv.organization_id = public.get_my_org_id()
                        AND public.has_permission_at('products.manage', rv.branch_id, NULL)));

-- A recipe can only be used by products its branch carries
CREATE OR REPLACE FUNCTION public.check_recipe_product_carried()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE prod text; br text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.recipe_versions rv
                 JOIN public.branch_products bp ON bp.branch_id = rv.branch_id AND bp.product_id = NEW.product_id
                 WHERE rv.id = NEW.recipe_version_id) THEN
    SELECT p.canonical_name, b.name INTO prod, br
    FROM public.recipe_versions rv JOIN public.branches b ON b.id = rv.branch_id, public.products p
    WHERE rv.id = NEW.recipe_version_id AND p.id = NEW.product_id;
    RAISE EXCEPTION '% isn''t in %''s product list — add it there before giving it a recipe', prod, br
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_rvp_product_carried BEFORE INSERT OR UPDATE ON public.recipe_version_products
  FOR EACH ROW EXECUTE FUNCTION public.check_recipe_product_carried();

-- create_recipe_version: same as 020, plus the branch. p_branch_id is
-- optional so existing callers keep working: a new recipe without one goes
-- to the organization's default branch.
DROP FUNCTION public.create_recipe_version(uuid, uuid, uuid, text, jsonb, uuid[], date, text);

CREATE FUNCTION public.create_recipe_version(
  p_replaces       uuid,
  p_category_id    uuid,
  p_color_id       uuid,
  p_variant_label  text,
  p_items          jsonb,    -- [{material_id, quantity, unit_id, quantity_confirmed, notes}]
  p_product_ids    uuid[],   -- products using the new version; NULL = same as the replaced one
  p_effective_date date,
  p_notes          text,
  p_branch_id      uuid DEFAULT NULL   -- new recipes only; NULL = the organization's default branch
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  org     uuid := public.get_my_org_id();
  old     public.recipe_versions;
  new_id  uuid;
  next_no int;
  bad     text;
BEGIN
  IF org IS NULL THEN
    RAISE EXCEPTION 'You don''t have permission to change recipes' USING ERRCODE = '42501';
  END IF;

  IF p_replaces IS NOT NULL THEN
    SELECT * INTO old FROM public.recipe_versions
    WHERE id = p_replaces AND organization_id = org
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Recipe not found' USING ERRCODE = '23514';
    END IF;
    IF old.status <> 'active' THEN
      RAISE EXCEPTION 'This recipe was changed meanwhile — reload and try again' USING ERRCODE = '23514';
    END IF;
    p_category_id   := old.category_id;
    p_color_id      := old.color_id;
    p_variant_label := old.variant_label;
    p_branch_id     := old.branch_id;
  ELSE
    p_branch_id := coalesce(p_branch_id, (SELECT default_branch_id FROM public.organizations WHERE id = org));
    IF p_branch_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id AND organization_id = org) THEN
      RAISE EXCEPTION 'Choose the branch this recipe is for' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NOT public.has_permission_at('products.manage', p_branch_id, NULL) THEN
    RAISE EXCEPTION 'You don''t have permission to change this branch''s recipes' USING ERRCODE = '42501';
  END IF;

  IF p_replaces IS NOT NULL THEN
    UPDATE public.recipe_versions SET status = 'archived' WHERE id = old.id;
  ELSE
    p_variant_label := nullif(btrim(p_variant_label), '');
    IF num_nonnulls(p_color_id, p_variant_label) <> 1 THEN
      RAISE EXCEPTION 'Choose a colour or name a variant — not both' USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.product_categories WHERE id = p_category_id AND organization_id = org) THEN
      RAISE EXCEPTION 'Category not found' USING ERRCODE = '23514';
    END IF;
    IF p_color_id IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM public.product_category_colors
         WHERE category_id = p_category_id AND color_id = p_color_id) THEN
      RAISE EXCEPTION 'That colour is not one of this category''s colours' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (SELECT 1 FROM public.recipe_versions
               WHERE organization_id = org AND branch_id = p_branch_id AND category_id = p_category_id AND status = 'active'
                 AND color_id IS NOT DISTINCT FROM p_color_id
                 AND variant_label IS NOT DISTINCT FROM p_variant_label) THEN
      RAISE EXCEPTION 'This recipe already exists in this branch — change it instead of adding it again' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'A recipe needs at least one ingredient' USING ERRCODE = '23514';
  END IF;

  SELECT coalesce(max(version_number), 0) + 1 INTO next_no
  FROM public.recipe_versions
  WHERE organization_id = org AND branch_id = p_branch_id AND category_id = p_category_id
    AND color_id IS NOT DISTINCT FROM p_color_id
    AND variant_label IS NOT DISTINCT FROM p_variant_label;

  INSERT INTO public.recipe_versions
    (organization_id, branch_id, category_id, color_id, variant_label, version_number, effective_date, status, notes, created_by)
  VALUES
    (org, p_branch_id, p_category_id, p_color_id, p_variant_label, next_no,
     coalesce(p_effective_date, current_date), 'active', nullif(btrim(p_notes), ''), auth.uid())
  RETURNING id INTO new_id;

  SELECT coalesce(i->>'material_id', '(none)') INTO bad
  FROM jsonb_array_elements(p_items) i
  LEFT JOIN public.materials m
    ON m.id = (i->>'material_id')::uuid AND m.organization_id = org AND m.status = 'active'
  WHERE m.id IS NULL
  LIMIT 1;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'Every ingredient must be an active material' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.recipe_items (recipe_version_id, material_id, quantity, unit_id, quantity_confirmed, notes)
  SELECT new_id,
         (i->>'material_id')::uuid,
         (i->>'quantity')::numeric,
         (i->>'unit_id')::uuid,
         coalesce((i->>'quantity_confirmed')::boolean, true),
         nullif(btrim(i->>'notes'), '')
  FROM jsonb_array_elements(p_items) i;

  SELECT m.name INTO bad
  FROM public.recipe_items ri
  JOIN public.materials m ON m.id = ri.material_id
  WHERE ri.recipe_version_id = new_id
    AND (ri.unit_id IS NULL OR (
         ri.unit_id IS DISTINCT FROM m.stock_unit_id
         AND NOT EXISTS (SELECT 1 FROM public.material_unit_conversions c
                         WHERE c.material_id = m.id AND c.unit_id = ri.unit_id)))
  LIMIT 1;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION '%: choose its stock unit or one of its listed unit conversions', bad USING ERRCODE = '23514';
  END IF;

  -- Products using this version: same category, carried by the branch
  -- (the carried check is trg_rvp_product_carried)
  INSERT INTO public.recipe_version_products (recipe_version_id, product_id)
  SELECT DISTINCT new_id, pid
  FROM unnest(coalesce(p_product_ids,
         ARRAY(SELECT product_id FROM public.recipe_version_products WHERE recipe_version_id = p_replaces))) pid;

  IF EXISTS (SELECT 1 FROM public.recipe_version_products rvp
             LEFT JOIN public.products p ON p.id = rvp.product_id AND p.organization_id = org
             WHERE rvp.recipe_version_id = new_id
               AND (p.id IS NULL OR p.category_id <> p_category_id)) THEN
    RAISE EXCEPTION 'Only products of this category can use this recipe' USING ERRCODE = '23514';
  END IF;

  RETURN new_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_recipe_version(uuid, uuid, uuid, text, jsonb, uuid[], date, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_recipe_version(uuid, uuid, uuid, text, jsonb, uuid[], date, text, uuid) TO authenticated;
COMMENT ON FUNCTION public.create_recipe_version(uuid, uuid, uuid, text, jsonb, uuid[], date, text, uuid)
  IS 'Saves a recipe change as a new version (old one archived), or adds a new recipe to a branch. The only app write path for recipe ingredients.';

-- Start a branch's recipe from another branch's. The copy is the target
-- branch's own from then on: later changes on either side don't carry over.
CREATE OR REPLACE FUNCTION public.copy_recipe_to_branch(
  p_version_id  uuid,               -- the recipe to start from (any branch)
  p_branch_id   uuid,               -- the branch getting its own copy
  p_product_ids uuid[] DEFAULT NULL, -- NULL = the source's products that the target branch carries
  p_notes       text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  org     uuid := public.get_my_org_id();
  src     public.recipe_versions;
  current uuid;
  items   jsonb;
  new_id  uuid;
BEGIN
  SELECT * INTO src FROM public.recipe_versions WHERE id = p_version_id AND organization_id = org;
  IF NOT FOUND THEN RAISE EXCEPTION 'Recipe not found' USING ERRCODE = '23514'; END IF;
  IF src.branch_id = p_branch_id THEN
    RAISE EXCEPTION 'That recipe is already this branch''s' USING ERRCODE = '23514';
  END IF;

  SELECT jsonb_agg(jsonb_build_object('material_id', material_id, 'quantity', quantity, 'unit_id', unit_id,
                                      'quantity_confirmed', quantity_confirmed, 'notes', notes))
  INTO items FROM public.recipe_items WHERE recipe_version_id = src.id;

  p_product_ids := coalesce(p_product_ids, ARRAY(
    SELECT l.product_id FROM public.recipe_version_products l
    JOIN public.branch_products bp ON bp.product_id = l.product_id AND bp.branch_id = p_branch_id AND bp.status = 'active'
    WHERE l.recipe_version_id = src.id));

  SELECT id INTO current FROM public.recipe_versions
  WHERE organization_id = org AND branch_id = p_branch_id AND category_id = src.category_id AND status = 'active'
    AND color_id IS NOT DISTINCT FROM src.color_id AND variant_label IS NOT DISTINCT FROM src.variant_label;

  new_id := public.create_recipe_version(current, src.category_id, src.color_id, src.variant_label, items, p_product_ids,
                                         NULL, coalesce(p_notes, 'Started from another branch''s recipe'), p_branch_id);
  UPDATE public.recipe_versions SET copied_from_version_id = src.id WHERE id = new_id;
  RETURN new_id;
END;
$$;

REVOKE ALL ON FUNCTION public.copy_recipe_to_branch(uuid, uuid, uuid[], text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.copy_recipe_to_branch(uuid, uuid, uuid[], text) TO authenticated;


-- ------------------------------------------------------------
-- 4. Prices: adding a price for a branch puts the product in its catalogue
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.price_adds_to_catalogue()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.branch_products (organization_id, branch_id, product_id, source, created_by)
  VALUES (NEW.organization_id, NEW.branch_id, NEW.product_id, 'price', auth.uid())
  ON CONFLICT (branch_id, product_id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pricing_adds_to_catalogue
  AFTER INSERT OR UPDATE OF branch_id, product_id ON public.product_branch_pricing
  FOR EACH ROW EXECUTE FUNCTION public.price_adds_to_catalogue();


-- ------------------------------------------------------------
-- 5. Stock: products come into a branch only if it carries them
-- ------------------------------------------------------------
-- Receipts and adjustments of a product the branch doesn't carry are
-- refused (likely a wrong pick). Stock that is physically there — opening
-- balances, counts, transfers in, reclassifications, reversals — never
-- blocks: the product joins the branch's catalogue, and an unexpected
-- arrival (transfer in, count) is flagged for review. Stock going OUT
-- needs no check: it was there.
CREATE OR REPLACE FUNCTION public.check_stock_product_carried()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  bp_id uuid;
  prod  text;
  br    text;
BEGIN
  IF NEW.product_id IS NULL OR NEW.quantity <= 0
     OR EXISTS (SELECT 1 FROM public.branch_products WHERE branch_id = NEW.branch_id AND product_id = NEW.product_id) THEN
    RETURN NEW;
  END IF;
  SELECT canonical_name INTO prod FROM public.products WHERE id = NEW.product_id;
  SELECT name INTO br FROM public.branches WHERE id = NEW.branch_id;

  IF NEW.transaction_type IN ('receipt', 'adjustment') THEN
    RAISE EXCEPTION '% isn''t in %''s product list — add it there first', prod, br USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.branch_products (organization_id, branch_id, product_id, source, created_by, notes)
  VALUES (NEW.organization_id, NEW.branch_id, NEW.product_id, 'stock', auth.uid(),
          'Added when ' || replace(NEW.transaction_type, '_', ' ') || ' stock was recorded')
  RETURNING id INTO bp_id;

  IF NEW.transaction_type IN ('transfer_in', 'count') THEN
    INSERT INTO public.review_flags (organization_id, entity_type, entity_id, reason_code, reason, created_by)
    VALUES (NEW.organization_id, 'branch_product', bp_id::text, 'stock_outside_catalogue',
            format('%s arrived in %s''s stock (%s) but wasn''t in %s''s product list, so it has been added. '
                   'If %s doesn''t really carry it, check the stock record.',
                   prod, br, CASE NEW.transaction_type WHEN 'count' THEN 'found in a stock count' ELSE 'by transfer' END,
                   br, br),
            auth.uid())
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_inventory_product_carried BEFORE INSERT ON public.inventory_transactions
  FOR EACH ROW EXECUTE FUNCTION public.check_stock_product_carried();


-- ------------------------------------------------------------
-- 6. Settling a product's identity carries its catalogue rows over
-- ------------------------------------------------------------
-- Same as 028, plus: when a product turns out to be another one, every
-- branch that carried it now carries the other (step 1b).
CREATE OR REPLACE FUNCTION public.resolve_product_identity(p_product_id uuid, p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org      uuid := public.get_my_org_id();
  uid      uuid := auth.uid();
  who      text;
  prod     public.products;
  target   public.products;
  choice   text := p->>'choice';
  mdate    date;
  lines    jsonb := '[]';
  b        record;
  alloc    numeric;
  movs     uuid[] := '{}';
  d        public.identity_decisions;
  new_id   uuid;
  names    text;
  note     text;
  x        uuid;
BEGIN
  IF uid IS NULL OR org IS NULL OR NOT public.has_permission('products.manage') THEN
    RAISE EXCEPTION 'Only product admins can settle what a product really is' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO prod FROM public.products WHERE id = p_product_id AND organization_id = org FOR UPDATE;
  IF NOT FOUND OR prod.status <> 'active' THEN
    RAISE EXCEPTION 'Product not found or already retired' USING ERRCODE = '23514';
  END IF;
  who := coalesce((SELECT nullif(btrim(concat_ws(' ', first_name, last_name)), '') FROM public.profiles WHERE id = uid),
                  (SELECT email FROM public.profiles WHERE id = uid), 'a user');
  -- Stock is moved as it stood at its first recorded date unless told otherwise
  mdate := coalesce(nullif(p->>'date', '')::date,
                    (SELECT min(transaction_date) FROM public.inventory_transactions WHERE product_id = prod.id),
                    public.org_today(org));

  IF choice = 'same_as' THEN
    SELECT * INTO target FROM public.products WHERE id = (p->>'target_product_id')::uuid AND organization_id = org AND status = 'active';
    IF NOT FOUND OR target.id = prod.id THEN
      RAISE EXCEPTION 'Choose the product it really is' USING ERRCODE = '23514';
    END IF;
    FOR b IN SELECT warehouse_id, color_id, sum(quantity) AS qty FROM public.inventory_transactions
             WHERE product_id = prod.id AND transaction_date <= mdate GROUP BY 1, 2 HAVING sum(quantity) > 0 LOOP
      lines := lines || jsonb_build_object('warehouse_id', b.warehouse_id, 'from_product_id', prod.id, 'to_product_id', target.id,
                                           'color_id', b.color_id, 'quantity', b.qty);
    END LOOP;
    note := prod.canonical_name || ' is ' || target.canonical_name;

  ELSIF choice = 'split' THEN
    IF jsonb_typeof(p->'allocations') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'allocations') = 0 THEN
      RAISE EXCEPTION 'Say how the stock divides between the products' USING ERRCODE = '23514';
    END IF;
    -- every store/colour holding stock must be fully divided, exactly
    FOR b IN SELECT warehouse_id, color_id, sum(quantity) AS qty FROM public.inventory_transactions
             WHERE product_id = prod.id AND transaction_date <= mdate GROUP BY 1, 2 HAVING sum(quantity) <> 0 LOOP
      SELECT coalesce(sum((a->>'quantity')::numeric), 0) INTO alloc FROM jsonb_array_elements(p->'allocations') a
      WHERE (a->>'warehouse_id')::uuid = b.warehouse_id AND nullif(a->>'color_id', '')::uuid IS NOT DISTINCT FROM b.color_id;
      IF alloc <> b.qty THEN
        RAISE EXCEPTION 'The parts add up to %, but % has % in that store — they must add up exactly',
          trim_scale(alloc), prod.canonical_name, trim_scale(b.qty) USING ERRCODE = '23514';
      END IF;
    END LOOP;
    FOR b IN SELECT a FROM jsonb_array_elements(p->'allocations') a LOOP
      IF (b.a->>'quantity')::numeric > 0 THEN
        lines := lines || jsonb_build_object('warehouse_id', b.a->>'warehouse_id', 'from_product_id', prod.id,
                                             'to_product_id', b.a->>'product_id', 'color_id', nullif(b.a->>'color_id', ''),
                                             'to_color_id', nullif(b.a->>'to_color_id', ''), 'quantity', (b.a->>'quantity')::numeric);
      END IF;
    END LOOP;
    SELECT string_agg(DISTINCT pr.canonical_name, ' and ') INTO names FROM public.products pr
    WHERE pr.id IN (SELECT (a->>'product_id')::uuid FROM jsonb_array_elements(p->'allocations') a);
    note := prod.canonical_name || ' was split between ' || names;

  ELSIF choice = 'keep' THEN
    note := prod.canonical_name || ' is a product in its own right';
  ELSE
    RAISE EXCEPTION 'Unknown choice' USING ERRCODE = '23514';
  END IF;

  IF nullif(btrim(p->>'note'), '') IS NOT NULL THEN note := note || ' — ' || btrim(p->>'note'); END IF;

  -- 1b. (031) Every branch that carried it now carries what it really is;
  --     the retired product leaves those catalogues
  IF choice = 'same_as' THEN
    INSERT INTO public.branch_products (organization_id, branch_id, product_id, source, created_by, notes)
    SELECT org, bp.branch_id, target.id, 'merge', uid, note
    FROM public.branch_products bp WHERE bp.product_id = prod.id AND bp.status = 'active'
    ON CONFLICT (branch_id, product_id) DO UPDATE SET status = 'active'
      WHERE public.branch_products.status = 'inactive';
  END IF;
  IF choice IN ('same_as', 'split') THEN
    UPDATE public.branch_products SET status = 'inactive' WHERE product_id = prod.id AND status = 'active';
  END IF;

  -- 1. Move the stock
  IF jsonb_array_length(lines) > 0 THEN
    movs := public.reclassify_stock(jsonb_build_object('date', mdate, 'reason', note, 'lines', lines));
  END IF;

  -- 2. Retire the product that turned out not to be one (keep: stays)
  IF choice IN ('same_as', 'split') THEN
    UPDATE public.products SET status = 'inactive',
           notes = coalesce(notes || E'\n', '') || 'Retired ' || to_char(public.org_today(org), 'YYYY-MM-DD') || ' by ' || who || ': ' || note || '.'
    WHERE id = prod.id;
  END IF;

  -- 3. Decisions: every standing answer that pointed at this product
  FOR d IN SELECT * FROM public.identity_decisions WHERE organization_id = org AND status = 'active'
           AND product_id = prod.id AND decision IN ('same_as', 'new_record') LOOP
    IF choice = 'same_as' THEN
      PERFORM public.correct_identity_decision(d.id, jsonb_build_object('decision', 'same_as', 'product_id', target.id), note);
    ELSIF choice = 'split' THEN
      PERFORM public.revoke_identity_decision(d.id, note || '. Count these products separately on future sheets.');
    END IF;
  END LOOP;
  IF choice = 'same_as' AND NOT EXISTS (SELECT 1 FROM public.identity_decisions WHERE organization_id = org AND status = 'active'
       AND subject_type = 'product' AND context_normalized = '' AND term_normalized = public.normalize_name(prod.canonical_name)) THEN
    INSERT INTO public.identity_decisions (organization_id, subject_type, term, decision, product_id, evidence, source, decided_by, decided_by_label)
    VALUES (org, 'product', prod.canonical_name, 'same_as', target.id, note, 'review_queue', uid, who);
  END IF;
  IF choice = 'keep' THEN
    FOR x IN SELECT value::uuid FROM jsonb_array_elements_text(coalesce(p->'not_products', '[]'::jsonb)) LOOP
      IF NOT EXISTS (SELECT 1 FROM public.identity_decisions WHERE organization_id = org AND status = 'active' AND decision = 'distinct_from'
                     AND subject_type = 'product' AND term_normalized = public.normalize_name(prod.canonical_name) AND product_id = x) THEN
        INSERT INTO public.identity_decisions (organization_id, subject_type, term, decision, product_id, evidence, source, decided_by, decided_by_label)
        SELECT org, 'product', prod.canonical_name, 'distinct_from', pr.id, note || ' (not ' || pr.canonical_name || ')', 'review_queue', uid, who
        FROM public.products pr WHERE pr.id = x AND pr.organization_id = org;
      END IF;
    END LOOP;
  END IF;

  -- 4. Close its open identity flags
  UPDATE public.review_flags SET status = 'resolved', resolved_at = now(), resolved_by = uid, resolution_note = note
  WHERE organization_id = org AND entity_type = 'product' AND entity_id = prod.id::text AND status = 'open'
    AND reason_code IN ('import_placeholder', 'unresolved_identity', 'possible_duplicate');

  RETURN jsonb_build_object('movements', to_jsonb(movs), 'note', note);
END;
$$;


-- ------------------------------------------------------------
-- 7. Size + strength specs: pieces per m² and the yield band
-- ------------------------------------------------------------
-- "30x30", "30 X 30", "30×30 cm" are one size
CREATE OR REPLACE FUNCTION public.size_key(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT nullif(regexp_replace(replace(lower(coalesce(p, '')), '×', 'x'), '\s+|cm', '', 'g'), '')
$$;

ALTER TABLE public.products ADD COLUMN strength_class text CHECK (strength_class IS NULL OR btrim(strength_class) <> '');
COMMENT ON COLUMN public.products.strength_class
  IS 'Strength grade where it varies within a size (e.g. paving "30MPa"). With size, picks the product''s size spec.';

-- Strength grades already written in product names ("Paving 8cm 30MPa",
-- "H-Paver 40-45MPa (8cm)"): copied as stated, nothing inferred beyond it
UPDATE public.products
SET strength_class = upper(replace((regexp_match(canonical_name, '(\d+(?:\s*-\s*\d+)?)\s*MPa', 'i'))[1], ' ', '')) || 'MPa'
WHERE canonical_name ~* '\d\s*MPa';

-- The organization's usual ± tolerance on yield per bag (pieces); a size
-- or a branch can set its own. NULL = no band, nothing gets checked.
ALTER TABLE public.organizations ADD COLUMN yield_tolerance numeric CHECK (yield_tolerance IS NULL OR yield_tolerance >= 0);
COMMENT ON COLUMN public.organizations.yield_tolerance
  IS 'Default ± pieces around the average yield per bag; production output outside the band is flagged for review (1d), never corrected.';

CREATE TABLE public.product_size_specs (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  category_id           uuid NOT NULL REFERENCES public.product_categories(id) ON DELETE RESTRICT,
  size_cm               text NOT NULL CHECK (btrim(size_cm) <> ''),
  size_key              text GENERATED ALWAYS AS (public.size_key(size_cm)) STORED,
  strength_class        text CHECK (strength_class IS NULL OR btrim(strength_class) <> ''),
  pcs_per_sqm           numeric CHECK (pcs_per_sqm IS NULL OR pcs_per_sqm > 0),           -- coverage: physical size
  average_yield_per_bag numeric CHECK (average_yield_per_bag IS NULL OR average_yield_per_bag > 0), -- QC expectation
  yield_tolerance       numeric CHECK (yield_tolerance IS NULL OR yield_tolerance >= 0),  -- NULL = the organization's
  status                text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  notes                 text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (organization_id, category_id, size_key, strength_class)
);

COMMENT ON TABLE public.product_size_specs
  IS 'Pieces per m² and average yield per bag for every product of a size (+ strength) in a category. Yield is an average used for quality control (± tolerance), not an output formula.';

CREATE TABLE public.branch_yield_overrides (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  spec_id               uuid NOT NULL REFERENCES public.product_size_specs(id) ON DELETE RESTRICT,
  branch_id             uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  average_yield_per_bag numeric NOT NULL CHECK (average_yield_per_bag > 0),
  yield_tolerance       numeric CHECK (yield_tolerance IS NULL OR yield_tolerance >= 0),
  notes                 text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (spec_id, branch_id)
);

COMMENT ON TABLE public.branch_yield_overrides
  IS 'A branch''s own average yield per bag for a size spec (e.g. its mix differs). Pieces per m² is physical and is never overridden.';

CREATE TRIGGER trg_size_specs_updated_at BEFORE UPDATE ON public.product_size_specs
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_size_specs_category_org BEFORE INSERT OR UPDATE ON public.product_size_specs
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('product_categories', 'category_id');
CREATE TRIGGER trg_size_specs_audit AFTER INSERT OR UPDATE OR DELETE ON public.product_size_specs
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('size_spec', 'id');
CREATE TRIGGER trg_size_specs_no_delete BEFORE DELETE ON public.product_size_specs
  FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('size_spec');

CREATE TRIGGER trg_yield_overrides_updated_at BEFORE UPDATE ON public.branch_yield_overrides
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_yield_overrides_spec_org BEFORE INSERT OR UPDATE ON public.branch_yield_overrides
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('product_size_specs', 'spec_id');
CREATE TRIGGER trg_yield_overrides_branch_org BEFORE INSERT OR UPDATE ON public.branch_yield_overrides
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('branches', 'branch_id');
CREATE TRIGGER trg_yield_overrides_audit AFTER INSERT OR UPDATE OR DELETE ON public.branch_yield_overrides
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('branch_yield', 'id');

ALTER TABLE public.product_size_specs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "size_specs: read own org" ON public.product_size_specs FOR SELECT
  USING (organization_id = public.get_my_org_id());
CREATE POLICY "size_specs: admins can manage" ON public.product_size_specs FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('products.manage'));

ALTER TABLE public.branch_yield_overrides ENABLE ROW LEVEL SECURITY;
CREATE POLICY "branch_yields: read own org" ON public.branch_yield_overrides FOR SELECT
  USING (organization_id = public.get_my_org_id());
CREATE POLICY "branch_yields: managers of the branch" ON public.branch_yield_overrides FOR ALL
  USING      (organization_id = public.get_my_org_id() AND public.has_permission_at('products.manage', branch_id, NULL))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_at('products.manage', branch_id, NULL));

-- Specs from the existing catalogue: where every product of a size (and
-- strength) that has a figure agrees, that figure becomes the size's.
-- Where they disagree, the spec leaves it blank, products keep their own
-- figures, and the disagreement is flagged — nothing is picked.
INSERT INTO public.product_size_specs (organization_id, category_id, size_cm, strength_class, pcs_per_sqm, average_yield_per_bag, notes)
SELECT organization_id, category_id, min(size_cm), strength_class,
       CASE WHEN count(DISTINCT pcs_per_sqm) = 1 THEN max(pcs_per_sqm) END,
       CASE WHEN count(DISTINCT wastani_per_bag) = 1 THEN max(wastani_per_bag) END,
       format('From the existing catalogue (%s product%s of this size).', count(*), CASE WHEN count(*) = 1 THEN '' ELSE 's' END)
FROM public.products
WHERE status = 'active' AND public.size_key(size_cm) IS NOT NULL
GROUP BY organization_id, category_id, public.size_key(size_cm), strength_class;

INSERT INTO public.review_flags (organization_id, entity_type, entity_id, reason_code, reason)
SELECT s.organization_id, 'size_spec', s.id::text, 'conflicting_size_figures',
       format('Products of size %s%s disagree on %s, so this size has no shared figure yet. Each keeps its own until you set one here%s.',
              s.size_cm, coalesce(' ' || s.strength_class, ''),
              concat_ws(' and ',
                CASE WHEN count(DISTINCT p.pcs_per_sqm) > 1 THEN 'pieces per m² (' || string_agg(DISTINCT trim_scale(p.pcs_per_sqm)::text, ', ') || ')' END,
                CASE WHEN count(DISTINCT p.wastani_per_bag) > 1 THEN 'yield per bag (' || string_agg(DISTINCT trim_scale(p.wastani_per_bag)::text, ', ') || ')' END),
              ' — or give them different strengths if they really differ')
FROM public.product_size_specs s
JOIN public.products p ON p.organization_id = s.organization_id AND p.category_id = s.category_id AND p.status = 'active'
 AND public.size_key(p.size_cm) = s.size_key AND p.strength_class IS NOT DISTINCT FROM s.strength_class
GROUP BY s.id, s.organization_id, s.size_cm, s.strength_class
HAVING count(DISTINCT p.pcs_per_sqm) > 1 OR count(DISTINCT p.wastani_per_bag) > 1;

-- Effective figures per product: the size spec's, else the product's own
-- (legacy per-product figures, kept until every size has a spec)
CREATE VIEW public.product_specs
WITH (security_invoker = true) AS
SELECT p.id AS product_id, p.organization_id, s.id AS spec_id,
       coalesce(s.pcs_per_sqm, p.pcs_per_sqm)                 AS pcs_per_sqm,
       CASE WHEN s.pcs_per_sqm IS NOT NULL THEN 'size' WHEN p.pcs_per_sqm IS NOT NULL THEN 'product' END AS pcs_source,
       coalesce(s.average_yield_per_bag, p.wastani_per_bag)   AS average_yield_per_bag,
       CASE WHEN s.average_yield_per_bag IS NOT NULL THEN 'size' WHEN p.wastani_per_bag IS NOT NULL THEN 'product' END AS yield_source,
       coalesce(s.yield_tolerance, o.yield_tolerance)         AS yield_tolerance
FROM public.products p
JOIN public.organizations o ON o.id = p.organization_id
LEFT JOIN public.product_size_specs s
  ON s.organization_id = p.organization_id AND s.category_id = p.category_id AND s.status = 'active'
 AND s.size_key = public.size_key(p.size_cm) AND s.strength_class IS NOT DISTINCT FROM p.strength_class;

-- The yield band a production run at a branch is checked against (1d):
-- branch override, else size spec, else the product's own figure
CREATE OR REPLACE FUNCTION public.product_yield_band(p_product_id uuid, p_branch_id uuid)
RETURNS TABLE (average_yield_per_bag numeric, yield_tolerance numeric, yield_min numeric, yield_max numeric, source text)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT avg_y, tol, avg_y - tol, avg_y + tol, src
  FROM (
    SELECT coalesce(y.average_yield_per_bag, ps.average_yield_per_bag) AS avg_y,
           coalesce(y.yield_tolerance, ps.yield_tolerance)            AS tol,
           CASE WHEN y.id IS NOT NULL THEN 'branch' ELSE ps.yield_source END AS src
    FROM public.product_specs ps
    LEFT JOIN public.branch_yield_overrides y ON y.spec_id = ps.spec_id AND y.branch_id = p_branch_id
    WHERE ps.product_id = p_product_id
  ) x
$$;

COMMENT ON FUNCTION public.product_yield_band(uuid, uuid)
  IS 'Expected pieces per bag (average ± tolerance) for QC. Never used to compute or post output.';


-- ------------------------------------------------------------
-- 8. Suppliers belong to purchases, not to materials
-- ------------------------------------------------------------
-- Receipts record the supplier at the time of purchase (migration 022).
-- Fixed per-branch sources are kept as history but no longer edited.
DROP POLICY "mbs: admins can manage" ON public.material_branch_sources;
COMMENT ON TABLE public.material_branch_sources
  IS 'RETIRED (031): historical per-branch sources. A supplier is recorded on each receipt, never fixed on a material. Read-only.';

UPDATE public.review_flags
SET status = 'dismissed', resolved_at = now(),
    resolution_note = 'No longer needed: the supplier is recorded on each purchase (receipt), not fixed per material.'
WHERE status = 'open' AND reason_code = 'missing_branch_source';


-- ------------------------------------------------------------
-- 9. Branch managers: their own branch's catalogue and recipes
-- ------------------------------------------------------------
-- Their grants are branch-scoped, so this reaches has_permission_at() for
-- their branch only; org-wide has_permission() still needs an org-wide grant.
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM public.roles r, public.permissions p
WHERE r.name = 'branch_manager' AND r.is_system_role AND p.code = 'products.manage'
ON CONFLICT DO NOTHING;
