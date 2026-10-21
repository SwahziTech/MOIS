-- One-off (run once after migration 045; never re-run). SwahziTech, 2026-10-21:
-- Dodoma's capacity. Mold counts from ratios_and_molds.json (vibro molds; the
-- file's counts are Dodoma's — confirmed); products matched by product_id_ref,
-- active products only. Press: only Tofali 5" 80–110 bags/day (SwahziTech);
-- other press products are left blank for the branch manager — the file's
-- per-product pieces ranges are not used as bags/day (they don't agree: Tofali 5"
-- 2,500–10,000 pcs = 50–200 bags). Steel-cast products: none (not defined).
INSERT INTO public.branch_product_capacity (organization_id, branch_id, product_id, molds, notes)
SELECT p.organization_id, b.id, p.id, v.molds, 'From ratios_and_molds.json (Dodoma), 2026-10-21'
FROM (VALUES ('floor_tiles_01', 18), ('floor_tiles_02', 75), ('floor_tiles_03', 60), ('floor_tiles_04', 100), ('floor_tiles_05', 65), ('floor_tiles_06', 220), ('floor_tiles_07', 100), ('floor_tiles_08', 95), ('floor_tiles_09', 99), ('floor_tiles_10', 446), ('floor_tiles_11', 6), ('floor_tiles_12', 6), ('floor_tiles_13', 8), ('floor_tiles_14', 120), ('floor_tiles_15', 107), ('floor_tiles_16', 220), ('floor_tiles_17', 123), ('floor_tiles_18', 399), ('floor_tiles_19', 16), ('floor_tiles_20', 430), ('floor_tiles_21', 60), ('wall_tiles_01', 12), ('wall_tiles_02', 12), ('wall_tiles_03', 22), ('wall_tiles_04', 52), ('wall_tiles_05', 12), ('paving_01', 20), ('paving_02', 990), ('paving_03', 27), ('paving_04', 30), ('paving_05', 40), ('paving_06', 52), ('paving_07', 2449), ('paving_08', 675), ('curbstones_01', 10), ('curbstones_02', 11), ('curbstones_03', 10), ('curbstones_04', 5), ('trench_covers_01', 10), ('trench_covers_02', 8), ('trench_covers_03', 15), ('trench_covers_04', 15), ('trench_covers_05', 10), ('trench_covers_06', 20)) AS v(ref, molds)
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
