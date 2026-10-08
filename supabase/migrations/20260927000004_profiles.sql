-- ============================================================
-- Migration 004: Profiles
-- Extends auth.users. id = auth.users.id (1:1).
-- organization_id links the user to their tenant.
-- ============================================================

CREATE TABLE public.profiles (
  id              uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  organization_id uuid REFERENCES public.organizations(id) ON DELETE SET NULL,
  first_name      text NOT NULL DEFAULT '',
  last_name       text NOT NULL DEFAULT '',
  phone           text,
  avatar_url      text,
  status          text NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'inactive')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_profiles_org ON public.profiles(organization_id);

CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.profiles
  IS 'One row per Supabase Auth user. organization_id links the user to their tenant.';

-- ----------------------------------------------------------------
-- Trigger: auto-create a profile row when a new user signs up.
-- Reads first_name / last_name from raw_user_meta_data if provided
-- (e.g. passed during signUp({ data: { first_name, last_name } })).
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, first_name, last_name)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'first_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'last_name', '')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ----------------------------------------------------------------
-- Back-fill foreign key constraints on branches/warehouses
-- that reference auth.users (created_by / updated_by).
-- These could not be added in migration 003 before profiles existed.
-- We reference auth.users directly (not profiles) so cascade works.
-- ----------------------------------------------------------------
ALTER TABLE public.branches
  ADD CONSTRAINT fk_branches_created_by FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD CONSTRAINT fk_branches_updated_by FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.warehouses
  ADD CONSTRAINT fk_warehouses_created_by FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD CONSTRAINT fk_warehouses_updated_by FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;
