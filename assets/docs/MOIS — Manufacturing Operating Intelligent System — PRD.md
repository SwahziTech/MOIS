# MOIS — Manufacturing Operating Intelligent System

**Product Requirements Document**

**Version:** 1.0  
**Product:** MOIS  
**Full Name:** Manufacturing Operating Intelligent System  
**Product Type:** Multi-tenant manufacturing SaaS  
**Primary Market:** Manufacturing SMEs  
**Initial Market:** Tanzania → East Africa → Africa → Global  
**First Validation Tenant:** Stumarcot  
**Status:** Build Specification

---

# 1. Overview

MOIS (Manufacturing Operating Intelligent System) is a multi-tenant, AI-native manufacturing operating platform designed for small and medium-sized manufacturers that need one reliable system for purchasing, raw-material inventory, production, WIP/curing, finished goods, sales, payments, costing, reporting, and operational intelligence. MOIS replaces disconnected paper records, spreadsheets, messaging apps, and fragmented systems with a standardized manufacturing engine that becomes the operational source of truth for a factory. Each manufacturing company receives its own organization, configuration, users, branches, products, recipes, workflows, and visual branding, while the underlying MOIS manufacturing engine remains standardized and unchanged.

---

# 2. Problem & Solution

## 2.1 Problem

Many manufacturing SMEs operate with disconnected information across:

- paper stock books
- Excel spreadsheets
- WhatsApp
- manually prepared reports
- accounting systems disconnected from production
- informal production records
- manually calculated material consumption
- separate sales records
- supplier records
- physical stock counts

This creates several operational problems:

- management cannot see the real state of the factory quickly
- inventory balances become unreliable
- raw-material consumption is difficult to compare against standards
- production waste is difficult to identify
- actual product costs are unclear
- WIP and curing stock are poorly tracked
- purchasing decisions are reactive
- sales and production information are disconnected
- branch performance is difficult to compare
- reporting consumes significant staff time
- managers have data but not operational intelligence

Traditional ERP systems can be complex, expensive, difficult to configure, and often optimized around accounting rather than the physical reality of manufacturing.

Generic business software does not adequately represent:

**Raw Materials → Production → WIP/Curing → Quality → Finished Goods → Sales → Payments → Costing**

## 2.2 Solution

MOIS provides one connected manufacturing operating system.

Core lifecycle:

```text
Supplier
   ↓
Procurement
   ↓
Receiving
   ↓
Raw Materials
   ↓
Inventory
   ↓
Production
   ↓
WIP / Curing
   ↓
Quality
   ↓
Finished Goods
   ↓
Sales
   ↓
Dispatch
   ↓
Payments
   ↓
Costing
   ↓
Intelligence
```

MOIS is different because it is designed around the physical and economic operation of a factory rather than simply digitizing administrative records.

The product evolves through:

```text
Manual
  ↓
Digital
  ↓
Connected
  ↓
Intelligent
  ↓
Predictive
  ↓
Optimized
```

The core principle is:

> **Build the manufacturing engine once. Configure the experience for every manufacturer.**

Customer customization must never create separate versions of the core engine.

Think:

> **Same diesel engine, different body.**

Not:

> **Different engine for every customer.**

---

# 3. Target Users

## 3.1 Primary Personas

### A. Factory Owner / Director

Needs:

- visibility across the business
- branch comparison
- stock visibility
- production visibility
- sales visibility
- profitability
- cash and receivables visibility
- operational alerts
- management-level AI questions

Typical questions:

- What stock do we have?
- What did we produce today?
- Which branch has what stock?
- What materials are running low?
- Which customers owe us?
- Are we consuming more material than expected?
- What requires management attention?

Access:

- organization-wide or authorized multi-branch access
- management dashboards
- reports
- financial information according to permissions
- AI operational intelligence

---

### B. Branch / Factory Manager

Needs:

- branch stock
- production planning
- production status
- material requirements
- sales activity
- branch reports
- operational alerts

Access:

- assigned branches
- assigned warehouses
- production
- inventory
- sales
- relevant reports
- authorized AI queries

---

### C. Storekeeper / Inventory User

Needs:

- receiving materials
- issuing materials
- stock transfers
- stock adjustments
- stock counts
- inventory visibility

Access:

- assigned warehouses
- inventory transactions
- receiving
- transfers
- stock counts
- authorized inventory reports

---

### D. Production User / Production Manager

Needs:

- production orders
- recipes
- material issuing
- actual consumption
- batch quantities
- waste
- rejection
- WIP
- curing
- finished goods

Access:

- assigned production operations
- production records
- relevant inventory
- quality workflows

---

### E. Sales / Administrative User

Needs:

- customers
- catalogue
- pricing
- quotations
- proformas
- orders
- invoices
- payments
- customer balances

Access:

- assigned sales functions
- authorized customer information
- document creation

---

### F. Platform Administrator

This is a separate MOIS platform-level role.

Needs:

- manage organizations
- subscriptions
- plans
- platform configuration
- system health
- platform users
- support functions
- platform audit information

Platform administrators are NOT ordinary tenant users.

---

## 3.2 Secondary Personas

- finance/accounting users
- procurement users
- logistics/delivery users
- quality-control users
- maintenance users
- future AI/operations users
- customers with restricted access in future versions

