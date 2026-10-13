-- ============================================================
-- 026 — Identity decision log (1b)
--
-- Every answer to "is X the same as Y / what is X?" for catalogue items
-- (products, materials, colours, categories, suppliers) is stored here
-- once and used everywhere afterwards: stock-sheet imports, the Review
-- queue, product merges, and anyone (person or assistant) about to ask the
-- question again. Generalizes import_aliases (024), which it replaces.
--
--   decision = same_as       the term means this existing record
--            = new_record    the term was a new record, created for it
--                            (matches exactly like same_as)
--            = distinct_from the term is NOT this record (stops it being
--                            suggested or asked about again)
--            = not_tracked   the term isn't stocked here at all (skip it)
--
-- Who/when/why are required (decided_by_label, decided_at, evidence).
-- Decisions are never edited or deleted: a correction supersedes the old
-- row (correct_identity_decision), keeping the history, and takes effect
-- for every future match at once because matching reads only active rows.
-- ============================================================

CREATE TABLE public.identity_decisions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id    uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  subject_type       text NOT NULL CHECK (subject_type IN ('product', 'material', 'color', 'category', 'supplier')),
  term               text NOT NULL CHECK (btrim(term) <> ''),
  term_normalized    text NOT NULL,
  context            text NOT NULL DEFAULT '',   -- where the term appears, e.g. a sheet heading; '' = anywhere
  context_normalized text NOT NULL DEFAULT '',
  decision           text NOT NULL CHECK (decision IN ('same_as', 'new_record', 'distinct_from', 'not_tracked')),
  product_id         uuid REFERENCES public.products(id),
  material_id        uuid REFERENCES public.materials(id),
  color_id           uuid REFERENCES public.color_palette(id),
  category_id        uuid REFERENCES public.product_categories(id),
  supplier_id        uuid REFERENCES public.suppliers(id),
  evidence           text NOT NULL CHECK (btrim(evidence) <> ''),
  source             text NOT NULL CHECK (source IN ('import', 'review_queue', 'product_edit', 'merge', 'chat', 'source_records')),
  decided_by         uuid REFERENCES auth.users(id),
  decided_by_label   text NOT NULL CHECK (btrim(decided_by_label) <> ''),
  decided_at         timestamptz NOT NULL DEFAULT now(),
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'superseded', 'revoked')),
  superseded_by      uuid REFERENCES public.identity_decisions(id),
  status_note        text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  -- exactly one target of the subject's type, except not_tracked (none)
  CHECK (CASE WHEN decision = 'not_tracked' THEN num_nonnulls(product_id, material_id, color_id, category_id, supplier_id) = 0
              ELSE num_nonnulls(product_id, material_id, color_id, category_id, supplier_id) = 1
               AND CASE subject_type WHEN 'product'  THEN product_id  IS NOT NULL
                                     WHEN 'material' THEN material_id IS NOT NULL
                                     WHEN 'color'    THEN color_id    IS NOT NULL
                                     WHEN 'category' THEN category_id IS NOT NULL
                                     ELSE supplier_id IS NOT NULL END END),
  CHECK ((status = 'superseded') = (superseded_by IS NOT NULL))
);

-- One standing answer per term (in its context); "not X" answers can be many
CREATE UNIQUE INDEX uq_identity_decisions_answer
  ON public.identity_decisions (organization_id, subject_type, context_normalized, term_normalized)
  WHERE status = 'active' AND decision IN ('same_as', 'new_record', 'not_tracked');
CREATE UNIQUE INDEX uq_identity_decisions_distinct
  ON public.identity_decisions (organization_id, subject_type, context_normalized, term_normalized,
                                coalesce(product_id, material_id, color_id, category_id, supplier_id))
  WHERE status = 'active' AND decision = 'distinct_from';
CREATE INDEX idx_identity_decisions_lookup
  ON public.identity_decisions (organization_id, subject_type, term_normalized) WHERE status = 'active';

CREATE OR REPLACE FUNCTION public.identity_decision_normalize()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.term_normalized    := public.normalize_name(NEW.term);
  NEW.context_normalized := public.normalize_name(NEW.context);
  IF NEW.term_normalized = '' THEN
    RAISE EXCEPTION 'The term needs letters or digits' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_identity_decisions_normalize
  BEFORE INSERT ON public.identity_decisions
  FOR EACH ROW EXECUTE FUNCTION public.identity_decision_normalize();

-- History is permanent: only status / superseded_by / status_note may change
CREATE OR REPLACE FUNCTION public.identity_decision_history_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF (NEW.subject_type, NEW.term, NEW.context, NEW.decision, NEW.product_id, NEW.material_id, NEW.color_id,
      NEW.category_id, NEW.supplier_id, NEW.evidence, NEW.source, NEW.decided_by, NEW.decided_by_label, NEW.decided_at)
     IS DISTINCT FROM
     (OLD.subject_type, OLD.term, OLD.context, OLD.decision, OLD.product_id, OLD.material_id, OLD.color_id,
      OLD.category_id, OLD.supplier_id, OLD.evidence, OLD.source, OLD.decided_by, OLD.decided_by_label, OLD.decided_at) THEN
    RAISE EXCEPTION 'A decision can''t be edited — correct it instead (the old one stays as history)' USING ERRCODE = '23514';
  END IF;
  IF OLD.status <> 'active'
     AND NOT (OLD.status = 'revoked' AND NEW.status = 'superseded'
              AND current_setting('mois.identity_correction', true) = 'on') THEN
    RAISE EXCEPTION 'This decision has already been replaced or revoked' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_identity_decisions_history
  BEFORE UPDATE ON public.identity_decisions
  FOR EACH ROW EXECUTE FUNCTION public.identity_decision_history_only();

