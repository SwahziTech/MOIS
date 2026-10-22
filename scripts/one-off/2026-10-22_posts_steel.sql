-- One-off (run once; never re-run). SwahziTech, 2026-10-22:
-- Steel in the Posts And Bicons recipes at Dodoma.
--   R6 (6mm steel) is stocked per roller (PCS); a roller is about 400 m
--     → 1 m = 0.0025 PCS (unit conversion on the material).
--   Nguzo: 3.8 m long, 4 bars plus rings → 16 m of R6 per piece;
--     wastani 5 pcs/bag → 80 m per bag of cement.
--   Bicon: 60 cm long, 4 bars → 2.4 m per piece; wastani 15 pcs/bag
--     → 36 m per bag. Steel type for Bicon not stated — R6 used, as for
--     Nguzo (change it under Recipes if it is another steel).
-- Nguzo and Bicon shared one recipe ("Standard"); they now differ only by
-- steel, so: Standard gets a new version for Bicon only (+ R6 36 m), and a
-- new "Nguzo" variant (same mix + R6 80 m) is used by Nguzo. Through
-- create_recipe_version(); the old version is archived, kept.
-- Supersedes ratios_and_molds.md's "1 roller = 25 Nguzo" (15.5 m/pc):
-- SwahziTech gave 16 m/pc and ~400 m/roller.
-- Runs as the Technical admin (MOIS Admin) so the change is audited as theirs.
DO $$
DECLARE
  org     uuid;
  dod     uuid;
  r6      uuid;
  metre   uuid;
  std     record;
  base    jsonb;
  nguzo   uuid;
  bicon   uuid;
  v_bicon uuid;
  v_nguzo uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"ae48a74f-aaf7-4a56-b6bb-76150a6261e6","role":"authenticated"}', true);
  org := public.get_my_org_id();
  SELECT id INTO dod FROM public.branches WHERE organization_id = org AND name = 'Dodoma';
  SELECT id INTO r6 FROM public.materials WHERE organization_id = org AND name = 'R6 (6mm steel)';
  SELECT id INTO metre FROM public.units WHERE symbol = 'm' AND name = 'Metre';
  SELECT id INTO nguzo FROM public.products WHERE organization_id = org AND product_id_ref = 'posts_01';
  SELECT id INTO bicon FROM public.products WHERE organization_id = org AND product_id_ref = 'posts_02';
  IF dod IS NULL OR r6 IS NULL OR metre IS NULL OR nguzo IS NULL OR bicon IS NULL THEN
    RAISE EXCEPTION 'Not found: branch %, R6 %, metre %, Nguzo %, Bicon %', dod, r6, metre, nguzo, bicon;
  END IF;

  -- R6 in metres: one roller (stock PCS) ≈ 400 m
  INSERT INTO public.material_unit_conversions (organization_id, material_id, unit_id, factor_to_stock_unit, notes)
  VALUES (org, r6, metre, 0.0025, 'One roller ≈ 400 m (SwahziTech 2026-10-22)')
  ON CONFLICT (material_id, unit_id) DO NOTHING;

  SELECT rv.* INTO std FROM public.recipe_versions rv
    JOIN public.product_categories c ON c.id = rv.category_id AND c.category_id_ref = 'posts_and_bicons'
   WHERE rv.organization_id = org AND rv.branch_id = dod AND rv.status = 'active' AND rv.variant_label = 'Standard' AND rv.color_id IS NULL;
  IF std.id IS NULL THEN RAISE EXCEPTION 'Posts And Bicons Standard recipe at Dodoma not found'; END IF;
  IF EXISTS (SELECT 1 FROM public.recipe_items WHERE recipe_version_id = std.id AND material_id = r6) THEN
    RAISE EXCEPTION 'Already has R6 — this one-off has run before';
  END IF;

  SELECT jsonb_agg(jsonb_build_object('material_id', ri.material_id, 'quantity', ri.quantity, 'unit_id', ri.unit_id,
                                      'quantity_confirmed', ri.quantity_confirmed, 'notes', ri.notes))
    INTO base FROM public.recipe_items ri WHERE ri.recipe_version_id = std.id;

  -- Bicon: the Standard recipe + R6 36 m per bag
  v_bicon := public.create_recipe_version(std.id, NULL, NULL, NULL,
    base || jsonb_build_array(jsonb_build_object('material_id', r6, 'quantity', 36, 'unit_id', metre, 'quantity_confirmed', true,
                                                 'notes', 'Bicon 2.4 m R6 per piece × 15 pcs/bag (SwahziTech 2026-10-22)')),
    ARRAY[bicon], current_date,
    'R6 steel added: 2.4 m per Bicon (60 cm, 4 bars) × 15 pcs/bag = 36 m per bag. Nguzo moved to its own "Nguzo" recipe — SwahziTech 2026-10-22');

  -- Nguzo: same mix + R6 80 m per bag
  v_nguzo := public.create_recipe_version(NULL, std.category_id, NULL, 'Nguzo',
    base || jsonb_build_array(jsonb_build_object('material_id', r6, 'quantity', 80, 'unit_id', metre, 'quantity_confirmed', true,
                                                 'notes', 'Nguzo 16 m R6 per piece × 5 pcs/bag (SwahziTech 2026-10-22)')),
    ARRAY[nguzo], current_date,
    'Nguzo: the posts mix plus R6 steel — 16 m per piece (3.8 m, 4 bars and rings) × 5 pcs/bag = 80 m per bag. SwahziTech 2026-10-22',
    dod);

  RAISE NOTICE 'Bicon recipe %, Nguzo recipe %', v_bicon, v_nguzo;
END $$;
