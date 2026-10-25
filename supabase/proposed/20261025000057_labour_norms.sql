-- ============================================================
-- 057 — Labour norms (1d): how many people a batch should take
--
-- SwahziTech, 2026-10-25, the user, Stumarcot's rule for labour and
-- production capacity: tiles and vibro pavings 1 person per 3 bags; vibro
-- curbstones and trench covers 4 bags; the press makina runs with a crew of
-- 12 at most (it can drop to 10 or 9); culverts, bicon and posts 2–3 bags a
-- person.
--
-- Generic: two kinds of norm, set per branch —
--   * bags per person (a range) on a product the branch makes — the people a
--     batch needs grow with its bags;
--   * a crew (a range) on a machine — the people it takes to run, whatever
--     the bags (counted once a day per machine).
-- The tenant's figures go in a one-off script. Screens compare the people
-- who worked (each counted once a day) with what the norms give.
-- ============================================================

ALTER TABLE public.branch_products
  ADD COLUMN bags_per_person_min numeric CHECK (bags_per_person_min > 0),
  ADD COLUMN bags_per_person_max numeric CHECK (bags_per_person_max > 0),
  ADD CONSTRAINT branch_products_bags_per_person_range CHECK (bags_per_person_min IS NULL OR bags_per_person_max IS NULL OR bags_per_person_min <= bags_per_person_max);
COMMENT ON COLUMN public.branch_products.bags_per_person_min IS 'Labour norm (057): cement bags one person casts in a day, from…';
COMMENT ON COLUMN public.branch_products.bags_per_person_max IS '…to (equal to min for a single figure).';

ALTER TABLE public.machines
  ADD COLUMN crew_min int CHECK (crew_min > 0),
  ADD COLUMN crew_max int CHECK (crew_max > 0),
  ADD CONSTRAINT machines_crew_range CHECK (crew_min IS NULL OR crew_max IS NULL OR crew_min <= crew_max);
COMMENT ON COLUMN public.machines.crew_min IS 'Labour norm (057): people it takes to run this machine, from… (whatever the bags)';
COMMENT ON COLUMN public.machines.crew_max IS '…to.';