---

# 4. Core Features

Features are organized by functional module.

---

## 4.1 Authentication & Account Management

### Features

- email/password signup
- first name
- second name
- email
- password
- email verification
- login
- logout
- password reset
- Google OAuth
- profile management
- user invitation
- user activation/deactivation

### Serves

All users.

---

# 4.2 Organization & Multi-Tenancy

MOIS is a true multi-tenant SaaS.

Each company is an organization.

### Features

- create organization
- organization profile
- company information
- company logo
- organization settings
- branches
- warehouses
- users
- roles
- permissions
- organization status
- tenant isolation

Every organization-owned record must be associated with an `organization_id`.

### Serves

Platform administrators, company administrators, directors.

---

# 4.3 Company Configuration & Branding

Customer customization must be configuration-driven.

### Configurable

- company name
- logo
- favicon
- brand colors
- document branding
- company information
- branches
- warehouses
- products
- materials
- units
- categories
- recipes
- approval thresholds
- enabled modules
- terminology/display labels
- user roles
- permissions
- workflow settings

### Non-configurable

Customers cannot modify:

- core inventory logic
- core production logic
- costing calculations
- tenant isolation
- authorization architecture
- security architecture
- audit architecture
- transaction integrity
- core database architecture
- AI security controls

### Serves

Company administrators and platform administrators.

---

# 4.4 Master Data

### Products

Store:

- product name
- product code
- category
- unit
- dimensions/specifications
- active/inactive status
- recipe/BOM
- pricing

### Materials

Store:

- material name
- code
- category
- unit
- supplier relationships
- purchase cost
- reorder level
- active status

### Suppliers

Store:

- supplier details
- materials supplied
- purchase history
- prices
- balances

### Customers

Store:

- customer details
- contact information
- sales history
- payment history
- outstanding balance

### Other Master Data

- product categories
- material categories
- units
- machines
- production lines
- employees/operators

### Serves

Administrators, storekeepers, production, procurement, sales, management.

---

# 4.5 Procurement

### Workflow

```text
Purchase Request
      ↓
Approval
      ↓
Purchase Order
      ↓
Goods Receiving
      ↓
Inventory
      ↓
Supplier Liability
```

### Features

- purchase requests
- purchase request approval
- supplier selection
- purchase orders
- purchase order items
- goods receiving
- partial receiving
- supplier purchase history
- supplier price history
- receiving documentation

### Serves

Procurement, storekeepers, managers, finance, directors.

---

# 4.6 Inventory

Inventory is transaction-based.

The system must NOT rely on uncontrolled direct stock edits.

### Supported Transactions

- opening balance
- purchase receipt
- material issue
- production consumption
- production completion
- sale
- transfer
- return
- waste
- stock adjustment
- stock count

### Stock States

- available
- reserved
- WIP
- curing
- ready
- rejected
- damaged

### Every Inventory Movement Must Record

```text
What
How Much
Where
When
Why
Who
Reference
```

### Core Rule

Inventory balance is derived from authoritative inventory transactions.

Example:

```text
Purchase Receipt
      ↓
Inventory Transaction
      ↓
Stock Balance
```

### Serves

Storekeepers, production users, managers, directors, sales.

---

# 4.7 Manufacturing / Production

### Core Workflow

```text
Production Plan
      ↓
Production Order
      ↓
Issue Materials
      ↓
Production Batch
      ↓
Record Actual Consumption
      ↓
Quality
      ↓
WIP / Curing
      ↓
Finished Goods
```

### Features

- production planning
- production orders
- recipe selection
- production batches
- material issuing
- actual material consumption
- standard vs actual consumption
- operator assignment
- machine/line assignment
- planned quantity
- produced quantity
- good quantity
- rejected quantity
- waste
- WIP
- curing
- finished goods
- production costing

### Serves

Production users, factory managers, directors.

---

# 4.8 Recipes / BOMs

Recipes define the standard materials required to manufacture a product.

### Features

- product recipe
- recipe version
- recipe items
- standard quantity
- unit
- effective date
- status
- historical version retention

Historical production must retain the exact recipe version used.

Changing the current recipe must never rewrite historical production.

### Serves

Production managers, factory managers, administrators.

---

# 4.9 WIP, Curing & Finished Goods

Track the manufacturing state:

```text
Raw Materials
      ↓
Production
      ↓
WIP
      ↓
Curing
      ↓
Quality
      ↓
Ready Stock
```

### Features

- WIP records
- curing records
- curing start/end
- quality status
- rejected quantity
- ready quantity
- finished-goods inventory

### Serves

Production, quality, storekeepers, managers, sales.

---

# 4.10 Quality

### Features

- batch inspection
- quality checks
- pass/fail
- rejected quantity
- defect types
- notes
- corrective action
- quality history

### Serves

Production, quality users, managers.

---

# 4.11 Sales & CRM

### Features

- customers
- customer history
- product catalogue
- pricing
- discounts
- quotations
- proformas
- sales orders
- invoices
- payments
- customer statements
- receivables

Sales must connect to actual inventory availability.

### Serves

Sales, administrators, directors, customers in future versions.

---

# 4.12 Documents

MOIS must generate controlled business documents.

### Documents

