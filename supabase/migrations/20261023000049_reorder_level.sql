-- ============================================================
-- 049 — Reorder level per branch (1d)
--
-- SwahziTech, 2026-10-23: each product gets a low-stock reorder threshold,
-- set in its edit window; Stock shows LOW when the branch's finished-goods
-- stock falls below it. Per branch (each branch holds its own stock), on the
-- branch's product list (branch_products), in the product's stock unit.
-- Kept by whoever keeps that branch's list (products.manage at the branch).
-- ============================================================

ALTER TABLE public.branch_products
  ADD COLUMN reorder_level numeric CHECK (reorder_level IS NULL OR reorder_level >= 0);
COMMENT ON COLUMN public.branch_products.reorder_level
  IS 'Low-stock threshold at this branch, in the product''s stock unit; NULL = none set (049).';
