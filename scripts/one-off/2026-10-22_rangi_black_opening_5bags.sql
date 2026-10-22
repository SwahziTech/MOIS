-- One-off (run once; never re-run). SwahziTech, 2026-10-22 (second correction):
-- Rangi Black's opening stock at Dodoma — Raw Materials Store was 5 bags
-- (125 kg), not 4 (the first correction, same day, took it from 3 to 4).
-- Adds the fifth bag with an adjustment dated 30 Sep, then approves the
-- waiting production days in date order (14, 15, 16 Oct). Checked beforehand:
-- with this bag every material of those days stays above zero.
-- Runs as the Technical admin (MOIS Admin) so all of it is audited as theirs.
DO $$
DECLARE
  rangi  uuid;
  bag    uuid;
  wh     uuid;
  r      record;
  res    jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"ae48a74f-aaf7-4a56-b6bb-76150a6261e6","role":"authenticated"}', true);
  SELECT id INTO rangi FROM public.materials WHERE organization_id = public.get_my_org_id() AND name = 'Rangi Black';
  SELECT u.id INTO bag FROM public.material_unit_conversions c JOIN public.units u ON u.id = c.unit_id WHERE c.material_id = rangi AND u.symbol = '25kg bag';
  SELECT w.id INTO wh FROM public.warehouses w JOIN public.branches b ON b.id = w.branch_id
   WHERE b.name = 'Dodoma' AND w.type = 'raw_materials' AND w.status = 'active' AND w.organization_id = public.get_my_org_id();
  IF rangi IS NULL OR bag IS NULL OR wh IS NULL THEN RAISE EXCEPTION 'Not found: Rangi Black %, bag unit %, store %', rangi, bag, wh; END IF;
  IF EXISTS (SELECT 1 FROM public.inventory_movements WHERE warehouse_id = wh AND movement_type = 'adjustment' AND reason LIKE 'Rangi Black opening stock was 5 bags%') THEN
    RAISE EXCEPTION 'Already corrected — this one-off has run before';
  END IF;

  PERFORM public.post_inventory_movement(jsonb_build_object(
    'type', 'adjustment', 'warehouse_id', wh, 'movement_date', '2026-09-30',
    'reason', 'Rangi Black opening stock was 5 bags (125 kg), not 4 — SwahziTech 2026-10-22 (second correction)',
    'lines', jsonb_build_array(jsonb_build_object('material_id', rangi, 'quantity', 1, 'unit_id', bag))));

  FOR r IN SELECT id, summary FROM public.pending_changes
            WHERE status = 'pending' AND kind = 'production_day' AND organization_id = public.get_my_org_id()
            ORDER BY payload->'batches'->0->>'batch_date', requested_at LOOP
    res := public.decide_change(r.id, true, 'Rangi Black opening stock corrected to 5 bags first');
    IF res->>'status' <> 'approved' THEN
      RAISE EXCEPTION 'Could not approve "%": %', r.summary, res->>'error';
    END IF;
    RAISE NOTICE 'Approved: %', r.summary;
  END LOOP;
END $$;
