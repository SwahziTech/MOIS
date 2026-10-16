-- One-off (PROPOSED — run once, after migration 031, never again):
-- Stumarcot data given by SwahziTech in chat on 2026-10-16.
--   * Yield per bag is an average with a ±5 pieces tolerance (QC band).
--   * "40 Mayai 2"" and "40 Dot 2"" are 40x40 cm and 2 inches thick: their
--     size says so, so they don't share the 1-inch 40x40 tiles' yield.
--   * "30 Draft" and "Draft 9" are two distinct products (both 30x30).
DO $$
DECLARE
  org   uuid;
  owner uuid;
  n     int;
BEGIN
  SELECT id INTO STRICT org FROM organizations WHERE legal_name = 'STUMARCOT CO LTD';
  SELECT ur.user_id INTO STRICT owner FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
  WHERE ur.organization_id = org AND ro.name = 'owner' AND ur.branch_id IS NULL LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', owner, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  UPDATE organizations SET yield_tolerance = 5 WHERE id = org;

  UPDATE products SET size_cm = '40x40x2in'
  WHERE organization_id = org AND canonical_name IN ('40 Mayai 2"', '40 Dot 2"') AND size_cm = '40x40';
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 2 THEN RAISE EXCEPTION '2-inch tiles: %', n; END IF;

  PERFORM resolve_product_identity((SELECT id FROM products WHERE organization_id = org AND canonical_name = '30 Draft' AND status = 'active'),
    jsonb_build_object('choice', 'keep',
                       'not_products', jsonb_build_array((SELECT id FROM products WHERE organization_id = org AND canonical_name = 'Draft 9')),
                       'note', 'both 30x30 cm but different products — SwahziTech in chat, 2026-10-16'));

  EXECUTE 'RESET ROLE';
END $$;
