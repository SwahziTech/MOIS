-- One-off (run once, 2026-10-17): standing import decision, confirmed by
-- SwahziTech in chat — the stock sheet heading "CUBSTONES" (a recurring
-- misspelling) is the Curbstones category.
DO $$
DECLARE
  org   uuid;
  owner uuid;
  cat   uuid;
BEGIN
  SELECT id INTO STRICT org FROM organizations WHERE legal_name = 'STUMARCOT CO LTD';
  SELECT ur.user_id INTO STRICT owner FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
  WHERE ur.organization_id = org AND ro.name = 'owner' AND ur.branch_id IS NULL LIMIT 1;
  SELECT id INTO STRICT cat FROM product_categories WHERE organization_id = org AND category_id_ref = 'curbstones';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', owner, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  INSERT INTO identity_decisions (organization_id, subject_type, term, decision, category_id, evidence, source, decided_by, decided_by_label)
  VALUES (org, 'category', 'CUBSTONES', 'same_as', cat,
          'Recurring misspelling of the Curbstones heading on the Dodoma stock-take sheet; it never matched automatically.',
          'chat', owner, 'SwahziTech (in chat with Claude Code, 2026-10-17)');

  EXECUTE 'RESET ROLE';
END $$;
