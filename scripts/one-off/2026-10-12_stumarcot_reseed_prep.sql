-- One-off Stumarcot data changes, run ONCE before the 2026-10-12 re-seed.
-- Tenant data, not schema — kept here as a record, not as a migration.
-- Each step asserts its exact row count; any mismatch aborts everything.
--
--   supabase db query --linked -f scripts/one-off/2026-10-12_stumarcot_reseed_prep.sql
DO $$
DECLARE
  org uuid;
  n   int;
BEGIN
  SELECT id INTO STRICT org FROM public.organizations WHERE legal_name = 'STUMARCOT CO LTD';

  -- A. Rename the category IN PLACE (same id, keeps its recipes and history).
  --    product_master.json now calls it 'blocks'; the seed upserts by id_ref.
  UPDATE public.product_categories
     SET category_id_ref = 'blocks', name = 'Blocks'
   WHERE organization_id = org AND category_id_ref = 'press_machine_bricks_and_kerbstones';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'A: expected 1 category renamed, got %', n; END IF;

  -- B. The price list now maps 'DRAFT 300*300' to the new product 'Draft'
  --    (floor_tiles_25). Remove those 3 rows from '30 Draft'; the seed adds
  --    them to floor_tiles_25.
  DELETE FROM public.product_branch_pricing pbp
   USING public.products p
   WHERE p.id = pbp.product_id
     AND p.organization_id = org AND p.product_id_ref = 'floor_tiles_15'
     AND pbp.raw_notes = 'DRAFT' AND pbp.source_item_no = 13 AND pbp.color_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 3 THEN RAISE EXCEPTION 'B: expected 3 price rows moved off 30 Draft, got %', n; END IF;

  -- Purge the 3 pre-N/R-split culverts (inactive; no prices, no transactions)
  DELETE FROM public.recipe_version_products rvp
   USING public.products p
   WHERE p.id = rvp.product_id AND p.organization_id = org AND p.status = 'inactive'
     AND p.product_id_ref IN ('culverts_400', 'culverts_600', 'culverts_900');
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 3 THEN RAISE EXCEPTION 'Purge: expected 3 recipe links, got %', n; END IF;

  DELETE FROM public.product_branch_pricing pbp
   USING public.products p
   WHERE p.id = pbp.product_id AND p.organization_id = org
     AND p.product_id_ref IN ('culverts_400', 'culverts_600', 'culverts_900');
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 0 THEN RAISE EXCEPTION 'Purge: expected 0 price rows, got %', n; END IF;

  DELETE FROM public.products
   WHERE organization_id = org AND status = 'inactive'
     AND product_id_ref IN ('culverts_400', 'culverts_600', 'culverts_900');
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 3 THEN RAISE EXCEPTION 'Purge: expected 3 products, got %', n; END IF;
END $$;
