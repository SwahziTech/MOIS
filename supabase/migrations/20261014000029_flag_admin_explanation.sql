-- ============================================================
-- 029 — "Explain in your own words" on Review-queue flags (1b)
--
-- A free-text note the admin can add to any flag, alongside (or instead of)
-- the structured choices, for whatever the fixed choices don't capture.
-- Saved exactly as typed; nothing reads or acts on it automatically.
--
-- Deliberately NOT interpreted today. It exists so that when 1f (Reports &
-- AI) is built, an assistant has these explanations as real data to read —
-- the decision to pull AI interpretation forward was considered and declined
-- (2026-10-14); 1c/1d/1e come first.
-- ============================================================

ALTER TABLE public.review_flags
  ADD COLUMN admin_explanation    text,
  ADD COLUMN admin_explanation_by uuid REFERENCES auth.users(id),
  ADD COLUMN admin_explanation_at timestamptz;

COMMENT ON COLUMN public.review_flags.admin_explanation
  IS 'The admin''s own words about this flag, saved as typed. Not interpreted by the system (reserved for 1f AI features to read).';
