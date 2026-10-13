-- One-off (after migration 026): record Stumarcot's identity decisions that
-- so far lived only in the source files' decision logs and in chat, so they
-- are never asked again. Run ONCE:
--   supabase db query --linked -f scripts/one-off/2026-10-14_stumarcot_identity_decisions.sql
-- Every target is looked up by exact name + category and must exist; any
-- miss aborts the whole script.
DO $$
DECLARE
  org uuid;
  n   int := 0;
  rec_label  constant text := 'SwahziTech (project records)';
  chat_label constant text := 'Stumarcot (in chat with Claude Code)';

BEGIN
  SELECT id INTO STRICT org FROM public.organizations WHERE legal_name = 'STUMARCOT CO LTD';

  CREATE TEMP TABLE _d (subject_type text, term text, context text, decision text,
                        product text, category_ref text, color text, evidence text, source text, label text, decided_at timestamptz)
  ON COMMIT DROP;

  INSERT INTO _d VALUES
  -- From the source files (ratios_and_molds.json _decisions_log / product_master.json), confirmed 2026-10-12
  ('product', 'Worldcup', '', 'same_as', 'Paving W/Cup', 'press_machine_paving', NULL,
   '_decisions_log: "Worldcup = W/Cup (same product, merged via alias)."', 'source_records', rec_label, '2026-10-12'),
  ('product', 'Zigzag', '', 'distinct_from', 'Paving Z-Plain', 'press_machine_paving', NULL,
   '_decisions_log: "Zigzag is NOT Z-Plain - confirmed distinct." Zigzag is a 3-variant family (30MPa 6cm, 30-35MPa 8cm, 40-45MPa 8cm).', 'source_records', rec_label, '2026-10-12'),
  ('product', 'Rectangular (30MPa, 6cm)', '', 'same_as', 'Paving 6cm 30MPa', 'press_machine_paving', NULL,
   'Confirmed by SwahziTech: price-list "Rectangular/Square Rough Paving" IS this product, size and grade match exactly.', 'source_records', rec_label, '2026-10-12'),
  ('product', 'Rectangular (30-35MPa, 8cm)', '', 'same_as', 'Paving 8cm 30MPa', 'press_machine_paving', NULL,
   'Confirmed by SwahziTech: price-list "Rectangular/Square Rough Paving" IS this product, size and grade match exactly.', 'source_records', rec_label, '2026-10-12'),
  ('product', 'Rectangular (40-45MPa, 8cm)', '', 'same_as', 'Paving 8cm 40MPa', 'press_machine_paving', NULL,
   'Confirmed by SwahziTech: price-list "Rectangular/Square Rough Paving" IS this product, size and grade match exactly.', 'source_records', rec_label, '2026-10-12'),
  ('product', '2IG-2AG 40MPa', '', 'same_as', 'Paving Zigzag 40-45MPa (8cm)', 'press_machine_paving', NULL,
   'Confirmed by user: the notebook entry is a mistranscription of ZIGZAG; ratio matches exactly.', 'source_records', rec_label, '2026-10-12'),
  ('product', 'Tofali 6"', '', 'same_as', 'Sand Block (450x230x150mm)', 'blocks', NULL,
   'Confirmed by SwahziTech: price-list "Sand Block" at 450x230x150mm - height (150mm) matches Tofali 6" exactly.', 'source_records', rec_label, '2026-10-12'),
  ('product', 'Tofali 6" Chipping', '', 'same_as', 'Chipping Block (450x230x150mm)', 'blocks', NULL,
   'Confirmed by SwahziTech: price-list "Chipping Block" - the only chipping variant, height matches Tofali 6" Chipping.', 'source_records', rec_label, '2026-10-12'),
  ('product', 'Tofali Tundu 6"', '', 'same_as', 'Hollow Block (450x230x150mm)', 'blocks', NULL,
   'Confirmed by SwahziTech: price-list "Hollow Block" is Tofali Tundu (150mm).', 'source_records', rec_label, '2026-10-12'),
  ('product', '6'''' Hollow', '', 'same_as', 'Hollow Block (450x230x150mm)', 'blocks', NULL,
   'product_master.json alt_names of Hollow Block.', 'source_records', rec_label, '2026-10-12'),
  ('product', '8'''' Hollow', '', 'same_as', 'Tofali Tundu 8"', 'blocks', NULL,
   'product_master.json alt_names of Tofali Tundu 8".', 'source_records', rec_label, '2026-10-12'),
  ('product', 'Hollow Block', '', 'distinct_from', 'Hollow', 'trench_covers', NULL,
   'Confirmed by SwahziTech: Hollow Block is Tofali Tundu, NOT Trench Cover''s "Hollow" (that earlier match was wrong).', 'source_records', rec_label, '2026-10-12'),
  ('product', '60 Round', '', 'same_as', '60 Oval', 'curbstones', NULL,
   '_decisions_log: "60 Round" renamed "60 Oval".', 'source_records', rec_label, '2026-10-12'),
  ('product', 'Buibui (250mm)', '', 'same_as', '25 Buibui', 'floor_tiles', NULL,
   '_decisions_log: "Buibui(250mm)=25 Buibui".', 'source_records', rec_label, '2026-10-12'),
  ('product', 'MFUNIKO MDOGO', '', 'same_as', '50 Mdogo Tundu 5', 'trench_covers', NULL,
   'Confirmed by Stumarcot: one product at TZS 11,500 in all branches; the second "MFUNIKO MDOGO" row at 16,500 in the Mwanza and Dar sheets is a price-list error, not a variant.', 'source_records', rec_label, '2026-10-12'),

  -- Decided in chat
  ('product', 'Draft (490x450mm)', '', 'same_as', '50 Draft', 'floor_tiles', NULL,
   'Stumarcot confirmed "50 Draft" and "Draft (490x450mm)" are the same product (same price, inconsistent naming across branches); merged in the app.', 'chat', chat_label, '2026-10-12'),
  ('product', 'NGUZO', 'CULVERTS', 'same_as', 'Nguzo', 'posts_and_bicons', NULL,
   'Stumarcot: Nguzo/Bicon belong to the existing "Posts And Bicons" category, not Culverts (stock sheet lists them under CULVERTS).', 'chat', chat_label, '2026-10-14'),
  ('product', 'BICON', 'CULVERTS', 'same_as', 'Bicon', 'posts_and_bicons', NULL,
   'Stumarcot: Nguzo/Bicon belong to the existing "Posts And Bicons" category, not Culverts.', 'chat', chat_label, '2026-10-14'),
  ('product', '40 MAYAI 2''''', '', 'new_record', '40 Mayai 2"', 'floor_tiles', NULL,
   'Stumarcot: a separate new product, 40x40 cm and 2 inches thick (supersedes product_master.json naming_resolutions, which read 2" as the standard thickness).', 'chat', chat_label, '2026-10-14'),
  ('product', '40 MAYAI 2''''', '', 'distinct_from', '40 Mayai', 'floor_tiles', NULL,
   'Stumarcot: the 2-inch tile is not the standard 40 Mayai.', 'chat', chat_label, '2026-10-14'),
  ('product', '40 DOT 2''''', '', 'new_record', '40 Dot 2"', 'floor_tiles', NULL,
   'Stumarcot: a separate new product, 40x40 cm and 2 inches thick.', 'chat', chat_label, '2026-10-14'),
  ('product', '40 DOT 2''''', '', 'distinct_from', '40 Dot', 'floor_tiles', NULL,
   'Stumarcot: the 2-inch tile is not the standard 40 Dot.', 'chat', chat_label, '2026-10-14'),
  ('product', '8 GONE', 'FLOOR TILES', 'same_as', '30 8gon', 'floor_tiles', NULL,
   'Stumarcot: 8 GONE is the 30x30 8gon.', 'chat', chat_label, '2026-10-14'),
  ('product', 'DRAFT PLAIN', 'FLOOR TILES', 'same_as', 'Draft', 'floor_tiles', NULL,
   'Stumarcot: DRAFT PLAIN is "Draft" (same as "30 Draft"), distinct from "Draft 9" and "50 Draft".', 'chat', chat_label, '2026-10-14'),
  ('product', '30 Draft', '', 'same_as', 'Draft', 'floor_tiles', NULL,
   'Stumarcot: "Draft" and "30 Draft" are the same product (two catalogue records — merge them under Products when ready).', 'chat', chat_label, '2026-10-14'),
  ('product', 'Draft', '', 'distinct_from', 'Draft 9', 'floor_tiles', NULL,
   'Stumarcot: Draft is confirmed distinct from Draft 9.', 'chat', chat_label, '2026-10-14'),
  ('product', 'Draft', '', 'distinct_from', '50 Draft', 'floor_tiles', NULL,
   'Stumarcot: Draft is confirmed distinct from 50 Draft.', 'chat', chat_label, '2026-10-14'),
  ('product', '40 Y', '', 'new_record', '40 Y', 'floor_tiles', NULL,
   'Stumarcot: a new floor tile, priced at the standard floor-tile tier.', 'chat', chat_label, '2026-10-14'),
  ('product', 'U-DOT', 'PAVING BLOCKS', 'same_as', 'U-Dot Kubwa', 'paving_blocks_vibro', NULL,
   'Stumarcot: U-DOT on the paving stock sheet is U-Dot Kubwa.', 'chat', chat_label, '2026-10-14'),
  ('product', 'MIKUBWA CM 80', 'TRENCHCOVERS', 'same_as', 'Hollow', 'trench_covers', NULL,
   'Stumarcot answered "Trench cover" when asked whether MIKUBWA CM 80 is Mkubwa Nondo (its own row), Trench Cover "Hollow" (70x50) or a new product - read as Trench Cover "Hollow". Correct it here if that reading is wrong.', 'chat', chat_label, '2026-10-14'),
  ('color', 'MAROON', '', 'same_as', NULL, NULL, 'Maroon',
   'Stumarcot: Maroon was a one-time test batch — recorded as a colour, inactive (discontinued) immediately so the stock can be sold down.', 'chat', chat_label, '2026-10-14');

  INSERT INTO public.identity_decisions
    (organization_id, subject_type, term, context, decision, product_id, color_id, evidence, source, decided_by_label, decided_at)
  SELECT org, d.subject_type, d.term, d.context, d.decision,
         CASE WHEN d.subject_type = 'product' THEN
           (SELECT p.id FROM public.products p JOIN public.product_categories c ON c.id = p.category_id
            WHERE p.organization_id = org AND p.canonical_name = d.product AND c.category_id_ref = d.category_ref) END,
         CASE WHEN d.subject_type = 'color' THEN
           (SELECT id FROM public.color_palette WHERE organization_id = org AND name = d.color) END,
         d.evidence, d.source, d.label, d.decided_at
  FROM _d d;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> (SELECT count(*) FROM _d) THEN RAISE EXCEPTION 'expected % decisions, got %', (SELECT count(*) FROM _d), n; END IF;
  RAISE NOTICE 'recorded % decisions', n;
END $$;
