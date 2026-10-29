-- ============================================================
-- 093 — Team members: add, deactivate, remove (HR › Staff › Teams › Edit)
-- ============================================================
-- SwahziTech, 2026-10-30: a team's Edit adds, deactivates and removes
-- members. Deactivated = still in the team, off for now ('inactive');
-- removed = taken out of the team ('removed', hidden). Rows are never deleted
-- (056 keeps them; the audit trail stays). Adding someone again brings their
-- row back to active. Members are a list to pick from on a batch; nobody is
-- ticked automatically (who worked is chosen on each batch).
-- ============================================================

ALTER TABLE public.production_team_members DROP CONSTRAINT IF EXISTS production_team_members_status_check;
ALTER TABLE public.production_team_members ADD CONSTRAINT production_team_members_status_check
  CHECK (status IN ('active', 'inactive', 'removed'));

-- one row per person in a team (adding again reuses it)
CREATE UNIQUE INDEX IF NOT EXISTS uq_production_team_members_staff ON public.production_team_members (team_id, staff_id) WHERE staff_id IS NOT NULL;
