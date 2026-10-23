-- One-off (run once). SwahziTech, 2026-10-23:
-- "Use these exact units: 'Pipa' on display, known in its details as a 200 L
-- barrel; for Rangi 'Bag/s' on display, detailed as a 25 kg bag."
-- Renames the two units in place (the symbol is what screens show, the name
-- is the detail). Every stock entry, conversion and main unit keeps pointing
-- at the same unit, so nothing else changes. Only Dawa uses the barrel and
-- only Rangi Black / Red use the 25 kg bag.
UPDATE public.units u SET symbol = 'Pipa', name = 'Pipa — 200 L barrel'
  FROM public.organizations o WHERE o.id = u.organization_id AND o.name = 'Stumarcot' AND u.symbol = '200L barrel';
UPDATE public.units u SET symbol = 'Bag/s', name = 'Bag — 25 kg'
  FROM public.organizations o WHERE o.id = u.organization_id AND o.name = 'Stumarcot' AND u.symbol = '25kg bag';

SELECT symbol, name FROM public.units WHERE symbol IN ('Pipa', 'Bag/s');
