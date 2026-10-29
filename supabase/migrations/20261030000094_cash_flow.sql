-- ============================================================
-- 094 — Cash flow: money in and out by account (CRM & Cash flow, part 1)
-- ============================================================
-- SwahziTech, 2026-10-30: cash flow first — money in/out by account, a cash
-- flow statement, a forecast. Most of the money is already recorded:
--   in:  sale payments (account) · weekly cash paid by the directors
--   out: supplier payments (account) · expenses paid (wages and statutory
--        included) · advances (an expense too)
-- Added here:
--   * payment_accounts.opening_balance / opening_date — where each account
--     starts (set by those who manage the accounts);
--   * expenses.account_id — the account an expense was paid from (expenses
--     from pay sheets and advances take their account; older ones stay
--     "account not set");
--   * cash_movements — every movement, one row each (newest first on screen);
--   * finance.view — who sees cash: owner, director, branch manager.
-- ============================================================

INSERT INTO public.permissions (code, description, module) VALUES
  ('finance.view', 'See cash flow: account balances, money in and out, forecast', 'finance')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code = 'finance.view'
WHERE r.is_system_role AND r.name IN ('owner', 'director', 'branch_manager')
ON CONFLICT DO NOTHING;

ALTER TABLE public.payment_accounts
  ADD COLUMN opening_balance numeric NOT NULL DEFAULT 0,
  ADD COLUMN opening_date    date;
COMMENT ON COLUMN public.payment_accounts.opening_balance IS 'The account''s balance on opening_date; movements after it add up from there (094).';

ALTER TABLE public.expenses ADD COLUMN account_id uuid REFERENCES public.payment_accounts(id) ON DELETE RESTRICT;
COMMENT ON COLUMN public.expenses.account_id IS 'The account it was paid from (094).';
-- expenses made from pay sheets and advances: their account
UPDATE public.expenses e SET account_id = s.account_id FROM public.pay_sheets s WHERE s.expense_id = e.id AND s.account_id IS NOT NULL AND e.account_id IS NULL;
UPDATE public.expenses e SET account_id = a.account_id FROM public.staff_advances a WHERE a.expense_id = e.id AND a.account_id IS NOT NULL AND e.account_id IS NULL;

-- keep it so from now on: pay sheets and advances name the account on their expense
CREATE OR REPLACE FUNCTION public.expense_account_from_source()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_TABLE_NAME = 'pay_sheets' AND NEW.expense_id IS NOT NULL AND NEW.account_id IS NOT NULL THEN
    UPDATE public.expenses SET account_id = NEW.account_id WHERE id = NEW.expense_id AND account_id IS NULL;
  ELSIF TG_TABLE_NAME = 'staff_advances' AND NEW.expense_id IS NOT NULL AND NEW.account_id IS NOT NULL THEN
    UPDATE public.expenses SET account_id = NEW.account_id WHERE id = NEW.expense_id AND account_id IS NULL;
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER trg_pay_sheet_expense_account AFTER INSERT OR UPDATE OF expense_id, account_id ON public.pay_sheets
  FOR EACH ROW EXECUTE FUNCTION public.expense_account_from_source();
CREATE TRIGGER trg_advance_expense_account AFTER INSERT OR UPDATE OF expense_id, account_id ON public.staff_advances
  FOR EACH ROW EXECUTE FUNCTION public.expense_account_from_source();

-- ------------------------------------------------------------
-- Every movement of money, one row each
-- kind: sale | topup (weekly cash from the directors) | purchase | wages | statutory | expense
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.cash_movements WITH (security_invoker = true) AS
SELECT p.organization_id, s.branch_id, p.account_id, p.paid_on AS day, 'in'::text AS direction, p.amount, 'sale'::text AS kind,
       'Sale ' || s.sale_no AS ref, s.id AS doc_id, p.created_at
  FROM public.sale_payments p JOIN public.sales s ON s.id = p.sale_id
UNION ALL
SELECT r.organization_id, r.branch_id, NULL, r.paid_on, 'in', r.paid_amount, 'topup',
       'Weekly cash, week ending ' || to_char(r.week_ending, 'YYYY-MM-DD'), r.id, r.updated_at
  FROM public.cash_requests r WHERE r.status = 'paid' AND r.paid_on IS NOT NULL AND coalesce(r.paid_amount, 0) > 0
UNION ALL
SELECT pp.organization_id, pu.branch_id, pp.account_id, pp.paid_on, 'out', pp.amount, 'purchase',
       'Purchase' || coalesce(' ' || pu.invoice_reference, ''), pu.id, pp.created_at
  FROM public.purchase_payments pp JOIN public.purchases pu ON pu.id = pp.purchase_id WHERE pu.status = 'recorded'
UNION ALL
SELECT e.organization_id, e.branch_id, e.account_id, coalesce(e.paid_on, e.expense_date), 'out', e.amount_paid,
       CASE WHEN c.name ILIKE 'wages' THEN 'wages' WHEN c.name ILIKE 'statutory%' THEN 'statutory' ELSE 'expense' END,
       e.description, e.id, e.created_at
  FROM public.expenses e LEFT JOIN public.expense_categories c ON c.id = e.category_id
 WHERE e.status = 'recorded' AND e.amount_paid > 0;
COMMENT ON VIEW public.cash_movements IS 'Money in and out, one row each: sale payments, weekly cash from the directors, supplier payments, expenses paid (094).';
GRANT SELECT ON public.cash_movements TO authenticated;
