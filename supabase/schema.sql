-- ============================================================================
-- Rent Management SaaS — Database Schema (Postgres / Supabase)
-- ============================================================================
-- Notes on open decisions from the plan doc — schema is built to support
-- either resolution without a redesign, decisions are flagged inline as
-- OPEN DECISION comments.
-- ============================================================================

create extension if not exists "pgcrypto";   -- gen_random_uuid()
create extension if not exists "btree_gist"; -- for exclusion constraints if needed later

-- ============================================================================
-- 1. ENUMS
-- ============================================================================

create type property_kind        as enum ('apartment', 'cottage');
create type unit_status          as enum ('vacant', 'occupied', 'maintenance', 'inactive');
create type lease_status         as enum ('active', 'ended', 'terminated', 'pending');
create type rent_increase_mode   as enum ('fixed', 'percentage');          -- OPEN DECISION: % increase
create type increase_scope       as enum ('global', 'individual');
create type invoice_status_key   as enum ('draft', 'issued', 'partially_paid', 'paid', 'overdue', 'void');
create type invoice_kind         as enum ('rent', 'fine', 'utility', 'deposit', 'other');
create type ledger_entry_type    as enum ('invoice', 'payment', 'adjustment');
create type message_channel      as enum ('sms', 'whatsapp', 'email', 'in_app');   -- OPEN DECISION: channel priority
create type message_purpose      as enum ('reminder', 'warning', 'overdue', 'announcement', 'rent_increase');
create type message_status       as enum ('queued', 'sent', 'failed', 'delivered');
create type move_event_type      as enum ('move_in', 'move_out');
create type deposit_txn_type     as enum ('collected', 'deducted', 'refunded');
create type billing_cycle_mode   as enum ('fixed_30_day', 'calendar_month'); -- OPEN DECISION: cycle mode
create type grace_scope          as enum ('per_property', 'per_tenant');     -- OPEN DECISION: grace scope

-- ============================================================================
-- 2. OWNERS (SaaS tenants — property-owning accounts)
-- ============================================================================

create table owners (
  id                    uuid primary key references auth.users(id) on delete cascade,
  business_name         text,
  default_property_type property_kind,           -- null if "Both" chosen at onboarding
  onboarded_both_types  boolean not null default false,
  billing_cycle_mode    billing_cycle_mode not null default 'fixed_30_day',
  grace_scope           grace_scope not null default 'per_property',
  grace_period_days     integer not null default 5,   -- default/global grace window
  created_at            timestamptz not null default now()
);

-- ============================================================================
-- 3. LOOKUP TABLES (global rows have owner_id null; owners can add custom ones)
-- ============================================================================

create table property_types (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid references owners(id) on delete cascade,
  name        text not null,
  kind        property_kind not null,
  is_system   boolean not null default false,
  unique (owner_id, name)
);

create table facility_templates (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid references owners(id) on delete cascade,
  name        text not null,
  is_system   boolean not null default false,
  unique (owner_id, name)
);

create table rule_templates (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid references owners(id) on delete cascade,
  name        text not null,
  description text,
  is_system   boolean not null default false,
  unique (owner_id, name)
);

create table charge_types (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid references owners(id) on delete cascade,
  name        text not null,          -- e.g. "Water", "Electricity", "Parking"
  is_recurring boolean not null default false,
  is_system   boolean not null default false,
  unique (owner_id, name)
);

create table invoice_types (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid references owners(id) on delete cascade,
  name        text not null,
  kind        invoice_kind not null,
  is_system   boolean not null default false,
  unique (owner_id, name)
);

create table invoice_statuses (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid references owners(id) on delete cascade,
  name        text not null,
  key         invoice_status_key not null,
  is_system   boolean not null default false,
  unique (owner_id, name)
);

create table payment_methods (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid references owners(id) on delete cascade,
  name        text not null,          -- cash, bank transfer, mobile money, card
  is_system   boolean not null default false,
  unique (owner_id, name)
);

create table numbering_patterns (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid references owners(id) on delete cascade,
  name        text not null,
  prefix      text not null default '',
  pattern     text not null default '{prefix}-{n}',  -- e.g. "A-{n}" -> A-1, A-2
  start_at    integer not null default 1,
  is_system   boolean not null default false,
  unique (owner_id, name)
);

-- ============================================================================
-- 4. PROPERTY / UNIT / SEAT HIERARCHY
-- ============================================================================

