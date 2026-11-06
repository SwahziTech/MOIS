-- 109 (2026-11-06, the user): the director marks the slip by drawing on it —
-- a green tick for received, a red cross for a query — as done on WhatsApp
-- before. The drawing is kept with the proof (strokes as 0..1 points over the
-- photo) and shown on the slip wherever it is opened.
--   mark = { "color": "green"|"red", "strokes": [[[x,y],...], ...] }
-- A new proof (replaced by the branch) starts unmarked.

ALTER TABLE public.sale_payment_proofs ADD COLUMN IF NOT EXISTS mark jsonb;
COMMENT ON COLUMN public.sale_payment_proofs.mark IS 'The director''s hand-drawn tick or cross over the slip: {color, strokes:[[[x,y]..]..]} in 0..1 of the photo (109).';

CREATE OR REPLACE FUNCTION public.sale_payment_proofs_clear_mark()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.status = 'waiting' AND (OLD.status IS DISTINCT FROM 'waiting' OR NEW.file_path IS DISTINCT FROM OLD.file_path) THEN
    NEW.mark := NULL;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_sale_payment_proofs_clear_mark ON public.sale_payment_proofs;
CREATE TRIGGER trg_sale_payment_proofs_clear_mark BEFORE UPDATE ON public.sale_payment_proofs
  FOR EACH ROW EXECUTE FUNCTION public.sale_payment_proofs_clear_mark();

DROP FUNCTION IF EXISTS public.review_payment_proof(uuid, text, text);
CREATE OR REPLACE FUNCTION public.review_payment_proof(p_payment uuid, p_action text, p_note text DEFAULT NULL, p_mark jsonb DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  pr public.sale_payment_proofs;
BEGIN
  SELECT * INTO pr FROM public.sale_payment_proofs WHERE payment_id = p_payment AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No proof has been added for this payment yet' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('sales.confirm_payments', pr.branch_id, NULL) THEN
    RAISE EXCEPTION 'Only a director can confirm payments' USING ERRCODE = '42501';
  END IF;
  -- a photo slip is marked by hand: the drawing must come with it
  IF pr.file_path IS NOT NULL AND pr.file_path !~* '\.pdf$'
     AND (p_mark IS NULL OR jsonb_typeof(p_mark->'strokes') <> 'array' OR jsonb_array_length(p_mark->'strokes') = 0) THEN
    RAISE EXCEPTION 'Draw your mark on the slip first' USING ERRCODE = '23514';
  END IF;
  IF p_mark IS NOT NULL AND length(p_mark::text) > 60000 THEN
    RAISE EXCEPTION 'The mark is too long; clear it and draw again' USING ERRCODE = '23514';
  END IF;
  IF p_action = 'confirm' THEN
    UPDATE public.sale_payment_proofs SET status = 'confirmed', reviewed_by = auth.uid(), reviewed_at = now(), note = NULL,
      mark = CASE WHEN p_mark IS NULL THEN NULL ELSE jsonb_build_object('color', 'green', 'strokes', p_mark->'strokes') END
    WHERE id = pr.id;
  ELSIF p_action = 'query' THEN
    IF nullif(btrim(p_note), '') IS NULL THEN RAISE EXCEPTION 'Say what is wrong with the proof' USING ERRCODE = '23514'; END IF;
    UPDATE public.sale_payment_proofs SET status = 'queried', reviewed_by = auth.uid(), reviewed_at = now(), note = btrim(p_note),
      mark = CASE WHEN p_mark IS NULL THEN NULL ELSE jsonb_build_object('color', 'red', 'strokes', p_mark->'strokes') END
    WHERE id = pr.id;
  ELSE
    RAISE EXCEPTION 'Confirm or query' USING ERRCODE = '23514';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.review_payment_proof(uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_payment_proof(uuid, text, text, jsonb) TO authenticated;
