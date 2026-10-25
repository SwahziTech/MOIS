-- One-off (run once, after 056). Stumarcot — Dodoma's machines / lines and
-- the products each makes by default (SwahziTech, 2026-10-25, the user):
--   1. Vibro (godown): tiles (floor, wall), vibro paving, curbstones, trench covers
--   2. Press makina: press products — blocks, press paving, press kerbs
--   3. Culvert machine: culverts
--   4. Machine C: Bicon and posts (Nguzo)
-- "Use these as default when corresponding products are selected. Until set
-- otherwise user can remove, change, add machine/line" (Production ⚙ settings,
-- or + New machine in the batch form).
-- Press kerbs: the curbstones "50 Press" and "80 Press" (no molds at Dodoma —
-- every other curbstone is cast in molds on the vibro).
SELECT set_config('request.jwt.claims', '{"sub":"ae48a74f-aaf7-4a56-b6bb-76150a6261e6","role":"authenticated"}', true);

WITH br AS (SELECT b.id AS branch_id, b.organization_id FROM public.branches b JOIN public.organizations o ON o.id = b.organization_id
            WHERE o.name = 'Stumarcot' AND b.name = 'Dodoma')
INSERT INTO public.machines (organization_id, branch_id, name)
SELECT br.organization_id, br.branch_id, m.name FROM br
CROSS JOIN (VALUES ('Vibro (godown)'), ('Press makina'), ('Culvert machine'), ('Machine C')) AS m(name)
WHERE NOT EXISTS (SELECT 1 FROM public.machines x WHERE x.branch_id = br.branch_id AND public.normalize_name(x.name) = public.normalize_name(m.name));

WITH br AS (SELECT b.id AS branch_id, b.organization_id FROM public.branches b JOIN public.organizations o ON o.id = b.organization_id
            WHERE o.name = 'Stumarcot' AND b.name = 'Dodoma'),
prod AS (
  SELECT p.id AS product_id, p.canonical_name, c.name AS category, g.name AS grp, br.branch_id, br.organization_id
    FROM br JOIN public.branch_products bp ON bp.branch_id = br.branch_id AND bp.status = 'active'
    JOIN public.products p ON p.id = bp.product_id AND p.status = 'active'
    JOIN public.product_categories c ON c.id = p.category_id
    LEFT JOIN public.product_categories g ON g.id = c.parent_category_id),
pick AS (
  SELECT prod.*, CASE
    WHEN category IN ('Floor Tiles', 'Wall Tiles', 'Trench Covers') THEN 'Vibro (godown)'
    WHEN grp = 'Paving Blocks' AND category = 'Vibro' THEN 'Vibro (godown)'
    WHEN category = 'Curbstones' AND canonical_name IN ('50 Press', '80 Press') THEN 'Press makina'
    WHEN category = 'Curbstones' THEN 'Vibro (godown)'
    WHEN category = 'Blocks / Matofali' THEN 'Press makina'
    WHEN grp = 'Paving Blocks' AND category = 'Press' THEN 'Press makina'
    WHEN category = 'Culverts' THEN 'Culvert machine'
    WHEN category = 'Posts And Bicons' THEN 'Machine C'
  END AS machine FROM prod)
INSERT INTO public.machine_products (machine_id, product_id, organization_id)
SELECT m.id, pick.product_id, pick.organization_id
  FROM pick JOIN public.machines m ON m.branch_id = pick.branch_id AND m.name = pick.machine
ON CONFLICT DO NOTHING;

-- check: machines and how many products each makes; products left without one
SELECT m.name AS machine, count(mp.product_id) AS products
  FROM public.machines m JOIN public.branches b ON b.id = m.branch_id AND b.name = 'Dodoma'
  LEFT JOIN public.machine_products mp ON mp.machine_id = m.id GROUP BY m.name ORDER BY m.name;
SELECT p.canonical_name AS without_machine FROM public.branch_products bp
  JOIN public.branches b ON b.id = bp.branch_id AND b.name = 'Dodoma' JOIN public.products p ON p.id = bp.product_id
 WHERE bp.status = 'active' AND p.status = 'active' AND NOT EXISTS (SELECT 1 FROM public.machine_products mp WHERE mp.product_id = p.id);