- quotation
- proforma invoice
- sales order
- invoice
- payment receipt
- purchase request
- purchase order
- goods received note
- delivery note
- customer statement
- supplier statement
- stock adjustment
- stock transfer
- production report
- dispatch document
- proof of delivery

AI may assist with document preparation.

However, deterministic backend logic controls:

- quantities
- prices
- discounts
- taxes
- totals
- balances

AI must never be the source of financial arithmetic.

---

# 4.13 Costing & Basic Financial Visibility

Phase 1 costing includes:

- material costs
- production costs
- batch costs
- unit costs
- basic profitability
- customer balances
- supplier balances
- purchases
- payments
- revenue

### Formula

```text
Material Cost
=
SUM(quantity consumed × unit cost)
```

```text
Batch Unit Cost
=
Total Batch Production Cost ÷ Good Quantity
```

### Variance

Compare:

```text
Standard Consumption
vs
Actual Consumption
```

and:

```text
Standard Cost
vs
Actual Cost
```

### Serves

Directors, managers, finance users.

---

# 4.14 Logistics

Phase 1 supports basic dispatch/delivery information where necessary.

### Features

- delivery orders
- dispatch
- driver assignment
- vehicle assignment
- delivery status
- proof of delivery
- delivery history

Advanced fleet and logistics intelligence belongs to later phases.

### Serves

Sales, logistics users, managers.

---

# 4.15 Dashboards & Reports

### Management Dashboard

- revenue
- sales
- production
- inventory
- receivables
- payables
- profitability
- alerts

### Production Dashboard

- production orders
- production status
- WIP
- curing
- finished goods
- waste
- rejection
- material variance

### Inventory Dashboard

- current stock
- low stock
- stock movement
- stock by branch
- stock by warehouse
- material consumption

### Sales Dashboard

- sales
- orders
- invoices
- payments
- receivables

### Reports

- inventory report
- stock movement
- production report
- sales report
- purchases report
- customer balances
- supplier balances
- material consumption
- standard vs actual consumption
- basic profitability
- branch comparison

---

# 4.16 Notifications

Initial notifications:

- low stock
- pending approval
- overdue invoice
- production variance
- quality rejection
- pending purchase order
- delivery update

Notifications must respect:

- organization
- branch
- warehouse
- role
- permission

Push notifications use Firebase Cloud Messaging.

---

# 4.17 Platform Administration

Separate from tenant applications.

### Features

- organizations
- tenant status
- subscription plans
- subscriptions
- feature entitlements
- platform users
- support access
- system health
- platform audit information

A normal company user must never see platform administration.

---

# 4.18 Subscription & Billing

MOIS is SaaS.

Subscriptions are associated with organizations.

The platform must support:

- subscription plans
- plan status
- trial status if enabled
- billing period
- subscription start/end
- payment status
- feature entitlements

Payment provider:

> **Snippe.sh only**

Do not implement Stripe or Pesapal.

---

# 5. User Flows

## 5.1 Organization Onboarding

```text
User opens MOIS
      ↓
Signup / Login
      ↓
Create Organization
      ↓
Enter Company Information
      ↓
Upload Logo
      ↓
Configure Basic Branding
      ↓
Create First Branch
      ↓
Create First Warehouse
      ↓
Invite Users
      ↓
Assign Roles
      ↓
Configure Master Data
      ↓
MOIS Dashboard
```

The onboarding flow should guide the administrator without requiring technical knowledge.

---

## 5.2 Procurement → Inventory

```text
Authorized user creates Purchase Request
      ↓
Manager approves
      ↓
Purchase Order created
      ↓
Supplier delivers materials
      ↓
Storekeeper opens Goods Receipt
      ↓
Select Purchase Order
      ↓
Enter received quantities
      ↓
Confirm receipt
      ↓
Backend creates inventory transactions
      ↓
Stock balance updates
      ↓
Supplier purchase history updates
```

No direct stock manipulation should occur.

---

## 5.3 Production → Finished Goods

```text
Production manager creates Production Order
      ↓
Select product
      ↓
Select recipe version
      ↓
Enter planned quantity
      ↓
Issue required materials
      ↓
Start production batch
      ↓
Record actual consumption
      ↓
Record produced quantity
      ↓
Record waste/rejection
      ↓
WIP/Curing
      ↓
Quality inspection
      ↓
Approve good quantity
      ↓
Finished Goods transaction
      ↓
Finished stock becomes available
```

The system should calculate standard vs actual consumption.

---

## 5.4 Sales → Payment

```text
Sales user selects customer
      ↓
Create quotation/proforma/order
      ↓
Select products
      ↓
System checks available stock
      ↓
Apply authorized pricing/discount
      ↓
Confirm order
      ↓
Create invoice
      ↓
Receive payment
      ↓
Record payment
      ↓
Update customer balance
      ↓
Dispatch/delivery
```

Financial calculations must be deterministic.

---

## 5.5 Subscription Payment

```text
Organization selects plan
      ↓
MOIS creates payment request
      ↓
Payment processed through Snippe.sh
      ↓
Server verifies payment
      ↓
Subscription status updated
      ↓
Entitlements activated
```

Never trust a frontend-only payment confirmation.

---

# 6. Data Model

All tables must be designed for true multi-tenancy.

