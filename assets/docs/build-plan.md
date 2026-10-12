# MOIS — Build Plan

This file exists because `docs/prd.md` defines "Phase 1 / V1" as one large
target (full inventory → production → sales → costing → reports → AI v1 →
billing). Building that as one undifferentiated block is how the Sept 26
incident happened (an agent reorganizing/deleting source files mid-task
because the scope was too large to hold safely in one pass).

This file breaks PRD Phase 1 into sequenced sub-phases. **Only the sub-phase
marked CURRENT is authorized to be built.** Everything below it is real,
documented, and coming — not a surprise, not to be built early "since the
architecture could support it" (see AGENTS.md / PRD Rule 9).

When a sub-phase is confirmed complete (tested, checkpointed, committed),
update its status here before starting the next one. This file should
always show one CURRENT phase and nothing more than that being actively built.

---

## 1a — Foundation & Master Data
**Status: done (2026-10-12)**

Verified, not just claimed: 62/62 live tenant-isolation checks passed, real
Stumarcot org/branches seeded, Google OAuth + invite flow + branch-scoped
roles tested end-to-end with a real external account, migrations 013-014
closed the anon-write hole and the profiles/user_roles relationship bug,
admin credentials rotated off the leaked value, and all previously-missing
pricing (culverts split into N/R variants, Rectangular/Zigzag/H-Paver/
Worldcup resolved against the price list) has been re-seeded. Known real
gap carried forward, not hidden: Zigzag (3 variants) and H-Paver (3
variants) have no recipe/ratio data anywhere in the source notebook - they
have prices but can't yet be costed or produced from a BOM. See
`ratios_and_molds.json` `_decisions_log` for the full trail.

PRD sections covered: 4.1 (Auth), 4.2 (Org/Multi-tenancy), 4.4 (Master Data
subset: products, categories, units, recipes) — NOT suppliers/customers yet.

- Auth (email/password + Google OAuth), org/branch/warehouse structure,
  roles/permissions/RLS, user management
- Seed real Stumarcot data: products, recipes/BOMs, per-branch pricing
  from `product_master.json` / `ratios_and_molds.json` /
  `price_list_structured.json`
- No inventory, production, sales, or costing logic yet — intentional

## 1a.1 — Master Data Admin UI
**Status: CURRENT**

Not in the original PRD phasing — inserted because 1a seeded products,
recipes, and prices directly from the three source JSON files via script,
with no way for an org admin to change any of it without a developer
re-running a seed. That's fine for getting Stumarcot live once; it's not
fine as an ongoing way to run the business. Confirmed with the user to do
this before 1b rather than after, so 1b's inventory transactions are built
against data that's already properly editable, not against a seed script.

**Why this matters beyond Stumarcot:** reconciling Stumarcot's real data
(2026-10-12) against their price list surfaced real-world messiness that
is NOT Stumarcot-specific — ambiguous product names, likely duplicate
price-list rows, products with no recorded recipe/yield, branch-specific
product variants. MOIS is a multi-tenant product; a second tenant will
have their own version of this same messiness with their own naming
conventions. The fix is not "get Stumarcot's data perfectly clean before
building" — it's this screen. Nothing about this UI should assume
Stumarcot's categories, color palette, or unit types are fixed; a tenant
defines and corrects their own catalog here, Stumarcot being the first
one doing it. Build it generic now, not Stumarcot-shaped now and
generalized later.

PRD section: 4.4 (Master Data) — the editing/management half that 1a's
seed-only approach deliberately skipped.

- Org-admin-only screens (not branch managers) to create/edit/deactivate:
  products (name, category, color structure, unit), recipes/BOM ratios
  per category+color, molds within a category (inherits the category's
  shared ratio), per-branch prices, and the global color palette
- A "needs review" flag on any product, visible in these screens, for
  items seeded with an unresolved identity (duplicate name, uncertain
  size, missing recipe) — Stumarcot's own seed has ~10 of these right now
  (see `ratios_and_molds.json` `_decisions_log`, 2026-10-12 entries). The
  admin merges/edits/dismisses them here instead of a developer doing it
  in a JSON file.
- Every edit writes to the SAME tables 1a seeded — this is not a parallel
  system, it replaces the "edit the JSON and re-run the seed script" path
  going forward
- No hard delete on anything with existing stock/recipe/price history —
  deactivate (soft-delete) only, so historical transactions and reports
  in later phases never point at a vanished product
- Basic audit trail: who changed what field, old value, new value, when —
  this is real pricing/recipe data a manufacturing business runs on;
  silent edits are not acceptable
- Out of scope here: no inventory, production, or sales logic — this
  phase only makes 1a's existing master data editable, it doesn't add
  new kinds of data (suppliers/customers still arrive in 1b/1e as planned)

## 1b — Inventory Engine
**Status: not started**

PRD section: 4.6 (Inventory)

- Transaction-based stock (receiving, issues, transfers, adjustments,
  stock counts) — never a directly-editable stock number (see AGENTS.md §5)
- Suppliers added to master data here, since procurement/receiving needs them

## 1c — Procurement
**Status: not started**

PRD section: 4.5 (Procurement)

- Purchase requests, purchase orders, goods receiving, supplier history
- Depends on 1b's inventory transaction model (receiving writes a transaction)

## 1d — Production Engine
**Status: not started**

PRD sections: 4.7 (Production), 4.8 (Recipes/BOMs — activation),
4.9 (WIP/Curing/Finished Goods), 4.10 (Quality)

- Production orders, batches, material consumption against recipes seeded
  in 1a, standard-vs-actual variance, waste/rejection, WIP/curing,
  finished goods
- This is where the vibro-vs-press capacity model (AGENTS.md §3) actually
  gets used for scheduling/targets — not before

## 1e — Sales & Costing
**Status: not started**

PRD sections: 4.11 (Sales/CRM), 4.12 (Documents), 4.13 (Costing)

- Customers, catalogue, quotations, sales orders, invoices, payments
- Material cost, batch cost, unit cost, basic profitability
- Customers added to master data here (mirrors suppliers in 1b)

## 1f — Reports & AI v1
**Status: not started**

PRD sections: 4.15 (Dashboards & Reports), 7 (AI Features — V1 slice only:
Ask MOIS, basic authorized queries, basic analysis, AI-assisted document
drafts). Predict/Optimize/Act (PRD Phase 3) explicitly excluded.

## 1g — Billing
**Status: not started**

PRD section: 4.18 (Subscription & Billing), Snippe.sh integration.

Deliberately sequenced LAST within Phase 1, not first, despite the PRD
listing it under "V1 required." Reasoning: billing has zero dependency on
being built early, and building it before the operational core is proven
with a real user (Stumarcot) risks integrating a payment provider around
a product that might still change shape. Revisit this sequencing decision
if a second paying tenant becomes imminent before 1a-1f are solid.

---

## After Phase 1 (PRD Phase 2 / Phase 3)

Not detailed here — see `docs/prd.md` sections "PHASE 2 — MOIS INTELLIGENCE"
and "PHASE 3 — MOIS PREDICTIVE & AUTONOMOUS". Do not pull work forward from
these into any 1a-1g sub-phase without updating this file first.
