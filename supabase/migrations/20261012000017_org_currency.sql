-- ============================================================
-- Migration 017: Organization currency
--
-- The Pricing screen hardcoded 'TZS'. Currency is an organization setting
-- (PRD §10.14: currency must be configurable). ISO 4217 code, no default —
-- each tenant sets its own (Stumarcot's is set by its seed, as tenant data).
-- ============================================================

ALTER TABLE public.organizations
  ADD COLUMN currency_code text CHECK (currency_code ~ '^[A-Z]{3}$');

COMMENT ON COLUMN public.organizations.currency_code
  IS 'ISO 4217 currency code used to display this organization''s prices (e.g. TZS). Org setting, not hardcoded.';
