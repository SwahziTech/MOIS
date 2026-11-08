-- 111 (2026-11-08, the user): the day's list of sales in Record a sale is saved
-- at once — every sale, or none. Each item is recorded exactly as record_sale
-- records one sale (rules, prices, VAT box, payments). An error names the sale
-- ("Sale 2: …") so the form can show which one to fix.
-- SECURITY INVOKER: record_sale checks the caller's own rights for each sale.

CREATE OR REPLACE FUNCTION public.record_sales_day(p_sales jsonb)
RETURNS uuid[]
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  x   jsonb;
  i   int := 0;
  ids uuid[] := '{}';
BEGIN
  IF p_sales IS NULL OR jsonb_typeof(p_sales) <> 'array' OR jsonb_array_length(p_sales) = 0 THEN
    RAISE EXCEPTION 'The day''s list is empty' USING ERRCODE = '23514';
  END IF;
  IF jsonb_array_length(p_sales) > 200 THEN
    RAISE EXCEPTION 'Save at most 200 sales at once' USING ERRCODE = '23514';
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(p_sales) LOOP
    i := i + 1;
    BEGIN
      ids := ids || public.record_sale(x - 'id');
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Sale %: %', i, SQLERRM USING ERRCODE = SQLSTATE;
    END;
  END LOOP;
  RETURN ids;
END;
$$;
REVOKE ALL ON FUNCTION public.record_sales_day(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_sales_day(jsonb) TO authenticated;
