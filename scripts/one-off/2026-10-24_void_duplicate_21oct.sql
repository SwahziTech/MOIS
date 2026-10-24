-- One-off (run once). SwahziTech, 2026-10-24: 21 Oct production was saved
-- twice (22 Oct 18:24 and 18:32). The 18:32 save is the full day (it also has
-- Nguzo + Bicon); the three batches of the 18:24 save are voided, which
-- reverses their curing pieces and their materials. Voided batches stay on
-- record (Production › Released & void). Runs as the Technical admin.
DO $$
DECLARE
  b uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"ae48a74f-aaf7-4a56-b6bb-76150a6261e6","role":"authenticated"}', true);
  FOREACH b IN ARRAY ARRAY['64170f2d-5677-4b1d-93eb-9d1e31b4854c', 'a64a5aa3-6764-4acf-86d7-0736df60600f', '2ddec899-b7f8-4da7-b522-73424467df5a']::uuid[] LOOP
    IF NOT EXISTS (SELECT 1 FROM public.production_batches WHERE id = b AND batch_date = '2026-10-21' AND status = 'curing') THEN
      RAISE EXCEPTION 'Batch % is not a curing 21 Oct batch — nothing changed', b;
    END IF;
    PERFORM public.void_production_batch(b, '21 Oct entered twice — duplicate of the 22 Oct 18:32 save');
  END LOOP;
END $$;

SELECT status, count(*) FROM public.production_batches WHERE batch_date = '2026-10-21' GROUP BY 1;
