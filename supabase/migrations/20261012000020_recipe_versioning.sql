-- ============================================================
-- 020 — Recipe versioning (build-plan 1a.1 step 4)
--
-- A saved recipe version is never edited: every change to a recipe's
-- ingredients creates a new version and archives the old one, so later
-- production batches (1d) always point at the exact recipe they used.
--
--   1. At most one ACTIVE version per recipe (category + colour/variant).
--   2. Ingredients of a saved version are frozen for app users; only the
--      transaction that creates a version may write its ingredients.
--      Version keys (category, colour/variant, number, date) are frozen too.
--      Product links (recipe_version_products) stay editable — they say
--      which molds use the recipe, not what the recipe is.
--   3. create_recipe_version(): the one way the app saves a recipe change —
--      archive old + insert new + copy ingredients/links, atomically.
--
-- Server-side scripts (service_role, SQL editor) are exempt from 2, as with
-- prevent_hard_delete() in 018.
-- ============================================================


-- ------------------------------------------------------------
-- 1. One active version per recipe
-- ------------------------------------------------------------
CREATE UNIQUE INDEX uq_recipe_versions_one_active
  ON public.recipe_versions (organization_id, category_id, color_id, variant_label)
  NULLS NOT DISTINCT
  WHERE status = 'active';


-- ------------------------------------------------------------
-- 2. Freeze saved versions
-- ------------------------------------------------------------
-- True when the row was inserted by the current transaction
CREATE OR REPLACE FUNCTION public.recipe_version_is_new(p_version_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.recipe_versions
    WHERE id = p_version_id AND xmin = pg_current_xact_id()::xid
  );
$$;

CREATE OR REPLACE FUNCTION public.freeze_recipe_items()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE v uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.recipe_version_id ELSE NEW.recipe_version_id END;
BEGIN
  IF auth.role() = 'service_role' OR auth.uid() IS NULL THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF NOT public.recipe_version_is_new(v)
     OR (TG_OP = 'UPDATE' AND OLD.recipe_version_id <> NEW.recipe_version_id) THEN
    RAISE EXCEPTION 'A saved recipe cannot be edited — save a new version instead'
      USING ERRCODE = '23514';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER trg_recipe_items_frozen
  BEFORE INSERT OR UPDATE OR DELETE ON public.recipe_items
  FOR EACH ROW EXECUTE FUNCTION public.freeze_recipe_items();

CREATE OR REPLACE FUNCTION public.freeze_recipe_version_keys()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF auth.role() = 'service_role' OR auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF (NEW.category_id, NEW.color_id, NEW.variant_label, NEW.version_number, NEW.effective_date)
     IS DISTINCT FROM
     (OLD.category_id, OLD.color_id, OLD.variant_label, OLD.version_number, OLD.effective_date) THEN
    RAISE EXCEPTION 'A saved recipe cannot be edited — save a new version instead'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_recipe_versions_frozen
  BEFORE UPDATE ON public.recipe_versions
  FOR EACH ROW EXECUTE FUNCTION public.freeze_recipe_version_keys();


-- ------------------------------------------------------------
-- 3. create_recipe_version()
-- ------------------------------------------------------------
-- SECURITY INVOKER: every write still passes the caller's RLS
-- (products.manage via an org-wide grant, 018).
CREATE OR REPLACE FUNCTION public.create_recipe_version(
  p_replaces       uuid,     -- the active version being replaced; NULL for a new recipe
  p_category_id    uuid,     -- recipe key, used only when p_replaces is NULL
  p_color_id       uuid,
  p_variant_label  text,
  p_items          jsonb,    -- [{material_id, quantity, unit_id, quantity_confirmed, notes}]
  p_product_ids    uuid[],   -- products using the new version; NULL = same as the replaced one
  p_effective_date date,
  p_notes          text
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
  IF org IS NULL OR NOT public.has_permission('products.manage') THEN
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
               WHERE organization_id = org AND category_id = p_category_id AND status = 'active'
                 AND color_id IS NOT DISTINCT FROM p_color_id
                 AND variant_label IS NOT DISTINCT FROM p_variant_label) THEN
      RAISE EXCEPTION 'This recipe already exists — change it instead of adding it again' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'A recipe needs at least one ingredient' USING ERRCODE = '23514';
  END IF;

  SELECT coalesce(max(version_number), 0) + 1 INTO next_no
  FROM public.recipe_versions
  WHERE organization_id = org AND category_id = p_category_id
    AND color_id IS NOT DISTINCT FROM p_color_id
    AND variant_label IS NOT DISTINCT FROM p_variant_label;

  INSERT INTO public.recipe_versions
    (organization_id, category_id, color_id, variant_label, version_number, effective_date, status, notes, created_by)
  VALUES
    (org, p_category_id, p_color_id, p_variant_label, next_no,
     coalesce(p_effective_date, current_date), 'active', nullif(btrim(p_notes), ''), auth.uid())
  RETURNING id INTO new_id;

  -- Ingredients: active materials of this org, each once, in its stock
  -- unit or one of its listed conversions
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

  -- Products using this version: same category only
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

REVOKE ALL ON FUNCTION public.create_recipe_version(uuid, uuid, uuid, text, jsonb, uuid[], date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_recipe_version(uuid, uuid, uuid, text, jsonb, uuid[], date, text) TO authenticated;

COMMENT ON FUNCTION public.create_recipe_version(uuid, uuid, uuid, text, jsonb, uuid[], date, text)
  IS 'Saves a recipe change as a new version (old one archived), or adds a new recipe. The only app write path for recipe ingredients.';
