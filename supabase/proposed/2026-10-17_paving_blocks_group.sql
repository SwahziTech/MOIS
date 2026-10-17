-- One-off (PROPOSED — run once, after migration 038): Stumarcot's paving
-- categories become "Vibro" and "Press" under a new "Paving Blocks" group,
-- as decided by SwahziTech in chat (2026-10-17). Products, recipes,
-- colours, prices and size specs stay on the two existing categories.
-- The old names are recorded as standing import decisions, so stock
-- sheets headed with them still match without asking.
DO $$
DECLARE
  org    uuid;
  owner  uuid;
  vibro  uuid;
  press  uuid;
  grp    uuid;
  who    constant text := 'SwahziTech (in chat with Claude Code, 2026-10-17)';
BEGIN
  SELECT id INTO STRICT org FROM organizations WHERE legal_name = 'STUMARCOT CO LTD';
  SELECT ur.user_id INTO STRICT owner FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
  WHERE ur.organization_id = org AND ro.name = 'owner' AND ur.branch_id IS NULL LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', owner, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  SELECT id INTO STRICT vibro FROM product_categories WHERE organization_id = org AND category_id_ref = 'paving_blocks_vibro';
  SELECT id INTO STRICT press FROM product_categories WHERE organization_id = org AND category_id_ref = 'press_machine_paving';

  -- the group: first in the list, as the two paving categories were
  INSERT INTO product_categories (organization_id, category_id_ref, name, display_format, sort_order, status)
  VALUES (org, 'paving_blocks', 'Paving Blocks', 'plain', 1, 'active')
  RETURNING id INTO grp;

  -- old names → standing import decisions (before renaming)
  INSERT INTO identity_decisions (organization_id, subject_type, term, decision, category_id, evidence, source, decided_by, decided_by_label)
  VALUES (org, 'category', 'Paving Blocks Vibro', 'same_as', vibro, 'Renamed to "Vibro" under the new "Paving Blocks" group; sheets may still use the old name.', 'chat', owner, who),
         (org, 'category', 'Press Machine Paving', 'same_as', press, 'Renamed to "Press" under the new "Paving Blocks" group; sheets may still use the old name.', 'chat', owner, who);

  -- the two become subcategories: Vibro first, then Press
  UPDATE product_categories SET parent_category_id = grp, name = 'Vibro', sort_order = 1 WHERE id = vibro;
  UPDATE product_categories SET parent_category_id = grp, name = 'Press', sort_order = 2 WHERE id = press;

  EXECUTE 'RESET ROLE';
END $$;
