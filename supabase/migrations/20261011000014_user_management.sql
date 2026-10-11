-- ============================================================
-- Migration 014: User management support (Phase 1a)
--
-- - profiles.email (PRD §6.4) so admins can see who a user is, incl.
--   invited users who have not set a name yet
-- - signup trigger understands Google OAuth metadata (full_name, avatar)
-- - deactivated users lose ALL tenant access: get_my_org_id() and
--   is_member_of() only resolve for status = 'active', so every RLS policy
--   returns nothing for them even while an old JWT is still valid
-- ============================================================


-- ------------------------------------------------------------
-- 1. profiles.email — copy of auth.users.email, maintained by triggers
-- ------------------------------------------------------------
ALTER TABLE public.profiles ADD COLUMN email text;

UPDATE public.profiles p
SET email = u.email
FROM auth.users u
WHERE u.id = p.id;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  meta      jsonb := COALESCE(NEW.raw_user_meta_data, '{}'::jsonb);
  full_name text  := NULLIF(trim(COALESCE(meta->>'full_name', meta->>'name', '')), '');
BEGIN
  INSERT INTO public.profiles (id, email, first_name, last_name, avatar_url)
  VALUES (
    NEW.id,
    NEW.email,
    -- email signup sends first_name/last_name; Google sends full_name/name
    COALESCE(NULLIF(meta->>'first_name', ''), split_part(full_name, ' ', 1), ''),
    COALESCE(NULLIF(meta->>'last_name', ''),
             NULLIF(trim(substr(full_name, length(split_part(full_name, ' ', 1)) + 1)), ''), ''),
    NULLIF(meta->>'avatar_url', '')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_user_email_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.profiles SET email = NEW.email WHERE id = NEW.id;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_email_changed
  AFTER UPDATE OF email ON auth.users
  FOR EACH ROW
  WHEN (OLD.email IS DISTINCT FROM NEW.email)
  EXECUTE FUNCTION public.handle_user_email_change();

-- email is a mirror of auth.users — clients may not edit it
CREATE OR REPLACE FUNCTION public.protect_profile_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- service_role (seed / Edge Functions) and direct SQL (no JWT) are trusted
  IF auth.role() = 'service_role' OR auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
    RAISE EXCEPTION 'Organization membership cannot be changed from the client'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'Account status cannot be changed from the client'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.email IS DISTINCT FROM OLD.email THEN
    RAISE EXCEPTION 'Email is managed by authentication, not the profile'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP POLICY "profiles: insert own on signup" ON public.profiles;
CREATE POLICY "profiles: insert own on signup"
  ON public.profiles FOR INSERT
  WITH CHECK (id = auth.uid() AND organization_id IS NULL AND status = 'active' AND email IS NULL);


-- ------------------------------------------------------------
-- 2. Deactivated users resolve to no organization
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_org_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT organization_id FROM public.profiles
  WHERE id = auth.uid() AND status = 'active'
$$;

CREATE OR REPLACE FUNCTION public.is_member_of(org_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND organization_id = org_id AND status = 'active'
  )
$$;

COMMENT ON FUNCTION public.get_my_org_id()
  IS 'Caller org_id from profiles, only while the profile is active. Used in every tenant RLS policy.';
