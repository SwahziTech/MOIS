-- ============================================================
-- Migration 005: RLS helper functions
-- Must come AFTER profiles table exists.
-- NOTE: is_org_owner() is defined in migration 006 (after user_roles exists).
-- ============================================================

-- Returns the calling user's organization_id from their profile.
-- SECURITY DEFINER + STABLE so it's called once per query, not per row.
CREATE OR REPLACE FUNCTION public.get_my_org_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT organization_id FROM public.profiles WHERE id = auth.uid()
$$;

-- Returns true if the calling user belongs to the given org.
CREATE OR REPLACE FUNCTION public.is_member_of(org_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND organization_id = org_id
  )
$$;

COMMENT ON FUNCTION public.get_my_org_id()
  IS 'Returns current user org_id from profiles. Used in every tenant RLS policy.';
COMMENT ON FUNCTION public.is_member_of(uuid)
  IS 'True if current user belongs to the given org. Used in organizations RLS.';
