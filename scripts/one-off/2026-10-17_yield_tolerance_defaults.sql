-- One-off (run once, after migration 037): Stumarcot's default yield
-- tolerance per category, as decided by SwahziTech in chat (2026-10-17):
-- ±5 pieces per bag for paving and tiles, exact (±0) for everything else.
-- Products can override this in their edit window.
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

  UPDATE product_categories SET default_yield_tolerance =
    CASE WHEN category_id_ref IN ('paving_blocks_vibro', 'press_machine_paving', 'floor_tiles', 'wall_tiles') THEN 5 ELSE 0 END
  WHERE organization_id = org;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 9 THEN RAISE EXCEPTION 'expected 9 categories, got %', n; END IF;

  EXECUTE 'RESET ROLE';
END $$;
