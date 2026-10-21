-- One-off (run once; never re-run). SwahziTech, 2026-10-21:
-- "Include dawa for all vibro products (tiles and pavings)" — tiles already
-- have it; Paving Blocks › Vibro gets Dawa 1 L per bag (same as floor
-- tiles), Dodoma's four colours (the only branch with these recipes).
-- Not in ratios_and_molds.json (its paving ratios have no dawa): a new
-- decision, recorded in each version's notes. Each colour gets a new
-- version through create_recipe_version(); version 1 is archived, kept.
-- Runs as the Technical admin (MOIS Admin) so the change is audited as theirs.
DO $$
DECLARE
  v      record;
  items  jsonb;
  dawa   uuid;
  litre  uuid;
  newid  uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"ae48a74f-aaf7-4a56-b6bb-76150a6261e6","role":"authenticated"}', true);
  SELECT id INTO dawa FROM public.materials WHERE organization_id = public.get_my_org_id() AND name = 'Dawa';
  SELECT stock_unit_id INTO litre FROM public.materials WHERE id = dawa;
  IF dawa IS NULL OR litre IS NULL THEN RAISE EXCEPTION 'Dawa or its unit not found'; END IF;

  FOR v IN SELECT rv.id, cp.name AS colour
           FROM public.recipe_versions rv
           JOIN public.product_categories c ON c.id = rv.category_id AND c.name = 'Vibro'
           JOIN public.product_categories g ON g.id = c.parent_category_id AND g.name = 'Paving Blocks'
           JOIN public.branches b ON b.id = rv.branch_id AND b.name = 'Dodoma'
           LEFT JOIN public.color_palette cp ON cp.id = rv.color_id
           WHERE rv.status = 'active' AND rv.organization_id = public.get_my_org_id()
             AND NOT EXISTS (SELECT 1 FROM public.recipe_items x WHERE x.recipe_version_id = rv.id AND x.material_id = dawa)
  LOOP
    SELECT jsonb_agg(jsonb_build_object('material_id', ri.material_id, 'quantity', ri.quantity, 'unit_id', ri.unit_id,
                                        'quantity_confirmed', ri.quantity_confirmed, 'notes', ri.notes))
           || jsonb_build_array(jsonb_build_object('material_id', dawa, 'quantity', 1, 'unit_id', litre, 'quantity_confirmed', true,
                                                   'notes', 'Added 2026-10-21 (SwahziTech)'))
      INTO items FROM public.recipe_items ri WHERE ri.recipe_version_id = v.id;
    newid := public.create_recipe_version(v.id, NULL, NULL, NULL, items, NULL, current_date,
      'Dawa 1 L per bag added for vibro paving — SwahziTech 2026-10-21 (not in ratios_and_molds.json, which has no dawa for paving)');
    RAISE NOTICE '% → new version %', v.colour, newid;
  END LOOP;
END $$;
