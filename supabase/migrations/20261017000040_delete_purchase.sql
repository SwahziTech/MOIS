-- ============================================================
-- 040 — The technical admin can delete a purchase entered wrongly (1c)
--
-- Decided with SwahziTech (2026-10-17): a purchase whose details are
-- wrong can be deleted outright — by the technical admin only
-- (system.manage). Everyone else voids it (035).
--
-- What stays:
--   * the receipt (stock side, append-only). Without "undo the goods" it
--     goes back under "Waiting for details", to be completed again.
--     With it, the receipt is reversed (the normal reversal: dated at the
--     original, refused if the stock has since been used).
--   * audit_log: the row-level trigger keeps every value of the purchase
--     and its lines; this function adds who deleted it and why.
-- ============================================================

-- Purchases keep refusing deletes (as prevent_hard_delete, 018) except the
-- one delete_purchase() is making: it marks that purchase id for the
-- current transaction only.
CREATE OR REPLACE FUNCTION public.purchase_delete_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.role() = 'service_role' OR auth.uid() IS NULL
     OR current_setting('mois.deleting_purchase', true) = OLD.id::text THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'purchase records cannot be deleted — void them instead' USING ERRCODE = '42501';
END;
$$;

DROP TRIGGER trg_purchases_no_delete ON public.purchases;
CREATE TRIGGER trg_purchases_no_delete BEFORE DELETE ON public.purchases
  FOR EACH ROW EXECUTE FUNCTION public.purchase_delete_guard();

CREATE OR REPLACE FUNCTION public.delete_purchase(p_id uuid, p_reason text, p_undo_receipt boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  pu   public.purchases;
  why  text := nullif(btrim(p_reason), '');
  rev  uuid;
BEGIN
  IF NOT public.has_permission('system.manage') THEN
    RAISE EXCEPTION 'Only the technical admin can delete a purchase' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO pu FROM public.purchases WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found' USING ERRCODE = '23514'; END IF;
  IF why IS NULL THEN RAISE EXCEPTION 'Give a reason' USING ERRCODE = '23514'; END IF;

  -- Who deleted it and why (the delete trigger records the values themselves)
  INSERT INTO public.audit_log (organization_id, entity_type, entity_id, action, field, old_value, new_value, changed_by, changed_via)
  VALUES (pu.organization_id, 'purchase', pu.id::text, 'delete', 'delete_reason',
          jsonb_build_object('purchase_date', pu.purchase_date, 'movement_id', pu.movement_id, 'status', pu.status),
          jsonb_build_object('reason', why, 'undo_receipt', coalesce(p_undo_receipt, false)),
          auth.uid(), 'app');

  PERFORM set_config('mois.deleting_purchase', pu.id::text, true);
  DELETE FROM public.purchases WHERE id = pu.id;   -- its lines go with it (ON DELETE CASCADE)
  PERFORM set_config('mois.deleting_purchase', '', true);

  IF coalesce(p_undo_receipt, false) THEN
    rev := public.reverse_inventory_movement(pu.movement_id, 'Purchase deleted: ' || why);
  END IF;

  RETURN jsonb_build_object('deleted', pu.id, 'reversal_movement_id', rev);
END;
$$;

REVOKE ALL ON FUNCTION public.delete_purchase(uuid, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_purchase(uuid, text, boolean) TO authenticated;
