# MOIS — Web app

React 19 + Vite + Supabase. Tenant data is isolated by Supabase Row Level
Security; nothing in this app is specific to one organization.

## Setup

1. Copy `.env.example` to `.env.local` and fill in the project URL and
   **anon** key (never the service-role key).
2. `npm install`
3. `npm run dev` — http://localhost:5173

## Scripts

- `npm run dev` — dev server
- `npm run build` — production build to `dist/`
- `npm run lint` — oxlint

Database migrations live in `../supabase/migrations/`; master data is seeded
by `../scripts/seed.js` (see the header of that file).