Where applicable, organization-owned records must include:

```text
organization_id
created_at
updated_at
created_by
updated_by
```

Use PostgreSQL foreign keys and appropriate indexes.

---

## 6.1 organizations

Stores tenant/company information.

Key fields:

- id
- name
- legal/company information
- logo
- branding configuration
- status
- created_at
- updated_at

Relationships:

- one organization has many branches
- one organization has many users
- one organization has many warehouses
- one organization owns operational data

---

## 6.2 branches

Stores company branches/factories.

Fields:

- id
- organization_id
- name
- location
- contact information
- status

Relationships:

- belongs to organization
- has warehouses
- has users
- has production
- has sales
- has inventory

---

## 6.3 warehouses

Stores inventory locations.

Fields:

- id
- organization_id
- branch_id
- name
- type
- status

Relationships:

- belongs to organization
- optionally belongs to branch
- contains inventory

---

## 6.4 profiles

Extends Supabase Auth users.

Fields:

- id
- first_name
- second_name
- email
- phone
- avatar
- status
- organization_id

The Supabase Auth user ID must be referenced.

---

## 6.5 roles

Defines organization roles.

Fields:

- id
- organization_id
- name
- description

---

## 6.6 permissions

Defines available permissions.

Examples:

- inventory.view
- inventory.receive
- inventory.adjust
- production.view
- production.create
- production.complete
- sales.create
- invoices.create
- reports.view

Permissions are standardized MOIS capabilities.

---

## 6.7 role_permissions

Maps roles to permissions.

---

## 6.8 user_roles

Maps users to roles and organization scope.

May include:

- organization_id
- branch_id
- warehouse_id

depending on permission architecture.

---

## 6.9 product_categories

Product classification.

---

## 6.10 products

Fields:

- id
- organization_id
- category_id
- name
- code
- unit
- specifications
- status
- image
- default price

---

## 6.11 materials

Fields:

- id
- organization_id
- category
- name
- code
- unit
- reorder_level
- status

---

## 6.12 suppliers

Supplier master data.

---

## 6.13 customers

Customer master data.

---

## 6.14 machines

Manufacturing equipment.

---

## 6.15 production_lines

Production line/workstation information.

---

## 6.16 recipes

Product-level recipe definition.

---

## 6.17 recipe_versions

Versioned recipe snapshots.

Fields include:

- product_id
- version_number
- effective_date
- status

---

## 6.18 recipe_items

Materials and standard quantities belonging to a recipe version.

Fields:

- recipe_version_id
- material_id
- quantity
- unit

---

## 6.19 purchase_requests

Purchase request header.

---

## 6.20 purchase_request_items

Requested materials and quantities.

---

## 6.21 purchase_orders

Purchase order header.

---

## 6.22 purchase_order_items

Materials/products and ordered quantities.

---

## 6.23 goods_receipts

Receiving header.

---

## 6.24 goods_receipt_items

Received quantities linked to purchase order items.

---

## 6.25 inventory_transactions

The authoritative inventory movement ledger.

Fields should include:

- organization_id
- branch_id
- warehouse_id
- transaction_type
- material/product
- quantity
- unit
- reference_type
- reference_id
- transaction_date
- created_by

Examples:

- receipt
- issue
- production consumption
- production completion
- sale
- transfer
- return
- waste
- adjustment
- opening balance

---

## 6.26 stock_balances

Current/derived inventory balances.

This must remain consistent with inventory transactions.

Do not allow uncontrolled frontend writes.

---

## 6.27 production_orders

Production order header.

---

## 6.28 production_batches

Actual production execution.

Fields:

- production_order_id
- product_id
- recipe_version_id
- planned_quantity
- produced_quantity
- good_quantity
- rejected_quantity
- waste_quantity
- status

---

## 6.29 production_consumption

Actual material consumption.

Fields:

- production_batch_id
- material_id
- planned_quantity
- actual_quantity
- unit
- unit_cost

---

## 6.30 curing_records

Tracks WIP/cured products.

---

## 6.31 quality_inspections

Quality inspection results.

---

## 6.32 quotations

Quotation header.

---

## 6.33 sales_orders

Sales order header.

---

## 6.34 sales_order_items

Sales order products and quantities.

---

## 6.35 invoices

Invoice header and financial totals.

Totals must be calculated by deterministic backend logic.

---

## 6.36 payments

Customer payments.

---

## 6.37 delivery_orders

Delivery/dispatch records.

---

## 6.38 proof_of_delivery

Proof of delivery records and attachments.

Files are stored in Cloudflare R2.

---

## 6.39 vehicles

Vehicle records.

Advanced fleet management is later scope.

---

## 6.40 maintenance_records

Equipment maintenance information.

Advanced predictive maintenance is later scope.

---

## 6.41 notifications

Stores application notifications.

---

## 6.42 audit_logs

Immutable audit trail for important actions.

Record:

- user
- organization
- action
- entity
- entity ID
- timestamp
- relevant metadata

---

## 6.43 subscriptions

Organization subscription state.

---

## 6.44 subscription_plans

Available SaaS plans.

---

## 6.45 payment_transactions

Snippe.sh payment records.

Must include:

- organization
- amount
- currency
- provider reference
- status
- verification information
- timestamps

