# AGENTS.md — Standing Rules for MOIS

This file applies to every task in this repo, in every phase. Phase-specific
prompts define *scope* only — they do not repeat these rules, and they never
override them. If a phase prompt conflicts with this file, stop and ask
rather than picking one.

MOIS (Manufacturing Operating Intelligent System) is a multi-tenant SaaS
product built by SwahziTech (Tanzania). Its first real tenant is Stumarcot,
a concrete/construction-products manufacturer with branches in Mwanza,
Dar es Salaam, and Dodoma. Stumarcot validates the product. It never defines
the architecture.

## 1. Multi-tenant, always

- Every tenant-owned table has `organization_id`, enforced by Supabase Row
  Level Security. RLS is the authoritative boundary — frontend checks are
  UX convenience only, never security.
- NEVER write `if organization == 'Stumarcot'` or any equivalent conditional
  on a specific tenant's identity, name, or ID, anywhere in the codebase.
  Tenant-specific behavior is always configuration data, never code.
- Before calling any feature involving tenant data "done," verify cross-tenant
  isolation: create a second dummy organization and confirm it cannot read,
  write, or infer anything about the first.

## 2. Tech stack (current phase: web only)

- Web: React + Supabase (Postgres, Auth, RLS, Realtime).
- Do not introduce Flutter, Next.js, Cloudflare services, Firebase Cloud
  Messaging, or any billing provider unless a phase prompt explicitly scopes
  them in. Adding infrastructure "for later" without being asked is scope
  creep — flag it as a suggestion instead of building it.
- No ORM magic that hides SQL from review. Migrations are plain SQL files
  under `supabase/migrations/`, reviewed before `db push`.

## 3. Money, units, and physical-reality fields — never conflate these

These are recurring sources of real bugs in this domain. Treat each as a
distinct field with a distinct meaning. Do not merge them into one number
or one free-text note under time pressure:

- **pcs_per_sqm** (coverage): how many pieces are needed to cover one square
  meter. A fixed property of a mold's physical size. Independent of cement.
- **wastani_per_bag** (yield): average pieces produced from one 50kg bag of
  cement. Depends on the mix ratio, not the mold's footprint.
- **m2_covered_per_bag**: derived from the two above — never store this as
  if it were a primitive fact if you can compute it instead.
- **stock_unit** (SQM or PCS): the authoritative unit for a given product.
  Tiles and paving are counted in SQM; everything else (curbstones,
  culverts, trench covers, matofali, posts/bicons) is counted in PCS. This
  is fixed per product, defined in `product_master.json` — never inferred
  from context or assumed uniform across a whole category.
- **Recipes/BOMs are shared per category + color**, not per mold. Molds of
  the same category and color use the identical cement:sand:chip:dawa:rangi
  ratio; only their yield (pcs_per_sqm, coverage) differs. Do not create
  a duplicate recipe per mold when the ratio is identical.
- **Production capacity differs by method** — do not apply one formula
  everywhere:
  - Vibro (floor tiles, wall tiles, paving, curbstones, trench covers):
    `qty_of_molds` for a product IS its maximum daily output in pieces —
    one cast-and-cure cycle per mold per day.
  - Press (bricks, kerbstones, press-paving): one large mold per product,
    cycling repeatedly. Capacity is cycle-speed × hours worked, not mold
    count. Do not treat any single observed daily-output range as a fixed
    ceiling to validate other numbers against — it varies by product and
    hours.
  - Steel-ring-cast (culverts) and steel-roller-cast (posts/bicons) have
    no defined capacity model yet. Do not invent one — flag it as missing
    if a task depends on it.

## 4. Product & pricing data

- `product_master.json` is the single source of truth for product names,
  categories, display format (`colored` = name + one qty column per color;
  `plain` = name + single qty column), and stock unit. Do not invent,
  merge, or split products differently than this file does.
- `ratios_and_molds.json` carries recipe/BOM and capacity data, plus a
  `_decisions_log` recording every judgment call already made on this data.
  Read the log before re-deriving a decision that's already there.
