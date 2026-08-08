# Rent Management SaaS — Full Plan Report (v2)

## 1. Tech Stack

| Layer | Choice |
|---|---|
| Frontend | React (Vite) |
| Backend | **None separate** — Supabase (Postgres, RLS, Auth, Realtime) is the entire backend |
| Data fetching/caching | Direct `supabase-js` calls from custom React hooks — **no React Query** |
| Live updates | Supabase Realtime channels (`postgres_changes`) pushed into React state |
| Styling | Responsive, mobile-app-like on small screens, full desktop layout on large screens |

**Why no React Query:** the app talks straight to Supabase with no intermediary server, so there's nothing for a query-caching library to sit in front of beyond what Supabase itself provides. Data needs (invoices, payment status, tenant ledgers, overdue lists) are handled with:
- Small custom hooks (`useInvoices`, `useTenants`, `useLedger`, …) wrapping `supabase-js` `select`/`insert`/`update` calls with local `useState`
- Manual optimistic updates for actions like "mark invoice paid" or "record payment" — update local state immediately, call Supabase, roll back on error
- Supabase Realtime subscriptions for anything that should update live across a session (e.g. dashboard refreshing when a payment lands), replacing what React Query + polling would have done

## 2. Core Concept
Multi-tenant SaaS for property owners managing apartment and/or cottage rentals — automated invoicing, dynamic rent, multi-channel messaging, tenant history, and reporting.

## 3. Onboarding & Property Type
- Owner selects property type at registration: Apartment, Cottage, or Both
- Navigation/forms conditional on that choice
- One shared data model underneath: Property → Unit → Seat(s) → Tenant(s) → Lease

## 4. Bulk Property/Unit Creation
- Property name + unit count + prefix/numbering pattern → generate all units in one submit
- Shared defaults (dimension, deposit, rent, rules, facilities, charges) via reusable templates
- Individual units editable after bulk creation
- Template values snapshot onto lease/invoice at creation time (no retroactive changes)

## 5. Cottage Seat Model
- Room → multiple seats, each with individual rent
- Tenant can hold 1..N seats, billed together
- Rent tracked at seat level; invoicing/payment at tenant level

## 6. Lookup Tables
`property_types`, `facility_templates`, `rule_templates`, `charge_types`, `invoice_types`, `invoice_statuses`, `payment_methods`, `numbering_patterns` — global system defaults + owner-scoped custom entries.

## 7. Rent & Invoicing Engine
- Auto-generated per tenant's joining-date anniversary, month = 30 days (calendar-drift decision still open)
- Owner-configured payment window (grace period) after month completion
- Strict no-duplicate-invoice-per-tenant-per-month, enforced at DB level
- Partial payments with running tenant ledger

## 8. Fines
- Separate invoice type from rent, optionally linked to the rent invoice they penalize
- Don't count against duplicate-rent-invoice rule

## 9. Annual Rent Increase
- Fixed amount added after 1 year of tenancy, per tenant anniversary
- Toggle globally or per individual tenant (individual overrides global)
- Snapshot to `rent_history` with audit trail, not a live recalculated formula
- Should trigger an announcement message before taking effect

## 10. Automated Messaging Engine
- Reminder → warning → overdue escalation → announcements → rent increase notices
- Channel: SMS/WhatsApp (tenant-facing) vs email/in-app (owner-facing) — decision pending

## 11. Tenant History & Reports
- Per-tenant payment/track record across all seats/units
- Reports: monthly collection summary, occupancy rate, overdue aging, year-end statement, owner income/expense, renewal-due list

## 12. Responsive UI Plan

**Mobile (app-like):**
- Sticky bottom navigation bar (not top nav) — matches native app conventions
- Dashboard prioritizes: today's/this-week's due amount, overdue count, quick stats (occupancy, collection rate)
- **Quick action buttons** on dashboard: e.g. "Record Payment," "Add Tenant," "Send Reminder," "Generate Invoice" — surfaced prominently, likely as a floating action button or a horizontal quick-action row
- Card-based lists for touch-friendly scanning (already part of your current UI direction)

**Desktop:**
- Sidebar navigation instead of bottom bar
- Table-based views (already in progress per your current app) for properties/tenants/invoices — denser, more scannable on larger screens
- Dashboard can show more simultaneous widgets (charts, multiple report summaries) since screen space allows it

**Shared:**
- Same custom Supabase hooks / data layer powers both layouts — only the presentation components differ, keeping logic DRY
- Consider a layout breakpoint hook (e.g. `useIsMobile`) to conditionally render `BottomNav` vs `Sidebar`, and `QuickActionBar` vs standard desktop buttons
- Realtime subscriptions live at the layout/data-hook level so both mobile and desktop views get the same live updates for free

## 13. Super Admin, Billing & Audit Log
- Every owner account gets a 14-day free trial on signup; after it lapses, owner must pay a monthly amount to keep using the system
- Access-gating is a single boolean check against Supabase (`v_owner_access` view: trialing-and-not-expired, or active subscription)
- Super admin panel (separate role, `super_admins` table) can monitor everything across all owners — properties, tenants, invoices, subscription status — via RLS policies that grant admins visibility on top of each owner's own row-level access
- Audit log records actor, action, entity, and metadata for platform activity
- Audit log data lives in the database and is **automatically deleted after 7 days** (scheduled daily purge)

## 14. Not-Yet-Built Additions Worth Including
- Security deposit tracking with move-out deduction
- Move-in/move-out workflow
- Utility/shared cost splitting
- Owner expense tracking / P&L
- Document storage (lease, ID, receipts)

## 15. Open Decisions
- 30-day cycle vs calendar month with proration
- Grace window: per-property or per-tenant
- Whether fines can stack multiple times per cycle
- Messaging channel priority (SMS cost vs WhatsApp vs email)
- Percentage-based rent increase option in addition to fixed amount

## 16. Build Order
1. ~~Core schema (Owner → Property → Unit → Seat → Tenant → Lease) + lookup tables~~ — **done** (includes super admin, subscription/trial billing, and audit log)
2. Bulk creation flow + reusable templates
3. Invoice generation engine (cycle, grace window, duplicate prevention, rent increase logic) + tenant ledger
4. Responsive shell (bottom nav/sidebar, dashboard quick actions) wired directly to Supabase via custom hooks + Realtime subscriptions
5. Messaging engine
6. Reports dashboard
7. Super admin panel + trial/subscription billing gate + audit log UI
8. Deposits, expenses, documents (v2 polish)