---

# 7. AI Features

AI is an intelligence layer over deterministic MOIS systems.

The architecture is:

```text
User
 ↓
Authentication
 ↓
Role
 ↓
Permissions
 ↓
Authorized MOIS Tools
 ↓
AI
 ↓
Answer / Analysis / Recommendation / Action
```

## 7.1 Ask MOIS

Users can ask natural-language questions about authorized business information.

Examples:

- What is our current cement stock?
- What did we produce today?
- Which materials are low?
- What is our sales total?
- Which customers owe money?
- What is happening in the Dodoma branch?
- Which batches had high material consumption?

The AI retrieves data through structured backend tools.

---

## 7.2 AI-Assisted Document Preparation

AI may assist with:

- creating a draft quotation
- creating a draft order
- preparing an invoice draft
- extracting user-provided natural-language instructions into structured fields

Example:

> "Create a quotation for 500 pieces of Product X for Customer Y."

AI can produce a structured draft.

The backend must then validate:

- customer
- product
- availability
- price
- discount
- tax
- totals
- permissions

before saving/finalizing.

---

## 7.3 Operational Analysis

AI can explain structured operational data.

Examples:

- explain material variance
- summarize today's production
- explain stock changes
- identify unusual consumption
- summarize sales
- summarize outstanding receivables

AI responses should distinguish between:

```text
FACT
CALCULATION
ANALYSIS
FORECAST
RECOMMENDATION
ACTION
```

---

## 7.4 AI Recommendations

Initial recommendations should be limited and controlled.

Examples:

- investigate low stock
- investigate unusual material consumption
- follow up overdue customers
- review production variance

AI should recommend rather than autonomously execute consequential operations.

---

## 7.5 AI Model / Technical Approach

The PRD intentionally does not hardcode a specific AI model provider because the validated MOIS technology stack does not specify one.

The implementation must therefore use a **server-side, model-agnostic LLM integration boundary**.

The AI layer must expose structured MOIS tools such as:

```text
get_stock()
get_production()
get_sales()
get_purchase_history()
get_customer_balance()
get_material_variance()
get_branch_summary()
create_draft_invoice()
create_draft_quotation()
```

The actual model/provider must be configured through secure server-side environment configuration once selected.

Do NOT put API keys in Flutter, React, or Next.js client code.

---

## 7.6 AI Must NOT Handle

AI must NOT independently control:

- authentication
- authorization
- tenant isolation
- permissions
- inventory truth
- stock balances
- financial truth
- invoice arithmetic
- tax arithmetic
- payment verification
- subscription status
- database security
- audit logs
- organization ownership
- transaction integrity
- security settings

AI can explain or recommend based on these systems.

It must not replace them.

---

## 7.7 AI Actions

Future controlled action architecture:

```text
EVENT
 ↓
RULE
 ↓
AI ANALYSIS
 ↓
RECOMMENDATION
 ↓
APPROVAL
 ↓
ACTION
```

Risk levels:

### Low Risk

May be automatically executed only when explicitly configured.

### Medium Risk

Requires recommendation/draft and user approval.

### High Risk

Requires explicit human authorization.

---

# 8. Monetization & Subscription Tiers

MOIS uses a SaaS subscription model.

The exact commercial pricing has not yet been finalized and must NOT be invented in the codebase.

Implement pricing as database configuration rather than hardcoding prices.

## Proposed Tier Structure

### Starter

Designed for smaller manufacturers beginning to digitize operations.

Potential limits:

- organizations
- users
- branches
- warehouses
- basic manufacturing
- inventory
- procurement
- sales
- basic reports

### Professional

Designed for growing manufacturers.

Potential additional capabilities:

- more users
- more branches
- advanced reporting
- expanded production capabilities
- costing
- AI operational queries
- additional automation

### Enterprise

Designed for larger manufacturing organizations.

Potential capabilities:

- higher limits
- advanced configuration
- advanced permissions
- advanced AI
- enterprise support
- advanced integrations
- custom workflows where supported

**Exact pricing and entitlement limits remain configurable.**

---

## 8.1 Subscription Architecture

Subscription status belongs to the organization.

Feature access should be determined through:

```text
Organization
 ↓
Subscription
 ↓
Plan
 ↓
Entitlements
 ↓
Feature Access
```

Do not scatter plan-specific `if` conditions throughout the application.

Use centralized entitlement checking.

---

## 8.2 Snippe.sh

Snippe.sh is the only payment provider.

Flow:

```text
MOIS
 ↓
Snippe.sh
 ↓
Payment
 ↓
Server-side verification
 ↓
Payment transaction
 ↓
Subscription update
```

Never trust a client-side payment success response.

Do not implement:

- Stripe
- Pesapal
- alternative payment providers

unless the product requirements are explicitly changed later.

---

# 9. Design Direction

## 9.1 Overall Style

MOIS should feel like:

> **A modern control room for a factory, not an accounting spreadsheet.**

Design characteristics:

- modern
- industrial
- premium
- clean
- information-dense without clutter
- highly readable
- mobile-first operational workflows
- desktop management dashboards
- contextual AI
- clear status indicators
- strong visual hierarchy

Avoid:

- excessive gradients
- gaming aesthetics
- cartoon-like interfaces
- clutter
- spreadsheet-heavy layouts
- unnecessary decorative elements

