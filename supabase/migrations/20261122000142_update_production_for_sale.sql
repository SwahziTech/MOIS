-- ============================================================
-- 142 — A customer order changed: its production order follows
--
-- SwahziTech, 2026-11-22 (the user): after an order's quantities, products or
-- date change, the sale offers to update the production order made for it
-- (more or fewer pieces, a product added — merged into it — or a new date)
-- instead of leaving the Planner out of step. The Planner's own writer
-- (save_production_order) does the change, so its rules hold: a line with
-- batches already counted stays; pieces are whole numbers. A product added
-- here is linked to its sale line.
--
-- update_production_for_sale(p_sale, p): p = { order_id, due_date?, lines: [{ sale_line_id, pieces }] }
--   lines named here are set to those pieces (added when new); the order's other lines stay as they are.
-- ============================================================

CREATE FUNCTION public.update_production_for_sale(p_sale uuid, p jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  s     public.sales;
  po    public.production_orders;
  l     jsonb;
  sl    public.sale_lines;
  pl    record;
  want  jsonb := '{}'::jsonb;   -- sale line id → pieces
  lines jsonb := '[]'::jsonb;
  k     text;
  lk    text;   -- the sale line a production line belongs to
BEGIN
  SELECT * INTO s FROM public.sales WHERE id = p_sale AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE = '23514'; END IF;
  SELECT * INTO po FROM public.production_orders WHERE id = nullif(p->>'order_id', '')::uuid AND sale_id = s.id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That production order isn''t this sale''s' USING ERRCODE = '23514'; END IF;

  FOR l IN SELECT * FROM jsonb_array_elements(coalesce(p->'lines', '[]'::jsonb)) LOOP
    SELECT * INTO sl FROM public.sale_lines WHERE id = nullif(l->>'sale_line_id', '')::uuid AND sale_id = s.id;
    IF NOT FOUND OR sl.product_id IS NULL THEN RAISE EXCEPTION 'A line is not a product of this sale' USING ERRCODE = '23514'; END IF;
    want := want || jsonb_build_object(sl.id::text, coalesce(nullif(l->>'pieces', '')::int, 0));
  END LOOP;

  -- the order's lines as they are, those named here with their new pieces
  -- (an edited sale gets new lines: a production line whose sale line is gone belongs to the line with its product and colour)
  FOR pl IN SELECT x.* FROM public.production_order_lines x WHERE x.order_id = po.id ORDER BY x.display_order LOOP
    lk := coalesce((SELECT y.id FROM public.sale_lines y WHERE y.id = pl.sale_line_id AND y.sale_id = s.id),
                   (SELECT y.id FROM public.sale_lines y WHERE y.sale_id = s.id AND y.product_id = pl.product_id AND y.color_id IS NOT DISTINCT FROM pl.color_id ORDER BY y.line_no LIMIT 1))::text;
    IF lk IS NOT NULL AND lk::uuid IS DISTINCT FROM pl.sale_line_id THEN UPDATE public.production_order_lines SET sale_line_id = lk::uuid WHERE id = pl.id; END IF;
    IF lk IS NOT NULL AND want ? lk THEN
      CONTINUE WHEN (want ->> lk)::int <= 0
        AND NOT EXISTS (SELECT 1 FROM public.production_batch_outputs o WHERE o.order_line_id = pl.id);
      lines := lines || jsonb_build_object('product_id', pl.product_id, 'color_id', pl.color_id,
                 'pieces', greatest((want ->> lk)::int, 1), 'sqm', NULL);
      want := want - lk;
    ELSE
      lines := lines || jsonb_build_object('product_id', pl.product_id, 'color_id', pl.color_id, 'pieces', pl.pieces, 'sqm', pl.sqm);
    END IF;
  END LOOP;
  -- sale lines not yet in it: added (merged into this production order)
  FOR k IN SELECT jsonb_object_keys(want) LOOP
    CONTINUE WHEN (want ->> k)::int <= 0;
    SELECT * INTO sl FROM public.sale_lines WHERE id = k::uuid;
    lines := lines || jsonb_build_object('product_id', sl.product_id, 'color_id', sl.color_id, 'pieces', (want ->> k)::int, 'sqm', NULL, 'sale_line_id', sl.id);
  END LOOP;
  IF jsonb_array_length(lines) = 0 THEN RAISE EXCEPTION 'Nothing would be left to make — cancel the production order in the Planner instead' USING ERRCODE = '23514'; END IF;

  PERFORM public.save_production_order(jsonb_build_object('id', po.id, 'reference', po.reference,
    'due_date', coalesce(nullif(p->>'due_date', ''), po.due_date::text), 'notes', po.notes, 'lines', lines));
  -- the added lines point to their sale line
  UPDATE public.production_order_lines x SET sale_line_id = (y->>'sale_line_id')::uuid
    FROM jsonb_array_elements(lines) y
   WHERE x.order_id = po.id AND x.sale_line_id IS NULL AND y ? 'sale_line_id'
     AND x.product_id = (y->>'product_id')::uuid AND x.color_id IS NOT DISTINCT FROM nullif(y->>'color_id', '')::uuid;
  RETURN po.id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.update_production_for_sale(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_production_for_sale(uuid, jsonb) TO authenticated;