create table properties (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid not null references owners(id) on delete cascade,
  property_type_id  uuid references property_types(id),
  kind              property_kind not null,
  name              text not null,
  address           text,
  numbering_pattern_id uuid references numbering_patterns(id),
  created_at        timestamptz not null default now()
);

-- Reusable defaults applied during bulk unit creation. Values SNAPSHOT onto
-- each unit/lease/invoice at creation time — editing a template does not
-- retroactively change existing units/leases.
create table unit_templates (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references owners(id) on delete cascade,
  property_id     uuid references properties(id) on delete cascade,
  name            text not null,
  dimension       text,
  base_rent       numeric(12,2) not null default 0,
  deposit_amount  numeric(12,2) not null default 0,
  created_at      timestamptz not null default now()
);

create table unit_template_facilities (
  unit_template_id  uuid not null references unit_templates(id) on delete cascade,
  facility_id       uuid not null references facility_templates(id),
  primary key (unit_template_id, facility_id)
);

create table unit_template_rules (
  unit_template_id  uuid not null references unit_templates(id) on delete cascade,
  rule_id           uuid not null references rule_templates(id),
  primary key (unit_template_id, rule_id)
);

create table unit_template_charges (
  unit_template_id  uuid not null references unit_templates(id) on delete cascade,
  charge_type_id    uuid not null references charge_types(id),
  default_amount    numeric(12,2) not null default 0,
  primary key (unit_template_id, charge_type_id)
);

create table units (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references owners(id) on delete cascade,
  property_id     uuid not null references properties(id) on delete cascade,
  unit_template_id uuid references unit_templates(id),
  unit_number     text not null,          -- generated from numbering pattern, editable after
  dimension       text,
  base_rent       numeric(12,2) not null default 0,   -- snapshot from template, editable per-unit
  deposit_amount  numeric(12,2) not null default 0,
  status          unit_status not null default 'vacant',
  created_at      timestamptz not null default now(),
  unique (property_id, unit_number)
);

create table unit_facilities (
  unit_id     uuid not null references units(id) on delete cascade,
  facility_id uuid not null references facility_templates(id),
  primary key (unit_id, facility_id)
);

create table unit_rules (
  unit_id uuid not null references units(id) on delete cascade,
  rule_id uuid not null references rule_templates(id),
  primary key (unit_id, rule_id)
);

create table unit_charges (
  unit_id         uuid not null references units(id) on delete cascade,
  charge_type_id  uuid not null references charge_types(id),
  amount          numeric(12,2) not null default 0,
  primary key (unit_id, charge_type_id)
);

-- Cottage seat model: a unit (room) is divided into individually rented seats.
create table seats (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references owners(id) on delete cascade,
  unit_id     uuid not null references units(id) on delete cascade,
  seat_label  text not null,             -- "Bed 1", "Seat A"
  seat_rent   numeric(12,2) not null default 0,
  status      unit_status not null default 'vacant',
  created_at  timestamptz not null default now(),
  unique (unit_id, seat_label)
);

-- ============================================================================
-- 5. TENANTS & LEASES
-- ============================================================================

create table tenants (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references owners(id) on delete cascade,
  full_name     text not null,
  phone         text,
  email         text,
  national_id   text,
  emergency_contact text,
  notes         text,
  created_at    timestamptz not null default now()
);

create table leases (
  id                    uuid primary key default gen_random_uuid(),
  owner_id              uuid not null references owners(id) on delete cascade,
  tenant_id             uuid not null references tenants(id) on delete cascade,
  unit_id               uuid references units(id),   -- null when tenant holds seats only (cottage)
  status                lease_status not null default 'active',
  start_date            date not null,               -- anniversary date for billing/increase cycles
  end_date              date,
  rent_amount_snapshot  numeric(12,2) not null,       -- snapshot at lease creation; seat leases sum from lease_seats
  deposit_amount_snapshot numeric(12,2) not null default 0,
  grace_period_days     integer,                      -- per-tenant override if grace_scope = per_tenant
  rent_increase_enabled boolean,                       -- null = inherit global toggle
  rent_increase_mode    rent_increase_mode default 'fixed',
  rent_increase_amount  numeric(12,2),                 -- fixed amount or percentage value
  increase_scope        increase_scope not null default 'global',
  created_at            timestamptz not null default now()
);

-- Multi-seat tenancy: tenant can hold 1..N seats billed together under one lease.
create table lease_seats (
  lease_id            uuid not null references leases(id) on delete cascade,
  seat_id             uuid not null references seats(id),
  seat_rent_snapshot  numeric(12,2) not null,
  primary key (lease_id, seat_id)
);

