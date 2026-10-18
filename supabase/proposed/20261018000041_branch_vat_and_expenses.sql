-- ============================================================
-- 041 — Branch VAT rate; expenses with categories (1c)
--
-- Decided with SwahziTech (2026-10-18):
--   * VAT on purchases is a branch setting, kept by the branch manager
--     (products.manage at the branch; org admins too). 0 = the branch is
--     not VAT-registered. Ticked on a purchase, VAT = amount × r/(100 + r).
--   * Expenses — electricity (LUKU), water, office tools, equipment… —
--     are recorded under a category. Categories are a list; what was
--     bought is typed each time and never becomes a list to pick from.
--     Expenses touch no stock and no material cost.
-- ============================================================

-- ------------------------------------------------------------
-- 1. VAT rate per branch
-- ------------------------------------------------------------
ALTER TABLE public.branches ADD COLUMN vat_rate numeric NOT NULL DEFAULT 18
  CHECK (vat_rate >= 0 AND vat_rate < 100);
COMMENT ON COLUMN public.branches.vat_rate
  IS 'VAT rate (%) used on this branch''s purchases and expenses; 0 = not VAT-registered. Set by the branch manager (set_branch_vat_rate).';

CREATE OR REPLACE FUNCTION public.set_branch_vat_rate(p_branch_id uuid, p_rate numeric)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id AND organization_id = public.get_my_org_id()) THEN
    RAISE EXCEPTION 'Branch not found' USING ERRCODE = '23514';
  END IF;
  IF NOT public.has_permission_at('products.manage', p_branch_id, NULL) THEN
    RAISE EXCEPTION 'Only the branch manager can change the branch''s VAT rate' USING ERRCODE = '42501';
  END IF;
  IF p_rate IS NULL OR p_rate < 0 OR p_rate >= 100 THEN
    RAISE EXCEPTION 'VAT rate must be from 0 to below 100' USING ERRCODE = '23514';
  END IF;
  UPDATE public.branches SET vat_rate = p_rate WHERE id = p_branch_id;
END;
$$;


