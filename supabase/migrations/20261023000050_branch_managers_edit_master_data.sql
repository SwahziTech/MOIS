-- ============================================================
-- 050 — Branch managers edit products and materials (1d)
--
-- SwahziTech, 2026-10-23: "enable branch managers to also edit materials
-- and products". Until now a branch manager could add products and keep
-- their branch's own materials, but changing a SHARED product or material
-- (name, size, wastani, unit, colours, conversions) needed an org-wide
-- grant. Now anyone holding products.manage / materials.manage at any
-- branch may change them. Every change stays in the audit log with who
-- made it.
--
-- Unchanged on purpose:
--   * making a branch's own material shared (all branches) stays org-admin
--     only (032: org admin can make shared, never reversed) — enforced by a
--     trigger, since a policy can't see the old row;
--   * merging products / settling product identity stays org-admin only;
--   * size specs, category colours and colour prices stay org-admin only.
-- ============================================================

-- Products: branch managers may change shared products (adding was already allowed, 031)
CREATE POLICY "products: branch managers edit" ON public.products FOR UPDATE
  USING      (organization_id = public.get_my_org_id() AND public.has_permission_anywhere('products.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_anywhere('products.manage'));

-- Materials: shared ones by anyone with materials.manage somewhere; a branch's own by that branch
DROP POLICY "materials: shared by org admins, own by the branch" ON public.materials;
CREATE POLICY "materials: shared by material managers, own by the branch" ON public.materials FOR ALL
  USING      (organization_id = public.get_my_org_id()
              AND CASE WHEN branch_id IS NULL THEN public.has_permission_anywhere('materials.manage')
                       ELSE public.has_permission_at('materials.manage', branch_id, NULL) END)
  WITH CHECK (organization_id = public.get_my_org_id()
              AND CASE WHEN branch_id IS NULL THEN public.has_permission_anywhere('materials.manage')
                       ELSE public.has_permission_at('materials.manage', branch_id, NULL) END);

-- ...but adding a shared material, or sharing a branch's own, stays with org admins
CREATE FUNCTION public.check_material_sharing()
RETURNS trigger LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  IF NEW.branch_id IS NULL AND (TG_OP = 'INSERT' OR OLD.branch_id IS NOT NULL)
     AND auth.uid() IS NOT NULL AND NOT public.has_permission('materials.manage') THEN
    RAISE EXCEPTION 'Only an organization admin can make a material shared by all branches' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_materials_sharing BEFORE INSERT OR UPDATE OF branch_id ON public.materials
  FOR EACH ROW EXECUTE FUNCTION public.check_material_sharing();

DROP POLICY "muc: whoever manages the material" ON public.material_unit_conversions;
CREATE POLICY "muc: whoever manages the material" ON public.material_unit_conversions FOR ALL
  USING (organization_id = public.get_my_org_id() AND EXISTS (
           SELECT 1 FROM public.materials m WHERE m.id = material_id
             AND CASE WHEN m.branch_id IS NULL THEN public.has_permission_anywhere('materials.manage')
                      ELSE public.has_permission_at('materials.manage', m.branch_id, NULL) END))
  WITH CHECK (organization_id = public.get_my_org_id() AND EXISTS (
           SELECT 1 FROM public.materials m WHERE m.id = material_id
             AND CASE WHEN m.branch_id IS NULL THEN public.has_permission_anywhere('materials.manage')
                      ELSE public.has_permission_at('materials.manage', m.branch_id, NULL) END));

-- Product colours: the same people (046 had org admins only; stock moves still need inventory.adjust at each store)
CREATE OR REPLACE FUNCTION public.set_product_colors(p_product uuid, p_own boolean, p_color_ids uuid[] DEFAULT '{}', p_move_to text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org      uuid := public.get_my_org_id();
  uid      uuid := auth.uid();
  prod     public.products;
  new_ids  uuid[];
  tcol     uuid;
  r        record;
  stranded text := '';
  movs     jsonb := '{}';
  mov      uuid;
  today    date;
  wh_label text;
  fname    text;
  tname    text;
BEGIN
  IF uid IS NULL OR org IS NULL THEN
    RAISE EXCEPTION 'Sign in to change products' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO prod FROM public.products WHERE id = p_product AND organization_id = org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Product not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_anywhere('products.manage') THEN
    RAISE EXCEPTION 'Only a branch manager or an admin can change a product''s colours' USING ERRCODE = '42501';
  END IF;

  IF p_own THEN
    IF EXISTS (SELECT 1 FROM unnest(coalesce(p_color_ids, '{}')) c
               WHERE NOT EXISTS (SELECT 1 FROM public.color_palette cp WHERE cp.id = c AND cp.organization_id = org)) THEN
      RAISE EXCEPTION 'Colour not found' USING ERRCODE = '23514';
    END IF;
    new_ids := ARRAY(SELECT c FROM unnest(coalesce(p_color_ids, '{}')) WITH ORDINALITY u(c, o) GROUP BY c ORDER BY min(o));
  ELSE
    new_ids := ARRAY(SELECT color_id FROM public.product_category_colors WHERE category_id = prod.category_id ORDER BY display_order);
  END IF;

  -- a batch still curing in a colour that goes away can't be released into it
  SELECT b.batch_date, cp.name AS cname INTO r
    FROM public.production_batch_outputs o
    JOIN public.production_batches b ON b.id = o.batch_id
    LEFT JOIN public.color_palette cp ON cp.id = o.color_id
   WHERE o.product_id = prod.id AND b.status = 'curing'
     AND (CASE WHEN cardinality(new_ids) = 0 THEN o.color_id IS NOT NULL
               ELSE o.color_id IS NULL OR NOT o.color_id = ANY (new_ids) END)
   ORDER BY b.batch_date LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION '% has a batch still curing in % (cast %) — release or void it first',
      prod.canonical_name, coalesce(r.cname, 'no colour'), to_char(r.batch_date, 'DD Mon YYYY') USING ERRCODE = '23514';
  END IF;

  -- where stock in a colour being switched off goes
  IF p_move_to IS NOT NULL THEN
    IF cardinality(new_ids) = 0 THEN
      IF p_move_to <> 'none' THEN RAISE EXCEPTION 'With no colours, the stock can only move to no colour' USING ERRCODE = '23514'; END IF;
      tcol := NULL;
    ELSE
      tcol := nullif(p_move_to, 'none')::uuid;
      IF tcol IS NULL OR NOT tcol = ANY (new_ids) THEN
        RAISE EXCEPTION 'Choose one of the colours being kept for the stock' USING ERRCODE = '23514';
      END IF;
    END IF;
  END IF;

  today := public.org_today(org);
  PERFORM set_config('mois.product_colors', 'on', true);

  FOR r IN
    SELECT sb.warehouse_id, sb.color_id, sb.quantity, w.branch_id, w.name AS wname, b.name AS bname, cp.name AS cname
      FROM public.stock_balances sb
      JOIN public.warehouses w ON w.id = sb.warehouse_id
      JOIN public.branches b ON b.id = w.branch_id
      LEFT JOIN public.color_palette cp ON cp.id = sb.color_id
     WHERE sb.product_id = prod.id AND sb.quantity <> 0
       AND (CASE WHEN cardinality(new_ids) = 0 THEN sb.color_id IS NOT NULL
                 ELSE sb.color_id IS NULL OR NOT sb.color_id = ANY (new_ids) END)
     ORDER BY b.name, w.name, cp.name
  LOOP
    wh_label := r.bname || ' — ' || r.wname;
    IF p_move_to IS NULL THEN
      stranded := stranded || CASE WHEN stranded = '' THEN '' ELSE '; ' END
        || trim(to_char(r.quantity, 'FM999,999,999,990.##'), '.') || ' ' || coalesce(r.cname, 'with no colour') || ' at ' || wh_label;
      CONTINUE;
    END IF;
    IF r.quantity < 0 THEN
      RAISE EXCEPTION '% % at % is below zero — correct the count first', prod.canonical_name, coalesce(r.cname, ''), wh_label USING ERRCODE = '23514';
    END IF;
    IF NOT public.has_permission_at('inventory.adjust', r.branch_id, r.warehouse_id) THEN
      RAISE EXCEPTION 'You don''t have permission to move stock at %', wh_label USING ERRCODE = '42501';
    END IF;
    fname := prod.canonical_name || coalesce(' ' || r.cname, '');
    tname := prod.canonical_name || coalesce(' ' || (SELECT name FROM public.color_palette WHERE id = tcol), '');
    PERFORM public.inventory_lock_item(r.warehouse_id, NULL, prod.id, r.color_id);
    PERFORM public.inventory_lock_item(r.warehouse_id, NULL, prod.id, tcol);
    PERFORM public.inventory_check_after_opening(r.warehouse_id, NULL, prod.id, tcol, today, tname, wh_label);
    PERFORM public.inventory_check_outflow(r.warehouse_id, NULL, prod.id, r.color_id, today, -r.quantity, fname, wh_label);

    mov := nullif(movs->>r.warehouse_id::text, '')::uuid;
    IF mov IS NULL THEN
      INSERT INTO public.inventory_movements (organization_id, movement_type, branch_id, warehouse_id, movement_date, reason, created_by)
      VALUES (org, 'reclassification', r.branch_id, r.warehouse_id, today,
              prod.canonical_name || ': colours changed — stock moved to ' || coalesce((SELECT name FROM public.color_palette WHERE id = tcol), 'no colour'), uid)
      RETURNING id INTO mov;
      movs := movs || jsonb_build_object(r.warehouse_id::text, mov);
    END IF;
    INSERT INTO public.inventory_transactions
      (organization_id, movement_id, transaction_type, branch_id, warehouse_id, product_id, color_id,
       quantity, stock_unit_id, entered_quantity, entered_unit_id, transaction_date, created_by)
    VALUES
      (org, mov, 'reclassification', r.branch_id, r.warehouse_id, prod.id, r.color_id, -r.quantity, prod.unit_id, r.quantity, prod.unit_id, today, uid),
      (org, mov, 'reclassification', r.branch_id, r.warehouse_id, prod.id, tcol,        r.quantity, prod.unit_id, r.quantity, prod.unit_id, today, uid);
  END LOOP;

  IF stranded <> '' THEN
    RAISE EXCEPTION '% has stock that won''t match its new colours: % — choose where that stock goes', prod.canonical_name, stranded
      USING ERRCODE = '23514', HINT = 'move_stock';
  END IF;

  UPDATE public.products SET own_colors = p_own WHERE id = prod.id AND own_colors IS DISTINCT FROM p_own;
  DELETE FROM public.product_colors WHERE product_id = prod.id;
  IF p_own THEN
    INSERT INTO public.product_colors (organization_id, product_id, color_id, display_order)
    SELECT org, prod.id, c, o FROM unnest(new_ids) WITH ORDINALITY u(c, o);
  END IF;
END;
$$;
