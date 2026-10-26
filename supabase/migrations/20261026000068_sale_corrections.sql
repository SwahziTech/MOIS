-- ============================================================
-- 068 — Correcting a sale (1e)
--
-- SwahziTech, 2026-10-26, the user: the Technical admin can "correct
-- anything, with a reason"; branch managers can correct their branch's
-- sales "through Approvals". An invoice is otherwise fixed (064).
--   * correct_sale(sale, changes): the Technical admin's correction applies
--     at once; a manager's (sales.discount at the branch) is checked as if
--     applied, then waits in Approvals (kind 'sale_correction'); an org admin
--     approves it (decide_change);
--   * what can change: date, customer / walk-in buyer, site, EFD receipt,
--     notes; lines (product, colour, quantity, price) — never below what has
--     already been delivered, a delivered line keeps its product and can't be
--     removed; payments (amount, account, date, receipt no.) — a wrong one can
--     be removed;
--   * every correction needs a reason and is kept with what the sale looked
--     like before (sale_corrections); a price other than the list carries the
--     reason as its discount reason; the total never drops below what has
--     been paid.
-- Removing a payment is the one delete allowed: prevent_hard_delete gives way
-- only inside apply_sale_correction (a setting for that transaction), and the
-- audit log keeps the removed row.
-- ============================================================

ALTER TABLE public.pending_changes DROP CONSTRAINT pending_changes_kind_check;
ALTER TABLE public.pending_changes ADD CONSTRAINT pending_changes_kind_check
  CHECK (kind IN ('price', 'color_rule', 'stock_movement', 'stock_reversal', 'stock_import', 'purchase', 'production_day', 'sale_correction'));

CREATE OR REPLACE FUNCTION public.prevent_hard_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.role() = 'service_role' OR auth.uid() IS NULL THEN
    RETURN OLD;
  END IF;
  -- 068: a sale correction may remove a wrong payment (set only inside apply_sale_correction)
  IF TG_TABLE_NAME = 'sale_payments' AND coalesce(current_setting('mois.sale_correction', true), '') = 'on' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION '% records cannot be deleted — deactivate them instead', TG_ARGV[0]
    USING ERRCODE = '42501';
END;
$$;