-- ------------------------------------------------------------
-- 2. Expense categories (a list per organization)
-- ------------------------------------------------------------
CREATE TABLE public.expense_categories (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name            text NOT NULL CHECK (btrim(name) <> ''),
  display_order   int  NOT NULL DEFAULT 0,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_expense_categories_name ON public.expense_categories (organization_id, public.normalize_name(name));

CREATE TRIGGER trg_expense_categories_updated_at BEFORE UPDATE ON public.expense_categories
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_expense_categories_audit AFTER INSERT OR UPDATE OR DELETE ON public.expense_categories
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('expense_category', 'id');
CREATE TRIGGER trg_expense_categories_no_delete BEFORE DELETE ON public.expense_categories
  FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('expense category');

ALTER TABLE public.expense_categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY "expense_categories: read own org" ON public.expense_categories FOR SELECT
  USING (organization_id = public.get_my_org_id());
CREATE POLICY "expense_categories: org admins add" ON public.expense_categories FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('materials.manage'));
CREATE POLICY "expense_categories: org admins change" ON public.expense_categories FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND public.has_permission('materials.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('materials.manage'));

-- The starting list (SwahziTech's): every organization gets it once
INSERT INTO public.expense_categories (organization_id, name, display_order)
SELECT o.id, c.name, c.ord
FROM public.organizations o
CROSS JOIN (VALUES ('Electricity (LUKU)', 1), ('Water', 2), ('Office tools', 3), ('Equipment', 4), ('Other', 99)) AS c(name, ord)
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- 3. Expenses
-- ------------------------------------------------------------
CREATE TABLE public.expenses (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  expense_date    date NOT NULL,
  category_id     uuid NOT NULL REFERENCES public.expense_categories(id) ON DELETE RESTRICT,
  description     text NOT NULL CHECK (btrim(description) <> ''),   -- typed each time, e.g. "LUKU token", "Hammer"
  quantity        numeric CHECK (quantity > 0),                      -- optional
  unit_price      numeric CHECK (unit_price >= 0),                   -- optional, with quantity
  amount          numeric NOT NULL CHECK (amount >= 0),              -- what it cost in all
  supplier_id     uuid REFERENCES public.suppliers(id) ON DELETE RESTRICT,   -- optional
  vat_amount      numeric CHECK (vat_amount >= 0),                   -- set when VAT is included in the amount
  amount_paid     numeric NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
  payment_method  text,
  paid_on         date,
  notes           text,
  status          text NOT NULL DEFAULT 'recorded' CHECK (status IN ('recorded', 'void')),
  void_reason     text,
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (amount_paid <= amount),
  CHECK (vat_amount IS NULL OR vat_amount <= amount),
  CHECK ((status = 'void') = (void_reason IS NOT NULL))
);
CREATE INDEX idx_expenses_branch_date ON public.expenses (organization_id, branch_id, expense_date DESC);

CREATE TRIGGER trg_expenses_updated_at BEFORE UPDATE ON public.expenses
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_expenses_audit AFTER INSERT OR UPDATE OR DELETE ON public.expenses
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('expense', 'id');
CREATE TRIGGER trg_expenses_no_delete BEFORE DELETE ON public.expenses
  FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('expense');

-- Read across the organization; written only through the functions below
ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "expenses: read own org" ON public.expenses FOR SELECT USING (organization_id = public.get_my_org_id());

COMMENT ON TABLE public.expenses
  IS 'Branch spending that is not stock: electricity, water, tools, equipment… Category from a list; description typed each time.';

-- Shared checks and the supplier (optional; found or added by name as for purchases)
CREATE OR REPLACE FUNCTION public.expense_fields(p jsonb, p_branch uuid, OUT sup uuid, OUT cat uuid, OUT amt numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org     uuid := public.get_my_org_id();
  new_sup text := nullif(btrim(p->>'new_supplier_name'), '');
BEGIN
  IF NOT public.has_permission_at('procurement.receive', p_branch, NULL) THEN
    RAISE EXCEPTION 'You can''t record expenses at this branch' USING ERRCODE = '42501';
  END IF;
  cat := nullif(p->>'category_id', '')::uuid;
  IF NOT EXISTS (SELECT 1 FROM public.expense_categories WHERE id = cat AND organization_id = org) THEN
    RAISE EXCEPTION 'Choose the expense category' USING ERRCODE = '23514';
  END IF;
  IF nullif(btrim(p->>'description'), '') IS NULL THEN
    RAISE EXCEPTION 'Say what was bought or paid for' USING ERRCODE = '23514';
  END IF;
  amt := nullif(p->>'amount', '')::numeric;
  IF amt IS NULL OR amt < 0 THEN RAISE EXCEPTION 'Enter the amount' USING ERRCODE = '23514'; END IF;
  IF nullif(p->>'expense_date', '') IS NULL THEN RAISE EXCEPTION 'Enter the date' USING ERRCODE = '23514'; END IF;
  IF coalesce(nullif(p->>'amount_paid', '')::numeric, 0) > amt THEN
    RAISE EXCEPTION 'Paid is more than the amount' USING ERRCODE = '23514';
  END IF;
  IF coalesce(nullif(p->>'vat_amount', '')::numeric, 0) > amt THEN
    RAISE EXCEPTION 'VAT is more than the amount' USING ERRCODE = '23514';
  END IF;

  sup := nullif(p->>'supplier_id', '')::uuid;
  IF sup IS NOT NULL AND new_sup IS NOT NULL THEN
    RAISE EXCEPTION 'Choose a supplier or name a new one — not both' USING ERRCODE = '23514';
  END IF;
  IF new_sup IS NOT NULL THEN
    SELECT id INTO sup FROM public.suppliers WHERE organization_id = org AND public.normalize_name(name) = public.normalize_name(new_sup);
    IF sup IS NULL THEN
      IF public.normalize_name(new_sup) = '' THEN RAISE EXCEPTION 'Name the supplier' USING ERRCODE = '23514'; END IF;
      INSERT INTO public.suppliers (organization_id, name) VALUES (org, new_sup) RETURNING id INTO sup;
    END IF;
  ELSIF sup IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id = sup AND organization_id = org) THEN
    RAISE EXCEPTION 'Supplier not found' USING ERRCODE = '23514';
  END IF;
END;
$$;

-- p: { branch_id, expense_date, category_id, description, quantity?, unit_price?, amount,
--      supplier_id? | new_supplier_name?, vat_amount?, amount_paid?, payment_method?, paid_on?, notes? }
CREATE OR REPLACE FUNCTION public.record_expense(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  br  uuid := nullif(p->>'branch_id', '')::uuid;
  f   record;
  eid uuid;
BEGIN
  IF org IS NULL OR auth.uid() IS NULL THEN RAISE EXCEPTION 'Not signed in to an organization' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = br AND organization_id = org) THEN
    RAISE EXCEPTION 'Branch not found' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO f FROM public.expense_fields(p, br);
  INSERT INTO public.expenses (organization_id, branch_id, expense_date, category_id, description, quantity, unit_price, amount,
                               supplier_id, vat_amount, amount_paid, payment_method, paid_on, notes, created_by)
  VALUES (org, br, (p->>'expense_date')::date, f.cat, btrim(p->>'description'),
          nullif(p->>'quantity', '')::numeric, nullif(p->>'unit_price', '')::numeric, f.amt, f.sup,
          nullif(p->>'vat_amount', '')::numeric, coalesce(nullif(p->>'amount_paid', '')::numeric, 0),
          nullif(btrim(p->>'payment_method'), ''), nullif(p->>'paid_on', '')::date, nullif(btrim(p->>'notes'), ''), auth.uid())
  RETURNING id INTO eid;
  RETURN eid;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_expense(p_id uuid, p jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ex public.expenses;
  f  record;
BEGIN
  SELECT * INTO ex FROM public.expenses WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND OR ex.status <> 'recorded' THEN RAISE EXCEPTION 'Expense not found' USING ERRCODE = '23514'; END IF;
  SELECT * INTO f FROM public.expense_fields(p, ex.branch_id);
  UPDATE public.expenses SET expense_date = (p->>'expense_date')::date, category_id = f.cat, description = btrim(p->>'description'),
         quantity = nullif(p->>'quantity', '')::numeric, unit_price = nullif(p->>'unit_price', '')::numeric, amount = f.amt,
         supplier_id = f.sup, vat_amount = nullif(p->>'vat_amount', '')::numeric,
         amount_paid = coalesce(nullif(p->>'amount_paid', '')::numeric, 0), payment_method = nullif(btrim(p->>'payment_method'), ''),
         paid_on = nullif(p->>'paid_on', '')::date, notes = nullif(btrim(p->>'notes'), '')
  WHERE id = ex.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.void_expense(p_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ex public.expenses;
BEGIN
  SELECT * INTO ex FROM public.expenses WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND OR ex.status <> 'recorded' THEN RAISE EXCEPTION 'Expense not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.receive', ex.branch_id, NULL) THEN
    RAISE EXCEPTION 'You can''t change expenses at this branch' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN RAISE EXCEPTION 'Give a reason' USING ERRCODE = '23514'; END IF;
  UPDATE public.expenses SET status = 'void', void_reason = btrim(p_reason) WHERE id = ex.id;
END;
$$;

REVOKE ALL ON FUNCTION public.set_branch_vat_rate(uuid, numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.expense_fields(jsonb, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_expense(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_expense(uuid, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.void_expense(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_branch_vat_rate(uuid, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_expense(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_expense(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.void_expense(uuid, text) TO authenticated;
