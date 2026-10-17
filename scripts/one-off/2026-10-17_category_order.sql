-- One-off (run once, 2026-10-17): Stumarcot's product category order, as
-- confirmed by SwahziTech in chat. Display order only (sort_order).
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

  UPDATE product_categories c SET sort_order = v.ord
  FROM (VALUES ('paving_blocks_vibro', 1), ('press_machine_paving', 2), ('floor_tiles', 3), ('wall_tiles', 4),
               ('curbstones', 5), ('trench_covers', 6), ('culverts', 7), ('posts_and_bicons', 8), ('blocks', 9)) v(ref, ord)
  WHERE c.organization_id = org AND c.category_id_ref = v.ref;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 9 THEN RAISE EXCEPTION 'expected 9 categories, got %', n; END IF;

  EXECUTE 'RESET ROLE';
END $$;
