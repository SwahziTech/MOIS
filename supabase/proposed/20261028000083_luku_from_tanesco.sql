-- ============================================================
-- 083 — LUKU is bought from TANESCO
--
-- SwahziTech, 2026-10-28: prepaid electricity (LUKU) has one seller, the
-- national utility TANESCO — never a person or another supplier. An order for
-- a meter's top-up goes to TANESCO (found among the suppliers, or added once)
-- and holds the top-up alone; a recorded token's expense names TANESCO too.
-- ============================================================

CREATE OR REPLACE FUNCTION public.tanesco_supplier(p_org uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  sid uuid;
BEGIN
  SELECT id INTO sid FROM public.suppliers WHERE organization_id = p_org AND public.normalize_name(name) LIKE '%' || public.normalize_name('Tanesco') || '%'
   ORDER BY (status = 'active') DESC, created_at LIMIT 1;
  IF sid IS NULL THEN INSERT INTO public.suppliers (organization_id, name) VALUES (p_org, 'TANESCO') RETURNING id INTO sid; END IF;
  RETURN sid;
END;
$$;
REVOKE ALL ON FUNCTION public.tanesco_supplier(uuid) FROM PUBLIC, anon, authenticated;

-- an order with a meter's top-up: TANESCO, and nothing else on it
CREATE OR REPLACE FUNCTION public.check_luku_order()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  po public.purchase_orders;
BEGIN
  IF NEW.meter_id IS NULL THEN
    IF EXISTS (SELECT 1 FROM public.purchase_order_lines WHERE order_id = NEW.order_id AND meter_id IS NOT NULL AND id <> NEW.id) THEN
      RAISE EXCEPTION 'A LUKU top-up is ordered on its own (from TANESCO)' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;
  IF EXISTS (SELECT 1 FROM public.purchase_order_lines WHERE order_id = NEW.order_id AND meter_id IS NULL AND id <> NEW.id) THEN
    RAISE EXCEPTION 'A LUKU top-up is ordered on its own (from TANESCO)' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO po FROM public.purchase_orders WHERE id = NEW.order_id;
  UPDATE public.purchase_orders SET supplier_id = public.tanesco_supplier(po.organization_id) WHERE id = po.id;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_purchase_order_lines_luku AFTER INSERT ON public.purchase_order_lines FOR EACH ROW EXECUTE FUNCTION public.check_luku_order();

-- a token's expense names TANESCO
CREATE OR REPLACE FUNCTION public.token_expense_supplier()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.expense_id IS NOT NULL THEN
    UPDATE public.expenses SET supplier_id = public.tanesco_supplier(NEW.organization_id) WHERE id = NEW.expense_id AND supplier_id IS NULL;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_power_tokens_supplier AFTER INSERT ON public.power_tokens FOR EACH ROW EXECUTE FUNCTION public.token_expense_supplier();

-- tokens already recorded: their expenses name TANESCO
UPDATE public.expenses e SET supplier_id = public.tanesco_supplier(e.organization_id)
FROM public.power_tokens t WHERE t.expense_id = e.id AND e.supplier_id IS NULL;