CREATE TRIGGER trg_identity_decisions_audit AFTER INSERT OR UPDATE OR DELETE ON public.identity_decisions
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('identity_decision', 'id');
CREATE TRIGGER trg_identity_decisions_no_delete BEFORE DELETE ON public.identity_decisions
  FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('identity_decision');
CREATE TRIGGER trg_identity_decisions_product_org BEFORE INSERT ON public.identity_decisions
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('products', 'product_id');
CREATE TRIGGER trg_identity_decisions_material_org BEFORE INSERT ON public.identity_decisions
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('materials', 'material_id');
CREATE TRIGGER trg_identity_decisions_category_org BEFORE INSERT ON public.identity_decisions
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('product_categories', 'category_id');
CREATE TRIGGER trg_identity_decisions_supplier_org BEFORE INSERT ON public.identity_decisions
  FOR EACH ROW EXECUTE FUNCTION public.check_ref_org('suppliers', 'supplier_id');
CREATE TRIGGER trg_identity_decisions_color_org BEFORE INSERT ON public.identity_decisions
  FOR EACH ROW EXECUTE FUNCTION public.check_color_org('color_id');

ALTER TABLE public.identity_decisions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "identity_decisions: read own org" ON public.identity_decisions FOR SELECT
  USING (organization_id = public.get_my_org_id());
-- Recording an answer directly: master-data admins, in their own name
CREATE POLICY "identity_decisions: admins record" ON public.identity_decisions FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id()
              AND (public.has_permission('products.manage') OR public.has_permission('materials.manage'))
              AND decided_by = auth.uid());
-- No UPDATE policy: corrections and revocations go through the functions below

COMMENT ON TABLE public.identity_decisions
  IS 'Standing answers to catalogue identity questions (is X the same as Y). Check here before asking again; correct, never edit.';


