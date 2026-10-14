-- One-off: rewrite Stumarcot's older Review-queue flags in plain business
-- language (wording only — no product, price or stock data changes).
DO $$
DECLARE org uuid; n int; total int := 0;
BEGIN
  SELECT id INTO STRICT org FROM public.organizations WHERE legal_name = 'STUMARCOT CO LTD';

  CREATE TEMP TABLE _w (item text, code text, reason text, new_code text) ON COMMIT DROP;
  INSERT INTO _w VALUES
  ('Draft', 'unresolved_identity',
   'Stumarcot confirmed (14 Oct) that Draft and 30 Draft are the same tile, but they are still two separate products here. Choose "It''s one of our existing products" and pick 30 Draft, so there is only one.', NULL),
  ('50 Draft', 'unresolved_identity',
   'Is 50 Draft the same tile as Draft 9? (It is already confirmed to be different from Draft / 30 Draft.) If it is Draft 9, choose "It''s one of our existing products"; if not, choose "It''s a product in its own right".', NULL),
  ('Sand Block (unlabeled height)', 'unresolved_identity',
   'The price list has a cheaper "Sand Block" with no height given. It is probably Tofali 4" or Tofali 5". If it is one of those, choose "It''s one of our existing products"; if it is a different block, choose "It''s a product in its own right".', NULL),
  ('Tofali 4"', 'unresolved_identity',
   'Nothing to decide on Tofali 4" itself — the open question is whether the price list''s unlabeled "Sand Block" is this brick or Tofali 5". Answer it on the "Sand Block (unlabeled height)" item, then mark this one as sorted.', 'related_question'),
  ('Tofali 5"', 'unresolved_identity',
   'Nothing to decide on Tofali 5" itself — the open question is whether the price list''s unlabeled "Sand Block" is this brick or Tofali 4". Answer it on the "Sand Block (unlabeled height)" item, then mark this one as sorted.', 'related_question'),
  ('U Dot Paver', 'unresolved_identity',
   'The price list has "U Dot Paver", which may be the same as U-Dot Kubwa or U-Dot Ndogo. (The Dodoma stock sheet''s "U-DOT" was confirmed as U-Dot Kubwa.) If U Dot Paver is one of them, choose "It''s one of our existing products"; if not, choose "It''s a product in its own right".', NULL),
  ('Wall Gamba', 'unresolved_identity',
   'Wall Gamba may be the same tile as Gamba Sq, but the price list gives them different prices (TZS 1,214.29 vs 1,159.09 each) and coverage (21 vs 22 pieces per m²), so they have not been combined. If they are the same, choose "It''s one of our existing products"; if not, choose "It''s a product in its own right".', NULL),
  ('Z Dot', 'unresolved_identity',
   'Z Dot may be a version of Z Plain. If it is the same tile, choose "It''s one of our existing products"; if it is different, choose "It''s a product in its own right".', NULL),
  ('Mafuta/oil', 'unconfirmed_use',
   'Mafuta/oil is not used in any recipe — it is probably fuel or oil for the machines (a running cost, not a mix ingredient). Please confirm what it is used for; that decides how it is costed later.', NULL),
  ('10mm steel', 'missing_unit',
   'We don''t yet know what unit this steel is bought and counted in (per metre, per rod, per kg…). Open the material and set it.', NULL),
  ('R6 (6mm steel)', 'missing_unit',
   'We don''t yet know what unit this steel is bought and counted in (per metre, per rod, per kg…). Open the material and set it.', NULL),
  ('40 Dot 2"', 'missing_data',
   'New tile (40x40 cm, 2 inches thick) with no price yet in any branch, and its pieces per m² aren''t known. Add its prices under Pricing.', NULL),
  ('40 Mayai 2"', 'missing_data',
   'New tile (40x40 cm, 2 inches thick) with no price yet in any branch, and its pieces per m² aren''t known. Add its prices under Pricing.', NULL),
  ('40 Y', 'missing_data',
   'New floor tile priced at TZS 25,500 per m², but its size and pieces per m² aren''t recorded, so there is no price per piece yet. Open it to add the size.', NULL),
  ('Slab', 'colour_price_missing',
   'Slab is counted and sold per piece (TZS 16,500 each). Red, Grey and Black Slab have no price yet — the floor-tile colour prices are per m², which doesn''t fit Slab. Add coloured Slab prices under Pricing before selling them.', NULL);

  UPDATE public.review_flags f
  SET reason = w.reason, reason_code = coalesce(w.new_code, f.reason_code)
  FROM _w w, public.products p
  WHERE f.organization_id = org AND f.status = 'open' AND f.entity_type = 'product' AND p.id::text = f.entity_id
    AND p.organization_id = org AND p.canonical_name = w.item AND f.reason_code = w.code;
  GET DIAGNOSTICS n = ROW_COUNT; total := total + n;

  UPDATE public.review_flags f
  SET reason = w.reason
  FROM _w w, public.materials m
  WHERE f.organization_id = org AND f.status = 'open' AND f.entity_type = 'material' AND m.id::text = f.entity_id
    AND m.organization_id = org AND m.name = w.item AND f.reason_code = w.code;
  GET DIAGNOSTICS n = ROW_COUNT; total := total + n;

  UPDATE public.review_flags
  SET reason = regexp_replace(reason, '^No source recorded for (.*)\.$',
                 'No supplier or source is recorded for \1 yet. Open the material and add where each branch buys it, once known.')
  WHERE organization_id = org AND status = 'open' AND reason_code = 'missing_branch_source' AND reason LIKE 'No source recorded for %';
  GET DIAGNOSTICS n = ROW_COUNT; total := total + n;

  UPDATE public.review_flags
  SET reason = replace(reason, ' If it isn''t, correct it under Decisions.', ' If it isn''t, choose "No, it''s something else".')
  WHERE organization_id = org AND status = 'open' AND reason_code = 'confirm_match';
  GET DIAGNOSTICS n = ROW_COUNT; total := total + n;

  IF total <> 15 + 13 + 9 THEN RAISE EXCEPTION 'expected 37 flags reworded, got %', total; END IF;
END $$;
