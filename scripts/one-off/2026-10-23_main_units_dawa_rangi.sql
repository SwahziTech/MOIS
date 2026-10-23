-- One-off (run once, after migration 051). SwahziTech, 2026-10-23:
-- "In stock counting, dawa's main unit should be pipa/barrels; rangi's main
-- units should be bags (25 kg each)." Sets the main unit only — the stock
-- unit (L, kg), the ledger and the recipes are unchanged.
UPDATE public.materials m SET main_unit_id = u.id
  FROM public.units u, public.organizations o
 WHERE o.id = m.organization_id AND o.name = 'Stumarcot'
   AND ((m.name = 'Dawa' AND u.symbol = '200L barrel')
     OR (m.name IN ('Rangi Black', 'Rangi Red') AND u.symbol = '25kg bag'))
   AND EXISTS (SELECT 1 FROM public.material_unit_conversions c WHERE c.material_id = m.id AND c.unit_id = u.id);

SELECT m.name, u.symbol AS main_unit FROM public.materials m JOIN public.units u ON u.id = m.main_unit_id ORDER BY 1;
