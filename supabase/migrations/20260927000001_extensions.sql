-- ============================================================
-- Migration 001: Extensions & shared utilities
-- NOTE: gen_random_uuid() is used everywhere (built-in PG14+, no extension needed).
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- for future fuzzy search on names

-- Shared trigger function: auto-set updated_at on row change
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;
