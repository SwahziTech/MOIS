-- One-off (run once; never re-run). SwahziTech, 2026-10-22:
-- Rangi Black's opening stock at Dodoma — Raw Materials Store was 4 bags
-- (100 kg), entered as 3 bags (75 kg). Adds the missing bag with an
-- adjustment dated 30 Sep (the opening date), then approves the waiting
-- production of 8 Oct, which was refused because Rangi Black would have
-- dropped to −9.5 kg on 10 Oct.
-- Runs as the Technical admin (MOIS Admin) so both are audited as theirs.
DO $$
DECLARE
  rangi  uuid;
  bag    uuid;
  wh     uuid;
  req    uuid;
  res    jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"ae48a74f-aaf7-4a56-b6bb-76150a6261e6","role":"authenticated"}', true);
  SELECT id INTO rangi FROM public.materials WHERE organization_id = public.get_my_org_id() AND name = 'Rangi Black';
  SELECT u.id INTO bag FROM public.material_unit_conversions c JOIN public.units u ON u.id = c.unit_id WHERE c.material_id = rangi AND u.symbol = '25kg bag';
  SELECT w.id INTO wh FROM public.warehouses w JOIN public.branches b ON b.id = w.branch_id
   WHERE b.name = 'Dodoma' AND w.type = 'raw_materials' AND w.status = 'active' AND w.organization_id = public.get_my_org_id();
  IF rangi IS NULL OR bag IS NULL OR wh IS NULL THEN RAISE EXCEPTION 'Not found: Rangi Black %, bag unit %, store %', rangi, bag, wh; END IF;
  IF EXISTS (SELECT 1 FROM public.inventory_movements WHERE warehouse_id = wh AND movement_type = 'adjustment' AND reason LIKE 'Rangi Black opening stock was 4 bags%') THEN
    RAISE EXCEPTION 'Already corrected — this one-off has run before';
  END IF;

  PERFORM public.post_inventory_movement(jsonb_build_object(
    'type', 'adjustment', 'warehouse_id', wh, 'movement_date', '2026-09-30',
    'reason', 'Rangi Black opening stock was 4 bags (100 kg), entered as 3 bags — SwahziTech 2026-10-22',
    'lines', jsonb_build_array(jsonb_build_object('material_id', rangi, 'quantity', 1, 'unit_id', bag))));

  SELECT id INTO req FROM public.pending_changes
   WHERE status = 'pending' AND kind = 'production_day' AND organization_id = public.get_my_org_id()
     AND payload->'batches'->0->>'batch_date' = '2026-10-08';
  IF req IS NULL THEN RAISE NOTICE 'No waiting 8 Oct request — nothing to approve'; RETURN; END IF;
  res := public.decide_change(req, true, 'Rangi Black opening stock corrected to 4 bags first');
  RAISE NOTICE 'Approval: %', res;
END $$;
