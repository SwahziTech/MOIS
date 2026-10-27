-- ============================================================
-- 075 — Technical-admin settings and a product's yield per bag (1e)
--
-- SwahziTech, 2026-10-27: a benchmark seen only by the Technical admin
-- (system.manage). Its figure is entered in the app and kept in this table,
-- which no other role can read. The yield per cement bag in the product's own
-- unit (m² or pieces) feeds it.
-- ============================================================

CREATE TABLE public.tech_admin_settings (
  organization_id        uuid PRIMARY KEY REFERENCES public.organizations(id) ON DELETE CASCADE,
  revenue_per_bag_target numeric CHECK (revenue_per_bag_target >= 0),
  updated_by             uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at             timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_tech_admin_settings_updated_at BEFORE UPDATE ON public.tech_admin_settings FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
ALTER TABLE public.tech_admin_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "tech_admin_settings: technical admin reads" ON public.tech_admin_settings FOR SELECT
  USING (organization_id = public.get_my_org_id() AND public.has_permission('system.manage'));
CREATE POLICY "tech_admin_settings: technical admin adds" ON public.tech_admin_settings FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('system.manage'));
CREATE POLICY "tech_admin_settings: technical admin changes" ON public.tech_admin_settings FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND public.has_permission('system.manage'))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission('system.manage'));

-- A product's average yield per cement bag at a branch, in its stock unit:
-- pieces for PCS products, m² (pieces ÷ pieces per m²) for SQM products
CREATE FUNCTION public.product_yield_per_unit(p_branch_id uuid)
RETURNS TABLE (product_id uuid, pieces_per_bag numeric, units_per_bag numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT ps.product_id, y.avg_y,
         CASE WHEN upper(u.symbol) = 'SQM' THEN CASE WHEN ps.pcs_per_sqm > 0 THEN y.avg_y / ps.pcs_per_sqm END ELSE y.avg_y END
    FROM public.product_specs ps
    JOIN public.products p ON p.id = ps.product_id AND p.organization_id = public.get_my_org_id()
    LEFT JOIN public.units u ON u.id = p.unit_id
    CROSS JOIN LATERAL (SELECT coalesce(o.average_yield_per_bag, ps.average_yield_per_bag) AS avg_y
                          FROM (SELECT 1) one
                          LEFT JOIN public.branch_yield_overrides o ON o.spec_id = ps.spec_id AND o.branch_id = p_branch_id) y
   WHERE y.avg_y > 0
$$;
REVOKE ALL ON FUNCTION public.product_yield_per_unit(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.product_yield_per_unit(uuid) TO authenticated;
