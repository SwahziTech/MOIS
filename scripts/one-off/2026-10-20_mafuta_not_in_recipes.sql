-- One-off (run once after migration 043; never re-run). SwahziTech, 2026-10-20:
-- Mafuta (mould oil) is not a mix ingredient — keep it out of recipes and batches.
UPDATE public.material_categories
SET used_in_recipes = false
WHERE organization_id = (SELECT id FROM public.organizations WHERE name = 'Stumarcot')
  AND name = 'Mafuta/oil';
