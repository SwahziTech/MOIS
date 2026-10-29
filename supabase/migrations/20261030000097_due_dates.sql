-- ============================================================
-- 097 — Payment terms, due dates and overdue sales (PRD 4.11, 4.16)
-- ============================================================
-- SwahziTech, 2026-10-30, chose "Due dates & notifications":
--   * organizations.default_payment_days — the company's usual terms
--     (0 = due when ordered/invoiced), set under Sales ⚙ by the managers;
--   * customers.payment_days — a customer's own terms (NULL = the usual);
--   * sales.due_date — set when a sale becomes an order or invoice
--     (its date + the terms), changeable on the sale by those who sell;
--   * overdue_sales — orders and invoices past their due date with a
--     balance, and by how many days (for Sales, the forecast and the alerts).
-- ============================================================

ALTER TABLE public.organizations ADD COLUMN default_payment_days integer NOT NULL DEFAULT 0
  CHECK (default_payment_days >= 0 AND default_payment_days <= 365);
ALTER TABLE public.customers ADD COLUMN payment_days integer CHECK (payment_days >= 0 AND payment_days <= 365);
ALTER TABLE public.sales ADD COLUMN due_date date;
COMMENT ON COLUMN public.sales.due_date IS 'When payment is due: the order/invoice date + the customer''s or the company''s payment days (097).';

CREATE OR REPLACE FUNCTION public.terms_days(p_org uuid, p_customer uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce((SELECT payment_days FROM public.customers WHERE id = p_customer),
                  (SELECT default_payment_days FROM public.organizations WHERE id = p_org), 0)
$$;

-- an order or invoice gets its due date (once; a later change is kept)
CREATE OR REPLACE FUNCTION public.sale_due_date()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.stage IN ('order', 'invoice') AND NEW.due_date IS NULL THEN
    NEW.due_date := coalesce(NEW.invoiced_on, NEW.ordered_on, NEW.sale_date) + public.terms_days(NEW.organization_id, NEW.customer_id);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_sale_due_date BEFORE INSERT OR UPDATE OF stage, ordered_on, invoiced_on ON public.sales
  FOR EACH ROW EXECUTE FUNCTION public.sale_due_date();

-- orders and invoices already made: due by the usual terms from their date
UPDATE public.sales s SET due_date = coalesce(s.invoiced_on, s.ordered_on, s.sale_date) + public.terms_days(s.organization_id, s.customer_id)
WHERE s.stage IN ('order', 'invoice') AND s.due_date IS NULL;

-- change a sale's due date (agreed with the customer)
CREATE OR REPLACE FUNCTION public.set_sale_due_date(p_sale uuid, p_due date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s public.sales;
BEGIN
  SELECT * INTO s FROM public.sales WHERE id = p_sale AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('sales.create', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change sales at this branch' USING ERRCODE = '42501'; END IF;
  IF s.stage NOT IN ('order', 'invoice') THEN RAISE EXCEPTION 'Only an order or invoice has a due date' USING ERRCODE = '23514'; END IF;
  IF p_due IS NULL THEN RAISE EXCEPTION 'Choose the due date' USING ERRCODE = '23514'; END IF;
  IF p_due < s.sale_date THEN RAISE EXCEPTION 'It can''t be due before the sale' USING ERRCODE = '23514'; END IF;
  UPDATE public.sales SET due_date = p_due WHERE id = s.id;
END;
$$;

-- the company's usual payment days (those who manage prices and discounts)
CREATE OR REPLACE FUNCTION public.set_default_payment_days(p_days integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_permission_anywhere('sales.discount') THEN RAISE EXCEPTION 'Only a manager sets the payment terms' USING ERRCODE = '42501'; END IF;
  IF p_days IS NULL OR p_days < 0 OR p_days > 365 THEN RAISE EXCEPTION 'Enter the days (0–365)' USING ERRCODE = '23514'; END IF;
  UPDATE public.organizations SET default_payment_days = p_days WHERE id = public.get_my_org_id();
END;
$$;
REVOKE ALL ON FUNCTION public.set_sale_due_date(uuid, date), public.set_default_payment_days(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_sale_due_date(uuid, date), public.set_default_payment_days(integer) TO authenticated;

-- orders and invoices past due with money still owed
CREATE OR REPLACE VIEW public.overdue_sales WITH (security_invoker = true) AS
SELECT s.id AS sale_id, s.organization_id, s.branch_id, s.sale_no, s.stage, s.customer_id, s.walk_in_name, s.due_date, b.balance,
       public.org_today(s.organization_id) - s.due_date AS days_overdue
FROM public.sales s JOIN public.sale_balances b ON b.sale_id = s.id
WHERE s.stage IN ('order', 'invoice') AND s.due_date < public.org_today(s.organization_id) AND b.balance > 0.01;
COMMENT ON VIEW public.overdue_sales IS 'Orders and invoices past their due date with a balance (097).';
GRANT SELECT ON public.overdue_sales TO authenticated;
