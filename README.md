# Build Prompt: Rent Management SaaS

Build a multi-tenant SaaS application for property owners to manage apartment
and/or cottage rentals — automated invoicing, dynamic rent, multi-channel
tenant messaging, tenant history, reporting, a super admin panel, and
subscription billing with a free trial. Follow every section below exactly;
none are optional polish.

---

## 1. Tech Stack

- **Frontend:** React with Vite
- **Backend/DB:** Supabase — Postgres, Row Level Security, Auth, Realtime
- **Data fetching/caching:** React Query (TanStack Query) as the single
  server-state layer for both mobile and desktop views
- **Styling:** fully responsive — mobile behaves like a native app, desktop
  gets a denser table-based layout (see Section 9)

Use the attached `schema.sql` as the source of truth for the database —
implement the app against those tables, enums, views, and RLS policies
exactly as defined. Do not invent parallel tables for the same concept.

---

## 2. User Roles

1. **Super admin** — platform operator, one or more rows in `super_admins`.
   Full cross-owner visibility via `is_super_admin()`.
2. **Owner** — a property-owning SaaS customer, one row in `owners`,
   `auth.users`-backed. Everything they see is scoped to their `owner_id`.
3. **Tenant** — the renter. Not a login/auth role in v1 unless you decide
   otherwise; tenants are data records the owner manages, contacted via
   SMS/WhatsApp/email, not app users.

---

## 3. Onboarding & Property Type

- On signup, the owner selects a property type: **Apartment**, **Cottage**,
  or **Both**. Store this on `owners.default_property_type` /
  `owners.onboarded_both_types`.
- Navigation and forms adapt to this choice — an apartment-only owner never
  sees cottage/seat UI, and vice versa; "Both" shows both.
- Underlying data model is shared regardless of choice: `Property → Unit →
  Seat(s) → Tenant(s) → Lease`.

---

## 4. Bulk Property/Unit Creation

- Owner creates a property, then bulk-generates units in one submit: give a
  property name, unit count, and a numbering pattern/prefix
  (`numbering_patterns` table) — e.g. prefix `A` + count `12` → `A-1`…`A-12`.
- Shared defaults (dimension, deposit, rent, facilities, rules, charges) come
  from a reusable `unit_templates` row selected during bulk creation.
- After bulk creation, every generated unit is individually editable.
- **Critical:** template values are a one-time snapshot onto the
  unit/lease/invoice at creation time. Editing a template later must never
  retroactively change already-created units, leases, or invoices.

---

## 5. Cottage Seat Model

- A cottage `unit` (a room) can be divided into multiple `seats`, each with
  its own rent amount (`seats.seat_rent`).
