-- One-off (run once after migration 045; never re-run). SwahziTech, 2026-10-21:
-- Dodoma's capacity. Mold counts from Molds Dom.md (SwahziTech's Dodoma mold list,
-- 2026-10-19; it overrides ratios_and_molds.json: 80 Combo 150, 40 Combo 399,
-- 40 Mawingu 304, 40 Mpira 306, 40 Y 300, U-Dot Ndogo 2448; Curbstones "Koner" 10 —
-- a new product, not produced yet: added to the catalogue and Dodoma's, SwahziTech
-- 2026-10-21); products matched by product_id_ref,
-- active products only. Press: only Tofali 5" 80–110 bags/day (SwahziTech);
-- other press products are left blank for the branch manager — the file's
-- per-product pieces ranges are not used as bags/day (they don't agree: Tofali 5"
-- 2,500–10,000 pcs = 50–200 bags). Culverts and posts (not in Molds Dom.md): from
-- ratios_and_molds.json (SwahziTech 2026-10-21: every type has its molds). Products with no count in
-- the file stay not defined.
-- Koner: a new curbstone (SwahziTech 2026-10-21: not produced yet; size, wastani
-- and recipe to be fed later). Same unit as the other curbstones.
INSERT INTO public.products (organization_id, category_id, product_id_ref, canonical_name, unit_id, status, notes)
SELECT o.id, c.id, 'curbstones_08', 'Koner', ref.unit_id, 'active',
       'New curbstone from Molds Dom.md (Dodoma, 10 molds), added 2026-10-21 by SwahziTech; not produced yet — size, wastani and recipe to be fed later.'
FROM public.organizations o
JOIN public.product_categories c ON c.organization_id = o.id AND c.name = 'Curbstones'
JOIN public.products ref ON ref.organization_id = o.id AND ref.product_id_ref = 'curbstones_01'
WHERE o.name = 'Stumarcot'
  AND NOT EXISTS (SELECT 1 FROM public.products x WHERE x.organization_id = o.id AND x.product_id_ref = 'curbstones_08');

INSERT INTO public.branch_products (organization_id, branch_id, product_id, source, notes)
SELECT p.organization_id, b.id, p.id, 'app', 'Koner: new curbstone (Molds Dom.md), 2026-10-21'
FROM public.products p
JOIN public.organizations o ON o.id = p.organization_id AND o.name = 'Stumarcot'
JOIN public.branches b ON b.organization_id = o.id AND b.name = 'Dodoma'
WHERE p.product_id_ref = 'curbstones_08'
  AND NOT EXISTS (SELECT 1 FROM public.branch_products x WHERE x.branch_id = b.id AND x.product_id = p.id);

INSERT INTO public.branch_product_capacity (organization_id, branch_id, product_id, molds, notes)
SELECT p.organization_id, b.id, p.id, v.molds, 'From Molds Dom.md (Dodoma, 2026-10-19)'
FROM (VALUES ('floor_tiles_01', 18), ('floor_tiles_02', 150), ('floor_tiles_03', 60), ('floor_tiles_04', 100), ('floor_tiles_05', 65), ('floor_tiles_06', 220), ('floor_tiles_07', 100), ('floor_tiles_08', 95), ('floor_tiles_09', 399), ('floor_tiles_10', 446), ('floor_tiles_11', 304), ('floor_tiles_12', 306), ('floor_tiles_13', 8), ('floor_tiles_14', 120), ('floor_tiles_15', 107), ('floor_tiles_16', 220), ('floor_tiles_17', 123), ('floor_tiles_18', 399), ('floor_tiles_19', 16), ('floor_tiles_20', 430), ('floor_tiles_21', 60), ('floor_tiles_29', 300), ('wall_tiles_01', 12), ('wall_tiles_02', 12), ('wall_tiles_03', 22), ('wall_tiles_04', 52), ('wall_tiles_05', 12), ('paving_01', 20), ('paving_02', 990), ('paving_03', 27), ('paving_04', 30), ('paving_05', 40), ('paving_06', 52), ('paving_07', 2448), ('paving_08', 675), ('curbstones_01', 10), ('curbstones_02', 11), ('curbstones_03', 10), ('curbstones_04', 5), ('curbstones_08', 10), ('trench_covers_01', 10), ('trench_covers_02', 8), ('trench_covers_03', 15), ('trench_covers_04', 15), ('trench_covers_05', 10), ('trench_covers_06', 20), ('culverts_400_N', 2), ('culverts_400_R', 2), ('culverts_600_N', 3), ('culverts_600_R', 3), ('culverts_900_N', 2), ('culverts_900_R', 2), ('posts_01', 5), ('posts_02', 5)) AS v(ref, molds)
JOIN public.products p ON p.product_id_ref = v.ref AND p.status = 'active'
JOIN public.organizations o ON o.id = p.organization_id AND o.name = 'Stumarcot'
JOIN public.branches b ON b.organization_id = o.id AND b.name = 'Dodoma'
ON CONFLICT (branch_id, product_id) DO NOTHING;

INSERT INTO public.branch_product_capacity (organization_id, branch_id, product_id, bags_per_day_min, bags_per_day_max, notes)
SELECT p.organization_id, b.id, p.id, 80, 110, 'SwahziTech 2026-10-20: about 80–110 bags a day'
FROM public.products p
JOIN public.organizations o ON o.id = p.organization_id AND o.name = 'Stumarcot'
JOIN public.branches b ON b.organization_id = o.id AND b.name = 'Dodoma'
WHERE p.product_id_ref = 'press_01' AND p.status = 'active'
ON CONFLICT (branch_id, product_id) DO NOTHING;
