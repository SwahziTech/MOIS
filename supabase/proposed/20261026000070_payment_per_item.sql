-- ============================================================
-- 070 — A payment for the whole order, or one per item (1e)
--
-- SwahziTech, 2026-10-26, the user: "the user should specify if it was paid
-- in full as the order or it was paid separately, so it can be easy to track
-- paying slips". A payment may name the item (sale line) it pays for; without
-- one it pays the whole order. An item is never paid more than it costs; the
-- order never more than its total. Editing a quotation/order re-creates its
-- lines, so an item payment then falls back to the whole order (SET NULL).
-- ============================================================

ALTER TABLE public.sale_payments ADD COLUMN sale_line_id uuid REFERENCES public.sale_lines(id) ON DELETE SET NULL;
COMMENT ON COLUMN public.sale_payments.sale_line_id IS 'The item this payment is for, when paid separately; NULL = the whole order (070).';

-- live definition as of 067; a payment may be for one item (070)
CREATE OR REPLACE FUNCTION public.record_sale_payment(p_sale uuid, p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s    public.sales;
  acc  public.payment_accounts;
  amt  numeric := round(nullif(p->>'amount', '')::numeric, 2);
  meth text := p->>'method';
  owed numeric;
  pid  uuid;
  dt   date;
  ln   public.sale_lines;   -- the item it pays for, when paid separately (070)
BEGIN
  SELECT * INTO s FROM public.sales WHERE id = p_sale AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
  IF s.stage NOT IN ('order', 'invoice') THEN RAISE EXCEPTION 'Payments are taken on an order or an invoice' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('payments.record', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t record payments at this branch' USING ERRCODE = '42501'; END IF;
  IF amt IS NULL OR amt <= 0 THEN RAISE EXCEPTION 'Enter the amount paid' USING ERRCODE = '23514'; END IF;
  IF nullif(p->>'account_id', '') IS NOT NULL THEN
    SELECT * INTO acc FROM public.payment_accounts WHERE id = (p->>'account_id')::uuid AND branch_id = s.branch_id AND status = 'active';
    IF NOT FOUND THEN RAISE EXCEPTION 'Choose the account it was paid into' USING ERRCODE = '23514'; END IF;
    meth := acc.kind;
  ELSE
    IF EXISTS (SELECT 1 FROM public.payment_accounts WHERE branch_id = s.branch_id AND status = 'active') THEN
      RAISE EXCEPTION 'Choose the account it was paid into' USING ERRCODE = '23514';
    END IF;
    IF coalesce(meth, '') NOT IN ('cash', 'mobile_money', 'bank') THEN RAISE EXCEPTION 'Choose how it was paid' USING ERRCODE = '23514'; END IF;
    IF meth <> 'cash' AND nullif(btrim(p->>'reference'), '') IS NULL THEN
      RAISE EXCEPTION 'Enter the % reference', CASE meth WHEN 'bank' THEN 'bank' ELSE 'mobile money' END USING ERRCODE = '23514';
    END IF;
  END IF;
  IF nullif(p->>'sale_line_id', '') IS NOT NULL THEN
    SELECT * INTO ln FROM public.sale_lines WHERE id = (p->>'sale_line_id')::uuid AND sale_id = s.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'That item is not on this sale' USING ERRCODE = '23514'; END IF;
    IF amt > ln.total - coalesce((SELECT sum(amount) FROM public.sale_payments WHERE sale_line_id = ln.id), 0) + 0.004 THEN
      RAISE EXCEPTION 'That is more than this item still owes' USING ERRCODE = '23514';
    END IF;
  END IF;
  owed := s.total - coalesce((SELECT sum(amount) FROM public.sale_payments WHERE sale_id = s.id), 0);
  IF amt > owed + 0.004 THEN RAISE EXCEPTION 'That is more than the % still owed', to_char(owed, 'FM999G999G990D00') USING ERRCODE = '23514'; END IF;
  dt := coalesce(nullif(p->>'paid_on', '')::date, public.org_today(s.organization_id));
  IF dt > public.org_today(s.organization_id) THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;
  INSERT INTO public.sale_payments (organization_id, sale_id, paid_on, amount, method, reference, notes, received_by, account_id, receipt_no, sale_line_id)
  VALUES (s.organization_id, s.id, dt, amt, meth, nullif(btrim(p->>'reference'), ''), nullif(btrim(p->>'notes'), ''), auth.uid(),
          acc.id, nullif(btrim(p->>'receipt_no'), ''), ln.id)
  RETURNING id INTO pid;
  RETURN pid;
END;
$$;

-- live definition as of 067; payments may name their item (070)
CREATE OR REPLACE FUNCTION public.record_sale(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  sid uuid;
  pm  jsonb;
  dt  date;
BEGIN
  sid := public.save_sale(p - 'id');
  UPDATE public.sales SET site = nullif(btrim(p->>'site'), '') WHERE id = sid;
  dt := (SELECT sale_date FROM public.sales WHERE id = sid);
  IF coalesce(p->>'stage', 'invoice') = 'order' THEN
    PERFORM public.set_sale_stage(sid, 'order', jsonb_build_object('date', dt));
  ELSE
    PERFORM public.set_sale_stage(sid, 'invoice', jsonb_build_object('date', dt, 'efd_receipt_no', p->>'efd_receipt_no'));
  END IF;
  FOR pm IN SELECT * FROM jsonb_array_elements(coalesce(p->'payments', '[]'::jsonb)) LOOP
    CONTINUE WHEN coalesce(nullif(pm->>'amount', '')::numeric, 0) = 0;
    -- paid separately: the item by its place on the sale (line_no, 1 = the first)
    PERFORM public.record_sale_payment(sid, pm || jsonb_build_object('paid_on', coalesce(nullif(pm->>'paid_on', ''), dt::text))
      || CASE WHEN nullif(pm->>'line_no', '') IS NOT NULL
              THEN jsonb_build_object('sale_line_id', (SELECT id FROM public.sale_lines WHERE sale_id = sid AND line_no = (pm->>'line_no')::int))
              ELSE '{}'::jsonb END);
  END LOOP;
  RETURN sid;
END;
$$;