CREATE TABLE public.sale_corrections (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  sale_id         uuid NOT NULL REFERENCES public.sales(id) ON DELETE RESTRICT,
  reason          text NOT NULL CHECK (btrim(reason) <> ''),
  changes         jsonb NOT NULL,             -- what was asked
  before          jsonb NOT NULL,             -- the sale, its lines and payments before
  requested_by    uuid REFERENCES auth.users(id),
  applied_by      uuid REFERENCES auth.users(id),
  applied_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_sale_corrections_sale ON public.sale_corrections (sale_id);
ALTER TABLE public.sale_corrections ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sale_corrections: read with the sale" ON public.sale_corrections FOR SELECT
  USING (organization_id = public.get_my_org_id() AND EXISTS (SELECT 1 FROM public.sales s WHERE s.id = sale_id AND public.has_permission_at('sales.view', s.branch_id, NULL)));


-- ------------------------------------------------------------
-- Apply a correction (no permission check — callers decide who may)
-- changes: { sale_date?, customer_id? | walk_in_name?, walk_in_phone?, site?, efd_receipt_no?, notes?,
--            lines?: [{ id?, product_id, color_id?, quantity, price? (without VAT), remove? }],
--            payments?: [{ id, amount?, account_id?, paid_on?, receipt_no?, remove? }] }
-- ------------------------------------------------------------
CREATE FUNCTION public.apply_sale_correction(p_sale uuid, ch jsonb, p_reason text, p_requested_by uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s      public.sales;
  snap   jsonb;
  l      jsonb;
  old    public.sale_lines;
  prod   public.products;
  col    uuid;
  qty    numeric;
  done   numeric;
  lp     numeric;
  pr     numeric;
  rate   numeric;
  pi     numeric;
  tot    numeric;
  amt    numeric;
  pm     jsonb;
  pay    public.sale_payments;
  acc    public.payment_accounts;
  n      int;
  paid   numeric;
BEGIN
  IF nullif(btrim(p_reason), '') IS NULL THEN RAISE EXCEPTION 'Give the reason for the correction' USING ERRCODE = '23514'; END IF;
  SELECT * INTO s FROM public.sales WHERE id = p_sale FOR UPDATE;
  IF NOT FOUND OR s.stage = 'cancelled' THEN RAISE EXCEPTION 'Sale not found or cancelled' USING ERRCODE = '23514'; END IF;
  snap := jsonb_build_object('sale', to_jsonb(s),
    'lines', (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.line_no), '[]') FROM public.sale_lines x WHERE x.sale_id = s.id),
    'payments', (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.paid_on), '[]') FROM public.sale_payments x WHERE x.sale_id = s.id));

  -- the sale itself
  IF ch ? 'customer_id' AND nullif(ch->>'customer_id', '') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.customers WHERE id = (ch->>'customer_id')::uuid AND organization_id = s.organization_id) THEN
    RAISE EXCEPTION 'Customer not found' USING ERRCODE = '23514';
  END IF;
  IF ch ? 'sale_date' AND (ch->>'sale_date')::date > public.org_today(s.organization_id) THEN
    RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514';
  END IF;
  UPDATE public.sales SET
         sale_date      = CASE WHEN ch ? 'sale_date' THEN (ch->>'sale_date')::date ELSE sale_date END,
         invoiced_on    = CASE WHEN ch ? 'sale_date' AND stage = 'invoice' AND invoiced_on = sale_date THEN (ch->>'sale_date')::date ELSE invoiced_on END,
         customer_id    = CASE WHEN ch ? 'customer_id' OR ch ? 'walk_in_name' THEN nullif(ch->>'customer_id', '')::uuid ELSE customer_id END,
         walk_in_name   = CASE WHEN ch ? 'customer_id' OR ch ? 'walk_in_name' THEN CASE WHEN nullif(ch->>'customer_id', '') IS NULL THEN nullif(btrim(ch->>'walk_in_name'), '') END ELSE walk_in_name END,
         walk_in_phone  = CASE WHEN ch ? 'customer_id' OR ch ? 'walk_in_name' THEN CASE WHEN nullif(ch->>'customer_id', '') IS NULL THEN nullif(btrim(ch->>'walk_in_phone'), '') END ELSE walk_in_phone END,
         site           = CASE WHEN ch ? 'site' THEN nullif(btrim(ch->>'site'), '') ELSE site END,
         efd_receipt_no = CASE WHEN ch ? 'efd_receipt_no' THEN nullif(btrim(ch->>'efd_receipt_no'), '') ELSE efd_receipt_no END,
         notes          = CASE WHEN ch ? 'notes' THEN nullif(btrim(ch->>'notes'), '') ELSE notes END
   WHERE id = s.id;

  -- lines: the database prices them as save_sale does; delivered quantities stand
  FOR l IN SELECT * FROM jsonb_array_elements(coalesce(ch->'lines', '[]'::jsonb)) LOOP
    old := NULL;
    IF nullif(l->>'id', '') IS NOT NULL THEN
      SELECT * INTO old FROM public.sale_lines WHERE id = (l->>'id')::uuid AND sale_id = s.id;
      IF NOT FOUND THEN RAISE EXCEPTION 'A line is not on this sale' USING ERRCODE = '23514'; END IF;
    END IF;
    done := CASE WHEN old.id IS NULL THEN 0 ELSE coalesce((SELECT sum(quantity) FROM public.sale_delivery_lines WHERE sale_line_id = old.id), 0) END;
    IF coalesce((l->>'remove')::boolean, false) THEN
      IF old.id IS NULL THEN CONTINUE; END IF;
      IF done > 0 THEN RAISE EXCEPTION 'A line with goods delivered can''t be removed' USING ERRCODE = '23514'; END IF;
      DELETE FROM public.sale_lines WHERE id = old.id;
      CONTINUE;
    END IF;
    SELECT * INTO prod FROM public.products WHERE id = nullif(l->>'product_id', '')::uuid AND organization_id = s.organization_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Choose the product' USING ERRCODE = '23514'; END IF;
    col := CASE WHEN public.product_is_coloured(prod.id) THEN nullif(l->>'color_id', '')::uuid END;
    IF public.product_is_coloured(prod.id) AND (col IS NULL OR NOT public.product_color_ok(prod.id, col)) THEN
      RAISE EXCEPTION '%: choose one of its colours', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    IF done > 0 AND (prod.id <> old.product_id OR col IS DISTINCT FROM old.color_id) THEN
      RAISE EXCEPTION '%: goods have been delivered on this line — its product stays', prod.canonical_name USING ERRCODE = '23514';
    END IF;
    qty := nullif(l->>'quantity', '')::numeric;
    IF qty IS NULL OR qty <= 0 THEN RAISE EXCEPTION '%: enter the quantity', prod.canonical_name USING ERRCODE = '23514'; END IF;
    IF qty + 1e-9 < done THEN RAISE EXCEPTION '%: % already delivered — the quantity can''t go below it', prod.canonical_name, trim_scale(done) USING ERRCODE = '23514'; END IF;
    lp := (SELECT x.price FROM public.product_price_ex_vat(s.branch_id, prod.id, col) x);
    pr := coalesce(nullif(l->>'price', '')::numeric, CASE WHEN old.id IS NOT NULL AND old.product_id = prod.id AND old.color_id IS NOT DISTINCT FROM col THEN old.price END, lp);
    IF pr IS NULL THEN RAISE EXCEPTION '% has no price at this branch — give one', prod.canonical_name USING ERRCODE = '23514'; END IF;
    rate := CASE WHEN old.id IS NOT NULL AND old.product_id = prod.id AND old.color_id IS NOT DISTINCT FROM col THEN old.vat_rate
                 ELSE public.product_price_vat_rate(s.branch_id, prod.id, col) END;
    pi := round(pr * (1 + rate / 100), 2);
    tot := round(qty * pi, 2);
    amt := round(tot / (1 + rate / 100), 2);
    IF old.id IS NOT NULL THEN
      UPDATE public.sale_lines SET product_id = prod.id, color_id = col, quantity = qty, unit_id = prod.unit_id,
             list_price = round(coalesce(lp, pr), 4), price = round(pr, 4), vat_rate = rate,
             discount_reason = CASE WHEN lp IS NULL OR round(pr, 2) <> round(lp, 2) THEN coalesce(old.discount_reason, btrim(p_reason)) END,
             discount_by = CASE WHEN lp IS NULL OR round(pr, 2) <> round(lp, 2) THEN coalesce(old.discount_by, auth.uid()) END,
             amount = amt, vat = tot - amt, total = tot
       WHERE id = old.id;
    ELSE
      SELECT coalesce(max(line_no), 0) + 1 INTO n FROM public.sale_lines WHERE sale_id = s.id;
      INSERT INTO public.sale_lines (organization_id, sale_id, line_no, product_id, color_id, quantity, unit_id, list_price, price, vat_rate,
                                     discount_reason, discount_by, amount, vat, total)
      VALUES (s.organization_id, s.id, n, prod.id, col, qty, prod.unit_id, round(coalesce(lp, pr), 4), round(pr, 4), rate,
              CASE WHEN lp IS NULL OR round(pr, 2) <> round(lp, 2) THEN btrim(p_reason) END,
              CASE WHEN lp IS NULL OR round(pr, 2) <> round(lp, 2) THEN auth.uid() END, amt, tot - amt, tot);
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM public.sale_lines WHERE sale_id = s.id) THEN RAISE EXCEPTION 'A sale keeps at least one line' USING ERRCODE = '23514'; END IF;

  -- payments
  FOR pm IN SELECT * FROM jsonb_array_elements(coalesce(ch->'payments', '[]'::jsonb)) LOOP
    SELECT * INTO pay FROM public.sale_payments WHERE id = nullif(pm->>'id', '')::uuid AND sale_id = s.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'A payment is not on this sale' USING ERRCODE = '23514'; END IF;
    IF coalesce((pm->>'remove')::boolean, false) THEN
      PERFORM set_config('mois.sale_correction', 'on', true);
      DELETE FROM public.sale_payments WHERE id = pay.id;
      PERFORM set_config('mois.sale_correction', '', true);
      CONTINUE;
    END IF;
    acc := NULL;
    IF nullif(pm->>'account_id', '') IS NOT NULL THEN
      SELECT * INTO acc FROM public.payment_accounts WHERE id = (pm->>'account_id')::uuid AND branch_id = s.branch_id;
      IF NOT FOUND THEN RAISE EXCEPTION 'Account not found at this branch' USING ERRCODE = '23514'; END IF;
    END IF;
    IF pm ? 'amount' AND coalesce(nullif(pm->>'amount', '')::numeric, 0) <= 0 THEN RAISE EXCEPTION 'A payment is more than zero — remove it instead' USING ERRCODE = '23514'; END IF;
    IF pm ? 'paid_on' AND (pm->>'paid_on')::date > public.org_today(s.organization_id) THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;
    UPDATE public.sale_payments SET
           amount     = CASE WHEN pm ? 'amount' THEN round((pm->>'amount')::numeric, 2) ELSE amount END,
           account_id = CASE WHEN acc.id IS NOT NULL THEN acc.id ELSE account_id END,
           method     = CASE WHEN acc.id IS NOT NULL THEN acc.kind ELSE method END,
           paid_on    = CASE WHEN pm ? 'paid_on' THEN (pm->>'paid_on')::date ELSE paid_on END,
           receipt_no = CASE WHEN pm ? 'receipt_no' THEN nullif(btrim(pm->>'receipt_no'), '') ELSE receipt_no END
     WHERE id = pay.id;
  END LOOP;

  UPDATE public.sales SET subtotal = (SELECT sum(amount) FROM public.sale_lines WHERE sale_id = s.id),
         vat = (SELECT sum(vat) FROM public.sale_lines WHERE sale_id = s.id),
         total = (SELECT sum(total) FROM public.sale_lines WHERE sale_id = s.id)
   WHERE id = s.id;
  SELECT coalesce(sum(amount), 0) INTO paid FROM public.sale_payments WHERE sale_id = s.id;
  IF (SELECT total FROM public.sales WHERE id = s.id) + 0.004 < paid THEN
    RAISE EXCEPTION 'The total would be less than what has been paid (%) — correct or remove a payment too', to_char(paid, 'FM999G999G990D00') USING ERRCODE = '23514';
  END IF;
  INSERT INTO public.sale_corrections (organization_id, sale_id, reason, changes, before, requested_by, applied_by)
  VALUES (s.organization_id, s.id, btrim(p_reason), ch, snap, coalesce(p_requested_by, auth.uid()), auth.uid());
  RETURN jsonb_build_object('sale_id', s.id);
