-- ============================================================
-- 081 — LUKU top-ups asked from the meter (Purchases › Electricity)
--
-- SwahziTech, 2026-10-28: on the Electricity page the user picks the meter
-- that needs recharging and asks for a top-up (how much, about how many
-- units). The branch manager approves; the directors buy the token from
-- their account and record it — units, token number, amount, the receipt's
-- VAT and levies. Recording it tops the meter up (a token, 072/074), makes
-- the Electricity expense (paid by the directors' account) and closes the
-- request as bought. A top-up is a purchase request (077) with one expense
-- line for that meter.
-- ============================================================

ALTER TABLE public.purchase_request_lines ADD COLUMN meter_id uuid REFERENCES public.power_meters(id) ON DELETE RESTRICT;
ALTER TABLE public.purchase_requests DROP CONSTRAINT purchase_requests_status_check;
ALTER TABLE public.purchase_requests ADD CONSTRAINT purchase_requests_status_check
  CHECK (status IN ('waiting', 'approved', 'rejected', 'ordered', 'done', 'cancelled'));
COMMENT ON COLUMN public.purchase_request_lines.meter_id IS 'A LUKU top-up: the meter it is for (081).';

-- the branch's electricity expense category (e.g. "Electricity (LUKU)"), made when missing
CREATE OR REPLACE FUNCTION public.electricity_category(p_org uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  cat uuid;
BEGIN
  SELECT id INTO cat FROM public.expense_categories WHERE organization_id = p_org AND public.normalize_name(name) LIKE public.normalize_name('Electricity') || '%'
   ORDER BY (public.normalize_name(name) = public.normalize_name('Electricity')) DESC, (status = 'active') DESC, created_at LIMIT 1;
  IF cat IS NULL THEN INSERT INTO public.expense_categories (organization_id, name) VALUES (p_org, 'Electricity') RETURNING id INTO cat; END IF;
  RETURN cat;
END;
$$;
REVOKE ALL ON FUNCTION public.electricity_category(uuid) FROM PUBLIC, anon, authenticated;

-- Ask — p: { meter_id, amount, units?, needed_by?, note? }
CREATE OR REPLACE FUNCTION public.request_power_topup(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  m   public.power_meters;
  amt numeric := round(nullif(p->>'amount', '')::numeric, 2);
  un  numeric := nullif(p->>'units', '')::numeric;
  rid uuid;
BEGIN
  SELECT * INTO m FROM public.power_meters WHERE id = (p->>'meter_id')::uuid AND organization_id = public.get_my_org_id();
  IF NOT FOUND OR m.status <> 'active' THEN RAISE EXCEPTION 'Choose the meter' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('procurement.request', m.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t ask for purchases at this branch' USING ERRCODE = '42501'; END IF;
  IF amt IS NULL OR amt <= 0 THEN RAISE EXCEPTION 'Enter how much LUKU to buy' USING ERRCODE = '23514'; END IF;
  IF un IS NOT NULL AND un <= 0 THEN RAISE EXCEPTION 'Units must be above zero' USING ERRCODE = '23514'; END IF;
  IF EXISTS (SELECT 1 FROM public.purchase_request_lines l JOIN public.purchase_requests q ON q.id = l.request_id
             WHERE l.meter_id = m.id AND q.status IN ('waiting', 'approved')) THEN
    RAISE EXCEPTION '% already has a top-up waiting', m.name USING ERRCODE = '23514';
  END IF;
  INSERT INTO public.purchase_requests (organization_id, branch_id, request_no, requested_on, needed_by, notes, requested_by)
  VALUES (m.organization_id, m.branch_id, coalesce((SELECT max(request_no) FROM public.purchase_requests WHERE organization_id = m.organization_id), 0) + 1,
          public.org_today(m.organization_id), nullif(p->>'needed_by', '')::date, nullif(btrim(p->>'note'), ''), auth.uid())
  RETURNING id INTO rid;
  INSERT INTO public.purchase_request_lines (organization_id, request_id, line_no, kind, category_id, description, quantity, unit_text, amount, meter_id)
  VALUES (m.organization_id, rid, 1, 'expense', public.electricity_category(m.organization_id), 'LUKU top-up — ' || m.name, un, CASE WHEN un IS NOT NULL THEN 'units' END, amt, m.id);
  RETURN rid;
END;
$$;

-- Bought (the directors) — p: { units, amount, token_no?, vat_amount?, ewura_levy?, rea_levy?, debt_deducted?, receipt_ref?, loaded_at? }
CREATE OR REPLACE FUNCTION public.buy_power_topup(p_request uuid, p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  q   public.purchase_requests;
  l   public.purchase_request_lines;
  tid uuid;
  eid uuid;
BEGIN
  SELECT * INTO q FROM public.purchase_requests WHERE id = p_request AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Request not found' USING ERRCODE = '23514'; END IF;
  SELECT * INTO l FROM public.purchase_request_lines WHERE request_id = q.id AND meter_id IS NOT NULL LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'This is not a LUKU top-up' USING ERRCODE = '23514'; END IF;
  IF q.status <> 'approved' THEN RAISE EXCEPTION 'The branch manager approves it first' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('cash.approve', q.branch_id, NULL) THEN RAISE EXCEPTION 'The directors buy and record the token' USING ERRCODE = '42501'; END IF;
  -- the token: tops the meter up and makes the Electricity expense (074), paid from the directors' account
  tid := public.record_power_token(p || jsonb_build_object('meter_id', l.meter_id, 'paid_from', 'directors_account'));
  SELECT expense_id INTO eid FROM public.power_tokens WHERE id = tid;
  UPDATE public.expenses SET request_line_id = l.id, description = description || ' (request #' || q.request_no || ')' WHERE id = eid;
  UPDATE public.purchase_requests SET status = 'done' WHERE id = q.id;
  RETURN tid;
END;
$$;

REVOKE ALL ON FUNCTION public.request_power_topup(jsonb), public.buy_power_topup(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_power_topup(jsonb), public.buy_power_topup(uuid, jsonb) TO authenticated;
