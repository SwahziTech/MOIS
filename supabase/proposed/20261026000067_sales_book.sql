-- ============================================================
-- 067 — The sales book (1e): receiving accounts, site, receipt number,
-- and a sale recorded in one go
--
-- SwahziTech, 2026-10-26, from the tenant's own sales ledger: a daily book,
-- one row per item, the money under the ACCOUNT that received it, the
-- receipt number and the SITE the goods went to.
--   * payment_accounts: the accounts a branch takes money into (a bank
--     account, a mobile money line, the cash box — incl. accounts held by
--     staff), entered by the tenant (confidential — never seeded here);
--     managed by managers (sales.discount) at the branch;
--   * a payment names its account (its kind gives the method) and may carry
--     the receipt-book number;
--   * a sale may name its site;
--   * record_sale: a sale written straight into the book — saved, invoiced
--     and its payments taken in one transaction (rates other than the list
--     still need a manager and a reason — save_sale, 064).
-- ============================================================

CREATE TABLE public.payment_accounts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  name            text NOT NULL CHECK (btrim(name) <> ''),
  kind            text NOT NULL CHECK (kind IN ('cash', 'bank', 'mobile_money')),
  display_order   int  NOT NULL DEFAULT 0,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_payment_accounts_name ON public.payment_accounts (branch_id, public.normalize_name(name));
CREATE TRIGGER trg_payment_accounts_updated_at BEFORE UPDATE ON public.payment_accounts FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_payment_accounts_audit AFTER INSERT OR UPDATE OR DELETE ON public.payment_accounts FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('payment_account', 'id');
CREATE TRIGGER trg_payment_accounts_no_delete BEFORE DELETE ON public.payment_accounts FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('payment account');
ALTER TABLE public.payment_accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "payment_accounts: sales staff read" ON public.payment_accounts FOR SELECT
  USING (organization_id = public.get_my_org_id() AND public.has_permission_at('sales.view', branch_id, NULL));
CREATE POLICY "payment_accounts: managers add" ON public.payment_accounts FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_at('sales.discount', branch_id, NULL));
CREATE POLICY "payment_accounts: managers change" ON public.payment_accounts FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND public.has_permission_at('sales.discount', branch_id, NULL))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_at('sales.discount', branch_id, NULL));

ALTER TABLE public.sale_payments
  ADD COLUMN account_id uuid REFERENCES public.payment_accounts(id) ON DELETE RESTRICT,
  ADD COLUMN receipt_no text;          -- the receipt-book number, when one is written
ALTER TABLE public.sales ADD COLUMN site text;   -- where the goods go
COMMENT ON COLUMN public.sales.site IS 'Where the goods go (the customer''s site) — 067.';


-- ------------------------------------------------------------
-- A payment into a named account (replaces 064's; method from the account)
-- p: { account_id, amount, receipt_no?, reference?, paid_on?, notes? }
--    (without account_id, 064's { method, reference } still works)
-- ------------------------------------------------------------
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
  owed := s.total - coalesce((SELECT sum(amount) FROM public.sale_payments WHERE sale_id = s.id), 0);
  IF amt > owed + 0.004 THEN RAISE EXCEPTION 'That is more than the % still owed', to_char(owed, 'FM999G999G990D00') USING ERRCODE = '23514'; END IF;
  dt := coalesce(nullif(p->>'paid_on', '')::date, public.org_today(s.organization_id));
  IF dt > public.org_today(s.organization_id) THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;
  INSERT INTO public.sale_payments (organization_id, sale_id, paid_on, amount, method, reference, notes, received_by, account_id, receipt_no)
  VALUES (s.organization_id, s.id, dt, amt, meth, nullif(btrim(p->>'reference'), ''), nullif(btrim(p->>'notes'), ''), auth.uid(),
          acc.id, nullif(btrim(p->>'receipt_no'), ''))
  RETURNING id INTO pid;
  RETURN pid;
END;
$$;


-- ------------------------------------------------------------
-- A sale written straight into the book: saved, invoiced, paid — all or nothing
-- p: save_sale's fields + { site?, efd_receipt_no?, stage?: 'invoice' (default) | 'order',
--      payments?: [{ account_id, amount, receipt_no?, reference? }] }
-- ------------------------------------------------------------
CREATE FUNCTION public.record_sale(p jsonb)
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
    PERFORM public.record_sale_payment(sid, pm || jsonb_build_object('paid_on', coalesce(nullif(pm->>'paid_on', ''), dt::text)));
  END LOOP;
  RETURN sid;
END;
$$;
REVOKE ALL ON FUNCTION public.record_sale(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_sale(jsonb) TO authenticated;

-- the site can be set or corrected on any sale not cancelled
CREATE FUNCTION public.set_sale_site(p_sale uuid, p_site text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.sales;
BEGIN
  SELECT * INTO s FROM public.sales WHERE id = p_sale AND organization_id = public.get_my_org_id();
  IF NOT FOUND OR s.stage = 'cancelled' THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('sales.create', s.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change sales at this branch' USING ERRCODE = '42501'; END IF;
  UPDATE public.sales SET site = nullif(btrim(p_site), '') WHERE id = s.id;
END;
$$;
REVOKE ALL ON FUNCTION public.set_sale_site(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_sale_site(uuid, text) TO authenticated;
