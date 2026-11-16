-- ============================================================
-- 125 — A cancelled order or request is deleted for good
-- ============================================================
-- SwahziTech, 2026-11-16 (the user): Orders keeps only what is still to buy; bought ones move to
-- Purchases / Expenses; a cancelled one is deleted, not kept.
--   * cancelling a purchase order deletes it (its lines go with it); a purchase that pointed to it
--     (only void ones can) keeps its record, the link is cleared. Its request goes back to approved,
--     as before (084).
--   * cancelling a request deletes it with its lines (and any cancelled order left on it).
--   * the ones already cancelled are deleted now.
-- The audit log keeps a copy of every deleted row.
-- ============================================================

-- the delete guard (068, 123) lets these through, set only inside drop_cancelled_order
CREATE OR REPLACE FUNCTION public.prevent_hard_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.role() = 'service_role' OR auth.uid() IS NULL THEN
    RETURN OLD;
  END IF;
  -- 068: a sale correction may remove a wrong payment (set only inside apply_sale_correction)
  IF TG_TABLE_NAME = 'sale_payments' AND coalesce(current_setting('mois.sale_correction', true), '') = 'on' THEN
    RETURN OLD;
  END IF;
  -- 123: an unwanted weekly cash import (set only inside delete_cash_request)
  IF TG_TABLE_NAME = 'cash_requests' AND coalesce(current_setting('mois.cash_request_delete', true), '') = 'on' THEN
    RETURN OLD;
  END IF;
  -- 125: a cancelled order or request (set only inside drop_cancelled_order)
  IF TG_TABLE_NAME IN ('purchase_orders', 'purchase_requests') AND coalesce(current_setting('mois.order_delete', true), '') = 'on' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION '% records cannot be deleted — deactivate them instead', TG_ARGV[0]
    USING ERRCODE = '42501';
END;
$$;

CREATE OR REPLACE FUNCTION public.drop_cancelled_order()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM 'cancelled' THEN
    PERFORM set_config('mois.order_delete', 'on', true);
    IF TG_TABLE_NAME = 'purchase_orders' THEN
      UPDATE public.purchases SET purchase_order_id = NULL WHERE purchase_order_id = NEW.id;
      DELETE FROM public.purchase_orders WHERE id = NEW.id;
    ELSE
      UPDATE public.purchases SET purchase_order_id = NULL
       WHERE purchase_order_id IN (SELECT id FROM public.purchase_orders WHERE request_id = NEW.id AND status = 'cancelled');
      DELETE FROM public.purchase_orders WHERE request_id = NEW.id AND status = 'cancelled';
      DELETE FROM public.purchase_requests WHERE id = NEW.id;
    END IF;
    PERFORM set_config('mois.order_delete', '', true);
  END IF;
  RETURN NULL;
END;
$$;

-- named to run after the other AFTER UPDATE triggers (084 puts the request back to approved first)
CREATE TRIGGER trg_zz_purchase_orders_drop_cancelled AFTER UPDATE OF status ON public.purchase_orders
  FOR EACH ROW EXECUTE FUNCTION public.drop_cancelled_order();
CREATE TRIGGER trg_zz_purchase_requests_drop_cancelled AFTER UPDATE OF status ON public.purchase_requests
  FOR EACH ROW EXECUTE FUNCTION public.drop_cancelled_order();

-- the ones already cancelled
DO $$
BEGIN
  PERFORM set_config('mois.order_delete', 'on', true);
  UPDATE public.purchases SET purchase_order_id = NULL
   WHERE purchase_order_id IN (SELECT id FROM public.purchase_orders WHERE status = 'cancelled');
  DELETE FROM public.purchase_orders WHERE status = 'cancelled';
  UPDATE public.purchases SET purchase_order_id = NULL
   WHERE purchase_order_id IN (SELECT o.id FROM public.purchase_orders o JOIN public.purchase_requests r ON r.id = o.request_id WHERE r.status = 'cancelled');
  DELETE FROM public.purchase_requests r WHERE r.status = 'cancelled'
     AND NOT EXISTS (SELECT 1 FROM public.purchase_orders o WHERE o.request_id = r.id);
  PERFORM set_config('mois.order_delete', '', true);
END $$;
