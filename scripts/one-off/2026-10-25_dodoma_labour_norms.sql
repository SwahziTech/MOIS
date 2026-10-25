-- One-off (run once, after 057 and 2026-10-25_dodoma_machines.sql). Stumarcot —
-- Dodoma's labour norms (SwahziTech, 2026-10-25, the user):
--   tiles (floor, wall) and vibro pavings: 1 person per 3 bags
--   vibro curbstones and trench covers:    1 person per 4 bags
--   culverts, bicon, posts:                1 person per 2–3 bags
--   press makina:                          a crew of 9–12 (12 at most, can drop to 10 or 9)
-- Press products (blocks, press paving, press kerbs) take the press crew, not bags a person.
SELECT set_config('request.jwt.claims', '{"sub":"ae48a74f-aaf7-4a56-b6bb-76150a6261e6","role":"authenticated"}', true);

WITH br AS (SELECT b.id FROM public.branches b JOIN public.organizations o ON o.id = b.organization_id
            WHERE o.name = 'Stumarcot' AND b.name = 'Dodoma'),
norm AS (
  SELECT bp.id, CASE
      WHEN c.name IN ('Floor Tiles', 'Wall Tiles') OR (g.name = 'Paving Blocks' AND c.name = 'Vibro') THEN numrange(3, 3, '[]')
      WHEN c.name = 'Trench Covers' OR (c.name = 'Curbstones' AND p.canonical_name NOT IN ('50 Press', '80 Press')) THEN numrange(4, 4, '[]')
      WHEN c.name IN ('Culverts', 'Posts And Bicons') THEN numrange(2, 3, '[]')
    END AS r
    FROM br JOIN public.branch_products bp ON bp.branch_id = br.id
    JOIN public.products p ON p.id = bp.product_id
    JOIN public.product_categories c ON c.id = p.category_id
    LEFT JOIN public.product_categories g ON g.id = c.parent_category_id)
UPDATE public.branch_products bp SET bags_per_person_min = lower(norm.r), bags_per_person_max = upper(norm.r)
  FROM norm WHERE norm.id = bp.id AND norm.r IS NOT NULL;

UPDATE public.machines m SET crew_min = 9, crew_max = 12
  FROM public.branches b JOIN public.organizations o ON o.id = b.organization_id
 WHERE m.branch_id = b.id AND o.name = 'Stumarcot' AND b.name = 'Dodoma' AND m.name = 'Press makina';

-- check
SELECT coalesce(bp.bags_per_person_min::text || '–' || bp.bags_per_person_max::text, 'press crew / none') AS bags_per_person, count(*) AS products
  FROM public.branch_products bp JOIN public.branches b ON b.id = bp.branch_id AND b.name = 'Dodoma' WHERE bp.status = 'active' GROUP BY 1 ORDER BY 1;
SELECT m.name, m.crew_min, m.crew_max FROM public.machines m JOIN public.branches b ON b.id = m.branch_id AND b.name = 'Dodoma' ORDER BY m.name;
