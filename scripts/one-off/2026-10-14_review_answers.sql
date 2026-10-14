-- One-off: apply SwahziTech's Review-queue answers given in chat (2026-10-14).
-- Runs through the same functions the app uses, as the organization owner
-- account; every change is noted as answered by SwahziTech in chat.
-- All or nothing.
DO $$
DECLARE
  org   uuid;
  owner uuid;
  who   constant text := 'SwahziTech (in chat with Claude Code, 2026-10-14)';
  n     int;
  pid   uuid;
BEGIN
  SELECT id INTO STRICT org FROM organizations WHERE legal_name = 'STUMARCOT CO LTD';
  SELECT ur.user_id INTO STRICT owner FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
  WHERE ur.organization_id = org AND ro.name = 'owner' AND ur.branch_id IS NULL LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', owner, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  -- helper: close the open "please confirm" flag on a name-match decision
  CREATE TEMP TABLE _confirm (term text) ON COMMIT DROP;
  INSERT INTO _confirm VALUES ('40*80 COMBO'), ('W/CUP'), ('30 CULTURE'), ('V-SHAPE'), ('4'''' DUST'), ('5'''' DUST'), ('6'''' DUST'), ('MATOFALI');
  UPDATE review_flags f SET status = 'resolved', resolved_at = now(), resolved_by = owner, resolution_note = 'Confirmed by ' || who
  FROM identity_decisions d, _confirm c
  WHERE f.organization_id = org AND f.status = 'open' AND f.reason_code = 'confirm_match' AND f.entity_type = 'identity_decision'
    AND f.entity_id = d.id::text AND d.term_normalized = normalize_name(c.term);
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 2 THEN RAISE EXCEPTION 'confirm flags: expected 2, got %', n; END IF;

  -- 2/4/8/9: renames confirmed with the matches
  UPDATE products SET canonical_name = '80 Combo' WHERE organization_id = org AND canonical_name = 'Combo' AND status = 'active';
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'rename Combo: %', n; END IF;
  UPDATE products SET canonical_name = '30 Culture'
  WHERE organization_id = org AND canonical_name = 'Culture' AND category_id = (SELECT id FROM product_categories WHERE organization_id = org AND category_id_ref = 'floor_tiles');
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'rename Culture: %', n; END IF;
  UPDATE products SET canonical_name = 'Tofali 6"' WHERE organization_id = org AND canonical_name = 'Sand Block (450x230x150mm)';
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'rename Sand Block 6: %', n; END IF;
  UPDATE product_categories SET name = 'Blocks / Matofali' WHERE organization_id = org AND category_id_ref = 'blocks';
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'rename Blocks: %', n; END IF;

  -- 10: MIKUBWA CM 80 — answer was "not sure"; nothing changes (no open flag; its decision stays as it is)

  -- 11: Draft = 30 Draft → keep the priced one, named "30 Draft"
  PERFORM resolve_product_identity((SELECT id FROM products WHERE organization_id = org AND canonical_name = '30 Draft' AND status = 'active'),
    jsonb_build_object('choice', 'same_as', 'target_product_id', (SELECT id FROM products WHERE organization_id = org AND canonical_name = 'Draft' AND status = 'active'),
                       'note', 'answered by ' || who));
  UPDATE products SET canonical_name = '30 Draft' WHERE organization_id = org AND canonical_name = 'Draft' AND status = 'active';
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'rename Draft: %', n; END IF;
  UPDATE review_flags SET status = 'resolved', resolved_at = now(), resolved_by = owner,
         resolution_note = 'Draft and 30 Draft combined into one product named "30 Draft" — ' || who
  WHERE organization_id = org AND status = 'open' AND reason_code = 'unresolved_identity'
    AND entity_id = (SELECT id::text FROM products WHERE organization_id = org AND canonical_name = '30 Draft' AND status = 'active');

  -- 12: 50 Draft ≠ Draft 9
  PERFORM resolve_product_identity((SELECT id FROM products WHERE organization_id = org AND canonical_name = '50 Draft' AND status = 'active'),
    jsonb_build_object('choice', 'keep', 'not_products', jsonb_build_array((SELECT id FROM products WHERE organization_id = org AND canonical_name = 'Draft 9')),
                       'note', 'answered by ' || who));

  -- 13: unlabeled Sand Block = Tofali 4"; its prices become Tofali 4"'s (Tofali 4" had none)
  pid := (SELECT id FROM products WHERE organization_id = org AND canonical_name = 'Tofali 4"');
  IF EXISTS (SELECT 1 FROM product_branch_pricing WHERE product_id = pid) THEN RAISE EXCEPTION 'Tofali 4" already has prices'; END IF;
  UPDATE product_branch_pricing SET product_id = pid
  WHERE product_id = (SELECT id FROM products WHERE organization_id = org AND canonical_name = 'Sand Block (unlabeled height)');
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 3 THEN RAISE EXCEPTION 'Sand Block prices: %', n; END IF;
  PERFORM resolve_product_identity((SELECT id FROM products WHERE organization_id = org AND canonical_name = 'Sand Block (unlabeled height)' AND status = 'active'),
    jsonb_build_object('choice', 'same_as', 'target_product_id', pid, 'note', 'answered by ' || who || '; its prices moved to Tofali 4"'));
  UPDATE review_flags SET status = 'resolved', resolved_at = now(), resolved_by = owner,
         resolution_note = 'The unlabeled Sand Block was confirmed as Tofali 4" — ' || who
  WHERE organization_id = org AND status = 'open' AND reason_code = 'related_question';
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 2 THEN RAISE EXCEPTION 'related flags: %', n; END IF;

  -- 14: U Dot Paver = U-Dot Kubwa; its prices become U-Dot Kubwa's (Kubwa had none)
  pid := (SELECT id FROM products WHERE organization_id = org AND canonical_name = 'U-Dot Kubwa');
  IF EXISTS (SELECT 1 FROM product_branch_pricing WHERE product_id = pid) THEN RAISE EXCEPTION 'U-Dot Kubwa already has prices'; END IF;
  UPDATE product_branch_pricing SET product_id = pid
  WHERE product_id = (SELECT id FROM products WHERE organization_id = org AND canonical_name = 'U Dot Paver');
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 3 THEN RAISE EXCEPTION 'U Dot prices: %', n; END IF;
  PERFORM resolve_product_identity((SELECT id FROM products WHERE organization_id = org AND canonical_name = 'U Dot Paver' AND status = 'active'),
    jsonb_build_object('choice', 'same_as', 'target_product_id', pid, 'note', 'answered by ' || who || '; its prices moved to U-Dot Kubwa'));

  -- 15: Gamba Sq = Wall Gamba, keep Wall Gamba (Gamba Sq's stock moves; Wall Gamba's prices stay)
  PERFORM resolve_product_identity((SELECT id FROM products WHERE organization_id = org AND canonical_name = 'Gamba Sq' AND status = 'active'),
    jsonb_build_object('choice', 'same_as', 'target_product_id', (SELECT id FROM products WHERE organization_id = org AND canonical_name = 'Wall Gamba'),
                       'note', 'answered by ' || who));
  UPDATE review_flags SET status = 'resolved', resolved_at = now(), resolved_by = owner,
         resolution_note = 'Gamba Sq combined into Wall Gamba — ' || who
  WHERE organization_id = org AND status = 'open' AND reason_code = 'unresolved_identity'
    AND entity_id = (SELECT id::text FROM products WHERE organization_id = org AND canonical_name = 'Wall Gamba');

  -- 16: Z Dot ≠ Z Plain
  PERFORM resolve_product_identity((SELECT id FROM products WHERE organization_id = org AND canonical_name = 'Z Dot' AND status = 'active'),
    jsonb_build_object('choice', 'keep', 'not_products', jsonb_build_array((SELECT id FROM products WHERE organization_id = org AND canonical_name = 'Z Plain')),
                       'note', 'answered by ' || who));

  -- 17: Mafuta/oil is mould release oil
  UPDATE materials SET notes = 'Mould release oil — used on moulds during production (a production consumable, not a mix ingredient). Confirmed by ' || who || '.'
  WHERE organization_id = org AND name = 'Mafuta/oil';
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'Mafuta: %', n; END IF;
  UPDATE review_flags SET status = 'resolved', resolved_at = now(), resolved_by = owner, resolution_note = 'Mould release oil — ' || who
  WHERE organization_id = org AND status = 'open' AND reason_code = 'unconfirmed_use';

  -- 18: steel is counted per bar (pieces)
  UPDATE materials SET stock_unit_id = (SELECT id FROM units WHERE organization_id = org AND symbol = 'PCS')
  WHERE organization_id = org AND material_id_ref IN ('steel_10mm', 'steel_r6') AND stock_unit_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 2 THEN RAISE EXCEPTION 'steel units: %', n; END IF;
  UPDATE review_flags SET status = 'resolved', resolved_at = now(), resolved_by = owner, resolution_note = 'Counted per bar (pieces) — ' || who
  WHERE organization_id = org AND status = 'open' AND reason_code = 'missing_unit';

  -- 19: other branches enter their own data later — their source reminders wait
  UPDATE review_flags SET status = 'dismissed', resolved_at = now(), resolved_by = owner,
         resolution_note = 'Deferred: Mwanza and Dar es Salaam will enter their own data once MOIS is verified in Dodoma — ' || who
  WHERE organization_id = org AND status = 'open' AND reason_code = 'missing_branch_source' AND reason NOT LIKE '%Dodoma%';
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 11 THEN RAISE EXCEPTION 'source flags dismissed: %', n; END IF;
  UPDATE review_flags SET reason = 'No supplier or source is recorded for Dodoma yet. Open the material and add where Dodoma buys it, once known. (Mwanza and Dar es Salaam will add their own later.)'
  WHERE organization_id = org AND status = 'open' AND reason_code = 'missing_branch_source';

  -- 21: 40 Y is 40x40 cm, 6 per m² (per-piece price follows: 25,500 / 6 = 4,250)
  UPDATE products SET size_cm = '40x40', pcs_per_sqm = 6 WHERE organization_id = org AND canonical_name = '40 Y';
  UPDATE product_branch_pricing SET pcs_per_sqm_at_pricing = 6, price_per_unit_inclusive = 4250
  WHERE product_id = (SELECT id FROM products WHERE organization_id = org AND canonical_name = '40 Y') AND price_per_sqm_inclusive = 25500;
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 3 THEN RAISE EXCEPTION '40 Y prices: %', n; END IF;
  UPDATE review_flags SET status = 'resolved', resolved_at = now(), resolved_by = owner, resolution_note = '40x40 cm, 6 per m² — ' || who
  WHERE organization_id = org AND status = 'open' AND reason_code = 'missing_data'
    AND entity_id = (SELECT id::text FROM products WHERE organization_id = org AND canonical_name = '40 Y');

  EXECUTE 'RESET ROLE';
END $$;
