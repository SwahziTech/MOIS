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
**Status: CURRENT**

PRD sections covered: 4.1 (Auth), 4.2 (Org/Multi-tenancy), 4.4 (Master Data
subset: products, categories, units, recipes) — NOT suppliers/customers yet.

- Auth (email/password + Google OAuth), org/branch/warehouse structure,
  roles/permissions/RLS, user management
- Seed real Stumarcot data: products, recipes/BOMs, per-branch pricing
  from `product_master.json` / `ratios_and_molds.json` /
  `price_list_structured.json`
- No inventory, production, sales, or costing logic yet — intentional

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
