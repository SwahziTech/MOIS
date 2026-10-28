-- ============================================================
-- 080 — Purchase requests for expenses too (LUKU, tools, transport…)
--
-- SwahziTech, 2026-10-28: a purchase request asks for materials OR expenses
-- of a chosen kind (an expense category: Electricity, Tools…). Same flow:
-- asked by the storekeeper or secretary, approved by the branch manager.
-- An approved material line goes on a purchase order; an approved expense
-- line is bought and recorded as an expense, which remembers the line it
-- came from — so the request shows what has been done.
-- ============================================================

ALTER TABLE public.purchase_request_lines
  ADD COLUMN kind        text NOT NULL DEFAULT 'material' CHECK (kind IN ('material', 'expense')),
  ADD COLUMN category_id uuid REFERENCES public.expense_categories(id) ON DELETE RESTRICT,
  ADD COLUMN description text,
  ADD COLUMN unit_text   text,               -- an expense's unit as written (units, trips, pcs…)
  ADD COLUMN amount      numeric CHECK (amount >= 0);   -- what it should cost (an expense's estimate)
ALTER TABLE public.purchase_request_lines ALTER COLUMN material_id DROP NOT NULL, ALTER COLUMN unit_id DROP NOT NULL, ALTER COLUMN quantity DROP NOT NULL;
ALTER TABLE public.purchase_request_lines DROP CONSTRAINT IF EXISTS purchase_request_lines_quantity_check;
ALTER TABLE public.purchase_request_lines ADD CONSTRAINT purchase_request_lines_quantity_check CHECK (quantity IS NULL OR quantity > 0);
ALTER TABLE public.purchase_request_lines ADD CONSTRAINT purchase_request_lines_kind_fields_check CHECK (
  (kind = 'material' AND material_id IS NOT NULL AND unit_id IS NOT NULL AND quantity IS NOT NULL)
  OR (kind = 'expense' AND category_id IS NOT NULL AND btrim(coalesce(description, '')) <> ''));

ALTER TABLE public.expenses ADD COLUMN request_line_id uuid REFERENCES public.purchase_request_lines(id) ON DELETE SET NULL;
COMMENT ON COLUMN public.expenses.request_line_id IS 'The approved purchase-request line this expense fulfils (080).';

-- p: { branch_id, needed_by?, notes?, lines: [{ kind?, material_id?, quantity?, unit_id?, category_id?, description?, unit_text?, amount?, note? }] }
CREATE OR REPLACE FUNCTION public.submit_purchase_request(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  br  uuid := nullif(p->>'branch_id', '')::uuid;
  rid uuid;
  x   jsonb;
  n   int := 0;
  k   text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = br AND organization_id = org) THEN RAISE EXCEPTION 'Branch not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.request', br, NULL) THEN RAISE EXCEPTION 'You can''t ask for purchases at this branch' USING ERRCODE = '42501'; END IF;
  IF jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines') = 0 THEN RAISE EXCEPTION 'Add what is needed' USING ERRCODE = '23514'; END IF;
  INSERT INTO public.purchase_requests (organization_id, branch_id, request_no, requested_on, needed_by, notes, requested_by)
  VALUES (org, br, coalesce((SELECT max(request_no) FROM public.purchase_requests WHERE organization_id = org), 0) + 1,
          public.org_today(org), nullif(p->>'needed_by', '')::date, nullif(btrim(p->>'notes'), ''), auth.uid())
  RETURNING id INTO rid;
  FOR x IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    n := n + 1;
    k := coalesce(nullif(x->>'kind', ''), 'material');
    IF k = 'material' THEN
      IF nullif(x->>'quantity', '')::numeric IS NULL OR (x->>'quantity')::numeric <= 0 THEN RAISE EXCEPTION 'Line %: enter the quantity', n USING ERRCODE = '23514'; END IF;
      IF NOT EXISTS (SELECT 1 FROM public.materials WHERE id = nullif(x->>'material_id', '')::uuid AND organization_id = org) THEN RAISE EXCEPTION 'Line %: choose the material', n USING ERRCODE = '23514'; END IF;
      INSERT INTO public.purchase_request_lines (organization_id, request_id, line_no, kind, material_id, quantity, unit_id, note)
      VALUES (org, rid, n, 'material', (x->>'material_id')::uuid, (x->>'quantity')::numeric, (x->>'unit_id')::uuid, nullif(btrim(x->>'note'), ''));
    ELSIF k = 'expense' THEN
      IF NOT EXISTS (SELECT 1 FROM public.expense_categories WHERE id = nullif(x->>'category_id', '')::uuid AND organization_id = org) THEN RAISE EXCEPTION 'Line %: choose what kind of expense', n USING ERRCODE = '23514'; END IF;
      IF nullif(btrim(x->>'description'), '') IS NULL THEN RAISE EXCEPTION 'Line %: say what it is', n USING ERRCODE = '23514'; END IF;
      IF nullif(x->>'quantity', '')::numeric IS NOT NULL AND (x->>'quantity')::numeric <= 0 THEN RAISE EXCEPTION 'Line %: the quantity must be above zero', n USING ERRCODE = '23514'; END IF;
      INSERT INTO public.purchase_request_lines (organization_id, request_id, line_no, kind, category_id, description, quantity, unit_text, amount, note)
      VALUES (org, rid, n, 'expense', (x->>'category_id')::uuid, btrim(x->>'description'), nullif(x->>'quantity', '')::numeric,
              nullif(btrim(x->>'unit_text'), ''), round(nullif(x->>'amount', '')::numeric, 2), nullif(btrim(x->>'note'), ''));
    ELSE
      RAISE EXCEPTION 'Line %: a material or an expense', n USING ERRCODE = '23514';
    END IF;
  END LOOP;
  RETURN rid;
END;
$$;

-- an expense recorded for an approved request line
CREATE OR REPLACE FUNCTION public.link_expense_to_request(p_expense uuid, p_line uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ex public.expenses;
  r  public.purchase_requests;
BEGIN
  SELECT * INTO ex FROM public.expenses WHERE id = p_expense AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Expense not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.receive', ex.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change expenses at this branch' USING ERRCODE = '42501'; END IF;
  SELECT q.* INTO r FROM public.purchase_requests q JOIN public.purchase_request_lines l ON l.request_id = q.id
   WHERE l.id = p_line AND l.kind = 'expense' AND q.organization_id = ex.organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Request line not found' USING ERRCODE = '23514'; END IF;
  IF r.status NOT IN ('approved', 'ordered') THEN RAISE EXCEPTION 'The request is not approved' USING ERRCODE = '23514'; END IF;
  IF r.branch_id <> ex.branch_id THEN RAISE EXCEPTION 'The request is for another branch' USING ERRCODE = '23514'; END IF;
  UPDATE public.expenses SET request_line_id = p_line WHERE id = ex.id;
END;
$$;

REVOKE ALL ON FUNCTION public.link_expense_to_request(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.link_expense_to_request(uuid, uuid) TO authenticated;
