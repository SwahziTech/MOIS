-- One-off (run once, after 054). SwahziTech, 2026-10-24: Stumarcot's batches cure at least 7 days.
UPDATE public.organizations SET min_curing_days = 7 WHERE name = 'Stumarcot';
SELECT name, curing_days, min_curing_days FROM public.organizations WHERE name = 'Stumarcot';
