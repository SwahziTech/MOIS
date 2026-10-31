-- ============================================================
-- 100 — Invitations and username sign-in
-- ============================================================
-- SwahziTech, 2026-10-31, the user: some people sign in by email, some by a
-- username, and everyone creates their own login. The Technical admin, or a
-- Branch Manager for their own branch, makes an invitation (a link and a short
-- code, 48 hours, one use) that fixes the company, role and branch; the person
-- then chooses email or username and their password. Nobody else knows it.
-- A username user who forgets their password gets a one-time reset link from
-- the Technical admin or their Branch Manager.
--   * profiles.username — unique across all of MOIS, so the sign-in screen
--     needs no company. Supabase Auth still needs an email, so a username
--     account has a hidden address nobody sees (manage-users, lib/authId.js).
--   * user_invitations — only hashes of the link and code are kept. The
--     manage-users function (service role) makes and claims them; people who
--     can invite read them here, without the hashes.
--   * invitation_attempts — wrong codes by source, to slow down guessing.
-- ============================================================

ALTER TABLE public.profiles ADD COLUMN username text
  CHECK (username IS NULL OR username ~ '^[a-z0-9][a-z0-9._-]{2,29}$');
CREATE UNIQUE INDEX uq_profiles_username ON public.profiles (username) WHERE username IS NOT NULL;
COMMENT ON COLUMN public.profiles.username IS 'Lower case, unique across all of MOIS; set when a person chooses to sign in by username (100).';

CREATE TABLE public.user_invitations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id),
  kind            text NOT NULL DEFAULT 'invite' CHECK (kind IN ('invite', 'reset')),
  first_name      text NOT NULL DEFAULT '',
  last_name       text NOT NULL DEFAULT '',
  role_id         uuid REFERENCES public.roles(id),
  branch_id       uuid REFERENCES public.branches(id),
  warehouse_id    uuid REFERENCES public.warehouses(id),
  target_user_id  uuid REFERENCES public.profiles(id),      -- reset: whose password
  token_hash      text NOT NULL UNIQUE,
  code_hash       text NOT NULL UNIQUE,
  expires_at      timestamptz NOT NULL DEFAULT now() + interval '48 hours',
  status          text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'claimed', 'cancelled')),
  claimed_by      uuid REFERENCES public.profiles(id),
  claimed_at      timestamptz,
  created_by      uuid REFERENCES public.profiles(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK ((kind = 'invite' AND role_id IS NOT NULL) OR (kind = 'reset' AND target_user_id IS NOT NULL))
);
CREATE INDEX idx_user_invitations_org ON public.user_invitations (organization_id, created_at DESC);
COMMENT ON TABLE public.user_invitations IS 'One-time invitations and password reset links; link and code kept only as hashes (100).';

ALTER TABLE public.user_invitations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "user_invitations: read by who can invite" ON public.user_invitations FOR SELECT TO authenticated
  USING (organization_id = public.get_my_org_id() AND (
    public.has_permission('users.invite') OR (branch_id IS NOT NULL AND public.has_permission_at('users.invite', branch_id, NULL))));
REVOKE ALL ON public.user_invitations FROM PUBLIC, anon, authenticated;
GRANT SELECT (id, organization_id, kind, first_name, last_name, role_id, branch_id, warehouse_id, target_user_id, expires_at, status, claimed_by, claimed_at, created_by, created_at)
  ON public.user_invitations TO authenticated;

CREATE TABLE public.invitation_attempts (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source     text NOT NULL,      -- a hash of where the request came from
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_invitation_attempts ON public.invitation_attempts (source, created_at DESC);
ALTER TABLE public.invitation_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.invitation_attempts FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.invitation_attempts IS 'Wrong invitation codes by source, to slow down guessing; service role only (100).';

-- Branch Managers can invite; the function and policy above keep them to their branch
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON p.code = 'users.invite'
WHERE r.name = 'branch_manager'
ON CONFLICT DO NOTHING;