- `price_list_structured.json` is a **national price list with per-branch
  availability differences**, not independently-set branch pricing. Most
  products share one price across all three branches; where a product's
  price genuinely differs by branch (confirmed real, e.g. culverts cost
  more in Mwanza due to transport from the Dodoma plant), that is
  authoritative branch pricing, not an error to normalize away.
- Every one of these files marks unresolved gaps with `null` plus a note,
  or with an explicit unmatched/flagged entry. **Never fill a null or
  resolve a flagged mismatch by guessing.** Surface it and ask.
- When data conflicts across sources (ratios notebook vs. printed catalog
  vs. stock-take vs. price list), do not silently pick one. State the
  conflict and either resolve it using the other two sources' agreement,
  or ask.

## 5. Inventory (applies once inventory tables exist, Phase 1b+)

Stock is transaction-derived, never a directly-editable number. Every
inventory-affecting action (receipt, consumption, production output,
transfer, adjustment) must write a transaction record with: what, quantity,
unit, location, date/time, reason, user, reference, organization, branch,
warehouse. A UI that lets someone type a stock quantity directly is a bug,
not a shortcut — this is the exact problem the Aug-31 manual stock-take
demonstrated (typed numbers, no ledger, no way to reconcile a shortage
against a cause).

## 6. Security & secrets

- Never hardcode Supabase secrets, service-role keys, or any credential.
  Use environment variables; `.env` files are gitignored, `.env.example`
  ships with empty placeholders.
- The service-role key never appears in frontend code — server-side only
  (seed scripts, Edge Functions).

## 7. UI

- No emoji as icons. Use proper SVG icons.
- No gradients as a default. Clean, role-aware navigation — users see only
  the modules they're authorized for.
- Don't over-invest in visual polish before the data model is right. Get
  the schema and the master-data seeding correct first; visual design is a
  later, separate pass.

## 8. Git

- Commit locally as you go, with real, logical commit messages.
- NEVER push to GitHub, and never run any command that publishes or shares
  this code outside the local machine, without an explicit instruction in
  that session to do so. This holds even if a past session pushed before —
  each push needs its own explicit go-ahead.

## 9. Scope discipline

- Build only what the current phase prompt scopes. Do not scaffold future
  phases' tables, screens, or infrastructure "while you're in there."
- If a requirement seems to need changing shared core logic in a way that
  would only make sense for one tenant, stop and say so instead of writing
  a tenant-specific branch to route around it.
- Before marking anything "complete," confirm it's not mocked, stubbed, or
  tested only against invented data — test against the real seed data in
  `supabase/seed/`.

## 10. When you're not sure

State the assumption you're about to make and what you'd do differently if
it's wrong, then ask, rather than proceeding on a guess — especially for
anything touching money, quantities, or tenant boundaries.

## 11. Design tokens (proposed defaults — pending visual approval)

Fonts: **Google Sans** (files provided by SwahziTech under `/assets/fonts` —
read them from there, do not substitute or download a different font even
if Google Sans isn't in UI_skill.md's curated list). Pair Google Sans for
both headings and body unless a second weight/style is clearly needed for
hierarchy; do not introduce Inter, Roboto, or a system font as a fallback
beyond a generic sans-serif safety net.

Color system — Dark Charcoal / Khaki / Coffee, per product brief. Exact hex
values below are PROPOSED, not final — confirm once seen on real screens,
then remove this note.

Known contradiction, resolved: the brief calls for "black primary text"
AND a dark charcoal background in dark mode — literal black text on a dark
charcoal background fails contrast entirely. Resolution: black text applies
to LIGHT mode only; dark mode uses an off-white/khaki-tinted text instead,
preserving the same intent (khaki as the secondary/brand text tone) without
being unreadable.