- A tenant can hold 1..N seats under a single `lease`, billed together via
  `lease_seats` (which snapshots each seat's rent at lease time).
- Rent is tracked and edited at the seat level; invoicing and payment happen
  at the tenant level (one invoice covers all of a tenant's seats).

---

## 6. Lookup Tables

Implement admin-manageable CRUD for: `property_types`, `facility_templates`,
`rule_templates`, `charge_types`, `invoice_types`, `invoice_statuses`,
`payment_methods`, `numbering_patterns`.

- Rows with `owner_id = null` are global system defaults, read-only to
  owners, editable only by the super admin.
- Owners can add their own custom rows scoped to their `owner_id`.
- Every owner-facing picker (facility list, charge list, etc.) must merge
  system defaults + that owner's custom entries.

---

## 7. Rent & Invoicing Engine

- Invoices auto-generate on each tenant's **joining-date anniversary**.
  Billing cycle mode is configurable per owner: `fixed_30_day` or
  `calendar_month` (`owners.billing_cycle_mode`) — implement both cleanly
  behind one interface so the owner can pick either.
- Owner configures a **grace period** (payment window) after cycle
  completion, scoped either `per_property` or `per_tenant`
  (`owners.grace_scope`, with `leases.grace_period_days` as the per-tenant
  override).
- **Hard rule, enforce at the DB level (already done via a partial unique
  index in the schema):** exactly one non-void rent invoice per tenant per
  billing period. Never allow app code to bypass this.
- Support partial payments against an invoice, and maintain a running
  per-tenant ledger (`ledger_entries`) that reflects invoice charges and
  payments as they land — this is what the dashboard reads for balances.

---

## 8. Fines

- Fines are their own `invoice_type` (kind = `fine`), separate from rent.
- A fine can optionally link to the rent invoice it penalizes via
  `invoices.linked_invoice_id`.
- Fines are explicitly excluded from the one-rent-invoice-per-month rule —
  do not let the fine flow trip that constraint.
- Decide and document whether fines can stack more than once per cycle for
  the same tenant (open decision — default to "yes, unlimited" unless told
  otherwise, since nothing in the schema currently blocks it).

---

## 9. Annual Rent Increase

- After 1 year of tenancy, add a rent increase on the tenant's anniversary.
- Increase can be **fixed amount** or **percentage**
  (`leases.rent_increase_mode`).
- Toggle globally (owner-level default) or per individual tenant — an
  individual override always wins over the global setting
  (`leases.rent_increase_enabled`, `leases.increase_scope`).
- Every increase writes a row to `rent_history` with the old/new amount,
  effective date, and reason — this is an audit trail, never a live
  recalculated formula. The app must always read current rent from the
  lease/rent_history, not derive it from a formula at render time.
- Before the increase takes effect, send an **announcement message**
  through the messaging engine (Section 10) and link it via
  `rent_history.announced_message_id`.

---

## 10. Automated Messaging Engine

Implement a pipeline covering these purposes (`message_purpose` enum):
`reminder → warning → overdue → announcement → rent_increase`.

- Channel is configurable per purpose: SMS/WhatsApp for tenant-facing
  messages, email/in-app for owner-facing notifications
  (`message_channel` enum covers all four — wire up at least one working
  provider integration per channel you actually ship, mock the rest behind
  the same interface).
- `message_templates` holds the editable body per purpose/channel (system
  defaults + owner custom overrides, same pattern as Section 6).
- `messages_log` records every send attempt with status
  (`queued/sent/failed/delivered`) — surface failures somewhere the owner
  can see them, don't let sends fail silently.

---

## 11. Tenant History & Reports

Build these reports, all owner-scoped:

- Per-tenant payment/track record across all their seats/units
- Monthly collection summary
- Occupancy rate
- Overdue aging report
- Year-end statement
- Owner income/expense summary (pulls from `expenses` + collected rent)
- Renewal-due list (leases approaching `end_date`)

Reports should be backed by SQL views/queries where practical rather than
computed ad-hoc in the frontend, so they stay consistent with the ledger.

---

## 12. Responsive UI Plan

**Mobile (app-like):**
- Sticky **bottom** navigation bar (not top nav)
- Dashboard prioritizes: today's/this-week's due amount, overdue count,
  quick stats (occupancy, collection rate)
- Prominent quick-action buttons: "Record Payment," "Add Tenant," "Send
  Reminder," "Generate Invoice" — as a floating action button or horizontal
  quick-action row
- Card-based lists for touch-friendly scanning

**Desktop:**
- Sidebar navigation instead of bottom bar
- Table-based views for properties/tenants/invoices — denser and more
  scannable
- Dashboard shows more simultaneous widgets (charts, multiple report
  summaries) since there's room

**Shared:**
- One React Query cache/data layer powers both layouts — only presentation
  components differ, keep the logic DRY
- Use a layout breakpoint hook (e.g. `useIsMobile`) to conditionally render
  `BottomNav` vs `Sidebar`, `QuickActionBar` vs standard desktop buttons

---

## 13. V2 Additions (build these too, not just the core loop)

- Security deposit tracking with move-out deduction (`deposit_transactions`)
- Move-in/move-out workflow with condition reports (`move_events`)
- Utility/shared cost splitting across tenants (`utility_bills` +
  `utility_bill_splits`)
- Owner expense tracking / P&L (`expenses`)
- Document storage — lease, ID, receipts (`documents`, store files in
  Supabase Storage, keep only the URL in the `documents` table)

---

## 14. Super Admin Panel

- Separate login/route space, gated by `is_super_admin()` — a super admin
  is a row in `super_admins`, never just an owner with a flag.
- Must be able to **monitor every owner's data** — properties, tenants,
  leases, invoices, payments — for support/oversight purposes. RLS already
  allows this (owner-isolation policies include `OR is_super_admin()`); the
  admin UI should expose owner search/drill-down, not just aggregate stats.
- Must include an **audit log viewer** reading from `audit_logs`
  (`actor_type`, `actor_id`, `owner_id`, `action`, `entity_type`,
  `entity_id`, `metadata`, `created_at`). Log meaningful actions from both
  owner and admin sides (logins, creates/edits/deletes on tenants, leases,
  invoices, payments; admin actions on any owner's data).
- Audit log data **auto-deletes after 7 days** — this is handled at the DB
  level via a `pg_cron` job (already in `schema.sql`), not app code. Make
  sure the admin UI doesn't assume audit history persists longer than a
  week, and don't build any feature that depends on audit logs older than
  that.
- Admin panel should also show subscription/billing status per owner (see
  Section 15) — who's trialing, who's active, who's past due — since that's
  core to "monitor everything."

---

## 15. Subscription & Trial Billing

- Every new owner automatically gets a **14-day free trial** starting at
  signup — this is already wired via a DB trigger
  (`fn_create_trial_subscription`) that inserts a `subscriptions` row with
  `status = 'trialing'` and `trial_end = signup date + 14 days`. Don't
  duplicate this logic in the app; just read the result.
- After the trial ends, the owner must pay a **recurring monthly amount** to
  keep using the system. Integrate a real payment provider (e.g. Stripe) to:
  - Create/manage the subscription and collect the monthly charge
  - Update `subscriptions.status` (`active`, `past_due`, `canceled`,
    `expired`) and `current_period_start/end` via webhook
  - Write `subscription_invoices` / `subscription_payments` rows so billing
    history is visible to both the owner and the super admin
- Gate app access off the `v_owner_access` view (`has_access = true` while
  trialing-and-not-expired, or while `active`). When access is false, block
  the owner's app UI behind a "please subscribe" screen — do not delete or
  hide their underlying data, only block the interface.
- Show the owner their trial countdown / current plan status somewhere
  persistent (e.g. a banner or account settings page).

---

## 16. Build Order

Follow this sequence — each step should be functionally complete and
testable before moving to the next:

1. **Core schema** — apply `schema.sql` as-is against Supabase; verify RLS
   policies and the trial trigger work end-to-end with a test owner signup.
2. **Auth + onboarding** — owner signup (triggers trial subscription),
   property-type selection, super admin login path.
3. **Bulk creation flow** — properties, unit templates, bulk unit
   generation, cottage seats.
4. **Invoice generation engine** — billing cycle, grace window, duplicate
   prevention, rent increase logic, tenant ledger, fines.
5. **Responsive shell** — bottom nav/sidebar, dashboard quick actions,
   wired to React Query.
6. **Messaging engine** — templates, send pipeline, delivery logging.
7. **Reports dashboard** — all reports from Section 11.
8. **Super admin panel** — owner monitoring, audit log viewer, billing
   status overview.
9. **Subscription billing integration** — payment provider wiring, webhook
   handling, access gating.
10. **V2 polish** — deposits, move-in/out, utility splitting, expenses,
    documents.

---

## 17. Open Decisions to Confirm or Default Sensibly

If not explicitly resolved before you start, default as noted and flag it
clearly in your output so it can be revisited:

- Billing cycle: `fixed_30_day` vs `calendar_month` — default `fixed_30_day`
- Grace window scope: `per_property` vs `per_tenant` — default
  `per_property`
- Fine stacking per cycle — default: allowed, unlimited
- Messaging channel priority/cost tradeoff (SMS vs WhatsApp vs email) —
  default: WhatsApp first, SMS fallback, email for owner-facing only
- Rent increase mode default — `fixed` amount, with `percentage` available
  as an explicit per-lease override