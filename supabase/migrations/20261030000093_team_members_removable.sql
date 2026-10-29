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

-- ------------------------------------------------------------
-- A recorded batch keeps its team and people as they were (SwahziTech, 2026-10-30):
-- editing a team — new team, rename, members added/deactivated/removed — is
-- for the current and future days; a batch already recorded never changes.
-- The team's name and the names of the people who worked are stored on the
-- batch when it is recorded, so a later rename doesn't rewrite history.
-- ------------------------------------------------------------
ALTER TABLE public.production_batches
  ADD COLUMN team_name    text,     -- the team's name when the batch was recorded
  ADD COLUMN worker_names text[];   -- the names of the people who worked, as they were then
COMMENT ON COLUMN public.production_batches.team_name IS 'The team''s name when recorded — kept as it was (093).';
COMMENT ON COLUMN public.production_batches.worker_names IS 'Who worked, by name, when recorded — kept as it was (093).';

CREATE OR REPLACE FUNCTION public.batch_keep_names()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.team_id IS NOT NULL AND NEW.team_name IS NULL THEN
    SELECT name INTO NEW.team_name FROM public.production_teams WHERE id = NEW.team_id;
  END IF;
  IF NEW.worker_ids IS NOT NULL AND NEW.worker_names IS NULL THEN
    SELECT array_agg(s.full_name ORDER BY s.full_name) INTO NEW.worker_names FROM public.staff s WHERE s.id = ANY(NEW.worker_ids);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_batch_keep_names BEFORE INSERT ON public.production_batches
  FOR EACH ROW EXECUTE FUNCTION public.batch_keep_names();

-- batches already recorded: the names as they are today (none has been renamed since 087)
UPDATE public.production_batches b SET team_name = t.name FROM public.production_teams t WHERE t.id = b.team_id AND b.team_name IS NULL;
UPDATE public.production_batches b SET worker_names = (SELECT array_agg(s.full_name ORDER BY s.full_name) FROM public.staff s WHERE s.id = ANY(b.worker_ids))
WHERE b.worker_ids IS NOT NULL AND b.worker_names IS NULL;

-- NEVER (SwahziTech, 2026-10-30): once recorded, a batch's team and people don't change —
-- not by renaming or removing a team, not by any later edit. The database refuses it.
CREATE OR REPLACE FUNCTION public.batch_people_fixed()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.team_id IS DISTINCT FROM OLD.team_id
     OR NEW.worker_ids IS DISTINCT FROM OLD.worker_ids
     OR (OLD.team_name IS NOT NULL AND NEW.team_name IS DISTINCT FROM OLD.team_name)
     OR (OLD.worker_names IS NOT NULL AND NEW.worker_names IS DISTINCT FROM OLD.worker_names) THEN
    RAISE EXCEPTION 'A recorded batch keeps its team and the people who worked as they were — they can''t change' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_batch_people_fixed BEFORE UPDATE ON public.production_batches
  FOR EACH ROW EXECUTE FUNCTION public.batch_people_fixed();
