-- ============================================================
-- 128 — A request carries the supplier and the prices
-- ============================================================
-- SwahziTech, 2026-11-16 (the user): "it should have all … required to fill a new purchase, so
-- when filled the user should not rewrite the details." The request now holds the supplier
-- (picked, or a new one by name — created when the order is made) and each material's agreed
-- price a unit. Approving opens the order filled from the request (approve makes the order).
-- ============================================================

ALTER TABLE public.purchase_requests
  ADD COLUMN supplier_id   uuid REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  ADD COLUMN supplier_name text;   -- a new supplier, by name, until the order creates it
ALTER TABLE public.purchase_request_lines
  ADD COLUMN unit_price numeric CHECK (unit_price >= 0);   -- a material's agreed price a unit (its unit_id)

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
  sup uuid := nullif(p->>'supplier_id', '')::uuid;
  pr  numeric;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = br AND organization_id = org) THEN RAISE EXCEPTION 'Branch not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.request', br, NULL) THEN RAISE EXCEPTION 'You can''t ask for purchases at this branch' USING ERRCODE = '42501'; END IF;
  IF jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines') = 0 THEN RAISE EXCEPTION 'Add what is needed' USING ERRCODE = '23514'; END IF;
  -- 128: the supplier, picked or named, so the order and the purchase are filled from the request
  IF sup IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id = sup AND organization_id = org) THEN
    RAISE EXCEPTION 'Supplier not found' USING ERRCODE = '23514';
  END IF;
  INSERT INTO public.purchase_requests (organization_id, branch_id, request_no, requested_on, needed_by, notes, requested_by, supplier_id, supplier_name)
  VALUES (org, br, coalesce((SELECT max(request_no) FROM public.purchase_requests WHERE organization_id = org), 0) + 1,
          public.org_today(org), nullif(p->>'needed_by', '')::date, nullif(btrim(p->>'notes'), ''), auth.uid(),
          sup, CASE WHEN sup IS NULL THEN nullif(btrim(p->>'supplier_name'), '') END)
  RETURNING id INTO rid;
  FOR x IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    n := n + 1;
    k := coalesce(nullif(x->>'kind', ''), 'material');
    IF k = 'material' THEN
      IF nullif(x->>'quantity', '')::numeric IS NULL OR (x->>'quantity')::numeric <= 0 THEN RAISE EXCEPTION 'Line %: enter the quantity', n USING ERRCODE = '23514'; END IF;
      IF NOT EXISTS (SELECT 1 FROM public.materials WHERE id = nullif(x->>'material_id', '')::uuid AND organization_id = org) THEN RAISE EXCEPTION 'Line %: choose the material', n USING ERRCODE = '23514'; END IF;
      pr := nullif(x->>'unit_price', '')::numeric;
      IF pr < 0 THEN RAISE EXCEPTION 'Line %: the price can''t be below zero', n USING ERRCODE = '23514'; END IF;
      INSERT INTO public.purchase_request_lines (organization_id, request_id, line_no, kind, material_id, quantity, unit_id, note, unit_price)
      VALUES (org, rid, n, 'material', (x->>'material_id')::uuid, (x->>'quantity')::numeric, (x->>'unit_id')::uuid, nullif(btrim(x->>'note'), ''), pr);
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