-- Snapshot/audit trail for rent changes — never a live recalculated formula.
create table rent_history (
  id              uuid primary key default gen_random_uuid(),
  lease_id        uuid not null references leases(id) on delete cascade,
  old_rent        numeric(12,2) not null,
  new_rent        numeric(12,2) not null,
  mode            rent_increase_mode not null,
  effective_date  date not null,
  reason          text,                  -- "annual increase", "manual adjustment"
  announced_message_id uuid,             -- fk added after messages table (below)
  created_at      timestamptz not null default now()
);

-- ============================================================================
-- 6. INVOICING & PAYMENTS
-- ============================================================================

create table invoices (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid not null references owners(id) on delete cascade,
  tenant_id         uuid not null references tenants(id) on delete cascade,
  lease_id          uuid references leases(id),
  invoice_type_id   uuid not null references invoice_types(id),
  invoice_status_id uuid not null references invoice_statuses(id),
  linked_invoice_id uuid references invoices(id),   -- e.g. a fine linked to the rent invoice it penalizes
  period_start      date,
  period_end        date,
  amount            numeric(12,2) not null,
  amount_paid       numeric(12,2) not null default 0,
  due_date          date not null,
  created_at        timestamptz not null default now()
);

create table invoice_line_items (
  id              uuid primary key default gen_random_uuid(),
  invoice_id      uuid not null references invoices(id) on delete cascade,
  charge_type_id  uuid references charge_types(id),
  description     text,
  amount          numeric(12,2) not null
);

create table payments (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid not null references owners(id) on delete cascade,
  invoice_id        uuid not null references invoices(id) on delete cascade,
  tenant_id         uuid not null references tenants(id),
  amount            numeric(12,2) not null,
  payment_method_id uuid references payment_methods(id),
  paid_at           timestamptz not null default now(),
  recorded_by       uuid references owners(id)
);

-- Running per-tenant ledger (derivable from invoices+payments, but kept
-- explicit for fast dashboard/report reads).
create table ledger_entries (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references owners(id) on delete cascade,
  tenant_id       uuid not null references tenants(id) on delete cascade,
  entry_type      ledger_entry_type not null,
  reference_id    uuid not null,        -- invoices.id or payments.id
  amount          numeric(12,2) not null,   -- positive = charge, negative = payment/credit
  balance_after   numeric(12,2) not null,
  created_at      timestamptz not null default now()
);

-- Enforce: exactly one non-void RENT invoice per tenant per billing period.
-- Fines are a separate invoice_type and are excluded via the join to
-- invoice_types.kind = 'rent'.
create unique index uq_one_rent_invoice_per_tenant_period
  on invoices (tenant_id, period_start)
  where invoice_type_id in (select id from invoice_types where kind = 'rent');
-- NOTE: if fine-stacking-per-cycle is resolved as "not allowed" (open decision),
-- add a similar partial unique index scoped to kind = 'fine'.

-- ============================================================================
-- 7. MESSAGING ENGINE
-- ============================================================================

create table message_templates (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid references owners(id) on delete cascade,   -- null = system default
  purpose     message_purpose not null,
  channel     message_channel not null,
  body        text not null,
  is_system   boolean not null default false
);

create table messages_log (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references owners(id) on delete cascade,
  tenant_id     uuid references tenants(id),
  template_id   uuid references message_templates(id),
  purpose       message_purpose not null,
  channel       message_channel not null,
  status        message_status not null default 'queued',
  payload       jsonb,
  sent_at       timestamptz,
  created_at    timestamptz not null default now()
);

alter table rent_history
  add constraint fk_rent_history_message
  foreign key (announced_message_id) references messages_log(id);

-- ============================================================================
-- 8. DEPOSITS, MOVE-IN/OUT, UTILITIES, EXPENSES, DOCUMENTS
-- ============================================================================

create table deposit_transactions (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references owners(id) on delete cascade,
  lease_id    uuid not null references leases(id) on delete cascade,
  type        deposit_txn_type not null,
  amount      numeric(12,2) not null,
  reason      text,
  created_at  timestamptz not null default now()
);

create table move_events (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references owners(id) on delete cascade,
  lease_id      uuid not null references leases(id) on delete cascade,
  event_type    move_event_type not null,
  event_date    date not null,
  condition_report text,
  created_at    timestamptz not null default now()
);