END;
$$;
REVOKE ALL ON FUNCTION public.apply_sale_correction(uuid, jsonb, text, uuid) FROM PUBLIC, anon, authenticated;


-- ------------------------------------------------------------
-- Correct a sale: the Technical admin at once; a branch manager through Approvals
-- → { applied: true } or { request_id }
-- ------------------------------------------------------------
CREATE FUNCTION public.correct_sale(p_sale uuid, p_changes jsonb, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s   public.sales;
  rid uuid;
BEGIN
  SELECT * INTO s FROM public.sales WHERE id = p_sale AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN RAISE EXCEPTION 'Give the reason for the correction' USING ERRCODE = '23514'; END IF;
  IF public.has_permission('system.manage') THEN
    PERFORM public.apply_sale_correction(s.id, p_changes, p_reason, auth.uid());
    RETURN jsonb_build_object('applied', true);
  END IF;
  IF NOT public.has_permission_at('sales.discount', s.branch_id, NULL) THEN
    RAISE EXCEPTION 'Only a branch manager (through Approvals) or the Technical admin corrects a sale' USING ERRCODE = '42501';
  END IF;
  -- checked now as if applied, then undone — mistakes show at once, not at approval
  BEGIN
    PERFORM public.apply_sale_correction(s.id, p_changes, p_reason, auth.uid());
    RAISE EXCEPTION USING ERRCODE = 'P0068', MESSAGE = 'mois:sale-correction-checked';
  EXCEPTION WHEN SQLSTATE 'P0068' THEN NULL;
  END;
  INSERT INTO public.pending_changes (organization_id, branch_id, kind, summary, payload, requested_by)
  VALUES (s.organization_id, s.branch_id, 'sale_correction',
          format('Correct sale #%s: %s', s.sale_no, btrim(p_reason)),
          jsonb_build_object('sale_id', s.id, 'sale_no', s.sale_no, 'changes', p_changes, 'reason', btrim(p_reason)), auth.uid())
  RETURNING id INTO rid;
  RETURN jsonb_build_object('request_id', rid);
END;
$$;
REVOKE ALL ON FUNCTION public.correct_sale(uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_sale(uuid, jsonb, text) TO authenticated;

-- live definition as of 061; + sale_correction (068)
CREATE OR REPLACE FUNCTION public.decide_change(p_id uuid, p_approve boolean, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org     uuid := public.get_my_org_id();
  c       public.pending_changes;
  r       jsonb;
  res     jsonb;
  ids     uuid[];
  who     text;
  pid     uuid;
  cid     uuid;
  msg     text;
  rid     uuid;
BEGIN
  SELECT * INTO c FROM public.pending_changes WHERE id = p_id AND organization_id = org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Request not found' USING ERRCODE = '23514'; END IF;
  IF c.status <> 'pending' THEN RAISE EXCEPTION 'This request was already settled' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission(CASE WHEN c.kind IN ('price', 'color_rule') THEN 'products.manage' ELSE 'inventory.adjust' END) THEN
    RAISE EXCEPTION 'Only an org admin can approve this' USING ERRCODE = '42501';
  END IF;

  IF NOT p_approve THEN
    UPDATE public.pending_changes SET status = 'rejected', decided_by = auth.uid(), decided_at = now(),
           decision_note = nullif(btrim(p_note), '')
    WHERE id = c.id;
    RETURN jsonb_build_object('status', 'rejected');
  END IF;

  who := coalesce((SELECT nullif(btrim(concat_ws(' ', first_name, last_name)), '') FROM public.profiles WHERE id = c.requested_by),
                  (SELECT email FROM public.profiles WHERE id = c.requested_by), 'a branch manager');

  BEGIN   -- applied all or nothing; a failure leaves the request pending
    PERFORM set_config('mois.approved_change', 'on', true);

    IF c.kind = 'price' THEN
      FOR r IN SELECT value FROM jsonb_array_elements(c.payload->'rows') LOOP
        pid := (r->>'product_id')::uuid;
        cid := nullif(r->>'color_id', '')::uuid;
        INSERT INTO public.product_branch_pricing
          (organization_id, product_id, branch_id, color_id, price_per_unit_exclusive, vat_per_unit, price_per_unit_inclusive,
           price_per_sqm_inclusive, pcs_per_sqm_at_pricing, is_available, raw_notes, vat_rate)
        VALUES (org, pid, c.branch_id, cid,
                (r->>'price_per_unit_exclusive')::numeric, (r->>'vat_per_unit')::numeric, (r->>'price_per_unit_inclusive')::numeric,
                (r->>'price_per_sqm_inclusive')::numeric, (r->>'pcs_per_sqm_at_pricing')::numeric,
                coalesce((r->>'is_available')::boolean, true), nullif(r->>'raw_notes', ''), nullif(r->>'vat_rate', '')::numeric)
        ON CONFLICT ON CONSTRAINT product_branch_pricing_unique DO UPDATE SET
          price_per_unit_exclusive = EXCLUDED.price_per_unit_exclusive,
          vat_per_unit             = EXCLUDED.vat_per_unit,
          price_per_unit_inclusive = EXCLUDED.price_per_unit_inclusive,
          price_per_sqm_inclusive  = EXCLUDED.price_per_sqm_inclusive,
          pcs_per_sqm_at_pricing   = EXCLUDED.pcs_per_sqm_at_pricing,
          is_available             = EXCLUDED.is_available,
          raw_notes                = EXCLUDED.raw_notes,
          vat_rate                 = EXCLUDED.vat_rate;
      END LOOP;
      res := jsonb_build_object('price_rows', jsonb_array_length(c.payload->'rows'));

    ELSIF c.kind = 'stock_movement' THEN
      res := jsonb_build_object('movement_id', public.post_inventory_movement(
        c.payload || jsonb_build_object('notes', concat_ws(' — ', nullif(c.payload->>'notes', ''),
                                                    'Requested by ' || who || ', approved by an admin'))));

    ELSIF c.kind = 'stock_reversal' THEN
      res := jsonb_build_object('movement_id', public.reverse_inventory_movement(
        (c.payload->>'movement_id')::uuid, (c.payload->>'reason') || ' (requested by ' || who || ', approved by an admin)'));

    ELSIF c.kind = 'color_rule' THEN
      -- the rule as proposed: base colour, pricing type, and exactly these colour amounts
      INSERT INTO public.category_color_pricing_rules (organization_id, category_id, branch_id, base_color_id, pricing_type)
      VALUES (org, (c.payload->>'category_id')::uuid, c.branch_id, (c.payload->>'base_color_id')::uuid, c.payload->>'pricing_type')
      ON CONFLICT (category_id, branch_id) DO UPDATE SET base_color_id = EXCLUDED.base_color_id, pricing_type = EXCLUDED.pricing_type
      RETURNING id INTO rid;
      DELETE FROM public.category_color_price_items i
      WHERE i.rule_id = rid AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(coalesce(c.payload->'items', '[]'::jsonb)) x
        WHERE (x->>'color_id')::uuid = i.color_id AND (x->>'color_id')::uuid <> (c.payload->>'base_color_id')::uuid);
      INSERT INTO public.category_color_price_items (organization_id, rule_id, color_id, amount)
      SELECT org, rid, (x->>'color_id')::uuid, (x->>'amount')::numeric
      FROM jsonb_array_elements(coalesce(c.payload->'items', '[]'::jsonb)) x
      WHERE (x->>'color_id')::uuid <> (c.payload->>'base_color_id')::uuid
      ON CONFLICT (rule_id, color_id) DO UPDATE SET amount = EXCLUDED.amount;
      res := jsonb_build_object('rule_id', rid);

    ELSIF c.kind = 'production_day' THEN
      res := jsonb_build_object('batch_ids', to_jsonb(public.record_production_batches(jsonb_build_object('batches',
        (SELECT jsonb_agg(b || jsonb_build_object('notes', concat_ws(' — ', nullif(b->>'notes', ''),
                                                  'Requested by ' || who || ', approved by an admin')))
         FROM jsonb_array_elements(c.payload->'batches') b)))));

    ELSIF c.kind = 'sale_correction' THEN   -- 068: a manager's correction of a sale, now approved
      res := public.apply_sale_correction((c.payload->>'sale_id')::uuid, c.payload->'changes', c.payload->>'reason', c.requested_by);
    ELSIF c.kind = 'purchase' THEN
      res := jsonb_build_object('purchase_id', public.record_purchase(
        c.payload || jsonb_build_object('notes', concat_ws(' — ', nullif(c.payload->>'notes', ''),
                                                    'Requested by ' || who || ', approved by an admin'))));

    ELSE   -- stock_import
      ids := public.post_inventory_batch(c.payload->'batch');
      res := jsonb_build_object('movement_ids', to_jsonb(ids));
      IF nullif(c.payload->>'draft_id', '') IS NOT NULL THEN
        UPDATE public.stock_import_drafts SET status = 'posted', posted_movement_ids = ids
        WHERE id = (c.payload->>'draft_id')::uuid AND organization_id = org;
      END IF;
    END IF;

    PERFORM set_config('mois.approved_change', '', true);
  EXCEPTION WHEN OTHERS THEN
    msg := SQLERRM;
    PERFORM set_config('mois.approved_change', '', true);
    UPDATE public.pending_changes SET last_error = msg WHERE id = c.id;
    RETURN jsonb_build_object('status', 'pending', 'error', msg);
  END;

  UPDATE public.pending_changes SET status = 'approved', decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(btrim(p_note), ''), last_error = NULL, result = res
  WHERE id = c.id;
  RETURN jsonb_build_object('status', 'approved', 'result', res);
END;
$$;
