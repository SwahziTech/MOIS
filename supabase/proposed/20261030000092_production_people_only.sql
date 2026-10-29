-- ============================================================
-- 092 — Only production staff on a batch's "who worked" list
-- ============================================================
-- SwahziTech, 2026-10-30: teams change day to day (A may be b, j, g today and
-- d, f, e tomorrow), so the user simply ticks who worked on each batch; and
-- staff who aren't in production (driver, secretary…) must not be listed.
-- Production staff are those whose pay is part of product cost
-- (staff.in_production_cost, the "pay is part of product cost" tick).
-- The view gains that flag (names only, still no pay).
-- ============================================================

CREATE OR REPLACE VIEW public.production_people AS
SELECT s.id, s.organization_id, s.branch_id, s.full_name, s.kind, s.job_title, s.status, s.in_production_cost
FROM public.staff s
WHERE s.organization_id = public.get_my_org_id();
COMMENT ON VIEW public.production_people IS 'Staff names for ticking who worked on a batch — no pay; in_production_cost marks production staff (087, 092).';
GRANT SELECT ON public.production_people TO authenticated;
