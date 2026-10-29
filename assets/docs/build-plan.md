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
**Status: done (2026-10-12)**

Verified, not just claimed: migrations 018-021 applied live after PGlite
dry runs on a live snapshot; 86/86 live tenant-isolation checks; every
screen loaded against live data. Screens: colours, product categories,
products (incl. merging duplicates), recipes/BOM (every ingredient change
saves a new version via create_recipe_version; saved versions are frozen),
per-branch prices + colour pricing rules, materials (conversions,
per-branch sources, material categories, units), and a review queue for
"needs review" flags. Writes need an org-wide admin grant
(has_permission); deactivate-only; field-level audit_log. First real use:
"Draft (490x450mm)" merged into "50 Draft" by the tenant (2026-10-12).

Consequence carried forward: once an org has app edits, the app is its
source of truth — scripts/seed.js refuses such orgs unless
--force-reseed-org-with-app-edits is passed. Open data left for the tenant
to settle in the app (not code gaps): open review flags, active products
with no price, steel stock/purchase units, Mwanza/Dar material sources.
Known limitation: colour pricing rules have no status, so a rule can be
emptied but not retired.

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
**Status: done (2026-10-16)**

Verified, not just claimed: migrations 022-034 applied live, each after a
PGlite dry run on a live snapshot; live isolation checks 123/123. Built:
append-only stock ledger (receipts, issues, transfers, adjustments, counts,
opening balances, reversals, reclassification), dated movements and the
org's own timezone, stock-sheet import with drafts and never-blocking
placeholders, the identity decision log and Review-queue choices, Dodoma's
opening stock posted (2026-09-30). Mid-phase decisions with SwahziTech
(2026-10-16), all live: branch-scoped catalogues, recipes and branch-owned
materials (031/032 — product identity shared, membership per branch);
yield per bag as a ±5 QC band, never an output formula; supplier recorded
per purchase only; an approval queue for branch managers' price changes and
corrective stock entries (033); roles — Technical admin, Director, branch
manager, secretary, storekeeper, with storekeepers' count differences going
to approval (034). Known gaps carried forward: prices hidden from
storekeepers on screen only; Zigzag/H-Paver still lack recipe data.

PRD section: 4.6 (Inventory)

- Transaction-based stock (receiving, issues, transfers, adjustments,
  stock counts) — never a directly-editable stock number (see AGENTS.md §5)
- Suppliers added to master data here, since procurement/receiving needs them

