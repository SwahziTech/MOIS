-- ============================================================
-- 033 — Approval queue for prices and corrective stock entries (1b)
--
-- Decided with SwahziTech (2026-10-16): a branch manager's PRICE change
-- or CORRECTIVE STOCK entry is submitted, and takes effect only when an
-- org admin approves it. Everything else a branch does stays free:
-- catalogue, recipes, materials (031/032), and routine stock — receive,
-- issue, transfer, and counts (a count's difference posts at once).
--
-- Corrective = an adjustment, an opening balance, a reversal, or any entry
-- dated before today (backdated). Admin = an org-wide grant of the
-- matching permission (prices: products.manage; stock: inventory.adjust);
-- admins post directly, as before.
--
-- The requested change is kept exactly as submitted (payload) and applied
-- by the same functions the app uses, at approval time, as the approving
-- admin — so every existing check still runs then. If it no longer fits
-- (e.g. the stock has since moved), it stays pending with the reason and
-- the admin rejects it or the requester withdraws it.
-- ============================================================

CREATE TABLE public.pending_changes (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  kind            text NOT NULL CHECK (kind IN ('price', 'stock_movement', 'stock_reversal', 'stock_import')),
  summary         text NOT NULL CHECK (btrim(summary) <> ''),   -- plain words, shown in the queue
  payload         jsonb NOT NULL,
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'withdrawn')),
  requested_by    uuid NOT NULL REFERENCES auth.users(id),
  requested_at    timestamptz NOT NULL DEFAULT now(),
  decided_by      uuid REFERENCES auth.users(id),
  decided_at      timestamptz,
  decision_note   text,
  last_error      text,          -- why the last approval attempt couldn't be applied
  result          jsonb,         -- what approval created (movement ids, price rows)
  CHECK ((status = 'pending') = (decided_at IS NULL))
);

CREATE INDEX idx_pending_changes_org_status ON public.pending_changes (organization_id, status);
CREATE TRIGGER trg_pending_changes_branch_org BEFORE INSERT OR UPDATE ON public.pending_changes
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('branches', 'branch_id');
CREATE TRIGGER trg_pending_changes_audit AFTER INSERT OR UPDATE OR DELETE ON public.pending_changes
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('pending_change', 'id');
CREATE TRIGGER trg_pending_changes_no_delete BEFORE DELETE ON public.pending_changes
  FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('pending_change');

-- Readable across the organization (who asked for what is not secret);
-- written only through the functions below
ALTER TABLE public.pending_changes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pending_changes: read own org" ON public.pending_changes FOR SELECT
  USING (organization_id = public.get_my_org_id());

COMMENT ON TABLE public.pending_changes
  IS 'Branch managers'' price changes and corrective stock entries awaiting an org admin. Applied on approval by the normal functions; never deleted.';


-- ------------------------------------------------------------
-- 1. Corrective stock entries need an admin — or an approval
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_corrective_movement_approved()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL                                            -- server-side scripts
     OR NEW.movement_type = 'reclassification'                     -- product admins only (028)
     OR NOT (NEW.movement_type IN ('adjustment', 'opening_balance', 'reversal')
             OR NEW.movement_date < public.org_today(NEW.organization_id))
     OR public.has_permission('inventory.adjust')                  -- org-wide admin
     OR coalesce(current_setting('mois.approved_change', true), '') = 'on' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Corrections and backdated entries need an admin''s approval — submit this for approval instead'
    USING ERRCODE = '42501';
END;
$$;

CREATE TRIGGER trg_movements_corrective_approval BEFORE INSERT ON public.inventory_movements
  FOR EACH ROW EXECUTE FUNCTION public.check_corrective_movement_approved();


-- ------------------------------------------------------------
-- 2. Submit
-- ------------------------------------------------------------
-- p_kind / p_payload:
--   price           { rows: [{ product_id, color_id?, <price fields> }] } — all at p_branch_id
--   stock_movement  a post_inventory_movement() payload
--   stock_reversal  { movement_id, reason }
--   stock_import    { batch: <post_inventory_batch() payload>, draft_id? }
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
    IF NOT public.has_permission_at('inventory.adjust', br, wh) THEN
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


-- ------------------------------------------------------------
-- 3. Decide (admins) / withdraw (the requester)
-- ------------------------------------------------------------
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
BEGIN
  SELECT * INTO c FROM public.pending_changes WHERE id = p_id AND organization_id = org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Request not found' USING ERRCODE = '23514'; END IF;
  IF c.status <> 'pending' THEN RAISE EXCEPTION 'This request was already settled' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission(CASE c.kind WHEN 'price' THEN 'products.manage' ELSE 'inventory.adjust' END) THEN
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

CREATE OR REPLACE FUNCTION public.withdraw_change(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.pending_changes SET status = 'withdrawn', decided_by = auth.uid(), decided_at = now()
  WHERE id = p_id AND organization_id = public.get_my_org_id() AND requested_by = auth.uid() AND status = 'pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'Only your own pending requests can be withdrawn' USING ERRCODE = '23514'; END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.request_change(text, uuid, jsonb, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.decide_change(uuid, boolean, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.withdraw_change(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_change(text, uuid, jsonb, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decide_change(uuid, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.withdraw_change(uuid) TO authenticated;
