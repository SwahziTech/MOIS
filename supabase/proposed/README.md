# Proposed migrations — NOT applied

Files here are dry-run tested but waiting for approval. `supabase db push`
does not see this folder. To apply one: move it into `supabase/migrations/`
together with the app changes it needs, dry-run again, then push.

- `20261014000026_identity_decisions.sql` — identity decision log (replaces
  `import_aliases`). Needs the import screen switched to `identity_decisions`
  in the same release. Backfill: `scripts/one-off/2026-10-14_stumarcot_identity_decisions.sql`.
