-- ============================================================
-- 030 — Default branch for an organization's screens (1b)
--
-- Admins see every branch; screens scope to one branch at a time (with an
-- "All branches" option). Which branch they open on is the organization's
-- own setting, not code: a tenant rolling MOIS out branch by branch points
-- it at the branch being verified first. NULL = open on "All branches".
-- ============================================================

ALTER TABLE public.organizations
  ADD COLUMN default_branch_id uuid REFERENCES public.branches(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.organizations.default_branch_id
  IS 'Branch the app''s branch selector starts on. NULL = all branches. Must be one of this organization''s branches.';

CREATE OR REPLACE FUNCTION public.check_org_default_branch()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.default_branch_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.branches WHERE id = NEW.default_branch_id AND organization_id = NEW.id) THEN
    RAISE EXCEPTION 'The default branch must be one of this organization''s branches' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_organizations_default_branch
  BEFORE INSERT OR UPDATE OF default_branch_id ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION public.check_org_default_branch();
