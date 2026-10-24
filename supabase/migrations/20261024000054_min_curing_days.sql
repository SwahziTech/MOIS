-- ============================================================
-- 054 — Minimum curing period (1d)
--
-- SwahziTech, 2026-10-24: a batch cures 7 days at least, 14 normally.
-- organizations.min_curing_days: release is refused before it; from it on a
-- batch can be released without a reason (curing_days stays the normal
-- period, shown as "curing until"). NULL = no minimum (as before: an early
-- release needs a reason). Only release_production_batch changes (live
-- definition as of 053).
-- ============================================================

ALTER TABLE public.organizations ADD COLUMN min_curing_days int CHECK (min_curing_days IS NULL OR min_curing_days >= 0);
COMMENT ON COLUMN public.organizations.min_curing_days IS 'Fewest days a batch cures before its quality release (054); NULL = no minimum.';

CREATE OR REPLACE FUNCTION public.release_production_batch(p_batch uuid, p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  mindays int;            -- the organization's minimum curing days (054)
  org     uuid := public.get_my_org_id();
  b       public.production_batches;
  cur     public.warehouses;
  fg      public.warehouses;
  rdate   date;
  x       record;
  e       jsonb;
  r       jsonb;
  passed  int;
  rejected int;
  mv      uuid;
BEGIN
  SELECT * INTO b FROM public.production_batches WHERE id = p_batch AND organization_id = org FOR UPDATE;
  IF NOT FOUND OR b.status <> 'curing' THEN RAISE EXCEPTION 'Batch not found or not curing' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('production.complete', b.branch_id, NULL) THEN
    RAISE EXCEPTION 'You can''t release production at this branch' USING ERRCODE = '42501';
  END IF;
  rdate := coalesce(nullif(p->>'release_date', '')::date, public.org_today(org));
  IF rdate < b.batch_date OR rdate > public.org_today(org) THEN RAISE EXCEPTION 'Release date must be between the batch date and today' USING ERRCODE = '23514'; END IF;
  -- 054: with a minimum curing period, release is refused before it and needs no reason after it;
  -- without one, an early release (before curing_until) still needs a reason
  mindays := (SELECT min_curing_days FROM public.organizations WHERE id = org);
  IF mindays IS NOT NULL AND rdate < b.batch_date + mindays THEN
    RAISE EXCEPTION 'A batch cures at least % days — this one can be released from %', mindays, b.batch_date + mindays USING ERRCODE = '23514';
  END IF;
  IF mindays IS NULL AND rdate < b.curing_until AND nullif(btrim(p->>'note'), '') IS NULL THEN
    RAISE EXCEPTION 'Curing runs until % — say why it is released early', b.curing_until USING ERRCODE = '23514';
  END IF;
  SELECT * INTO fg FROM public.warehouses WHERE id = nullif(p->>'fg_warehouse_id', '')::uuid AND organization_id = org AND status = 'active';
  IF NOT FOUND OR fg.type <> 'finished_goods' OR fg.branch_id <> b.branch_id THEN
    RAISE EXCEPTION 'Choose the branch''s finished-goods store' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO cur FROM public.warehouses WHERE id = b.curing_warehouse_id;

  INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, notes, created_by, production_batch_id)
  VALUES (org, 'curing_release', b.branch_id, cur.id, rdate, 'Quality release', nullif(btrim(p->>'note'), ''), auth.uid(), b.id)
  RETURNING id INTO mv;

  FOR x IN SELECT o.*, pr.unit_id, pr.canonical_name || coalesce(' ' || cp.name, '') AS name
           FROM public.production_batch_outputs o JOIN public.products pr ON pr.id = o.product_id
           LEFT JOIN public.color_palette cp ON cp.id = o.color_id
           WHERE o.batch_id = b.id ORDER BY o.is_primary DESC, pr.canonical_name LOOP
    SELECT y INTO e FROM jsonb_array_elements(coalesce(p->'outputs', '[]'::jsonb)) y WHERE y->>'output_id' = x.id::text;
    IF e IS NULL THEN RAISE EXCEPTION '%: enter its passed and rejected pieces', x.name USING ERRCODE = '23514'; END IF;
    passed := nullif(e->>'pieces_passed', '')::int;
    IF passed IS NULL OR passed < 0 THEN RAISE EXCEPTION '%: enter the pieces that passed', x.name USING ERRCODE = '23514'; END IF;
    rejected := 0;
    FOR r IN SELECT * FROM jsonb_array_elements(coalesce(e->'rejects', '[]'::jsonb)) LOOP
      IF NOT EXISTS (SELECT 1 FROM public.reject_reasons WHERE id = nullif(r->>'reason_id', '')::uuid AND organization_id = org) THEN
        RAISE EXCEPTION 'Choose a reject reason from the list' USING ERRCODE = '23514';
      END IF;
      IF nullif(r->>'pieces', '')::int IS NULL OR (r->>'pieces')::int <= 0 THEN RAISE EXCEPTION 'Rejected pieces must be above zero' USING ERRCODE = '23514'; END IF;
      INSERT INTO public.production_batch_rejects (organization_id, batch_id, output_id, reason_id, pieces)
      VALUES (org, b.id, x.id, (r->>'reason_id')::uuid, (r->>'pieces')::int);
      rejected := rejected + (r->>'pieces')::int;
    END LOOP;
    IF passed + rejected <> x.pieces_cast THEN
      RAISE EXCEPTION '%: passed (%) and rejected (%) must add up to the % pieces cast', x.name, passed, rejected, x.pieces_cast USING ERRCODE = '23514';
    END IF;
    UPDATE public.production_batch_outputs SET pieces_passed = passed WHERE id = x.id;
    IF x.pieces_cast > 0 THEN
      PERFORM public.production_ledger_line(mv, 'curing_out', cur, NULL, x.product_id, x.color_id,
        -public.production_stock_qty(x.product_id, x.pieces_cast), x.unit_id, public.production_stock_qty(x.product_id, x.pieces_cast), x.unit_id, rdate, x.name);
    END IF;
    IF passed > 0 THEN
      PERFORM public.production_ledger_line(mv, 'curing_in', fg, NULL, x.product_id, x.color_id,
        public.production_stock_qty(x.product_id, passed), x.unit_id, public.production_stock_qty(x.product_id, passed), x.unit_id, rdate, x.name);
    END IF;
  END LOOP;

  UPDATE public.production_batches SET status = 'released', released_on = rdate, fg_warehouse_id = fg.id,
         release_movement_id = mv, release_note = nullif(btrim(p->>'note'), '')
  WHERE id = b.id;
  RETURN mv;
END;
$function$;
