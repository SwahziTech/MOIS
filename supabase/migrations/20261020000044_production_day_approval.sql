-- ============================================================
-- 044 — A day's production dated earlier goes through Approvals (1d)
--
-- Back-dated stock entries need an org admin (033); purchases and stock
-- movements already offer "Submit for approval". Production had no such
-- route, so a branch manager logging yesterday's batches was simply
-- refused (seen 2026-10-20). Now the day's batches are sent as one
-- request (kind 'production_day'), checked at once, and recorded exactly
-- as sent when an admin approves (inventory.adjust org-wide, like other
-- stock corrections).
-- ============================================================

ALTER TABLE public.pending_changes DROP CONSTRAINT pending_changes_kind_check;
ALTER TABLE public.pending_changes ADD CONSTRAINT pending_changes_kind_check
  CHECK (kind IN ('price', 'color_rule', 'stock_movement', 'stock_reversal', 'stock_import', 'purchase', 'production_day'));

-- request_change(): as in 039, plus kind 'production_day' — payload { batches: [record_production_batch payloads] }
CREATE OR REPLACE FUNCTION public.request_change(p_kind text, p_branch_id uuid, p_payload jsonb, p_summary text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org    uuid := public.get_my_org_id();
  br     uuid;
  wh     uuid;
  new_id uuid;
BEGIN
  IF org IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not signed in to an organization' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_summary), '') IS NULL THEN
    RAISE EXCEPTION 'Describe the change' USING ERRCODE = '23514';
  END IF;

  IF p_kind = 'price' THEN
    br := p_branch_id;
    IF jsonb_typeof(p_payload->'rows') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'rows') = 0 THEN
      RAISE EXCEPTION 'No price to change' USING ERRCODE = '23514';
    END IF;
    IF NOT public.has_permission_at('products.manage', br, NULL) THEN
      RAISE EXCEPTION 'You can''t change prices at this branch' USING ERRCODE = '42501';
    END IF;
  ELSIF p_kind = 'color_rule' THEN
    -- a category's colour pricing at one branch, proposed by that branch (039)
    br := p_branch_id;
    IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = br AND organization_id = org) THEN
      RAISE EXCEPTION 'Branch not found' USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.product_category_colors pcc JOIN public.product_categories c ON c.id = pcc.category_id
                   WHERE pcc.category_id = nullif(p_payload->>'category_id', '')::uuid AND c.organization_id = org) THEN
      RAISE EXCEPTION 'Choose a category that has colours' USING ERRCODE = '23514';
    END IF;
    IF coalesce(p_payload->>'pricing_type', '') NOT IN ('delta_over_base_color', 'absolute_price_per_sqmt')
       OR nullif(p_payload->>'base_color_id', '') IS NULL THEN
      RAISE EXCEPTION 'Choose the base colour and how other colours are priced' USING ERRCODE = '23514';
    END IF;
    IF NOT public.has_permission_at('products.manage', br, NULL) THEN
      RAISE EXCEPTION 'You can''t change colour pricing at this branch' USING ERRCODE = '42501';
    END IF;
  ELSIF p_kind = 'production_day' THEN
    -- a day's batches dated earlier (044): the branch's recorder sends them; nothing is
    -- recorded until an admin approves. Checked now, as if approved, then undone, so
    -- mistakes (short stock, no recipe…) show at once instead of at approval
    SELECT w.branch_id INTO br FROM public.warehouses w
    WHERE w.id = nullif(p_payload->'batches'->0->>'raw_warehouse_id', '')::uuid AND w.organization_id = org;
    IF br IS NULL THEN RAISE EXCEPTION 'Store not found' USING ERRCODE = '23514'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload->'batches') b
               JOIN public.warehouses w ON w.id = nullif(b->>'raw_warehouse_id', '')::uuid
               WHERE w.branch_id <> br) THEN
      RAISE EXCEPTION 'All batches of a day belong to one branch' USING ERRCODE = '23514';
    END IF;
    IF NOT public.has_permission_at('production.create', br, NULL) THEN
      RAISE EXCEPTION 'You can''t record production at this branch' USING ERRCODE = '42501';
    END IF;
    BEGIN
      PERFORM set_config('mois.approved_change', 'on', true);
      PERFORM public.record_production_batches(p_payload);
      RAISE EXCEPTION USING ERRCODE = 'P0042', MESSAGE = 'mois:production-day-checked';
    EXCEPTION WHEN SQLSTATE 'P0042' THEN
      PERFORM set_config('mois.approved_change', '', true);
    END;
  ELSIF p_kind = 'purchase' THEN
    -- goods + purchase in one, dated earlier: whoever may record purchases
    -- AND correct stock at that store (an earlier date is a correction)
    wh := nullif(p_payload->'receipt'->>'warehouse_id', '')::uuid;
    SELECT branch_id INTO br FROM public.warehouses WHERE id = wh AND organization_id = org;
    IF br IS NULL THEN RAISE EXCEPTION 'Store not found' USING ERRCODE = '23514'; END IF;
    IF coalesce(p_payload->'receipt'->>'type', '') <> 'receipt' THEN
      RAISE EXCEPTION 'A purchase records a receipt' USING ERRCODE = '23514';
    END IF;
    IF NOT public.has_permission_at('procurement.receive', br, wh) THEN
      RAISE EXCEPTION 'You can''t record purchases at this store' USING ERRCODE = '42501';
    END IF;
    IF NOT public.has_permission_at('inventory.adjust', br, wh) THEN
      RAISE EXCEPTION 'Earlier dates need stock-adjustment permission at this store — ask the branch manager' USING ERRCODE = '42501';
    END IF;
  ELSIF p_kind IN ('stock_movement', 'stock_reversal', 'stock_import') THEN
    -- the store decides the branch; never trust the caller's branch
    wh := CASE p_kind
            WHEN 'stock_movement' THEN nullif(p_payload->>'warehouse_id', '')::uuid
            WHEN 'stock_reversal' THEN (SELECT warehouse_id FROM public.inventory_movements
                                        WHERE id = nullif(p_payload->>'movement_id', '')::uuid AND organization_id = org)
            ELSE nullif(p_payload->'batch'->'movements'->0->>'warehouse_id', '')::uuid END;
    SELECT branch_id INTO br FROM public.warehouses WHERE id = wh AND organization_id = org;
    IF br IS NULL THEN RAISE EXCEPTION 'Store not found' USING ERRCODE = '23514'; END IF;
    IF p_kind = 'stock_import' AND EXISTS (
         SELECT 1 FROM jsonb_array_elements(p_payload->'batch'->'movements') m
         WHERE (SELECT branch_id FROM public.warehouses WHERE id = nullif(m->>'warehouse_id', '')::uuid) IS DISTINCT FROM br) THEN
      RAISE EXCEPTION 'One import goes to one branch' USING ERRCODE = '23514';
    END IF;
    IF p_kind = 'stock_movement' AND p_payload->>'type' = 'count' THEN
      IF NOT public.has_permission_at('inventory.count', br, wh) THEN
        RAISE EXCEPTION 'You can''t count stock at this store' USING ERRCODE = '42501';
      END IF;
    ELSIF NOT public.has_permission_at('inventory.adjust', br, wh) THEN
      RAISE EXCEPTION 'You can''t correct stock at this store' USING ERRCODE = '42501';
    END IF;
  ELSE
    RAISE EXCEPTION 'Unknown kind of change' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.pending_changes (organization_id, branch_id, kind, summary, payload, requested_by)
  VALUES (org, br, p_kind, btrim(p_summary), p_payload, auth.uid())
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- decide_change(): as in 039, plus kind 'production_day'
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
           price_per_sqm_inclusive, pcs_per_sqm_at_pricing, is_available, raw_notes)
        VALUES (org, pid, c.branch_id, cid,
                (r->>'price_per_unit_exclusive')::numeric, (r->>'vat_per_unit')::numeric, (r->>'price_per_unit_inclusive')::numeric,
                (r->>'price_per_sqm_inclusive')::numeric, (r->>'pcs_per_sqm_at_pricing')::numeric,
                coalesce((r->>'is_available')::boolean, true), nullif(r->>'raw_notes', ''))
        ON CONFLICT ON CONSTRAINT product_branch_pricing_unique DO UPDATE SET
          price_per_unit_exclusive = EXCLUDED.price_per_unit_exclusive,
          vat_per_unit             = EXCLUDED.vat_per_unit,
          price_per_unit_inclusive = EXCLUDED.price_per_unit_inclusive,
          price_per_sqm_inclusive  = EXCLUDED.price_per_sqm_inclusive,
          pcs_per_sqm_at_pricing   = EXCLUDED.pcs_per_sqm_at_pricing,
          is_available             = EXCLUDED.is_available,
          raw_notes                = EXCLUDED.raw_notes;
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
