-- ============================================================
-- One-off, 2026-10-27 — clear the test sales before real sales are entered
--
-- SwahziTech: every sale recorded so far was a test; real sales (from
-- 1 October) are entered from 2026-10-28. This removes, for every
-- organization:
--   * sales, their lines, payments, corrections and pending sale corrections;
--   * deliveries and their stock movements — the goods go back to the
--     finished-goods store as if they never left (any reversal of a delivery
--     goes too);
-- and keeps customers, receiving accounts and all other stock and production.
-- Sale and delivery numbers start again at 1 (they follow the highest one).
-- Runs as the database owner (no signed-in user), which the ledger and
-- no-delete guards allow; the audit log keeps the removed rows.
-- ============================================================
BEGIN;

CREATE TEMP TABLE _sale_moves ON COMMIT DROP AS
  SELECT id FROM public.inventory_movements WHERE sale_id IS NOT NULL;
INSERT INTO _sale_moves
  SELECT id FROM public.inventory_movements WHERE reverses_movement_id IN (SELECT id FROM _sale_moves);

SELECT 'before' AS stage,
       (SELECT count(*) FROM public.sales) AS sales,
       (SELECT count(*) FROM public.sale_payments) AS payments,
       (SELECT count(*) FROM public.sale_deliveries) AS deliveries,
       (SELECT count(*) FROM _sale_moves) AS stock_movements;

DELETE FROM public.sale_delivery_lines;
DELETE FROM public.sale_deliveries;
DELETE FROM public.inventory_transactions WHERE movement_id IN (SELECT id FROM _sale_moves);
DELETE FROM public.inventory_movements WHERE id IN (SELECT id FROM _sale_moves) AND reverses_movement_id IS NOT NULL;
DELETE FROM public.inventory_movements WHERE id IN (SELECT id FROM _sale_moves);
DELETE FROM public.sale_corrections;
DELETE FROM public.pending_changes WHERE kind = 'sale_correction';
DELETE FROM public.sale_payments;
DELETE FROM public.sale_lines;
DELETE FROM public.sales;

SELECT 'after' AS stage,
       (SELECT count(*) FROM public.sales) AS sales,
       (SELECT count(*) FROM public.sale_payments) AS payments,
       (SELECT count(*) FROM public.sale_deliveries) AS deliveries,
       (SELECT count(*) FROM public.inventory_movements WHERE sale_id IS NOT NULL) AS stock_movements;

COMMIT;