## 1c — Procurement
**Status: DONE** (2026-10-28, on SwahziTech's instruction)

Closed with the "Not yet" items built on 2026-10-28 (migrations 077–085):
- **Supplier payments** per purchase, with supplier balances.
- **Requests** for materials or expenses: the storekeeper or secretary asks
  and the branch manager approves. Each request is followed from its own
  row: approved → ordered → bought/received → done. Orders can be printed
  for the supplier or kept internal, and edited while nothing has come.
- **LUKU top-ups**, asked from the meter. They are always from TANESCO, and
  recording the token tops the meter up. Tokens can be entered any day
  after they were bought; only double entries are refused.
- **Weekly operations cash**: requested, approved by the branch manager then
  the directors, paid; last week's spending is read from what was recorded.
  It can be imported from the branch's Excel sheet or exported.
- **Suppliers** are suggested from what each one actually supplied.

Scope decided with SwahziTech (2026-10-16): the purchase record and its
payment status only — supplier, prices, transport (part of landed cost),
optional VAT (excluded from cost when shown separately), paid / part-paid /
unpaid. The storekeeper receives the goods; the secretary or branch manager
completes the purchase. Moving average material cost per branch, from
purchases only (no retroactive cost for opening stock). Purchase requests,
approval and purchase orders, and a running supplier balance, are deferred
until Stumarcot actually needs them (it buys informally today).

PRD section: 4.5 (Procurement)

**Not yet** (SwahziTech, 2026-10-22) — not part of 1c; to be raised again once
Phase 1 is through and Stumarcot enters live, same-day data instead of back-dated:
- Purchase requests and approvals
- Purchase orders
- A running supplier balance (how much is owed to each supplier)

- Purchase requests, purchase orders, goods receiving, supplier history
- Depends on 1b's inventory transaction model (receiving writes a transaction)

## 1d — Production Engine
**Status: DONE** (2026-10-25, on SwahziTech's instruction; started 2026-10-18)

Built (migrations 042–057): batches with main + residual products and the
weighted yield band; day lists saved together, back-dated days through
Approvals; material issue and material variance; curing store, minimum (7)
and normal (14) curing, quality release with reject reasons — one by one or
several at once; production orders with the capacity planner (vibro molds,
press bags a day); batch material cost first in first out at the full amount
paid, VAT included, shared by cement taken (cost per piece and per m²);
production tracking — team (who worked), machine/line, quality tags at
release; people per batch and per day with labour norms (bags a person per
product, a machine's crew); production ledger with a Tracking view; Production
settings behind the page's ⚙. Stumarcot's materials format (ProductionBreakdown)
is locked for every screen showing production materials.
Moved to 1e: stock at cost, a product's cost across batches, margins, and
full production cost (labour, power, diesel, expenses). Waste ("thrown away")
was built and removed on SwahziTech's instruction (2026-10-25); its tables stay
unused.

Spec decided with SwahziTech from Stumarcot's answers (2026-10-18): a batch is one
mix/session (one product, one colour), many per day; cement bags counted, other
materials from the recipe × bags unless counted, with material variance against
stock counts; curing 14 days org-wide in a Curing store (not sellable); quality
release with reject reasons (Broken, Cracked, Colour wrong, Size wrong); secretary
and branch manager record batches, the storekeeper issues materials (migration 042).

PRD sections: 4.7 (Production), 4.8 (Recipes/BOMs — activation),
4.9 (WIP/Curing/Finished Goods), 4.10 (Quality)

- Production orders, batches, material consumption against recipes seeded
  in 1a, standard-vs-actual variance, waste/rejection, WIP/curing,
  finished goods
- This is where the vibro-vs-press capacity model (AGENTS.md §3) actually
  gets used for scheduling/targets — not before

## 1e — Sales & Costing
**Status: DONE** (2026-10-27, on SwahziTech's instruction; started 2026-10-25 after 1d)

Built:
- **Sales:** quotation → order → invoice; part and per-item payments into named
  accounts; deliveries capped by paid value and stock; corrections; walk-ins
  promoted to customers; the sales book.
- **Documents:** A4 quotation, proforma, invoice, receipt and delivery note.
- **Customers:** who owes by age, history and statement of account.
- **Costing:** Products, Materials and Overheads.
  - Electricity: LUKU meters, tokens with their receipt breakdown, morning and
    evening readings, day use charged to batches.
  - Other overheads: expense categories ticked as production costs, shared
    monthly by cement bags and by machine.
  - The Technical-admin bag target.
- **Layout:** the locked page order (tabs, then 3-line summary cards, then
  search, then categories) and frozen page tabs and table headers.

Open when closed:
- Migration 076 (overheads) is waiting to be applied by SwahziTech.
- Live testing of electricity and overheads continues in use.
- Labour cost moves to Staff (HR).
- The two-way daily report moves to 1f.
- Supplier balances, purchase requests and approvals, and POs are still
  "Not yet".

Carried in from 1d (SwahziTech, 2026-10-25): stock at cost (a product's cost
across batches), margins, and full production cost — labour (teams, who
worked, labour norms), power, diesel and other expenses shared over what was
produced. Batch material cost (055) is already there; rejects never re-cost a
batch.

PRD sections: 4.11 (Sales/CRM), 4.12 (Documents), 4.13 (Costing)

- Customers, catalogue, quotations, sales orders, invoices, payments
- Material cost, batch cost, unit cost, basic profitability
- Customers added to master data here (mirrors suppliers in 1b)

Added to 1e (SwahziTech, 2026-10-27):
- **Production pages stay raw materials only.** Team and machine are still
  recorded there. Costing pulls everything else from where it is recorded.
- **Electricity sits under Expenses** (Purchases › Electricity):
  - LUKU meters and the machines each feeds (Purchases ⚙).
  - Tokens are entered as Electricity expenses (meter, units, token no.).
  - Each meter is read morning and evening, as in the daily report.
  - Day use (morning → evening) is charged by Costing to that day's batches
    on the meter's machines, by cement bags.
  - Night use (evening → next morning) is lights, a running cost.
  - Units are priced oldest token first.
  - No fixed office share. The days are tracked against production (units
    a cement bag, working vs idle days, nights) to learn what the use is
    made of.
- **Labour in costing waits for Staff (HR):** casuals separated from the
  employed staff on production teams.

## Staff (HR) — next phase after 1e
**Status: DONE** (2026-10-29; built 2026-10-28/29 as migrations 086–090. 087–090 must be applied, and the statutory rates confirmed against TRA/NSSF/WCF, before real pay is approved.)
(queued by SwahziTech, 2026-10-27; same dry-run and approval process as every phase)

**What was built:**
- HR › Staff: Employees and Casuals tabs. Each card shows this week's attendance and the pay due so far.
- Attendance.
- Who worked is ticked on each production batch. Teams are names only, because the people change from day to day (087).
- Statutory rates are kept in a dated table filled with the usual figures and marked "to verify". The Technical admin or a director confirms them. A pay sheet can't be approved on unconfirmed rates (088).
- Pay sheets are made automatically from attendance (089):
  - casuals weekly, at days × day rate;
  - employed staff every 2 weeks, at days × salary ÷ working days a month (26, set under ⚙).
- Deductions: NSSF, PAYE, WCF, SDL and other deductions.
- Paying a sheet records the net pay as a Wages expense. PAYE, NSSF, WCF and SDL are recorded as one Statutory contributions expense, owed until remitted.
- Payslips.
- Advances and loans, taken back automatically on the sheets (090).
- Returns: the month's PAYE, NSSF, SDL and WCF from paid sheets, with an Excel download (090).
- Costing › Labour follows attendance the same way pay does, plus the employer's NSSF, WCF and SDL, shared over the day's batches by cement bags (090).

**Open:** whether casuals count toward the SDL threshold — ask TRA. It is a setting on the SDL rate.

Its own sidebar section, with four parts:
- **Employees.** The master record: name, role, branch, employment type,
  salary or day rate, NSSF number, start date and status.
- **Attendance / Labour.**
  - Daily casual attendance.
  - The batch labour link from 1e, upgraded to pull from real employee
    records instead of a flat number.
- **Payroll.** Monthly runs for salaried staff and weekly runs for casuals.
  Statutory figures:
  - NSSF: 10% employee + 10% employer.
  - WCF: 0.5%, employer.
  - SDL: 3.5%, employer, once there are 10+ employees. Confirm whether
    casuals count toward that threshold.
  - PAYE, 2025/26 bands: 0% to 270k, 8% to 520k, 20% to 760k, 25% to 1M,
    30% above.
- **Payslips.**

**Before building:** flag to SwahziTech that the PAYE, NSSF, WCF and SDL
rates must be verified against TRA before real deductions go live.

**Starting point:** a first draft of staff, attendance and pay sheets
(proposed migration 071, not applied) was written on 2026-10-27 and will be
reworked here.

## 1f — Reports & AI v1
**Status: Reports part DONE (2026-10-30). The AI part is queued as the LAST step** (SwahziTech, 2026-10-30: "queue 1f into last step").

**Built (2026-10-29/30, no migrations):**
- Reports › Daily report: two-way, in Swahili. Written from MOIS, or a written report compared against it.
- Reports › Reports: production, sales, purchases & expenses, materials used against the recipe, basic profit, and branches. Each covers a date range and exports to Excel.
- Home dashboards: Overview (with "Needs attention"), Production, Inventory, Sales, and Setup. Each tab is shown only to the people who work in that area.

**Queued last:**
- Ask MOIS (AI v1), basic analysis and AI-assisted drafts.
- Reading `review_flags.admin_explanation`.
- Before building, ask SwahziTech three things: the AI provider, what tenant data may be sent to it, and who may use it.

PRD sections: 4.15 (Dashboards & Reports), 7 (AI Features — V1 slice only:
Ask MOIS, basic authorized queries, basic analysis, AI-assisted document
drafts). Predict/Optimize/Act (PRD Phase 3) explicitly excluded.

- **Daily report, two-way** (queued by SwahziTech, 2026-10-27; sample:
  Dodoma's handwritten day report).
  - MOIS writes the report from what is recorded:
    - production per product: pieces, cement, wastani, leftovers (mabaki),
      team people;
    - cement left in store;
    - each meter's morning, evening and used units.
  - Or the report is written or pasted in and MOIS reads it (units, cement
    count), then compares it with what the system holds.
  - In Swahili as written today.
  - No night shift any more.
- Input already waiting: `review_flags.admin_explanation` (migration 029) — admins' free-text notes on Review-queue flags, saved as-is since 1b, deliberately not interpreted yet (AI proposing stock-affecting actions from it was considered for earlier and declined on 2026-10-14).

## CRM & Cash flow
**Status: CURRENT** (from 2026-10-30, on SwahziTech's instruction. These came forward from PRD Phase 2; cash flow first.)

- **Cash flow** (SwahziTech chose):
  - Money in and out by account: opening balances; sale payments, weekly cash from the directors, supplier payments and expenses paid, which includes wages and statutory payments; a running balance.
  - A month's cash-flow statement.
  - A forecast: customers owe and weekly cash approved, against suppliers, statutory, other bills and pay sheets to pay.
  - Migration 094: `payment_accounts.opening_balance`/`opening_date`, `expenses.account_id` ("Paid from"), the `cash_movements` view, and `finance.view` (owner, director, branch manager).
- **CRM** (next): leads and follow-ups. Prospects (contractors, sites, enquiries) before they buy, the next follow-up date and who does it; a lead is turned into a customer plus a quotation.

## 1g — Billing
**Status: not started — queued AFTER the AI step** (SwahziTech, 2026-10-30: "que 1g after ai"; the order is 1f AI, then 1g).

PRD section: 4.18 (Subscription & Billing), Snippe.sh integration.

- Org onboarding (PRD 5.1): pre-fill new org's timezone from browserTimeZone() at creation, editable after.

Deliberately sequenced LAST within Phase 1, not first, despite the PRD
listing it under "V1 required." Reasoning: billing has zero dependency on
being built early, and building it before the operational core is proven
with a real user (Stumarcot) risks integrating a payment provider around
a product that might still change shape. Revisit this sequencing decision
if a second paying tenant becomes imminent before 1a-1f are solid.

---

## Mobile app (Flutter) — after Phase 1
**Status: not started** (SwahziTech, 2026-10-22: mobile comes after Phase 1)

PRD sections: 9.4 (Responsive design — Mobile), 10.1 (Flutter). Phone screens
first: materials, production, sales, stock. The React web app stays
desktop/tablet.

---

## After Phase 1 (PRD Phase 2 / Phase 3)

Not detailed here — see `docs/prd.md` sections "PHASE 2 — MOIS INTELLIGENCE"
and "PHASE 3 — MOIS PREDICTIVE & AUTONOMOUS". Do not pull work forward from
these into any 1a-1g sub-phase without updating this file first.
