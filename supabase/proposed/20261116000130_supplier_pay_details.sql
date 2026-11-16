-- ============================================================
-- 130 — A supplier's payment details
-- ============================================================
-- SwahziTech, 2026-11-16 (the user): paying a supplier (an order paid first, or a purchase owed) uses
-- the same Pay window as the weekly cash — where the money goes, editable, Copy all, open the bank app.
-- A supplier keeps where it is paid: bank or mobile network, account or phone number, account name.
-- Set on the supplier's form, and kept from the Pay window when the director pays to new details.
-- ============================================================

ALTER TABLE public.suppliers
  ADD COLUMN pay_bank         text,   -- the bank, or the mobile network (M-Pesa, Mixx by Yas…)
  ADD COLUMN pay_account_no   text,   -- the account number, or the phone number
  ADD COLUMN pay_account_name text;   -- the name on the account

-- the Pay window keeps the details paid to (a director may not edit suppliers otherwise)
CREATE OR REPLACE FUNCTION public.set_supplier_pay_to(p_id uuid, p_bank text, p_no text, p_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id = p_id AND organization_id = public.get_my_org_id()) THEN
    RAISE EXCEPTION 'Supplier not found' USING ERRCODE = '23514';
  END IF;
  IF NOT (public.has_permission('finance.pay') OR public.has_permission('materials.manage')) THEN
    RAISE EXCEPTION 'You can''t change a supplier''s payment details' USING ERRCODE = '42501';
  END IF;
  UPDATE public.suppliers SET pay_bank = nullif(btrim(p_bank), ''), pay_account_no = nullif(btrim(p_no), ''),
         pay_account_name = nullif(btrim(p_name), '')
   WHERE id = p_id;
END;
$$;
REVOKE ALL ON FUNCTION public.set_supplier_pay_to(uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_supplier_pay_to(uuid, text, text, text) TO authenticated;
