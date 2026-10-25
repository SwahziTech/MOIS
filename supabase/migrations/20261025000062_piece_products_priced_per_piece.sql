-- ============================================================
-- 062 — Products not counted in m² are priced per piece (1e)
--
-- SwahziTech, 2026-10-25, the user: "for products without sqm always use
-- pcs, not price/m2 — throughout the app". A price per m² is only for a
-- product whose stock unit is m² (SQM); anything else is priced per piece.
--   * a guard refuses a price per m² on a product not counted in m²;
--   * prices already entered per m² on such a product become its price per
--     piece: per m² ÷ pieces per m² when that was given, else the figure
--     itself (it was typed as the product's price — e.g. 50 Matundu 6,
--     11,500, entered 2026-10-25 with the window's per-m² default); the
--     figures without VAT follow the price's own VAT rate (061), else the
--     branch's.
-- ============================================================

CREATE FUNCTION public.check_price_per_piece()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.price_per_sqm_inclusive IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.products p JOIN public.units u ON u.id = p.unit_id WHERE p.id = NEW.product_id AND upper(u.symbol) = 'SQM') THEN
    RAISE EXCEPTION '% is counted in pieces — give its price per piece, not per m²',
      (SELECT canonical_name FROM public.products WHERE id = NEW.product_id) USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

-- existing per-m² prices on piece products → per piece (before the guard)
UPDATE public.product_branch_pricing x SET
       price_per_unit_inclusive = round(coalesce(x.price_per_unit_inclusive,
                                    CASE WHEN x.pcs_per_sqm_at_pricing > 0 THEN x.price_per_sqm_inclusive / x.pcs_per_sqm_at_pricing ELSE x.price_per_sqm_inclusive END), 2),
       price_per_sqm_inclusive = NULL,
       pcs_per_sqm_at_pricing = NULL
  FROM public.products p JOIN public.units u ON u.id = p.unit_id
 WHERE p.id = x.product_id AND upper(u.symbol) <> 'SQM' AND x.price_per_sqm_inclusive IS NOT NULL;
UPDATE public.product_branch_pricing x SET
       price_per_unit_exclusive = round(x.price_per_unit_inclusive / (1 + coalesce(x.vat_rate, b.vat_rate, 0) / 100), 2),
       vat_per_unit = round(x.price_per_unit_inclusive - x.price_per_unit_inclusive / (1 + coalesce(x.vat_rate, b.vat_rate, 0) / 100), 2),
       vat_rate = coalesce(x.vat_rate, b.vat_rate)
  FROM public.branches b, public.products p JOIN public.units u ON u.id = p.unit_id
 WHERE b.id = x.branch_id AND p.id = x.product_id AND upper(u.symbol) <> 'SQM'
   AND x.price_per_unit_inclusive IS NOT NULL AND x.price_per_unit_exclusive IS NULL;

CREATE TRIGGER trg_price_per_piece BEFORE INSERT OR UPDATE ON public.product_branch_pricing
  FOR EACH ROW EXECUTE FUNCTION public.check_price_per_piece();