---

## 9.2 Colors

### Primary Background

**Grey**

### Text

**Black**

All general application text should use black or appropriate accessible black/near-black variants.

### Accent Colors

**Khaki + Coffee / Deep Brown**

Use these primarily for:

- logos
- ribbons
- lines
- dividers
- highlights
- selected brand elements
- subtle accents

Do NOT use khaki or coffee/deep brown as the primary application background.

Do NOT use khaki or coffee/deep brown as general body text.

---

## 9.3 Branding

MOIS is the standardized platform.

Each organization may configure:

- logo
- company name
- brand colors
- document branding
- visual identity

Example:

```text
MOIS Engine
     ↓
Stumarcot Configuration
     ↓
Stumarcot MOIS
```

Branding must have:

> **Zero effect on underlying MOIS technical behavior.**

---

## 9.4 Responsive Design

The same system must support:

### Mobile

- Flutter
- bottom navigation
- maximum 5 primary navigation destinations
- grouped functionality
- quick operational actions
- touch-friendly controls

### Web

- React
- responsive desktop/tablet interface
- expandable/collapsible sidebar
- dashboards
- tables
- reports
- administration

### Marketing

- Next.js
- separate marketing/landing website

---

# 10. Non-Functional Requirements

## 10.1 Technology Stack

Use exactly:

### Mobile

**Flutter**

### Web Application

**React**

### Marketing Website

**Next.js**

### Backend / Database / Authentication / Realtime

**Supabase + PostgreSQL**

### Caching

**Cloudflare**

### File / Media Storage

**Cloudflare R2**

### CDN

**Cloudflare CDN**

### Payments

**Snippe.sh**

### Web Hosting

**Cloudflare**

### CI/CD

**GitHub Actions**

Including Flutter APK/AAB builds.

### Version Control

**Git + GitHub**

Do not substitute these technologies.

---

# 10.2 Multi-Tenancy

Every tenant-owned record must be isolated.

Primary rule:

```text
Every tenant-owned record
        ↓
organization_id
```

Use Supabase PostgreSQL Row Level Security.

RLS is mandatory.

Never rely only on frontend filtering for tenant isolation.

---

# 10.3 Authorization

Authorization must be enforced server-side/database-side.

Permission hierarchy:

```text
USER
 ↓
ROLE
 ↓
PERMISSION
 ↓
ORGANIZATION SCOPE
 ↓
BRANCH SCOPE
 ↓
WAREHOUSE SCOPE
 ↓
ACTION
```

A user must never gain access simply by manipulating frontend requests.

---

# 10.4 Authentication

Use Supabase Auth.

Support:

- email/password
- Google OAuth
- email verification
- password reset
- logout
- session management

Never expose secret credentials in frontend applications.

---

# 10.5 Inventory Integrity

Critical inventory operations must be:

- transactional
- duplicate-safe
- auditable
- server-authoritative

Do not perform uncontrolled direct stock mutations.

---

# 10.6 Financial Integrity

Financial totals must be calculated deterministically.

AI must never be the authoritative calculator.

---

# 10.7 Offline Support

Flutter should support practical offline workflows where operationally useful.

Offline architecture:

```text
User Action
 ↓
Local Temporary State
 ↓
Offline Queue
 ↓
Connectivity Restored
 ↓
Synchronization
 ↓
Server Validation
 ↓
Authoritative Server State
```

Requirements:

- offline detection
- queued transactions
- duplicate prevention
- conflict detection
- retry mechanism
- server-authoritative final state

Do not attempt to make the entire application fully offline if it compromises data integrity.

Prioritize practical operational workflows.

---

# 10.8 Realtime

Use Supabase Realtime where useful for:

- stock updates
- production status
- notifications
- order status
- operational dashboards

Do not use realtime unnecessarily for every query.

---

# 10.9 File Storage

Use Cloudflare R2 for:

- company logos
- product images
- invoices
- quotations
- documents
- proof of delivery
- attachments

Use Cloudflare CDN for appropriate public/cacheable assets.

Sensitive files must remain private and access-controlled.

---

# 10.10 Caching

Use Cloudflare caching for safe read-heavy/public content.

Do NOT publicly cache:

- tenant-sensitive data
- private financial information
- private inventory information
- user-specific data
- authorization-sensitive responses

---

# 10.11 Notifications

Use Firebase Cloud Messaging for push notifications.

Notifications must respect:

- tenant scope
- branch scope
- permissions
- user preferences

---

# 10.12 Error Handling

Users must receive understandable error messages.

Never expose:

- raw database errors
- stack traces
- secrets
- internal implementation details

Frontend should show useful messages such as:

> "We couldn't save this transaction. Please try again."

Detailed technical errors belong in internal logs.

---

# 10.13 Performance

Requirements:

- indexed PostgreSQL queries
- pagination for large datasets
- avoid unnecessary database requests
- lazy loading where appropriate
- optimized images
- compressed media
- CDN delivery
- efficient realtime subscriptions
- avoid loading entire tables into the client
- responsive interactions

---

# 10.14 Localization

Initial interface language:

> **English**

Architecture must support:

> **Swahili**

without requiring major architectural changes.

Currency must be configurable.

