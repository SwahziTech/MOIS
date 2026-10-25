-- ============================================================
-- 063 — A price follows its product's unit (1e)
--
-- SwahziTech, 2026-10-25, the user: "if a product unit price is set in sqm
-- use sqm, if it is set in pcs use pcs throughout. That's why there is
-- product edit/settings in the first place." The product's unit (Products,
-- unit of measure) decides: a product counted in m² is priced per m², any
-- other per piece. 062 guarded the piece side; this guards both. (No m²
-- product was priced per piece only, so no price changes.)
-- A price per piece may still be kept beside an m² price — it is worked out
-- from it (pieces per m²), never entered instead of it.
-- ============================================================

CREATE OR REPLACE FUNCTION public.check_price_per_piece()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  sqm  boolean;
  name text;
BEGIN
  SELECT upper(u.symbol) = 'SQM', p.canonical_name INTO sqm, name
    FROM public.products p JOIN public.units u ON u.id = p.unit_id WHERE p.id = NEW.product_id;
  IF NOT sqm AND NEW.price_per_sqm_inclusive IS NOT NULL THEN
    RAISE EXCEPTION '% is counted in pieces — give its price per piece, not per m²', name USING ERRCODE = '23514';
  END IF;
  IF sqm AND NEW.price_per_sqm_inclusive IS NULL AND NEW.price_per_unit_inclusive IS NOT NULL THEN
    RAISE EXCEPTION '% is counted in m² — give its price per m², not per piece', name USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
