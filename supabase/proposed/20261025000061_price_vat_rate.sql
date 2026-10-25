-- ============================================================
-- 061 — A price's own VAT rate: some products are sold without VAT (1e)
--
-- SwahziTech, 2026-10-25, the user (blocks at Dodoma): "some of them i want
-- to be priced without vat". A price per m² kept no VAT figures of its own
-- (only a price per piece did), so "sold without VAT" could not be stored.
-- product_branch_pricing.vat_rate: the VAT rate of this price (0 = sold
-- without VAT; NULL = the branch's rate). Filled for existing rows from their
-- own piece figures where they have them. The price without VAT (058) uses
-- it; prices sent for approval keep it.
-- ============================================================

ALTER TABLE public.product_branch_pricing ADD COLUMN vat_rate numeric CHECK (vat_rate >= 0 AND vat_rate < 100);
COMMENT ON COLUMN public.product_branch_pricing.vat_rate IS 'VAT rate (%) of this price; 0 = sold without VAT; NULL = the branch''s rate (061).';
UPDATE public.product_branch_pricing SET vat_rate = round((price_per_unit_inclusive / price_per_unit_exclusive - 1) * 100, 2)
 WHERE price_per_unit_exclusive > 0 AND price_per_unit_inclusive IS NOT NULL;

-- live definition as of 044; a price row also takes its VAT rate (061)
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

CREATE OR REPLACE FUNCTION public.product_price_ex_vat(p_branch_id uuid, p_product_id uuid, p_color_id uuid, OUT price numeric, OUT source text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p     public.products;
  prow  public.product_branch_pricing;
  rule  public.category_color_pricing_rules;
  amt   numeric;
  vat   numeric;
  sqm   boolean;
  incl  numeric;
BEGIN
  SELECT * INTO p FROM public.products WHERE id = p_product_id AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RETURN; END IF;
  SELECT upper(u.symbol) = 'SQM' INTO sqm FROM public.units u WHERE u.id = p.unit_id;
  SELECT coalesce(vat_rate, 0) INTO vat FROM public.branches WHERE id = p_branch_id;

  SELECT * INTO prow FROM public.product_branch_pricing x WHERE x.product_id = p_product_id AND x.branch_id = p_branch_id
     AND x.color_id IS NOT DISTINCT FROM p_color_id AND x.is_available;
  IF FOUND THEN source := 'price list';
  ELSE
    SELECT * INTO prow FROM public.product_branch_pricing x WHERE x.product_id = p_product_id AND x.branch_id = p_branch_id AND x.color_id IS NULL AND x.is_available;
    IF NOT FOUND THEN RETURN; END IF;
    source := 'price list';
    IF p_color_id IS NOT NULL THEN
      SELECT * INTO rule FROM public.category_color_pricing_rules cr WHERE cr.branch_id = p_branch_id
         AND cr.category_id IN (p.category_id, (SELECT parent_category_id FROM public.product_categories WHERE id = p.category_id))
       ORDER BY (cr.category_id = p.category_id) DESC LIMIT 1;
      IF FOUND AND rule.base_color_id IS DISTINCT FROM p_color_id THEN
        SELECT amount INTO amt FROM public.category_color_price_items WHERE rule_id = rule.id AND color_id = p_color_id;
        IF amt IS NULL THEN price := NULL; source := 'no price for this colour'; RETURN; END IF;
        vat := coalesce(prow.vat_rate, vat);   -- 061: the price's own rate (0 = sold without VAT)
        incl := CASE WHEN rule.pricing_type = 'absolute_price_per_sqmt' THEN amt ELSE prow.price_per_sqm_inclusive + amt END;
        IF incl IS NULL THEN source := 'no price for this colour'; RETURN; END IF;
        price := CASE WHEN sqm THEN incl ELSE incl / nullif(prow.pcs_per_sqm_at_pricing, 0) END / (1 + vat / 100);
        source := 'colour rule';
        RETURN;
      END IF;
    END IF;
  END IF;
  vat := coalesce(prow.vat_rate, vat);   -- 061
  IF sqm THEN
    price := coalesce(prow.price_per_sqm_inclusive / (1 + vat / 100),
                      prow.price_per_unit_exclusive * nullif(prow.pcs_per_sqm_at_pricing, 0));
  ELSE
    price := coalesce(prow.price_per_unit_exclusive, prow.price_per_unit_inclusive / (1 + vat / 100));
  END IF;
END;
$$;