Initial primary currency support:

> **TZS**

---

# 10.15 Auditability

Important actions must be recorded.

Examples:

- login/security events where appropriate
- stock adjustments
- inventory transactions
- production completion
- invoice creation
- payment recording
- permission changes
- configuration changes
- user activation/deactivation

Audit records must identify:

- who
- what
- when
- organization
- affected entity
- relevant metadata

---

# 10.16 Monitoring

### React Web

Use Sentry for error reporting.

### Flutter

Use Firebase Crashlytics / appropriate Firebase crash-reporting tooling.

Do not expose monitoring credentials to users.

---

# 10.17 CI/CD

GitHub Actions must support:

- web builds
- automated checks
- Flutter builds
- APK builds
- AAB builds where required

Never automatically push or deploy destructive changes.

---

# 11. MVP Scope vs Future Phases

## PHASE 1 — MOIS CORE / V1 LAUNCH

The objective of V1 is:

> **Make MOIS the operational source of truth for a manufacturing business.**

V1 must include only the capabilities required to prove that value.

### Required

#### Foundation

- authentication
- multi-tenancy
- organizations
- branches
- warehouses
- users
- roles
- permissions
- audit logs
- company configuration
- branding configuration

#### Master Data

- products
- product categories
- raw materials
- units
- suppliers
- customers
- recipes/BOMs

#### Procurement

- purchase requests
- purchase orders
- goods receiving
- supplier history

#### Inventory

- opening balances
- receiving
- material issues
- transfers
- adjustments
- stock counts
- stock balances
- inventory reports

#### Production

- production orders
- recipe selection
- production batches
- material consumption
- standard vs actual consumption
- good quantity
- rejection
- waste
- WIP
- curing
- finished goods

#### Sales

- customers
- catalogue
- pricing
- quotations
- proformas
- sales orders
- invoices
- payments
- customer balances

#### Costing

- material cost
- batch cost
- unit cost
- basic profitability
- standard vs actual consumption

#### Reports

- inventory
- production
- sales
- purchases
- receivables
- basic profitability

#### AI V1

- Ask MOIS
- authorized operational questions
- basic analysis
- AI-assisted document drafts
- limited recommendations

#### Billing

- subscription plans
- subscription state
- Snippe.sh payment integration
- server-side payment verification

---

# PHASE 2 — MOIS INTELLIGENCE

Phase 2 moves MOIS from recording operations to understanding and controlling them.

Add:

- advanced finance/accounting
- payables
- receivables
- cash flow
- advanced costing
- production planning
- capacity planning
- efficiency analysis
- advanced variance analysis
- advanced quality
- logistics
- fleet
- maintenance
- advanced CRM
- advanced dashboards
- branch intelligence
- approval workflows
- document automation
- advanced AI analysis
- AI recommendations
- controlled automation

AI progression:

```text
Ask
 ↓
Analyze
 ↓
Explain
 ↓
Recommend
```

---

# PHASE 3 — MOIS PREDICTIVE & AUTONOMOUS

Phase 3 moves MOIS from understanding operations toward prediction, optimization, and controlled action.

Add:

- demand forecasting
- material forecasting
- production forecasting
- cash forecasting
- stock optimization
- supplier optimization
- production optimization
- predictive maintenance
- AI agents
- approval-based autonomous actions

AI progression:

```text
Predict
 ↓
Optimize
 ↓
Act
```

---

# Long-Term Ecosystem

These are NOT required for V1:

- industry benchmarking
- supplier intelligence
- procurement network
- logistics network
- marketplace
- financing connections
- broader manufacturing ecosystem

These should only be pursued after product-market fit is demonstrated.

---

# V1 Success Criteria

V1 is successful when a real manufacturer can operate its core workflow through MOIS:

```text
Purchasing
   ↓
Receiving
   ↓
Inventory
   ↓
Production
   ↓
Finished Goods
   ↓
Sales
   ↓
Payments
```

Success is NOT measured by the number of screens built.

Measure:

- stock accuracy
- production recording accuracy
- transaction traceability
- reduction in manual reporting
- user adoption
- management visibility
- ability to answer operational questions quickly

For Stumarcot specifically, the target is for MOIS to become the operational source of truth rather than merely another reporting application.

---

# 12. Open Questions / Assumptions

The following items have not been fully finalized and should be configurable rather than hardcoded.

## 12.1 Exact Subscription Pricing

The pricing amounts for Starter, Professional, and Enterprise are not yet finalized.

**Assumption:** Store plans and prices in database configuration.

---

## 12.2 Exact AI Model Provider

A specific AI model/provider has not been locked into the validated technology stack.

**Assumption:** Build a server-side model abstraction/tool-calling layer so the model can be selected/configured without redesigning MOIS.

---

## 12.3 Tax Configuration

Exact tax rules and compliance requirements have not been fully specified.

**Assumption:** Do not hardcode tax behavior into the frontend. Build configurable tax fields/rules where needed and validate the exact requirements before production financial/compliance use.

---

## 12.4 Accounting Depth

V1 provides basic financial visibility and costing.

Full accounting is Phase 2.

**Assumption:** Do not turn V1 into a full accounting ERP.

---

## 12.5 Stumarcot Historical Data