create table utility_bills (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references owners(id) on delete cascade,
  property_id   uuid references properties(id),
  unit_id       uuid references units(id),
  charge_type_id uuid references charge_types(id),
  period_start  date not null,
  period_end    date not null,
  total_amount  numeric(12,2) not null,
  created_at    timestamptz not null default now()
);

create table utility_bill_splits (
  id              uuid primary key default gen_random_uuid(),
  utility_bill_id uuid not null references utility_bills(id) on delete cascade,
  tenant_id       uuid not null references tenants(id),
  amount          numeric(12,2) not null,
  invoice_id      uuid references invoices(id)
);

create table expenses (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references owners(id) on delete cascade,
  property_id   uuid references properties(id),
  category      text not null,
  amount        numeric(12,2) not null,
  expense_date  date not null,
  notes         text,
  created_at    timestamptz not null default now()
);

create table documents (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references owners(id) on delete cascade,
  tenant_id   uuid references tenants(id),
  lease_id    uuid references leases(id),
  doc_type    text not null,       -- lease, id, receipt, condition_report...
  file_url    text not null,
  uploaded_at timestamptz not null default now()
);

-- ============================================================================
-- 9. INDEXES
-- ============================================================================

create index idx_properties_owner        on properties(owner_id);
create index idx_units_property          on units(property_id);
create index idx_units_owner             on units(owner_id);
create index idx_seats_unit              on seats(unit_id);
create index idx_tenants_owner           on tenants(owner_id);
create index idx_leases_tenant           on leases(tenant_id);
create index idx_leases_unit             on leases(unit_id);
create index idx_invoices_tenant         on invoices(tenant_id);
create index idx_invoices_due_date       on invoices(due_date);
create index idx_invoices_status         on invoices(invoice_status_id);
create index idx_payments_invoice        on payments(invoice_id);
create index idx_ledger_tenant           on ledger_entries(tenant_id, created_at);
create index idx_messages_tenant         on messages_log(tenant_id, created_at);

-- ============================================================================
-- 10. ROW LEVEL SECURITY (owner-scoped multi-tenancy)
-- ============================================================================

alter table properties           enable row level security;
alter table unit_templates       enable row level security;
alter table units                enable row level security;
alter table seats                enable row level security;
alter table tenants              enable row level security;
alter table leases               enable row level security;
alter table invoices             enable row level security;
alter table payments             enable row level security;
alter table ledger_entries       enable row level security;
alter table messages_log         enable row level security;
alter table deposit_transactions enable row level security;
alter table move_events          enable row level security;
alter table utility_bills        enable row level security;
alter table expenses             enable row level security;
alter table documents            enable row level security;

-- Repeat this pattern for every owner-scoped table above (shown once here;
-- apply identically to the rest — omitted for brevity). is_super_admin()
-- is defined in section 11 below and lets the super admin panel read/write
-- across every owner's data for monitoring.
create policy owner_isolation_properties on properties
  using (owner_id = auth.uid() or is_super_admin())
  with check (owner_id = auth.uid());

create policy owner_isolation_units on units
  using (owner_id = auth.uid() or is_super_admin())
  with check (owner_id = auth.uid());

create policy owner_isolation_tenants on tenants
  using (owner_id = auth.uid() or is_super_admin())
  with check (owner_id = auth.uid());

create policy owner_isolation_leases on leases
  using (owner_id = auth.uid() or is_super_admin())
  with check (owner_id = auth.uid());

create policy owner_isolation_invoices on invoices
  using (owner_id = auth.uid() or is_super_admin())
  with check (owner_id = auth.uid());

create policy owner_isolation_payments on payments
  using (owner_id = auth.uid() or is_super_admin())
  with check (owner_id = auth.uid());

alter table owners enable row level security;
create policy owner_self_or_admin on owners
  using (id = auth.uid() or is_super_admin());

-- ============================================================================
-- 11. SUPER ADMIN
-- ============================================================================

create table super_admins (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  created_at  timestamptz not null default now()
);

-- security definer so it can be called from RLS policies on any table
create or replace function is_super_admin() returns boolean as $$
  select exists (select 1 from super_admins where id = auth.uid());
$$ language sql stable security definer;

alter table super_admins enable row level security;
create policy admin_only_super_admins on super_admins
  using (is_super_admin());

