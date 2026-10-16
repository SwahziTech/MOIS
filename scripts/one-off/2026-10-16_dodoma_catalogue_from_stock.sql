-- One-off (run once, 2026-10-16): SwahziTech in chat — "all products can be
-- in any branch, but for now (Dodoma) just add the products in the stock".
-- Dodoma's catalogue = the products Dodoma actually holds stock of. The
-- rest are marked not carried in Dodoma (rows kept, re-activated any time).
-- Mwanza / Dar es Salaam catalogues are untouched.
DO $$
DECLARE
  org   uuid;
  dod   uuid;
  owner uuid;
  who   constant text := 'SwahziTech (in chat with Claude Code, 2026-10-16)';
  n     int;
BEGIN
  SELECT id, default_branch_id INTO STRICT org, dod FROM organizations WHERE legal_name = 'STUMARCOT CO LTD';
  SELECT ur.user_id INTO STRICT owner FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
  WHERE ur.organization_id = org AND ro.name = 'owner' AND ur.branch_id IS NULL LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', owner, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  CREATE TEMP TABLE _stocked ON COMMIT DROP AS
  SELECT product_id FROM inventory_transactions
  WHERE branch_id = dod AND product_id IS NOT NULL GROUP BY product_id HAVING sum(quantity) <> 0;

  UPDATE branch_products bp
  SET status = 'inactive',
      notes = coalesce(bp.notes || E'\n', '') || 'Not carried in Dodoma for now: no Dodoma stock — ' || who || '.'
  WHERE bp.branch_id = dod AND bp.status = 'active' AND bp.product_id NOT IN (SELECT product_id FROM _stocked);
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 18 THEN RAISE EXCEPTION 'expected 18 not carried, got %', n; END IF;

  IF (SELECT count(*) FROM branch_products WHERE branch_id = dod AND status = 'active') <> 65
     OR EXISTS (SELECT 1 FROM _stocked s WHERE NOT EXISTS (
          SELECT 1 FROM branch_products bp WHERE bp.branch_id = dod AND bp.product_id = s.product_id AND bp.status = 'active')) THEN
    RAISE EXCEPTION 'Dodoma catalogue does not match its stock';
  END IF;

  -- The "does Dodoma sell it?" questions are answered by the stock
  UPDATE review_flags f
  SET status = 'resolved', resolved_at = now(), resolved_by = owner,
      resolution_note = CASE WHEN bp.status = 'active'
                             THEN 'Yes — Dodoma holds stock of it. ' || who
                             ELSE 'Not carried in Dodoma for now (no Dodoma stock). ' || who END
  FROM branch_products bp
  WHERE f.organization_id = org AND f.status = 'open' AND f.reason_code = 'unconfirmed_branch_carriage'
    AND f.entity_type = 'branch_product' AND f.entity_id = bp.id::text;
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 9 THEN RAISE EXCEPTION 'expected 9 flags, got %', n; END IF;

  EXECUTE 'RESET ROLE';
END $$;
