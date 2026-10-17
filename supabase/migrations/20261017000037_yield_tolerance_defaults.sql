-- ============================================================
-- 037 — Yield tolerance: per-category default, per-product override (1c)
--
-- A single ±5 band across the organization checks nothing for products
-- that only yield ~5 pieces a bag (curbstones: 0–10 passes). Decided with
-- SwahziTech (2026-10-17): each category has its own default tolerance,
-- and a product can override it in its edit window.
--
-- The band a product is checked against (product_yield_band, 031):
--   a branch's own figure for the size  (branch_yield_overrides)
--   → the product's own                 (products.yield_tolerance, new)
--   → the size's                        (product_size_specs.yield_tolerance)
--   → the category default              (product_categories.default_yield_tolerance, new)
--   → the organization's                (organizations.yield_tolerance)
-- 0 means "exactly the average"; NULL means "not set here, look further".
-- The tenant's defaults are data, set separately (not in this migration).
-- ============================================================

ALTER TABLE public.product_categories
  ADD COLUMN default_yield_tolerance numeric CHECK (default_yield_tolerance IS NULL OR default_yield_tolerance >= 0);
COMMENT ON COLUMN public.product_categories.default_yield_tolerance
  IS '± pieces per bag for products of this category, unless a product sets its own. NULL = the organization''s.';

ALTER TABLE public.products
  ADD COLUMN yield_tolerance numeric CHECK (yield_tolerance IS NULL OR yield_tolerance >= 0);
COMMENT ON COLUMN public.products.yield_tolerance
  IS '± pieces per bag for this product, overriding its size and category. NULL = not overridden.';

-- Same view as 031; only the tolerance now walks product → size → category → organization
CREATE OR REPLACE VIEW public.product_specs
WITH (security_invoker = true) AS
SELECT p.id AS product_id, p.organization_id, s.id AS spec_id,
       coalesce(s.pcs_per_sqm, p.pcs_per_sqm)                 AS pcs_per_sqm,
       CASE WHEN s.pcs_per_sqm IS NOT NULL THEN 'size' WHEN p.pcs_per_sqm IS NOT NULL THEN 'product' END AS pcs_source,
       coalesce(s.average_yield_per_bag, p.wastani_per_bag)   AS average_yield_per_bag,
       CASE WHEN s.average_yield_per_bag IS NOT NULL THEN 'size' WHEN p.wastani_per_bag IS NOT NULL THEN 'product' END AS yield_source,
       coalesce(p.yield_tolerance, s.yield_tolerance, c.default_yield_tolerance, o.yield_tolerance) AS yield_tolerance
FROM public.products p
JOIN public.organizations o ON o.id = p.organization_id
JOIN public.product_categories c ON c.id = p.category_id
LEFT JOIN public.product_size_specs s
  ON s.organization_id = p.organization_id AND s.category_id = p.category_id AND s.status = 'active'
 AND s.size_key = public.size_key(p.size_cm) AND s.strength_class IS NOT DISTINCT FROM p.strength_class;