```css
:root {
  /* Light mode */
  --color-bg: #FFFFFF;
  --color-surface: #F7F6F3;
  --color-text-primary: #1A1A1A;      /* black, per brief */
  --color-text-secondary: #8A7752;     /* deeper khaki, contrast-safe on white */
  --color-accent-khaki: #B7A57A;       /* logo, ribbons, dividers, selected states */
  --color-accent-coffee: #4B3621;      /* deep brown accent */
  --color-success: #2E7D32;
  --color-error: #C62828;
  --color-warning: #B8860B;

  --font-heading: 'Google Sans', sans-serif;
  --font-body: 'Google Sans', sans-serif;
}

:root[data-theme="dark"] {
  --color-bg: #201E1B;                 /* dark charcoal, warm-toned to pair with khaki/coffee */
  --color-surface: #2B2825;
  --color-text-primary: #EDE7DA;       /* off-white, NOT black - see note above */
  --color-text-secondary: #C9B98E;     /* lighter khaki for dark-bg legibility */
  --color-accent-khaki: #C9B98E;
  --color-accent-coffee: #6B4F35;      /* lightened coffee for dark mode, desaturated not inverted */
  --color-success: #4CAF50;
  --color-error: #EF5350;
  --color-warning: #D4A017;
}
```

Rules carried over from UI_skill.md, applied with these values instead of
its own example palette:
- Khaki and coffee are accent-only — logo, ribbons, dividers, highlights,
  selected states. Never used as the main background or as general body text.
- One accent color per icon set within a section (no multi-colored icon
  grids), exception for semantic status icons (success/error/warning).
- Verify contrast ≥4.5:1 for text before shipping either theme — the
  --color-text-secondary values above need an actual contrast check against
  their paired --color-bg, not just visual approval.
- Dark mode = desaturated tonal shift (as done above), never a simple
  inversion of the light palette.

## 12. Data files are read-only inputs, never build artifacts

`product_master.json`, `ratios_and_molds.json`, and `price_list_structured.json`
(plus this file, `UI_skill.md`, and everything under `/assets`) are final,
user-verified source-of-truth documents. They are inputs to read, not files
you generate, reshape, or maintain.

- NEVER delete, move, rename, overwrite, "clean up," or regenerate any of
  these files or `/assets` contents, for any reason, including refactors,
  seed script rewrites, or "improving" their structure. If a task seems to
  require touching one of them, STOP and ask first.
- When writing a seed script or any code that reads these files, read them
  **as-is**. Their categorization, naming, and field structure are already
  correct and cross-checked — do not flatten, re-categorize, rename, or
  reinterpret their structure while parsing them.
- If any of these files appears missing, unreadable, or different from a
  previously confirmed state, STOP IMMEDIATELY. Do not attempt to recreate,
  regenerate, or "reconstruct" it from memory or from code that reads it.
  Report exactly what you observed and wait for instruction.
- This rule exists because it was already violated once: an earlier session
  deleted these files while "cleaning up" the project structure, which broke
  the seed pipeline and cost a full project restart. Treat this as a hard
  constraint, not a preference.

**Known unresolved naming gap, not a bug**: `price_list_structured.json`'s
"PAVING BLOCKS (PRESS)" section names products by shape + strength grade
(RECTANGULAR, ZIGZAG, H PAVER, WORLDCUP) while `ratios_and_molds.json` names
the same product family by mold pattern (Z-Plain, W/Cup, 6cm/8cm 30/40MPa).
ZIGZAG ≈ Z-Plain and WORLDCUP ≈ W/Cup look like likely matches but are NOT
confirmed — do not merge them into one canonical product without explicit
confirmation from SwahziTech.

## 13. Session safety net

Before starting any work in a session, confirm a git commit exists covering
the current state of the 6 data/rule inputs above. After any checkpoint in
a phase prompt is confirmed working, commit again with a message describing
what just passed. Never treat git as optional bookkeeping — it is the only
recovery path available in this workflow (no local Docker reset is used;
Supabase is hosted-only per the current setup).

## 14. Vision and phasing documents

`docs/prd.md` is the full product vision, personas, data model, and
long-term phase plan (PRD Phase 1/V1, Phase 2, Phase 3). Read it for
context and rationale.

`docs/build-plan.md` breaks PRD "Phase 1/V1" into sequenced sub-phases
(1a-1g) because building all of Phase 1/V1 as one undifferentiated target
is what caused the Sept 26 file-deletion incident. **Only the sub-phase
marked CURRENT in build-plan.md is authorized to be built.** If prd.md
describes a capability that build-plan.md hasn't reached yet, do not build
it, scaffold it, or create its tables "since we'll need them soon" -
that is scope creep even when the destination is real and documented.
