-- ============================================================
-- 027 — Import placeholders (1b)
--
-- Standing import rule (2026-10-14): a stock-sheet line that can't be
-- confidently matched to one existing product never blocks the import and
-- is never guessed onto a product. The import creates a PLACEHOLDER product
-- named exactly as the sheet writes it, posts the stock against it, and
-- puts a plain-language "needs review" flag in the Review queue naming the
-- likely real products, so the business admin can resolve it later.
--
-- post_inventory_batch() gains `placeholders`; movement lines refer to one
-- by "placeholder_key". Everything — placeholders, flags, decisions,
-- movements — happens in one transaction: all or nothing.
-- ============================================================

-- p: { placeholders: [{ key, name, category_id, unit_id, context, candidate_product_ids: [...], why }],
--      movements:    [<post_inventory_movement payload; a line may use placeholder_key instead of product_id>],
--      decisions:    [{ subject_type, context, term, decision, product_id | color_id | category_id, evidence }] }
CREATE OR REPLACE FUNCTION public.post_inventory_batch(p jsonb)
RETURNS uuid[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org     uuid := public.get_my_org_id();
  uid     uuid := auth.uid();
  mv      jsonb;
  d       jsonb;
  ph      jsonb;
  ids     uuid[] := '{}';
  who     text;
  cur     public.identity_decisions;
  old_id  uuid;
  new_id  uuid;
  keys    jsonb := '{}';
  cat     public.product_categories;
  pid     uuid;
  ref     text;
  n       int;
  options text;
  clash   text;
BEGIN
  IF uid IS NULL OR org IS NULL THEN
    RAISE EXCEPTION 'Sign in to record stock movements' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p->'movements') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'movements') = 0 THEN
    RAISE EXCEPTION 'Nothing to post' USING ERRCODE = '23514';
  END IF;
  who := coalesce((SELECT nullif(btrim(concat_ws(' ', first_name, last_name)), '') FROM public.profiles WHERE id = uid),
                  (SELECT email FROM public.profiles WHERE id = uid), 'a user');

  -- 1. Placeholders
  FOR ph IN SELECT * FROM jsonb_array_elements(coalesce(p->'placeholders', '[]'::jsonb)) LOOP
    IF NOT public.has_permission_anywhere('inventory.adjust') THEN
      RAISE EXCEPTION 'You don''t have permission to add products from an import' USING ERRCODE = '42501';
    END IF;
    IF nullif(btrim(ph->>'name'), '') IS NULL OR nullif(ph->>'key', '') IS NULL THEN
      RAISE EXCEPTION 'A placeholder needs the sheet''s name for it' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO cat FROM public.product_categories WHERE id = (ph->>'category_id')::uuid AND organization_id = org;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Choose a category for "%"', ph->>'name' USING ERRCODE = '23514';
    END IF;
    SELECT canonical_name INTO clash FROM public.products
    WHERE organization_id = org AND category_id = cat.id AND status = 'active'
      AND public.normalize_name(canonical_name) = public.normalize_name(ph->>'name');
    IF FOUND THEN
      RAISE EXCEPTION '"%" already exists in % — match the line to it instead', clash, cat.name USING ERRCODE = '23505';
    END IF;

    ref := cat.category_id_ref || '_' || trim(both '_' FROM regexp_replace(lower(ph->>'name'), '[^a-z0-9]+', '_', 'g'));
    n := 1;
    WHILE EXISTS (SELECT 1 FROM public.products WHERE organization_id = org AND product_id_ref = ref || CASE WHEN n = 1 THEN '' ELSE '_' || n END) LOOP
      n := n + 1;
    END LOOP;
    ref := ref || CASE WHEN n = 1 THEN '' ELSE '_' || n END;

    SELECT string_agg(pr.canonical_name, ' or ' ORDER BY pr.canonical_name) INTO options
    FROM public.products pr
    WHERE pr.organization_id = org
      AND pr.id IN (SELECT value::uuid FROM jsonb_array_elements_text(coalesce(ph->'candidate_product_ids', '[]'::jsonb)));

    INSERT INTO public.products (organization_id, category_id, product_id_ref, canonical_name, unit_id, status, notes)
    VALUES (org, cat.id, ref, btrim(ph->>'name'), (ph->>'unit_id')::uuid, 'active',
            'Placeholder added by a stock-sheet import (' || to_char(now(), 'YYYY-MM-DD') || '): the sheet''s name couldn''t be matched to one product'
            || coalesce('; it is probably ' || options, '') || '. Stock is recorded here until someone chooses the real product.')
    RETURNING id INTO pid;

    INSERT INTO public.review_flags (organization_id, entity_type, entity_id, reason_code, reason, created_by)
    VALUES (org, 'product', pid::text, 'import_placeholder',
            'A stock sheet listed "' || btrim(ph->>'name') || '", and MOIS couldn''t tell which product that is'
            || coalesce(' — it could be ' || options, '') || '. '
            || coalesce(nullif(btrim(ph->>'why'), '') || ' ', '')
            || 'Its stock was recorded under a temporary product with that name, so nothing is lost. '
            || 'Choose the real product' || CASE WHEN options IS NOT NULL THEN ' (or split the stock between them)' ELSE '' END
            || ', or keep it as a new product.', uid);

    INSERT INTO public.identity_decisions
      (organization_id, subject_type, term, context, decision, product_id, evidence, source, decided_by, decided_by_label)
    VALUES (org, 'product', btrim(ph->>'name'), coalesce(ph->>'context', ''), 'new_record', pid,
            'Placeholder: an import couldn''t match this name to one product' || coalesce(' (possibly ' || options || ')', '')
            || '. Replace this answer once the real product is chosen.', 'import', uid, who);

    keys := keys || jsonb_build_object(ph->>'key', pid);
  END LOOP;

  -- 2. Movements (placeholder_key → the new product)
  FOR mv IN SELECT * FROM jsonb_array_elements(p->'movements') LOOP
    IF jsonb_typeof(mv->'lines') = 'array' THEN
      SELECT jsonb_set(mv, '{lines}', coalesce(jsonb_agg(
               CASE WHEN l ? 'placeholder_key'
                    THEN (l - 'placeholder_key') || jsonb_build_object('product_id',
                           coalesce(keys->>(l->>'placeholder_key'), 'missing-placeholder'))
                    ELSE l END ORDER BY o), '[]'::jsonb))
      INTO mv
      FROM jsonb_array_elements(mv->'lines') WITH ORDINALITY AS x(l, o);
    END IF;
    ids := ids || public.post_inventory_movement(mv);
  END LOOP;

  -- 3. Answers given while resolving the import become standing decisions.
  -- A different answer for a term that already has one replaces it (the old
  -- row stays, superseded): the poster saw the standing answer and chose otherwise.
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
        CONTINUE;
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