-- ============================================================================
-- 12. SUBSCRIPTION / TRIAL BILLING
-- ============================================================================
-- 14-day free trial on signup, then a recurring monthly charge. Access is
-- gated in the app layer off `v_owner_access` (bottom of this section) —
-- expired trial or lapsed payment should block the owner from using the app,
-- but their data is never deleted.

create type subscription_status as enum ('trialing', 'active', 'past_due', 'canceled', 'expired');

create table subscription_plans (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  price           numeric(12,2) not null,
  billing_interval text not null default 'monthly',
  is_active       boolean not null default true
);

-- One row per owner. status drives access; trial_end/current_period_end
-- drive the "should this owner be paying now" check.
create table subscriptions (
  id                    uuid primary key default gen_random_uuid(),
  owner_id              uuid not null references owners(id) on delete cascade,
  plan_id               uuid references subscription_plans(id),
  status                subscription_status not null default 'trialing',
  trial_start           date not null default current_date,
  trial_end             date not null default (current_date + interval '14 days'),
  current_period_start  date,
  current_period_end    date,
  canceled_at           timestamptz,
  created_at            timestamptz not null default now(),
  unique (owner_id)
);

-- Owner-level billing: the SaaS charging the property owner for platform
-- access. Deliberately separate from `invoices` (owner charging tenants).
create table subscription_invoices (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid not null references owners(id) on delete cascade,
  subscription_id   uuid not null references subscriptions(id) on delete cascade,
  amount            numeric(12,2) not null,
  period_start      date not null,
  period_end        date not null,
  due_date          date not null,
  status            invoice_status_key not null default 'issued',
  created_at        timestamptz not null default now()
);

create table subscription_payments (
  id                        uuid primary key default gen_random_uuid(),
  subscription_invoice_id   uuid not null references subscription_invoices(id) on delete cascade,
  amount                    numeric(12,2) not null,
  payment_method            text,
  paid_at                   timestamptz not null default now()
);

-- Auto-start the 14-day trial the moment an owner account is created.
create or replace function fn_create_trial_subscription() returns trigger as $$
begin
  insert into subscriptions (owner_id, status, trial_start, trial_end)
  values (new.id, 'trialing', current_date, current_date + interval '14 days');
  return new;
end;
$$ language plpgsql security definer;

create trigger trg_owner_trial_subscription
  after insert on owners
  for each row execute function fn_create_trial_subscription();

alter table subscriptions        enable row level security;
alter table subscription_invoices enable row level security;
alter table subscription_payments enable row level security;

create policy owner_or_admin_subscriptions on subscriptions
  using (owner_id = auth.uid() or is_super_admin());
create policy owner_or_admin_subscription_invoices on subscription_invoices
  using (owner_id = auth.uid() or is_super_admin());

-- Convenience view for the app's access-gate check.
create view v_owner_access as
select
  o.id as owner_id,
  s.status,
  s.trial_end,
  s.current_period_end,
  case
    when s.status = 'trialing' and s.trial_end >= current_date then true
    when s.status = 'active' then true
    else false
  end as has_access
from owners o
join subscriptions s on s.owner_id = o.id;

-- ============================================================================
-- 13. AUDIT LOG (7-day rolling retention)
-- ============================================================================

create type audit_actor_type as enum ('owner', 'super_admin', 'system');

create table audit_logs (
  id          uuid primary key default gen_random_uuid(),
  actor_type  audit_actor_type not null,
  actor_id    uuid,                          -- owner id, super_admin id, or null for system
  owner_id    uuid references owners(id) on delete cascade,  -- whose data was touched; null for platform-level actions
  action      text not null,                 -- e.g. 'invoice.created', 'tenant.deleted', 'login'
  entity_type text,
  entity_id   uuid,
  metadata    jsonb,
  ip_address  text,
  created_at  timestamptz not null default now()
);

create index idx_audit_logs_created_at on audit_logs(created_at);
create index idx_audit_logs_owner      on audit_logs(owner_id, created_at);

alter table audit_logs enable row level security;
create policy admin_only_audit_logs on audit_logs
  using (is_super_admin());

-- Requires the pg_cron extension (available on Supabase — enable it from
-- Database > Extensions first). Runs daily and purges anything past 7 days,
-- so the table self-cleans without app-side cron.
create extension if not exists pg_cron;

select cron.schedule(
  'audit-log-7-day-purge',
  '0 3 * * *',
  $$ delete from audit_logs where created_at < now() - interval '7 days' $$
);

-- ============================================================================
-- END OF SCHEMA
-- ============================================================================