Stumarcot reference documents may contain historical operational information.

**Assumption:**

- documents are used during development to understand requirements
- historical data may be used for controlled validation
- actual live Stumarcot operational data should ultimately enter through normal MOIS workflows
- Stumarcot data must not be hardcoded into MOIS source code

---

## 12.6 Stumarcot-Specific Requirements

Stumarcot is the first validation tenant.

**Assumption:**

Stumarcot-specific information becomes either:

1. MOIS Core capability,
2. Stumarcot tenant configuration, or
3. future capability.

Never create a separate Stumarcot software engine.

---

## 12.7 Offline Depth

The exact offline workflows are not fully defined.

**Assumption:** Prioritize offline support for practical operational transactions where connectivity problems would otherwise prevent factory work, while keeping the server authoritative.

---

## 12.8 Customer Portal

A full customer self-service portal is not essential to prove V1.

**Assumption:** Customer portal capabilities can remain limited or move to a later phase unless required by validated workflows.

---

## 12.9 Advanced Fleet Management

Basic delivery functionality may exist in V1 where required.

Full fleet management belongs to Phase 2.

---

## 12.10 Predictive AI

Forecasting, predictive maintenance, autonomous agents, and optimization are explicitly outside V1.

Do not prematurely build them.

---

# 13. Implementation Rules for the Coding Agent

The coding agent must follow these rules throughout development.

## Rule 1 — Inspect Before Changing

Before modifying an existing implementation:

- inspect the project structure
- inspect relevant files
- inspect existing database schema
- inspect existing routes/screens
- inspect dependencies
- inspect environment configuration
- inspect Git status

Do not blindly overwrite working code.

---

## Rule 2 — Preserve the MOIS Core

Do not introduce Stumarcot-specific business logic.

If a Stumarcot requirement appears:

```text
Requirement
 ↓
Core capability?
 ↓
Configuration?
 ↓
Future capability?
```

Make the correct architectural decision before coding.

---

## Rule 3 — Database First for Critical Logic

Critical business rules must not exist only in frontend code.

Authoritative logic must be enforced through appropriate backend/database mechanisms.

---

## Rule 4 — RLS Is Mandatory

Every tenant-owned table must have appropriate Supabase Row Level Security policies.

Never rely on:

```text
WHERE organization_id = currentOrganization
```

in the frontend as the security boundary.

---

## Rule 5 — Transactions Must Be Safe

Inventory and financial operations must be:

- atomic where necessary
- duplicate-safe
- auditable
- server-authoritative

---

## Rule 6 — No Hardcoded Secrets

Never commit:

- API keys
- service-role keys
- payment secrets
- OAuth secrets
- AI API keys
- production credentials

Use environment configuration.

---

## Rule 7 — No Technology Substitution

Use only the approved stack:

```text
Flutter
React
Next.js
Supabase/PostgreSQL
Cloudflare
Cloudflare R2
Cloudflare CDN
Snippe.sh
GitHub Actions
```

Do not replace them with alternative platforms.

Do not introduce Stripe or Pesapal.

---

## Rule 8 — Build in Small Verified Increments

For each major feature:

1. define database requirements
2. implement backend/security
3. implement UI
4. test
5. verify permissions
6. verify tenant isolation
7. verify mobile/web behavior
8. document the implementation

---

## Rule 9 — Do Not Build Unnecessary Features

If a feature is not required for V1's core value, move it to Phase 2 or Phase 3.

Do not expand scope simply because the architecture could support it.

---

## Rule 10 — Documentation

Maintain project documentation for:

```text
/docs
    architecture.md
    database.md
    security.md
    ai.md
    testing.md
    deployment.md
    decisions.md
```

Keep documentation synchronized with implementation.

---

# 14. Final Product Principle

MOIS is not simply an ERP.

It is a:

> **Manufacturing Operating Intelligent System.**

Its purpose is to connect the factory's physical operations with its economic reality and progressively transform operational data into useful intelligence.

The product progression is:

```text
RECORD
   ↓
CONNECT
   ↓
CONTROL
   ↓
UNDERSTAND
   ↓
EXPLAIN
   ↓
RECOMMEND
   ↓
ACT
   ↓
PREDICT
   ↓
OPTIMIZE
```

V1 focuses primarily on:

```text
RECORD
CONNECT
CONTROL
UNDERSTAND
```

Later phases progressively add:

```text
EXPLAIN
RECOMMEND
ACT
PREDICT
OPTIMIZE
```

The ultimate question behind every MOIS feature is:

> **How much better can a factory operate because MOIS exists?**

---

# 15. Architecture Principle

MOIS must be built as:

```text
                         MOIS
               STANDARD MANUFACTURING ENGINE
                            │
             ┌──────────────┴──────────────┐
             │                             │
   STUMARCOT CONFIGURATION            OTHER TENANTS
             │                             │
   STUMARCOT EXPERIENCE               THEIR EXPERIENCE
```

One powerful engine.

Different companies.

Different products.

Different data.

Different branding.

Different configuration.

But never a different underlying manufacturing engine.

> **CUSTOMIZE THE EXPERIENCE. DO NOT CUSTOMIZE THE CORE ENGINE.**

> **SAME DIESEL ENGINE + DIFFERENT BODY.**

# END OF PRD