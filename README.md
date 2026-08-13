# Rently — Multi-tenant Rent Management SaaS

A SaaS for property owners managing apartment and/or cottage rentals: automated
invoicing, dynamic rent, tenant messaging, tenant history, reporting, and a
super-admin layer with trial-based billing and a self-cleaning audit log.

## Stack

- **Frontend:** React + Vite, `supabase-js` called from small custom hooks, manual
  optimistic updates, Supabase Realtime (`postgres_changes`) for anything live.
- **Backend:** Supabase only. All business logic lives in Postgres — constraints,
  triggers, views, `pg_cron` jobs. No custom app server.
- **Styling:** Responsive. Mobile = native-app feel (bottom nav, card lists,
  floating action button). Desktop = sidebar + dense tables. Both share the same
  data hooks; only presentation differs (see `useIsMobile`).

## Architecture

```
Owner (account) → Property → Unit → Seat(s) → Tenant(s) → Lease
```

One shared schema underlies both apartment and cottage rentals. Cottages split a
unit into seats; a tenant may hold multiple seats billed as one tenant-level
invoice while rent is tracked per seat.

### Recurring patterns

- **Snapshot, don't recompute.** Unit templates, seat/unit rent and rent increases
  are snapshotted at creation/change time (`unit.template_snapshot`,
  `lease.rent_amount`, `rent_history`). Later template edits never retroactively
  change existing records.
- **Lookups over free text.** `property_types`, `invoice_types`, `invoice_statuses`,
  `payment_methods`, `numbering_patterns`, `charge_types`, `facility_templates`,
  `rule_templates` — each row is either a system default (`owner_id IS NULL`,
  read-only) or a per-owner custom entry.
- **Multi-tenant isolation.** Every owner-scoped table has `owner_id = auth.uid()`
  RLS plus an `is_super_admin()` bypass for the admin panel.
- **DB-level enforcement.** A partial unique index guarantees a tenant can't hold
  more than one non-void rent invoice per billing period.

## Setup

1. Create a Supabase project.
2. Run the migrations in `supabase/migrations/` (001 → 013) in the SQL editor or
   with the CLI, then run `supabase/seed.sql`.
3. Copy `.env.example` to `.env.local` and set `VITE_SUPABASE_URL` and
   `VITE_SUPABASE_ANON_KEY`.
4. `npm install && npm run dev`
5. Sign up — a 14-day free trial is provisioned automatically by the
   `on_owner_signup` trigger on `auth.users`. The signup form collects a phone
   number that is stored on the owner record (`owners.contact_phone`).

### Provisioning a super admin

Insert the auth user id into `super_admins` (use the service role / SQL editor):

```sql
insert into public.super_admins (user_id)
values ('<the-auth-user-id>');
```

## Key decisions (defaults chosen)

| Decision | Default | Where |
| --- | --- | --- |
| Billing cycle | 30-day fixed, anchored to the tenant's join date | `tenant_cycle_bounds` |
| Grace period scope | Per-property (`properties.grace_days`), lease overrides, owner default | `tenant_billing` |
| Fine stacking | Allowed by default; configurable per owner | `owner_settings.fine_stacking_allowed` |
| Messaging channels | Tenant-facing: WhatsApp/SMS; owner-facing: email/in-app | `owner_settings.*_channels`, channel-agnostic `messages` queue |
| Annual rent increase | Fixed amount and/or percent; global toggle + per-tenant override; `rent_history` audit | `apply_rent_increases` |
| Access gate | Single view `owner_access` (subscription + trial end + period) checked once by the frontend | `get_access_status` |
| Audit log | 7-day retention via a daily `pg_cron` job | `delete_old_audit_log` |

## Invoicing engine

- Invoices are generated per tenant per cycle by `ensure_rent_invoice`
  (idempotent) — invoked on lease creation and by the daily `pg_cron` job
  `rently-daily-invoices`.
- Partial payments: `record_payment` inserts a payment and a trigger keeps
  `invoices.amount_paid`/`status_key` in sync (`open → partially_paid → paid`).
  A daily job marks unpaid past-due invoices `overdue`.
- Fines are a separate invoice type, optionally linked to a rent invoice, and
  excluded from the one-rent-invoice-per-period constraint.
- `tenant_ledger` is a windowed view giving each tenant's running balance after
  every entry.

## Messaging engine

`messages` is a channel-agnostic outbox. Automated jobs queue
reminder → warning → escalation by overdue age (`generate_reminders`) and
rent-increase notices. Owners can broadcast announcements via
`create_announcement`. `dispatch_queued_messages` simulates sending when no
provider is configured — a production Edge Function reads `queued` rows and
delegates to the provider chosen in settings.

### Sending real SMS via bulkSMSBD (Bangladesh)

SMS messages (channel `sms`) are dispatched to tenants through
[bulkSMSBD](https://bulksmsbd.net) by the Vercel serverless function
`/api/dispatch-sms`. Deploy the frontend to Vercel and set these environment
variables (Vercel → Project → Settings → Environment Variables):

| Variable | Value |
| --- | --- |
| `VITE_SUPABASE_URL` | your Supabase project URL |
| `VITE_SUPABASE_ANON_KEY` | anon key (client) |
| `SUPABASE_SERVICE_ROLE_KEY` | service role key (server only, never exposed) |
| `BULKSMSBD_API_KEY` | bulkSMSBD account API key |
| `BULKSMSBD_SENDER_ID` | approved sender ID, e.g. `8809648906525` |

The `vercel.json` cron calls `/api/dispatch-sms` every 5 minutes (cron on the
Pro plan; on Hobby you can trigger it manually with the "Dispatch now" button
on the Messaging page). The function:

1. Reads `queued` + `sms` messages due now.
2. Normalizes the recipient number to `880...` and calls the bulkSMSBD
   `smsapimany` endpoint with one payload for all messages.
3. Marks them `sent` on `202`, otherwise `failed` with the provider error code
   (`1001` invalid number, `1007` insufficient balance, `1032` IP not
   whitelisted, etc.).
4. Non-SMS queued channels are still marked `sent` (simulated) since no other
   real provider is configured.

## Scheduled jobs (pg_cron)

| Job | Schedule | Function |
| --- | --- | --- |
| Daily invoicing | 02:00 | `generate_due_invoices()` |
| Overdue recompute | 03:00 | `recompute_overdue()` |
| Rent increases | 04:00 | `apply_rent_increases()` |
| Subscription expiry | 05:00 | `expire_subscriptions()` |
| Reminders | 06:00 | `generate_reminders()` |
| Message dispatch | every 5 min | `dispatch_queued_messages()` |
| Audit log cleanup (7 days) | 01:00 | `delete_old_audit_log()` |

## Reports

`monthly_collection_summary`, `occupancy_report` (+ `seat_occupancy_report`),
`overdue_aging`/`overdue_summary`, `year_end_statement`, `income_expense` and
`renewal_due_list` are all security-invoker views, so RLS scopes them per owner
and super admins see everyone.

## Scripts

```bash
npm run dev     # Vite dev server
npm run build   # production build
npm run lint    # ESLint
```

## v2 roadmap (not yet built)

Deposits workflow, move-in/move-out, utility splitting, expense tracking UI
(backend table + income/expense view already exist), document storage.
# rent-management
# rent-management