-- ------------------------------------------------------------
-- Correct or revoke (atomic; history kept)
-- ------------------------------------------------------------
-- p_new: { decision, product_id | material_id | color_id | category_id | supplier_id }
CREATE OR REPLACE FUNCTION public.correct_identity_decision(p_id uuid, p_new jsonb, p_evidence text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org    uuid := public.get_my_org_id();
  uid    uuid := auth.uid();
  old    public.identity_decisions;
  new_id uuid;
  who    text;
BEGIN
  IF uid IS NULL OR org IS NULL OR NOT (public.has_permission('products.manage') OR public.has_permission('materials.manage')) THEN
    RAISE EXCEPTION 'Only master-data admins can correct decisions' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_evidence), '') IS NULL THEN
    RAISE EXCEPTION 'Say why the decision was wrong' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO old FROM public.identity_decisions WHERE id = p_id AND organization_id = org FOR UPDATE;
  IF NOT FOUND OR old.status <> 'active' THEN
    RAISE EXCEPTION 'Decision not found or no longer active' USING ERRCODE = '23514';
  END IF;
  who := coalesce((SELECT nullif(btrim(concat_ws(' ', first_name, last_name)), '') FROM public.profiles WHERE id = uid),
                  (SELECT email FROM public.profiles WHERE id = uid), 'a user');

  -- free the unique slot first, then link once the new row exists
  UPDATE public.identity_decisions SET status = 'revoked', status_note = 'being corrected' WHERE id = old.id;
  INSERT INTO public.identity_decisions
    (organization_id, subject_type, term, context, decision, product_id, material_id, color_id, category_id, supplier_id,
     evidence, source, decided_by, decided_by_label)
  VALUES
    (org, old.subject_type, old.term, old.context, coalesce(p_new->>'decision', old.decision),
     nullif(p_new->>'product_id', '')::uuid, nullif(p_new->>'material_id', '')::uuid, nullif(p_new->>'color_id', '')::uuid,
     nullif(p_new->>'category_id', '')::uuid, nullif(p_new->>'supplier_id', '')::uuid,
     btrim(p_evidence), 'review_queue', uid, who)
  RETURNING id INTO new_id;
  -- revoked → superseded: allowed by the history trigger only in a correction
  PERFORM set_config('mois.identity_correction', 'on', true);
  UPDATE public.identity_decisions SET status = 'superseded', superseded_by = new_id,
         status_note = 'corrected by ' || who || ': ' || btrim(p_evidence)
  WHERE id = old.id;
  PERFORM set_config('mois.identity_correction', 'off', true);
  RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_identity_decision(p_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  uid uuid := auth.uid();
  n   int;
BEGIN
  IF uid IS NULL OR org IS NULL OR NOT (public.has_permission('products.manage') OR public.has_permission('materials.manage')) THEN
    RAISE EXCEPTION 'Only master-data admins can revoke decisions' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Say why it is being withdrawn' USING ERRCODE = '23514';
  END IF;
  UPDATE public.identity_decisions SET status = 'revoked', status_note = btrim(p_reason)
  WHERE id = p_id AND organization_id = org AND status = 'active';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'Decision not found or no longer active' USING ERRCODE = '23514'; END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.correct_identity_decision(uuid, jsonb, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revoke_identity_decision(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_identity_decision(uuid, jsonb, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_identity_decision(uuid, text) TO authenticated;


-- ------------------------------------------------------------
-- import_aliases (024) → identity_decisions; batch posting records decisions
-- ------------------------------------------------------------
INSERT INTO public.identity_decisions
  (organization_id, subject_type, term, context, decision, product_id, color_id, category_id, evidence, source, decided_by, decided_by_label, decided_at)
SELECT a.organization_id, a.alias_type, a.alias_text, a.scope, 'same_as', a.product_id, a.color_id, a.category_id,
       'Chosen in a stock-sheet import (migrated from import_aliases)', 'import', a.created_by,
       coalesce((SELECT nullif(btrim(concat_ws(' ', first_name, last_name)), '') FROM public.profiles WHERE id = a.created_by), 'a user'),
       a.created_at
FROM public.import_aliases a;

DROP TABLE public.import_aliases;

-- p: { movements: [...], decisions: [{ subject_type, context, term, decision,
--      product_id | color_id | category_id, evidence }] }
CREATE OR REPLACE FUNCTION public.post_inventory_batch(p jsonb)
RETURNS uuid[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org uuid := public.get_my_org_id();
  uid uuid := auth.uid();
  mv  jsonb;
  d   jsonb;
  ids uuid[] := '{}';
  who text;
  cur public.identity_decisions;
  old_id uuid;
  new_id uuid;
BEGIN
  IF uid IS NULL OR org IS NULL THEN
    RAISE EXCEPTION 'Sign in to record stock movements' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p->'movements') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'movements') = 0 THEN
    RAISE EXCEPTION 'Nothing to post' USING ERRCODE = '23514';
  END IF;

  FOR mv IN SELECT * FROM jsonb_array_elements(p->'movements') LOOP
    ids := ids || public.post_inventory_movement(mv);
  END LOOP;

  who := coalesce((SELECT nullif(btrim(concat_ws(' ', first_name, last_name)), '') FROM public.profiles WHERE id = uid),
                  (SELECT email FROM public.profiles WHERE id = uid), 'a user');

  -- Answers given while resolving this import become standing decisions.
  -- A different answer for a term that already has one replaces it (the
  -- old row stays, superseded) — the poster saw the standing answer and chose otherwise.
  FOR d IN SELECT * FROM jsonb_array_elements(coalesce(p->'decisions', '[]'::jsonb)) LOOP
    old_id := NULL;
    SELECT * INTO cur FROM public.identity_decisions
    WHERE organization_id = org AND status = 'active' AND decision IN ('same_as', 'new_record', 'not_tracked')
      AND subject_type = d->>'subject_type'
      AND context_normalized = public.normalize_name(coalesce(d->>'context', ''))
      AND term_normalized = public.normalize_name(d->>'term');
    IF FOUND THEN
      IF (cur.decision, cur.product_id, cur.color_id, cur.category_id)
         IS NOT DISTINCT FROM (coalesce(d->>'decision', 'same_as'), nullif(d->>'product_id', '')::uuid,
                               nullif(d->>'color_id', '')::uuid, nullif(d->>'category_id', '')::uuid) THEN
        CONTINUE;   -- same answer already on record
      END IF;
      old_id := cur.id;
      UPDATE public.identity_decisions SET status = 'revoked', status_note = 'being replaced by an import' WHERE id = old_id;
    END IF;
    INSERT INTO public.identity_decisions
      (organization_id, subject_type, term, context, decision, product_id, color_id, category_id, evidence, source, decided_by, decided_by_label)
    VALUES
      (org, d->>'subject_type', btrim(d->>'term'), coalesce(d->>'context', ''), coalesce(d->>'decision', 'same_as'),
       nullif(d->>'product_id', '')::uuid, nullif(d->>'color_id', '')::uuid, nullif(d->>'category_id', '')::uuid,
       coalesce(nullif(btrim(d->>'evidence'), ''), 'Chosen while posting a stock-sheet import'), 'import', uid, who)
    RETURNING id INTO new_id;
    IF old_id IS NOT NULL THEN
      PERFORM set_config('mois.identity_correction', 'on', true);
      UPDATE public.identity_decisions SET status = 'superseded', superseded_by = new_id,
             status_note = 'replaced in an import by ' || who WHERE id = old_id;
      PERFORM set_config('mois.identity_correction', 'off', true);
    END IF;
  END LOOP;

  RETURN ids;
END;
$$;

REVOKE ALL ON FUNCTION public.post_inventory_batch(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_inventory_batch(jsonb) TO authenticated;
