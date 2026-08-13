-- ============================================================================
-- Rently — full deploy script for Supabase SQL editor
-- Run this ONCE in: Supabase Dashboard → SQL Editor → New query
-- Includes: migrations 001-010 + seed data
-- ============================================================================

-- >>> supabase/migrations/001_core_schema.sql <<<
-- ============================================================================
-- 001_core_schema.sql
-- Core schema, lookup tables, platform roles and RLS foundation.
-- Order: extensions -> helpers -> lookups -> platform roles -> core entities
-- ============================================================================

-- Required extensions
create extension if not exists "pgcrypto";
create extension if not exists "uuid-ossp";

-- pg_cron is available on Supabase; schedule jobs only where it exists.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists "pg_cron";
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

-- Trigger that stamps updated_at on row change.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Trigger that defaults owner_id from the authenticated user on insert.
-- RLS requires owner_id = auth.uid(), so this guarantees rows can only be
-- created by their owner (the client must not be trusted to pick an owner).
-- SECURITY DEFINER so auth.uid() is reachable under the appuser role.
create or replace function public.set_owner_id()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.owner_id is null then
    new.owner_id = auth.uid();
  end if;
  if new.owner_id is null then
    raise exception 'not authenticated';
  end if;
  return new;
end;
$$;

-- True when the current auth user is a platform super admin.
-- SECURITY DEFINER so RLS on super_admins never leaks/limits the check.
-- plpgsql (not sql) so the body is lazily bound and the function can be
-- created before the super_admins table.
create or replace function public.is_super_admin()
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  return exists (
    select 1 from public.super_admins sa
    where sa.user_id = auth.uid()
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- Enums
-- ----------------------------------------------------------------------------

create type public.property_kind as enum ('apartment', 'cottage', 'both');

-- ----------------------------------------------------------------------------
-- Lookup tables
-- Lookup rows are either global system defaults (owner_id is null) or
-- per-owner custom entries (owner_id is set). System rows are readable by
-- every authenticated user and editable by nobody.
-- ----------------------------------------------------------------------------

create table public.property_types (
  key        text primary key,
  name       text not null,
  owner_id   uuid,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.facility_templates (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid,
  name       text not null,
  category   text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.rule_templates (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid,
  title      text not null,
  body       text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.charge_types (
  key        text primary key,
  name       text not null,
  owner_id   uuid,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.invoice_types (
  key        text primary key,
  name       text not null,
  owner_id   uuid,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.invoice_statuses (
  key        text primary key,
  name       text not null,
  owner_id   uuid,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.payment_methods (
  key        text primary key,
  name       text not null,
  owner_id   uuid,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.numbering_patterns (
  key        text primary key,
  pattern    text not null,
  description text,
  owner_id   uuid,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.property_types     enable row level security;
alter table public.facility_templates enable row level security;
alter table public.rule_templates     enable row level security;
alter table public.charge_types       enable row level security;
alter table public.invoice_types      enable row level security;
alter table public.invoice_statuses   enable row level security;
alter table public.payment_methods    enable row level security;
alter table public.numbering_patterns enable row level security;

-- Policy creator for lookup tables: system rows (owner_id null) readable by
-- all authenticated users and immutable; owner rows mutable only by owner.
create or replace function public.create_lookup_policies(_table text)
returns void
language plpgsql
as $$
begin
  execute format('create policy lookup_read on public.%I
                    for select using (owner_id is null or owner_id = auth.uid() or public.is_super_admin())', _table);
  execute format('create policy lookup_owner_manage on public.%I
                    for all using (owner_id = auth.uid() or public.is_super_admin())
                    with check (owner_id = auth.uid() or public.is_super_admin())', _table);
end;
$$;

select public.create_lookup_policies('property_types');
select public.create_lookup_policies('facility_templates');
select public.create_lookup_policies('rule_templates');
select public.create_lookup_policies('charge_types');
select public.create_lookup_policies('invoice_types');
select public.create_lookup_policies('invoice_statuses');
select public.create_lookup_policies('payment_methods');
select public.create_lookup_policies('numbering_patterns');

-- ----------------------------------------------------------------------------
-- Platform roles
-- ----------------------------------------------------------------------------

create table public.super_admins (
  user_id    uuid primary key,
  created_at timestamptz not null default now()
);

-- RLS with a blanket-deny policy: only roles that bypass RLS (postgres /
-- service_role) can manage it. is_super_admin() is SECURITY DEFINER so it
-- reads through RLS. This prevents any owner from self-promoting.
alter table public.super_admins enable row level security;
create policy super_admins_deny_all on public.super_admins
  for all using (false) with check (false);

-- ----------------------------------------------------------------------------
-- Owners (the SaaS account)
-- ----------------------------------------------------------------------------

create table public.owners (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid unique not null,
  business_name text not null,
  contact_email text,
  contact_phone text,
  property_kind public.property_kind not null default 'apartment',
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create trigger owners_updated_at
  before update on public.owners
  for each row execute function public.set_updated_at();

alter table public.owners enable row level security;

create policy owners_select on public.owners
  for select using (user_id = auth.uid() or public.is_super_admin());

create policy owners_insert on public.owners
  for insert with check (user_id = auth.uid() or public.is_super_admin());

create policy owners_update on public.owners
  for update using (user_id = auth.uid() or public.is_super_admin());

-- ----------------------------------------------------------------------------
-- Properties
-- ----------------------------------------------------------------------------

create table public.properties (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null references public.owners(id) on delete cascade,
  property_type_id text not null references public.property_types(key),
  name             text not null,
  address_line1    text,
  address_line2    text,
  city             text,
  state            text,
  postal_code      text,
  country          text not null default 'DE',
  unit_count       integer not null default 0 check (unit_count >= 0),
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create trigger properties_updated_at
  before update on public.properties
  for each row execute function public.set_updated_at();

alter table public.properties enable row level security;

create trigger properties_set_owner
  before insert on public.properties
  for each row execute function public.set_owner_id();

create policy properties_select on public.properties
  for select using (owner_id = auth.uid() or public.is_super_admin());

create policy properties_insert on public.properties
  for insert with check (owner_id = auth.uid() or public.is_super_admin());

create policy properties_update on public.properties
  for update using (owner_id = auth.uid() or public.is_super_admin());

create policy properties_delete on public.properties
  for delete using (owner_id = auth.uid() or public.is_super_admin());

create index properties_owner_idx on public.properties(owner_id);

-- ----------------------------------------------------------------------------
-- Unit templates (reusable defaults; values are snapshotted on use)
-- ----------------------------------------------------------------------------

create table public.unit_templates (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid not null references public.owners(id) on delete cascade,
  name              text not null,
  property_type_id  text references public.property_types(key),
  dimension         text,
  bedrooms          integer,
  bathrooms         integer,
  deposit_amount    numeric(12,2) not null default 0,
  default_rent      numeric(12,2) not null default 0,
  facilities        jsonb not null default '[]'::jsonb,
  rules             jsonb not null default '[]'::jsonb,
  charges           jsonb not null default '[]'::jsonb,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create trigger unit_templates_updated_at
  before update on public.unit_templates
  for each row execute function public.set_updated_at();

alter table public.unit_templates enable row level security;

create trigger unit_templates_set_owner
  before insert on public.unit_templates
  for each row execute function public.set_owner_id();

create policy unit_templates_select on public.unit_templates
  for select using (owner_id = auth.uid() or public.is_super_admin());

create policy unit_templates_insert on public.unit_templates
  for insert with check (owner_id = auth.uid() or public.is_super_admin());

create policy unit_templates_update on public.unit_templates
  for update using (owner_id = auth.uid() or public.is_super_admin());

create policy unit_templates_delete on public.unit_templates
  for delete using (owner_id = auth.uid() or public.is_super_admin());

create index unit_templates_owner_idx on public.unit_templates(owner_id);

-- ----------------------------------------------------------------------------
-- Units
-- A unit is a physical apartment or cottage room. Cottages may be further
-- split into seats; apartments typically use the unit itself as the rentable.
-- ----------------------------------------------------------------------------

create table public.units (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid not null references public.owners(id) on delete cascade,
  property_id       uuid not null references public.properties(id) on delete cascade,
  template_id       uuid references public.unit_templates(id) on delete set null,
  unit_number       text not null,
  floor             text,
  dimension         text,
  bedrooms          integer,
  bathrooms         integer,
  rent_amount       numeric(12,2) not null default 0,
  deposit_amount    numeric(12,2) not null default 0,
  status            text not null default 'available'
                    check (status in ('available','occupied','maintenance','off_market')),
  facilities        jsonb not null default '[]'::jsonb,
  rules             jsonb not null default '[]'::jsonb,
  charges           jsonb not null default '[]'::jsonb,
  template_snapshot jsonb,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (property_id, unit_number)
);

create trigger units_updated_at
  before update on public.units
  for each row execute function public.set_updated_at();

alter table public.units enable row level security;

create trigger units_set_owner
  before insert on public.units
  for each row execute function public.set_owner_id();

create policy units_select on public.units
  for select using (owner_id = auth.uid() or public.is_super_admin());

create policy units_insert on public.units
  for insert with check (owner_id = auth.uid() or public.is_super_admin());

create policy units_update on public.units
  for update using (owner_id = auth.uid() or public.is_super_admin());

create policy units_delete on public.units
  for delete using (owner_id = auth.uid() or public.is_super_admin());

create index units_property_idx on public.units(property_id);
create index units_owner_idx on public.units(owner_id);

-- ----------------------------------------------------------------------------
-- Seats (cottage room subdivision)
-- ----------------------------------------------------------------------------

create table public.seats (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references public.owners(id) on delete cascade,
  unit_id    uuid not null references public.units(id) on delete cascade,
  seat_number text not null,
  name       text,
  rent_amount numeric(12,2) not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (unit_id, seat_number)
);

create trigger seats_updated_at
  before update on public.seats
  for each row execute function public.set_updated_at();

alter table public.seats enable row level security;

create trigger seats_set_owner
  before insert on public.seats
  for each row execute function public.set_owner_id();

create policy seats_select on public.seats
  for select using (owner_id = auth.uid() or public.is_super_admin());

create policy seats_insert on public.seats
  for insert with check (owner_id = auth.uid() or public.is_super_admin());

create policy seats_update on public.seats
  for update using (owner_id = auth.uid() or public.is_super_admin());

create policy seats_delete on public.seats
  for delete using (owner_id = auth.uid() or public.is_super_admin());

create index seats_unit_idx on public.seats(unit_id);
create index seats_owner_idx on public.seats(owner_id);

-- ----------------------------------------------------------------------------
-- Tenants
-- Tenants are not auth users; they belong to an owner account.
-- ----------------------------------------------------------------------------

create table public.tenants (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references public.owners(id) on delete cascade,
  first_name   text not null,
  last_name    text not null,
  email        text,
  phone        text,
  whatsapp     text,
  join_date    date not null default current_date,
  note         text,
  status       text not null default 'active' check (status in ('active','past')),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create trigger tenants_updated_at
  before update on public.tenants
  for each row execute function public.set_updated_at();

alter table public.tenants enable row level security;

create trigger tenants_set_owner
  before insert on public.tenants
  for each row execute function public.set_owner_id();

create policy tenants_select on public.tenants
  for select using (owner_id = auth.uid() or public.is_super_admin());

create policy tenants_insert on public.tenants
  for insert with check (owner_id = auth.uid() or public.is_super_admin());

create policy tenants_update on public.tenants
  for update using (owner_id = auth.uid() or public.is_super_admin());

create policy tenants_delete on public.tenants
  for delete using (owner_id = auth.uid() or public.is_super_admin());

create index tenants_owner_idx on public.tenants(owner_id);

-- ----------------------------------------------------------------------------
-- Leases
-- A lease binds a tenant to either a seat (cottage) or a whole unit.
-- A tenant may hold multiple active leases/seats; rent is billed together.
-- ----------------------------------------------------------------------------

create table public.leases (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references public.owners(id) on delete cascade,
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  unit_id       uuid not null references public.units(id) on delete cascade,
  seat_id       uuid references public.seats(id) on delete set null,
  start_date    date not null default current_date,
  end_date      date,
  rent_amount   numeric(12,2) not null default 0,
  grace_days    integer not null default 3 check (grace_days >= 0),
  billing_cycle integer not null default 30 check (billing_cycle > 0),
  status        text not null default 'active' check (status in ('active','ended')),
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (seat_id is null or seat_id is not null)
);

-- A tenant cannot hold two active leases against the same unit (the
-- coalesced seat id makes the partial index work even when seat_id is null).
create unique index leases_active_unique
  on public.leases(tenant_id, unit_id, coalesce(seat_id, '00000000-0000-0000-0000-000000000000'))
  where status = 'active';

-- A seat referenced by a lease must belong to the lease's unit.
create or replace function public.leases_validate_seat()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.seat_id is not null then
    if not exists (
      select 1 from public.seats s
      where s.id = new.seat_id and s.unit_id = new.unit_id
    ) then
      raise exception 'seat % does not belong to unit %', new.seat_id, new.unit_id;
    end if;
  end if;
  return new;
end;
$$;

create trigger leases_validate_seat
  before insert or update on public.leases
  for each row execute function public.leases_validate_seat();

create trigger leases_updated_at
  before update on public.leases
  for each row execute function public.set_updated_at();

alter table public.leases enable row level security;

create trigger leases_set_owner
  before insert on public.leases
  for each row execute function public.set_owner_id();

create policy leases_select on public.leases
  for select using (owner_id = auth.uid() or public.is_super_admin());

create policy leases_insert on public.leases
  for insert with check (owner_id = auth.uid() or public.is_super_admin());

create policy leases_update on public.leases
  for update using (owner_id = auth.uid() or public.is_super_admin());

create policy leases_delete on public.leases
  for delete using (owner_id = auth.uid() or public.is_super_admin());

create index leases_tenant_idx on public.leases(tenant_id);
create index leases_unit_idx on public.leases(unit_id);
create index leases_owner_idx on public.leases(owner_id);

-- >>> supabase/migrations/002_auth_billing_foundation.sql <<<
-- ============================================================================
-- 002_auth_billing_foundation.sql
-- Owner provisioning on signup, owner preferences, trial subscription and
-- the single access-gate view that the whole app checks.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Owner preferences / settings
-- ----------------------------------------------------------------------------

create table public.owner_settings (
  id                         uuid primary key default gen_random_uuid(),
  owner_id                   uuid not null unique references public.owners(id) on delete cascade,
  default_grace_days         integer not null default 3 check (default_grace_days >= 0),
  fine_stacking_allowed      boolean not null default true,
  rent_increase_enabled      boolean not null default false,
  rent_increase_amount       numeric(12,2),
  rent_increase_percent      numeric(5,2),
  tenant_messaging_channels  jsonb not null default '["whatsapp","sms"]'::jsonb,
  owner_notification_channels jsonb not null default '["email","in_app"]'::jsonb,
  message_provider           text not null default 'none',
  currency                   text not null default 'EUR',
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now()
);

create trigger owner_settings_updated_at
  before update on public.owner_settings
  for each row execute function public.set_updated_at();

alter table public.owner_settings enable row level security;

create trigger owner_settings_set_owner
  before insert on public.owner_settings
  for each row execute function public.set_owner_id();

create policy owner_settings_select on public.owner_settings
  for select using (owner_id = auth.uid() or public.is_super_admin());

create policy owner_settings_insert on public.owner_settings
  for insert with check (owner_id = auth.uid() or public.is_super_admin());

create policy owner_settings_update on public.owner_settings
  for update using (owner_id = auth.uid() or public.is_super_admin());

-- ----------------------------------------------------------------------------
-- Billing plans (platform-defined, read-only)
-- ----------------------------------------------------------------------------

create table public.billing_plans (
  key            text primary key,
  name           text not null,
  monthly_amount numeric(12,2) not null,
  description    text,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- Subscriptions (one per owner; trial auto-created on signup)
-- ----------------------------------------------------------------------------

create table public.subscriptions (
  owner_id            uuid primary key references public.owners(id) on delete cascade,
  plan                text not null default 'trial',
  status              text not null default 'trial'
                      check (status in ('trial','active','past_due','cancelled','expired')),
  trial_started_at    timestamptz not null default now(),
  trial_ends_at       timestamptz not null default (now() + interval '14 days'),
  current_period_start timestamptz,
  current_period_end  timestamptz,
  monthly_amount      numeric(12,2) not null default 19.00,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create trigger subscriptions_updated_at
  before update on public.subscriptions
  for each row execute function public.set_updated_at();

alter table public.subscriptions enable row level security;

create policy subscriptions_select on public.subscriptions
  for select using (owner_id = auth.uid() or public.is_super_admin());

create policy subscriptions_insert on public.subscriptions
  for insert with check (owner_id = auth.uid() or public.is_super_admin());

create policy subscriptions_update on public.subscriptions
  for update using (owner_id = auth.uid() or public.is_super_admin());

-- ----------------------------------------------------------------------------
-- Owner provisioning on signup
-- ----------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_business_name text;
  v_kind          text;
  v_owner_id      uuid;
  v_kind_ok       text;
begin
  v_business_name := coalesce(new.raw_user_meta_data->>'business_name', 'My Property Business');
  v_kind          := coalesce(new.raw_user_meta_data->>'property_kind', 'apartment');
  v_kind_ok       := case when v_kind in ('apartment','cottage','both') then v_kind else 'apartment' end;

  insert into public.owners (id, user_id, business_name, contact_email, property_kind)
  values (new.id, new.id, v_business_name, new.email, v_kind_ok::public.property_kind)
  on conflict (user_id) do nothing
  returning id into v_owner_id;

  if v_owner_id is null then
    select id into v_owner_id from public.owners where user_id = new.id;
  end if;

  insert into public.owner_settings (owner_id)
  values (v_owner_id)
  on conflict (owner_id) do nothing;

  insert into public.subscriptions (owner_id)
  values (v_owner_id)
  on conflict (owner_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_owner_signup on auth.users;
create trigger on_owner_signup
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ----------------------------------------------------------------------------
-- Current owner helper
-- ----------------------------------------------------------------------------

create or replace function public.get_current_owner()
returns public.owners
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select * from public.owners where user_id = auth.uid();
$$;

create or replace function public.get_current_owner_id()
returns uuid
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select id from public.owners where user_id = auth.uid();
$$;

-- ----------------------------------------------------------------------------
-- Access gate
-- A single view combining subscription status, trial end date and current
-- billing period. security_invoker=true so each owner only sees their own
-- row (super admins see everything). The frontend calls this once.
-- ----------------------------------------------------------------------------

create or replace view public.owner_access
with (security_invoker = true) as
select
  o.id              as owner_id,
  o.user_id,
  o.business_name,
  o.property_kind,
  s.plan,
  s.status          as subscription_status,
  s.trial_ends_at,
  s.current_period_start,
  s.current_period_end,
  s.monthly_amount,
  case
    when public.is_super_admin()                                   then true
    when s.status = 'trial' and s.trial_ends_at >= now()           then true
    when s.status in ('active','past_due')
         and (s.current_period_end is null or s.current_period_end >= now()) then true
    else false
  end as has_access,
  case
    when public.is_super_admin()                       then 'super_admin'
    when s.status = 'trial' and s.trial_ends_at >= now() then 'trial'
    when s.status in ('active','past_due')
         and (s.current_period_end is null or s.current_period_end >= now()) then 'active'
    else 'expired'
  end as access_state
from public.owners o
left join public.subscriptions s on s.owner_id = o.id;

create or replace function public.get_access_status()
returns jsonb
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select to_jsonb(a) from public.owner_access a where a.user_id = auth.uid();
$$;

create or replace function public.can_access_app()
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select exists (
    select 1 from public.owner_access a where a.user_id = auth.uid() and a.has_access
  );
$$;

-- >>> supabase/migrations/003_bulk_creation.sql <<<
-- ============================================================================
-- 003_bulk_creation.sql
-- Bulk unit generation from a numbering pattern, and template snapshotting.
-- Template values are copied onto units at creation time so later edits to a
-- template never retroactively change existing records.
-- ============================================================================

-- Render a unit number from a pattern. '{n}' is replaced with a zero-padded
-- index; otherwise the pattern acts as a prefix.
create or replace function public.render_unit_number(p_pattern text, p_index integer, p_width integer)
returns text
language plpgsql
immutable
as $$
declare
  v_num text := lpad(p_index::text, greatest(p_width, 1), '0');
begin
  if p_pattern like '%{n}%' then
    return replace(p_pattern, '{n}', v_num);
  else
    return p_pattern || v_num;
  end if;
end;
$$;

-- Copy template values onto a unit (used at creation and on explicit
-- "apply template" actions). Existing unit values are overwritten.
create or replace function public.apply_unit_template(p_unit_id uuid, p_template_id uuid)
returns void
language plpgsql
as $$
declare
  v_owner uuid;
  v_tpl   record;
begin
  select owner_id into v_owner from public.units where id = p_unit_id;

  if v_owner is null then
    raise exception 'unit not found';
  end if;

  select * into v_tpl from public.unit_templates where id = p_template_id and owner_id = v_owner;
  if v_tpl is null then
    raise exception 'template not found for this owner';
  end if;

  update public.units
     set dimension        = v_tpl.dimension,
         bedrooms         = v_tpl.bedrooms,
         bathrooms        = v_tpl.bathrooms,
         rent_amount      = v_tpl.default_rent,
         deposit_amount   = v_tpl.deposit_amount,
         facilities       = v_tpl.facilities,
         rules            = v_tpl.rules,
         charges          = v_tpl.charges,
         template_id      = p_template_id,
         template_snapshot = jsonb_build_object(
           'template_id',   p_template_id,
           'template_name', v_tpl.name,
           'applied_at',    now()
         )
   where id = p_unit_id;
end;
$$;

-- Bulk-create units for a property.
-- p_count: number of units to create.
-- p_pattern: numbering pattern (may contain '{n}').
-- p_template_id: optional unit template whose values are snapshotted.
-- p_dimension / p_default_rent / p_deposit: overrides applied on top of any
-- template values.
create or replace function public.create_units_bulk(
  p_property_id uuid,
  p_count       integer,
  p_pattern     text default 'Unit ',
  p_template_id uuid default null,
  p_dimension   text default null,
  p_default_rent numeric(12,2) default null,
  p_deposit     numeric(12,2) default null
)
returns setof public.units
language plpgsql
as $$
declare
  v_owner    uuid;
  v_existing integer;
  v_width    integer;
  v_i        integer;
  v_number   text;
  v_dim      text;
  v_rent     numeric(12,2);
  v_deposit  numeric(12,2);
  v_tpl      record;
begin
  if p_count is null or p_count < 1 or p_count > 500 then
    raise exception 'p_count must be between 1 and 500';
  end if;

  select owner_id into v_owner from public.properties where id = p_property_id;
  if v_owner is null then
    raise exception 'property not found';
  end if;

  select count(*) into v_existing from public.units where property_id = p_property_id;
  v_width := length((v_existing + p_count)::text);

  if p_template_id is not null then
    select * into v_tpl from public.unit_templates where id = p_template_id and owner_id = v_owner;
    if v_tpl is null then
      raise exception 'template not found for this owner';
    end if;
  end if;

  for v_i in 1..p_count loop
    v_number := public.render_unit_number(p_pattern, v_existing + v_i, v_width);

    v_dim    := coalesce(p_dimension,   v_tpl.dimension);
    v_rent   := coalesce(p_default_rent, v_tpl.default_rent);
    v_deposit:= coalesce(p_deposit,     v_tpl.deposit_amount);

    return query
      insert into public.units
        (owner_id, property_id, template_id, unit_number,
         dimension, rent_amount, deposit_amount,
         facilities, rules, charges,
         template_snapshot)
      values
        (v_owner, p_property_id, p_template_id, v_number,
         v_dim, v_rent, v_deposit,
         coalesce(v_tpl.facilities, '[]'::jsonb),
         coalesce(v_tpl.rules, '[]'::jsonb),
         coalesce(v_tpl.charges, '[]'::jsonb),
         case when v_tpl.id is not null then
           jsonb_build_object(
             'template_id', v_tpl.id,
             'template_name', v_tpl.name,
             'applied_at', now()
           )
         else null end)
      returning *;
  end loop;

  update public.properties
     set unit_count = (select count(*) from public.units where property_id = p_property_id)
   where id = p_property_id;
end;
$$;

-- Create a unit (single) with an optional template snapshot.
create or replace function public.create_unit(
  p_property_id uuid,
  p_unit_number text,
  p_dimension   text default null,
  p_rent        numeric(12,2) default null,
  p_deposit     numeric(12,2) default null,
  p_template_id uuid default null
)
returns public.units
language plpgsql
as $$
declare
  v_owner uuid;
  v_unit  record;
begin
  select owner_id into v_owner from public.properties where id = p_property_id;
  if v_owner is null then
    raise exception 'property not found';
  end if;

  insert into public.units
    (owner_id, property_id, template_id, unit_number, dimension, rent_amount, deposit_amount)
  values
    (v_owner, p_property_id, p_template_id, p_unit_number, p_dimension,
     coalesce(p_rent, 0), coalesce(p_deposit, 0))
  returning * into v_unit;

  update public.properties
     set unit_count = (select count(*) from public.units where property_id = p_property_id)
   where id = p_property_id;

  return v_unit;
end;
$$;

-- >>> supabase/migrations/004_invoicing_engine.sql <<<
-- ============================================================================
-- 004_invoicing_engine.sql
-- Rent cycles (30-day fixed), auto invoice generation, the one-non-void-
-- rent-invoice-per-period constraint, partial payments, fines and the
-- per-tenant running ledger.
-- ============================================================================

alter table public.properties add column grace_days integer not null default 3 check (grace_days >= 0);

create sequence if not exists public.invoice_seq;

-- ----------------------------------------------------------------------------
-- Invoices
-- ----------------------------------------------------------------------------

create table public.invoices (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null references public.owners(id) on delete cascade,
  tenant_id        uuid not null references public.tenants(id) on delete cascade,
  property_id      uuid references public.properties(id) on delete set null,
  invoice_number   text not null default
                     ('INV-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.invoice_seq')::text, 5, '0')),
  invoice_type_key text not null references public.invoice_types(key),
  status_key       text not null default 'open' references public.invoice_statuses(key),
  period_start     date,
  period_end       date,
  issue_date       date not null default current_date,
  due_date         date,
  amount           numeric(12,2) not null default 0 check (amount >= 0),
  amount_paid      numeric(12,2) not null default 0 check (amount_paid >= 0),
  balance          numeric(12,2) generated always as (amount - amount_paid) stored,
  description      text,
  rent_invoice_id  uuid references public.invoices(id) on delete set null,
  fine_reason      text,
  is_void          boolean not null default false,
  void_reason      text,
  voided_at        timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (amount_paid <= amount),
  check (rent_invoice_id is null or invoice_type_key = 'fine'),
  check (invoice_type_key = 'fine' or (rent_invoice_id is null and fine_reason is null))
);

create index invoices_tenant_idx on public.invoices(tenant_id);
create index invoices_owner_idx on public.invoices(owner_id);
create index invoices_due_date_idx on public.invoices(due_date) where not is_void;

-- Enforce at the database level that a tenant cannot hold more than one
-- non-void rent invoice per billing period (period_start identifies the
-- cycle, because cycles are anchored to the tenant's join date).
create unique index invoices_one_rent_per_period
  on public.invoices(tenant_id, period_start)
  where invoice_type_key = 'rent' and not is_void;

-- Invoice line items (seat-level rent breakdown for a tenant-level invoice).
create table public.invoice_lines (
  id         uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  unit_id    uuid not null references public.units(id) on delete cascade,
  seat_id    uuid references public.seats(id) on delete set null,
  description text,
  amount     numeric(12,2) not null default 0 check (amount >= 0)
);

create index invoice_lines_invoice_idx on public.invoice_lines(invoice_id);

-- ----------------------------------------------------------------------------
-- Payments (partial payments supported; invoice status derives from them)
-- ----------------------------------------------------------------------------

create table public.payments (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.owners(id) on delete cascade,
  invoice_id  uuid not null references public.invoices(id) on delete cascade,
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  amount      numeric(12,2) not null check (amount > 0),
  paid_at     timestamptz not null default now(),
  method_key  text not null references public.payment_methods(key),
  reference   text,
  note        text,
  created_at  timestamptz not null default now()
);

create index payments_invoice_idx on public.payments(invoice_id);
create index payments_tenant_idx on public.payments(tenant_id);
create index payments_owner_idx on public.payments(owner_id);

alter table public.invoices enable row level security;
alter table public.invoice_lines enable row level security;
alter table public.payments enable row level security;

create policy invoices_select on public.invoices
  for select using (owner_id = auth.uid() or public.is_super_admin());
create policy invoices_insert on public.invoices
  for insert with check (owner_id = auth.uid() or public.is_super_admin());
create policy invoices_update on public.invoices
  for update using (owner_id = auth.uid() or public.is_super_admin());

create policy invoice_lines_select on public.invoice_lines
  for select using (
    exists (select 1 from public.invoices i where i.id = invoice_id and (i.owner_id = auth.uid() or public.is_super_admin()))
  );
create policy invoice_lines_insert on public.invoice_lines
  for insert with check (
    exists (select 1 from public.invoices i where i.id = invoice_id and (i.owner_id = auth.uid() or public.is_super_admin()))
  );

create policy payments_select on public.payments
  for select using (owner_id = auth.uid() or public.is_super_admin());
create policy payments_insert on public.payments
  for insert with check (owner_id = auth.uid() or public.is_super_admin());
create policy payments_delete on public.payments
  for delete using (owner_id = auth.uid() or public.is_super_admin());

-- ----------------------------------------------------------------------------
-- Cycle helpers
-- ----------------------------------------------------------------------------

-- The 30-day billing cycle (anchored to the tenant join date) that contains
-- p_anchor.
create or replace function public.tenant_cycle_bounds(p_tenant_id uuid, p_anchor date default current_date)
returns table (period_start date, period_end date)
language sql
stable
as $$
  select
    (t.join_date + ((p_anchor - t.join_date) / 30) * 30)::date as period_start,
    (t.join_date + ((p_anchor - t.join_date) / 30) * 30 + 29)::date as period_end
  from public.tenants t
  where t.id = p_tenant_id;
$$;

-- Total snapshot rent and resolved grace days for a tenant's active leases.
create or replace function public.tenant_billing(p_tenant_id uuid)
returns table (rent_amount numeric, grace_days integer)
language sql
stable
as $$
  select
    coalesce(sum(l.rent_amount), 0)::numeric(12,2) as rent_amount,
    greatest(coalesce(max(coalesce(l.grace_days, p.grace_days)), 0))::integer as grace_days
  from public.leases l
  left join public.units u on u.id = l.unit_id
  left join public.properties p on p.id = u.property_id
  where l.tenant_id = p_tenant_id and l.status = 'active';
$$;

-- ----------------------------------------------------------------------------
-- Invoice generation
-- ----------------------------------------------------------------------------

-- Create the rent invoice for a tenant's current cycle if one does not yet
-- exist. Idempotent: the partial unique index makes duplicate inserts no-ops.
create or replace function public.ensure_rent_invoice(p_tenant_id uuid)
returns public.invoices
language plpgsql
as $$
declare
  v_invoice public.invoices;
  v_owner   uuid;
  v_bounds  record;
  v_bill    record;
  v_lease   record;
begin
  select owner_id into v_owner from public.tenants where id = p_tenant_id;
  if v_owner is null then
    return null;
  end if;

  select * into v_bounds from public.tenant_cycle_bounds(p_tenant_id, current_date);
  if v_bounds.period_start is null or v_bounds.period_start > current_date then
    return null;
  end if;

  select * into v_invoice from public.invoices
   where tenant_id = p_tenant_id and invoice_type_key = 'rent' and not is_void
     and period_start = v_bounds.period_start;

  if v_invoice.id is not null then
    return v_invoice;
  end if;

  select * into v_bill from public.tenant_billing(p_tenant_id);
  if v_bill.rent_amount <= 0 then
    return null;
  end if;

  insert into public.invoices
    (owner_id, tenant_id, invoice_type_key, status_key,
     period_start, period_end, issue_date, due_date, amount, description)
  values
    (v_owner, p_tenant_id, 'rent', 'open',
     v_bounds.period_start, v_bounds.period_end, v_bounds.period_start,
     v_bounds.period_end + v_bill.grace_days, v_bill.rent_amount,
     'Rent ' || to_char(v_bounds.period_start, 'YYYY-MM-DD'))
  on conflict do nothing
  returning * into v_invoice;

  if v_invoice.id is null then
    select * into v_invoice from public.invoices
     where tenant_id = p_tenant_id and invoice_type_key = 'rent' and not is_void
       and period_start = v_bounds.period_start;
    return v_invoice;
  end if;

  for v_lease in
    select l.*, u.property_id,
           coalesce(s.rent_amount, l.rent_amount) as billed_amount,
           l.unit_id, l.seat_id
      from public.leases l
      left join public.units u on u.id = l.unit_id
      left join public.seats s on s.id = l.seat_id
     where l.tenant_id = p_tenant_id and l.status = 'active'
  loop
    insert into public.invoice_lines (invoice_id, unit_id, seat_id, description, amount)
    values (v_invoice.id, v_lease.unit_id, v_lease.seat_id,
            'Rent · ' || (select unit_number from public.units where id = v_lease.unit_id),
            v_lease.billed_amount);
  end loop;

  return v_invoice;
end;
$$;

-- Generate due invoices for every active tenant (optionally scoped to one
-- owner). Called daily by pg_cron and on lease creation.
create or replace function public.generate_due_invoices(p_owner_id uuid default null)
returns integer
language plpgsql
as $$
declare
  v_count integer := 0;
  v_tenant uuid;
begin
  for v_tenant in
    select t.id
      from public.tenants t
     where t.status = 'active'
       and (p_owner_id is null or t.owner_id = p_owner_id)
  loop
    perform public.ensure_rent_invoice(v_tenant);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- Create a fine (separate invoice type, optionally linked to a rent invoice).
-- Fine stacking is configurable per owner; when disabled, at most one
-- non-void fine is allowed per tenant per billing cycle.
create or replace function public.create_fine(
  p_tenant_id      uuid,
  p_amount         numeric(12,2),
  p_reason         text,
  p_rent_invoice_id uuid default null,
  p_description    text default null
)
returns public.invoices
language plpgsql
as $$
declare
  v_owner   uuid;
  v_settings record;
  v_period  record;
  v_fine    public.invoices;
begin
  select owner_id into v_owner from public.tenants where id = p_tenant_id;
  if v_owner is null then
    raise exception 'tenant not found';
  end if;

  select * into v_settings from public.owner_settings where owner_id = v_owner;

  select * into v_period from public.tenant_cycle_bounds(p_tenant_id, current_date);

  if not coalesce(v_settings.fine_stacking_allowed, true) then
    if exists (
      select 1 from public.invoices
       where tenant_id = p_tenant_id and invoice_type_key = 'fine' and not is_void
         and period_start = v_period.period_start
    ) then
      raise exception 'fine stacking is disabled for this owner';
    end if;
  end if;

  if p_rent_invoice_id is not null then
    if not exists (
      select 1 from public.invoices
       where id = p_rent_invoice_id and tenant_id = p_tenant_id and invoice_type_key = 'rent' and not is_void
    ) then
      raise exception 'linked rent invoice not found for tenant';
    end if;
  end if;

  insert into public.invoices
    (owner_id, tenant_id, invoice_type_key, status_key, period_start, period_end,
     issue_date, due_date, amount, description, rent_invoice_id, fine_reason)
  values
    (v_owner, p_tenant_id, 'fine', 'open', v_period.period_start, v_period.period_end,
     current_date, current_date + coalesce(v_settings.default_grace_days, 3),
     p_amount, coalesce(p_description, 'Fine: ' || p_reason), p_rent_invoice_id, p_reason)
  returning * into v_fine;

  return v_fine;
end;
$$;

-- ----------------------------------------------------------------------------
-- Payments
-- ----------------------------------------------------------------------------

create or replace function public.record_payment(
  p_invoice_id  uuid,
  p_amount      numeric(12,2),
  p_method_key  text default 'bank_transfer',
  p_paid_at     timestamptz default now(),
  p_reference   text default null,
  p_note        text default null
)
returns public.payments
language plpgsql
as $$
declare
  v_invoice  public.invoices;
  v_owner    uuid;
  v_payment  public.payments;
begin
  select * into v_invoice from public.invoices where id = p_invoice_id;
  if v_invoice.id is null then
    raise exception 'invoice not found';
  end if;
  if v_invoice.is_void then
    raise exception 'cannot pay a voided invoice';
  end if;

  v_owner := v_invoice.owner_id;

  insert into public.payments
    (owner_id, invoice_id, tenant_id, amount, paid_at, method_key, reference, note)
  values
    (v_owner, p_invoice_id, v_invoice.tenant_id, p_amount, p_paid_at, p_method_key, p_reference, p_note)
  returning * into v_payment;

  return v_payment;
end;
$$;

-- Keep invoice.amount_paid and status_key in sync after every payment.
create or replace function public.payments_sync_invoice()
returns trigger
language plpgsql
as $$
declare
  v_paid numeric(12,2);
  v_inv public.invoices;
begin
  select coalesce(sum(p.amount), 0) into v_paid
    from public.payments p where p.invoice_id = coalesce(new.invoice_id, old.invoice_id);

  select * into v_inv from public.invoices
    where id = coalesce(new.invoice_id, old.invoice_id);

  update public.invoices
     set amount_paid = v_paid,
         status_key = case
           when v_paid >= v_inv.amount then 'paid'
           when v_paid > 0 then 'partially_paid'
           else 'open'
         end
   where id = v_inv.id;

  return null;
end;
$$;

create trigger payments_sync_invoice
  after insert or delete on public.payments
  for each row execute function public.payments_sync_invoice();

-- ----------------------------------------------------------------------------
-- Voiding
-- ----------------------------------------------------------------------------

create or replace function public.void_invoice(p_invoice_id uuid, p_reason text)
returns void
language plpgsql
as $$
declare
  v_invoice public.invoices;
begin
  select * into v_invoice from public.invoices where id = p_invoice_id;
  if v_invoice.id is null then
    raise exception 'invoice not found';
  end if;
  if v_invoice.amount_paid > 0 then
    raise exception 'cannot void an invoice with recorded payments';
  end if;
  if v_invoice.invoice_type_key = 'rent' and exists (
    select 1 from public.invoices f
     where f.rent_invoice_id = v_invoice.id and not f.is_void
  ) then
    raise exception 'cannot void a rent invoice with attached fines';
  end if;

  update public.invoices
     set is_void = true, void_reason = p_reason, voided_at = now(), status_key = 'void'
   where id = p_invoice_id;
end;
$$;

-- Daily: mark invoices past their due date as overdue.
create or replace function public.recompute_overdue()
returns integer
language plpgsql
as $$
declare
  v_count integer;
begin
  update public.invoices
     set status_key = 'overdue'
   where not is_void
     and due_date < current_date
     and balance > 0
     and status_key in ('open','partially_paid');
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ----------------------------------------------------------------------------
-- Running per-tenant ledger
-- ----------------------------------------------------------------------------

create or replace view public.ledger_entries
with (security_invoker = true) as
select
  'invoice'::text       as entry_type,
  i.id                  as entry_id,
  i.owner_id,
  i.tenant_id,
  i.invoice_type_key    as kind,
  i.description         as description,
  i.amount              as delta,
  i.period_start,
  i.due_date,
  i.issue_date          as effective_at,
  i.created_at
from public.invoices i
where not i.is_void

union all

select
  'payment'::text       as entry_type,
  p.id                  as entry_id,
  p.owner_id,
  p.tenant_id,
  p.method_key          as kind,
  coalesce(p.reference, p.note, 'Payment') as description,
  -p.amount             as delta,
  null                  as period_start,
  null                  as due_date,
  p.paid_at             as effective_at,
  p.created_at
from public.payments p

order by effective_at, created_at, entry_id;

-- Running balance per tenant after each entry.
create or replace view public.tenant_ledger
with (security_invoker = true) as
select
  le.entry_type,
  le.entry_id,
  le.owner_id,
  le.tenant_id,
  le.kind,
  le.description,
  le.delta,
  le.period_start,
  le.due_date,
  le.effective_at,
  le.created_at,
  sum(le.delta) over (
    partition by le.tenant_id
    order by le.effective_at, le.created_at, le.entry_id
    rows between unbounded preceding and current row
  ) as running_balance
from public.ledger_entries le;

-- ----------------------------------------------------------------------------
-- Lease creation (snapshots rent, triggers first invoice)
-- ----------------------------------------------------------------------------

create or replace function public.create_lease(
  p_tenant_id   uuid,
  p_unit_id     uuid,
  p_seat_id     uuid default null,
  p_start_date  date default current_date,
  p_end_date    date default null,
  p_grace_days  integer default null,
  p_billing_cycle integer default 30,
  p_notes       text default null
)
returns public.leases
language plpgsql
as $$
declare
  v_owner    uuid;
  v_rent     numeric(12,2);
  v_lease    public.leases;
begin
  select owner_id into v_owner from public.tenants where id = p_tenant_id;
  if v_owner is null then
    raise exception 'tenant not found';
  end if;

  if not exists (
    select 1 from public.units where id = p_unit_id and owner_id = v_owner
  ) then
    raise exception 'unit not found for this owner';
  end if;

  select coalesce(s.rent_amount, u.rent_amount) into v_rent
    from public.units u
    left join public.seats s on s.id = p_seat_id
   where u.id = p_unit_id;

  insert into public.leases
    (owner_id, tenant_id, unit_id, seat_id, start_date, end_date,
     rent_amount, grace_days, billing_cycle, notes)
  values
    (v_owner, p_tenant_id, p_unit_id, p_seat_id, p_start_date, p_end_date,
     coalesce(v_rent, 0), coalesce(p_grace_days, 3), p_billing_cycle, p_notes)
  returning * into v_lease;

  perform public.ensure_rent_invoice(p_tenant_id);

  return v_lease;
end;
$$;

-- End a lease (e.g. move-out). Sets status to ended.
create or replace function public.end_lease(p_lease_id uuid, p_end_date date default current_date)
returns void
language plpgsql
as $$
begin
  update public.leases
     set status = 'ended', end_date = coalesce(p_end_date, end_date)
   where id = p_lease_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- Realtime + scheduled jobs
-- ----------------------------------------------------------------------------

do $$
begin
  begin
    alter publication supabase_realtime add table public.invoices, public.payments;
  exception when others then null;
  end;
end $$;

-- Daily invoicing + overdue recompute via pg_cron.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- Keep idempotent: unschedule if it already exists, else ignore the error.
    begin
      perform cron.unschedule('rently-daily-invoices');
    exception when others then null; end;
    perform cron.schedule('rently-daily-invoices', '0 2 * * *',
      'select public.generate_due_invoices();');
    begin
      perform cron.unschedule('rently-daily-overdue');
    exception when others then null; end;
    perform cron.schedule('rently-daily-overdue', '0 3 * * *',
      'select public.recompute_overdue();');
  end if;
end $$;

-- >>> supabase/migrations/005_rent_increase.sql <<<
-- ============================================================================
-- 005_rent_increase.sql
-- Annual rent increase: fixed amount and/or percentage, evaluated on each
-- tenant's join-date anniversary, with per-tenant override and an immutable
-- rent_history audit trail. Notices are queued via the messaging engine.
-- ============================================================================

alter table public.tenants
  add column rent_increase_enabled boolean,
  add column rent_increase_amount   numeric(12,2),
  add column rent_increase_percent  numeric(5,2);

-- Immutable history of every rent change.
create table public.rent_history (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null references public.owners(id) on delete cascade,
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  lease_id       uuid references public.leases(id) on delete set null,
  seat_id        uuid references public.seats(id) on delete set null,
  old_amount     numeric(12,2) not null,
  new_amount     numeric(12,2) not null,
  change_type    text not null check (change_type in ('fixed','percent','override','manual')),
  effective_date date not null default current_date,
  applied_by     text not null default 'system' check (applied_by in ('system','owner','super_admin')),
  note           text,
  created_at     timestamptz not null default now()
);

-- RLS: readable by owner; insertable only by system functions (owners may
-- record manual changes through the dedicated RPC, not by direct insert).
alter table public.rent_history enable row level security;

create policy rent_history_select on public.rent_history
  for select using (owner_id = auth.uid() or public.is_super_admin());

create policy rent_history_system_insert on public.rent_history
  for insert with check (
    owner_id = auth.uid() or public.is_super_admin()
  );

create index rent_history_tenant_idx on public.rent_history(tenant_id);
create index rent_history_owner_idx on public.rent_history(owner_id);

-- ----------------------------------------------------------------------------
-- Manual rent change (owner/super admin). Writes an immutable history row.
-- ----------------------------------------------------------------------------

create or replace function public.set_manual_rent(
  p_lease_id     uuid,
  p_new_amount   numeric(12,2),
  p_note         text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_lease public.leases;
  v_old   numeric(12,2);
begin
  select * into v_lease from public.leases where id = p_lease_id;
  if v_lease.id is null then
    raise exception 'lease not found';
  end if;

  v_old := v_lease.rent_amount;

  update public.leases set rent_amount = p_new_amount where id = p_lease_id;

  if v_lease.seat_id is not null then
    update public.seats set rent_amount = p_new_amount where id = v_lease.seat_id;
  else
    update public.units set rent_amount = p_new_amount where id = v_lease.unit_id;
  end if;

  insert into public.rent_history
    (owner_id, tenant_id, lease_id, seat_id, old_amount, new_amount,
     change_type, effective_date, applied_by, note)
  values
    (v_lease.owner_id, v_lease.tenant_id, v_lease.id, v_lease.seat_id,
     v_old, p_new_amount, 'manual', current_date, 'owner', p_note);
end;
$$;

-- Per-tenant override of the annual increase (nulls inherit the global
-- setting). Recording the change in rent_history keeps a full audit trail.
create or replace function public.set_tenant_rent_increase(
  p_tenant_id uuid,
  p_enabled   boolean default null,
  p_amount    numeric(12,2) default null,
  p_percent   numeric(5,2) default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant public.tenants;
begin
  select * into v_tenant from public.tenants where id = p_tenant_id;
  if v_tenant.id is null then
    raise exception 'tenant not found';
  end if;

  update public.tenants
     set rent_increase_enabled = coalesce(p_enabled, rent_increase_enabled),
         rent_increase_amount   = coalesce(p_amount, rent_increase_amount),
         rent_increase_percent  = coalesce(p_percent, rent_increase_percent)
   where id = p_tenant_id;

  insert into public.rent_history
    (owner_id, tenant_id, old_amount, new_amount, change_type, effective_date, applied_by, note)
  values
    (v_tenant.owner_id, v_tenant.id,
     coalesce(v_tenant.rent_increase_amount, 0),
     coalesce(p_amount, v_tenant.rent_increase_amount, 0),
     'override', current_date, 'owner',
     'Rent increase configuration changed (enabled=' || coalesce(p_enabled, v_tenant.rent_increase_enabled) || ')');
end;
$$;

-- ----------------------------------------------------------------------------
-- Annual increase evaluation (daily job + manual trigger)
-- ----------------------------------------------------------------------------

create or replace function public.apply_rent_increases(p_owner_id uuid default null)
returns integer
language plpgsql
as $$
declare
  v_count     integer := 0;
  v_tenant    record;
  v_settings  record;
  v_enabled   boolean;
  v_amount    numeric(12,2);
  v_percent   numeric(5,2);
  v_anchor    date;
  v_next_due  date;
  v_lease     record;
  v_old       numeric(12,2);
  v_new       numeric(12,2);
  v_type      text;
begin
  for v_tenant in
    select t.* from public.tenants t
     where t.status = 'active'
       and (p_owner_id is null or t.owner_id = p_owner_id)
  loop
    select * into v_settings from public.owner_settings where owner_id = v_tenant.owner_id;

    v_enabled := coalesce(v_tenant.rent_increase_enabled, v_settings.rent_increase_enabled);
    if not coalesce(v_enabled, false) then
      continue;
    end if;

    v_amount  := coalesce(v_tenant.rent_increase_amount, v_settings.rent_increase_amount);
    v_percent := coalesce(v_tenant.rent_increase_percent, v_settings.rent_increase_percent);
    if v_amount is null and v_percent is null then
      continue;
    end if;

    select coalesce(max(effective_date), v_tenant.join_date) into v_anchor
      from public.rent_history where tenant_id = v_tenant.id;

    v_next_due := v_anchor + interval '1 year';
    if current_date < v_next_due then
      continue;
    end if;

    if v_amount is not null and v_percent is not null then
      v_type := 'override';
    elsif v_percent is not null then
      v_type := 'percent';
    else
      v_type := 'fixed';
    end if;

    for v_lease in
      select l.* from public.leases l
       where l.tenant_id = v_tenant.id and l.status = 'active'
    loop
      v_old := v_lease.rent_amount;
      v_new := v_old
               + coalesce(v_amount, 0)
               + round(v_old * coalesce(v_percent, 0) / 100, 2);

      update public.leases set rent_amount = v_new where id = v_lease.id;

      if v_lease.seat_id is not null then
        update public.seats set rent_amount = v_new where id = v_lease.seat_id;
      else
        update public.units set rent_amount = v_new where id = v_lease.unit_id;
      end if;

      insert into public.rent_history
        (owner_id, tenant_id, lease_id, seat_id, old_amount, new_amount,
         change_type, effective_date, applied_by, note)
      values
        (v_tenant.owner_id, v_tenant.id, v_lease.id, v_lease.seat_id,
         v_old, v_new, v_type, v_next_due, 'system',
         'Annual rent increase');
    end loop;

    perform public.queue_rent_increase_notice(
      v_tenant.id,
      coalesce(v_amount, 0),
      coalesce(v_percent, 0),
      v_next_due
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.unschedule('rently-daily-rent-increase');
    exception when others then null; end;
    perform cron.schedule('rently-daily-rent-increase', '0 4 * * *',
      'select public.apply_rent_increases();');
  end if;
end $$;

-- >>> supabase/migrations/006_messaging_engine.sql <<<
-- ============================================================================
-- 006_messaging_engine.sql
-- Channel-agnostic message queue, message templates, owner notifications,
-- automated reminders/warnings/escalations and the daily dispatch job.
-- Channels (whatsapp/sms/email/in_app) are a configuration choice per owner,
-- not a rebuild. A real provider adapter would be an Edge Function that reads
-- 'queued' rows; in this environment dispatch simulates the send.
-- ============================================================================

create table public.message_templates (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid,
  key           text not null,
  channel_group text not null check (channel_group in ('tenant_facing','owner_facing')),
  subject       text not null,
  body          text not null,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  unique (key, owner_id)
);

create table public.messages (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null references public.owners(id) on delete cascade,
  actor_type     text not null default 'owner' check (actor_type in ('owner','super_admin','system')),
  actor_user_id  uuid,
  recipient_type text not null check (recipient_type in ('tenant','owner')),
  tenant_id      uuid references public.tenants(id) on delete set null,
  recipient_ref  text,
  channel        text not null check (channel in ('whatsapp','sms','email','in_app')),
  subject        text,
  body           text not null,
  status         text not null default 'queued' check (status in ('queued','sent','failed','cancelled')),
  template_key   text,
  entity_type    text,
  entity_id      uuid,
  scheduled_at   timestamptz not null default now(),
  sent_at        timestamptz,
  error          text,
  created_at     timestamptz not null default now()
);

create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references public.owners(id) on delete cascade,
  user_id    uuid not null,
  title      text not null,
  body       text,
  link       text,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);

alter table public.message_templates enable row level security;
alter table public.messages enable row level security;
alter table public.notifications enable row level security;

select public.create_lookup_policies('message_templates');

create policy messages_select on public.messages
  for select using (owner_id = auth.uid() or public.is_super_admin());
create policy messages_insert on public.messages
  for insert with check (owner_id = auth.uid() or public.is_super_admin());
create policy messages_update on public.messages
  for update using (owner_id = auth.uid() or public.is_super_admin());

create policy notifications_select on public.notifications
  for select using ((owner_id = auth.uid() and user_id = auth.uid()) or public.is_super_admin());
create policy notifications_insert on public.notifications
  for insert with check ((owner_id = auth.uid() and user_id = auth.uid()) or public.is_super_admin());
create policy notifications_update on public.notifications
  for update using ((owner_id = auth.uid() and user_id = auth.uid()) or public.is_super_admin());

create index messages_owner_idx on public.messages(owner_id);
create index messages_status_idx on public.messages(status);
create index notifications_user_idx on public.notifications(user_id);

-- ----------------------------------------------------------------------------
-- Queueing helpers
-- ----------------------------------------------------------------------------

-- Low-level queue insert (owner must match the auth user via RLS).
create or replace function public.queue_message(
  p_owner_id         uuid,
  p_recipient_type   text,
  p_channel          text,
  p_body             text,
  p_subject          text default null,
  p_tenant_id        uuid default null,
  p_recipient_ref    text default null,
  p_template_key     text default null,
  p_entity_type      text default null,
  p_entity_id        uuid default null,
  p_scheduled_at     timestamptz default now(),
  p_actor_type       text default 'owner'
)
returns public.messages
language plpgsql
as $$
declare
  v_msg public.messages;
begin
  insert into public.messages
    (owner_id, actor_type, actor_user_id, recipient_type, tenant_id, recipient_ref,
     channel, subject, body, template_key, entity_type, entity_id, scheduled_at)
  values
    (p_owner_id, p_actor_type, auth.uid(), p_recipient_type, p_tenant_id, p_recipient_ref,
     p_channel, p_subject, p_body, p_template_key, p_entity_type, p_entity_id, p_scheduled_at)
  returning * into v_msg;
  return v_msg;
end;
$$;

-- Queue a tenant-facing message on the tenant's preferred channels, resolved
-- from the owner's channel configuration.
create or replace function public.queue_tenant_message(
  p_tenant_id     uuid,
  p_body          text,
  p_subject       text default null,
  p_template_key  text default null,
  p_entity_type   text default null,
  p_entity_id     uuid default null,
  p_scheduled_at  timestamptz default now()
)
returns setof public.messages
language plpgsql
as $$
declare
  v_tenant   public.tenants;
  v_settings record;
  v_channel  text;
begin
  select * into v_tenant from public.tenants where id = p_tenant_id;
  if v_tenant.id is null then
    raise exception 'tenant not found';
  end if;

  select * into v_settings from public.owner_settings where owner_id = v_tenant.owner_id;

  for v_channel in
    select jsonb_array_elements_text(v_settings.tenant_messaging_channels) as c
  loop
    if v_channel = 'whatsapp' and v_tenant.whatsapp is not null then
      return query select * from public.queue_message(
        v_tenant.owner_id, 'tenant', 'whatsapp', p_body, p_subject,
        p_tenant_id, v_tenant.whatsapp, p_template_key, p_entity_type, p_entity_id, p_scheduled_at);
    elsif v_channel = 'sms' and v_tenant.phone is not null then
      return query select * from public.queue_message(
        v_tenant.owner_id, 'tenant', 'sms', p_body, p_subject,
        p_tenant_id, v_tenant.phone, p_template_key, p_entity_type, p_entity_id, p_scheduled_at);
    elsif v_channel = 'email' and v_tenant.email is not null then
      return query select * from public.queue_message(
        v_tenant.owner_id, 'tenant', 'email', p_body, p_subject,
        p_tenant_id, v_tenant.email, p_template_key, p_entity_type, p_entity_id, p_scheduled_at);
    end if;
  end loop;
end;
$$;

-- Queue an owner-facing notification (email + in-app).
create or replace function public.queue_owner_notification(
  p_title text,
  p_body  text,
  p_link  text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner public.owners;
  v_settings record;
  v_channel text;
begin
  select * into v_owner from public.owners where user_id = auth.uid();
  if v_owner.id is null then
    raise exception 'owner not found for current user';
  end if;

  select * into v_settings from public.owner_settings where owner_id = v_owner.id;

  for v_channel in
    select jsonb_array_elements_text(v_settings.owner_notification_channels) as c
  loop
    if v_channel = 'email' then
      perform public.queue_message(
        v_owner.id, 'owner', 'email', p_body, p_title,
        null, v_owner.contact_email, null, null, null, now(), 'owner');
    end if;
  end loop;

  insert into public.notifications (owner_id, user_id, title, body, link)
  values (v_owner.id, auth.uid(), p_title, p_body, p_link);
end;
$$;

-- Rent-increase notice (invoked by the annual increase job).
create or replace function public.queue_rent_increase_notice(
  p_tenant_id      uuid,
  p_amount         numeric(12,2),
  p_percent        numeric(5,2),
  p_effective_date date
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant public.tenants;
  v_body   text;
begin
  select * into v_tenant from public.tenants where id = p_tenant_id;
  if v_tenant.id is null then
    return;
  end if;

  v_body := 'Dear ' || v_tenant.first_name || ', as of ' || p_effective_date
            || ' your rent will increase'
            || case
                 when p_amount > 0 and p_percent > 0 then ' by ' || p_amount || ' plus ' || p_percent || '%'
                 when p_percent > 0 then ' by ' || p_percent || '%'
                 when p_amount > 0 then ' by ' || p_amount
                 else ''
               end || '. Regards, your landlord.';

  perform public.queue_tenant_message(p_tenant_id, 'Rent increase notice', v_body, 'rent_increase');
end;
$$;

-- Create an announcement to all (or selected) active tenants.
create or replace function public.create_announcement(
  p_subject    text,
  p_body       text,
  p_tenant_ids uuid[] default null
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid;
  v_count integer := 0;
  v_tenant uuid;
begin
  v_owner := public.get_current_owner_id();
  if v_owner is null then
    raise exception 'owner not found';
  end if;

  if p_tenant_ids is null then
    for v_tenant in
      select t.id from public.tenants t where t.owner_id = v_owner and t.status = 'active'
    loop
      perform public.queue_tenant_message(v_tenant, p_subject, p_body, 'announcement', 'announcement', null);
      v_count := v_count + 1;
    end loop;
  else
    for v_tenant in
      select unnest(p_tenant_ids) as id
    loop
      if exists (select 1 from public.tenants t where t.id = v_tenant and t.owner_id = v_owner) then
        perform public.queue_tenant_message(v_tenant, p_subject, p_body, 'announcement', 'announcement', null);
        v_count := v_count + 1;
      end if;
    end loop;
  end if;

  return v_count;
end;
$$;

-- ----------------------------------------------------------------------------
-- Automated payment reminders → warning → escalation
-- ----------------------------------------------------------------------------

create or replace function public.generate_reminders()
returns integer
language plpgsql
as $$
declare
  v_count integer := 0;
  v_inv   record;
  v_owner uuid;
  v_txt   text;
  v_key   text;
  v_days  integer;
begin
  for v_inv in
    select i.*, t.first_name, t.last_name, t.owner_id as t_owner
      from public.invoices i
      join public.tenants t on t.id = i.tenant_id
     where i.invoice_type_key = 'rent'
       and not i.is_void
       and i.balance > 0
       and i.due_date < current_date
       and i.status_key = 'overdue'
  loop
    v_days := (current_date - v_inv.due_date);

    if v_days <= 7 then
      v_key := 'payment_reminder';
      v_txt := 'Dear ' || v_inv.first_name || ', this is a friendly reminder that invoice ' || v_inv.invoice_number || ' of ' || v_inv.amount || ' is due. Balance: ' || v_inv.balance || '.';
    elsif v_days <= 30 then
      v_key := 'payment_warning';
      v_txt := 'Dear ' || v_inv.first_name || ', invoice ' || v_inv.invoice_number || ' is ' || v_days || ' days overdue. Please settle the balance of ' || v_inv.balance || ' as soon as possible.';
    else
      v_key := 'overdue_escalation';
      v_txt := 'Dear ' || v_inv.first_name || ', your account is significantly overdue (' || v_days || ' days). Please arrange payment of ' || v_inv.balance || ' immediately to avoid further action.';
    end if;

    if not exists (
      select 1 from public.messages
       where owner_id = v_inv.t_owner and entity_type = 'invoice' and entity_id = v_inv.id
         and template_key = v_key
    ) then
      perform public.queue_tenant_message(v_inv.tenant_id, v_key, v_txt, v_key, 'invoice', v_inv.id);
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

-- Dispatch queued messages. With no external provider configured this simply
-- marks them as sent (simulated). A production deployment would hook a
-- provider (WhatsApp Business API / SMTP) per owner_settings.message_provider.
create or replace function public.dispatch_queued_messages()
returns integer
language plpgsql
as $$
declare
  v_count integer;
begin
  update public.messages
     set status = 'sent', sent_at = now()
   where status = 'queued' and scheduled_at <= now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.unschedule('rently-daily-reminders');
    exception when others then null; end;
    perform cron.schedule('rently-daily-reminders', '0 6 * * *',
      'select public.generate_reminders();');
    begin
      perform cron.unschedule('rently-daily-dispatch');
    exception when others then null; end;
    perform cron.schedule('rently-daily-dispatch', '*/5 * * * *',
      'select public.dispatch_queued_messages();');
  end if;
end $$;

-- >>> supabase/migrations/007_reports.sql <<<
-- ============================================================================
-- 007_reports.sql
-- Reporting views: monthly collection, occupancy, overdue aging, year-end
-- statements, income/expense and the renewal-due list. All views are
-- security_invoker so RLS scopes them per owner; super admins see everyone.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Expenses (used by income/expense report; v2 feature shipped early)
-- ----------------------------------------------------------------------------

create table public.expenses (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.owners(id) on delete cascade,
  property_id uuid references public.properties(id) on delete set null,
  amount      numeric(12,2) not null check (amount >= 0),
  category    text not null default 'maintenance',
  description text,
  incurred_on date not null default current_date,
  created_at  timestamptz not null default now()
);

alter table public.expenses enable row level security;

create policy expenses_select on public.expenses
  for select using (owner_id = auth.uid() or public.is_super_admin());
create policy expenses_insert on public.expenses
  for insert with check (owner_id = auth.uid() or public.is_super_admin());
create policy expenses_update on public.expenses
  for update using (owner_id = auth.uid() or public.is_super_admin());
create policy expenses_delete on public.expenses
  for delete using (owner_id = auth.uid() or public.is_super_admin());

create index expenses_owner_idx on public.expenses(owner_id);

-- ----------------------------------------------------------------------------
-- Monthly collection summary
-- ----------------------------------------------------------------------------

create or replace view public.monthly_collection_summary
with (security_invoker = true) as
with invoiced as (
  select owner_id, date_trunc('month', period_start)::date as month,
         sum(amount) as invoiced,
         sum(balance) as outstanding
    from public.invoices
   where not is_void
   group by 1, 2
), collected as (
  select owner_id, date_trunc('month', paid_at)::date as month,
         sum(amount) as collected
    from public.payments
   group by 1, 2
)
select
  coalesce(i.owner_id, c.owner_id) as owner_id,
  coalesce(i.month, c.month)       as month,
  coalesce(i.invoiced, 0)          as invoiced,
  coalesce(c.collected, 0)         as collected,
  coalesce(i.outstanding, 0)       as outstanding,
  case
    when coalesce(i.invoiced, 0) > 0
      then round(100.0 * coalesce(c.collected, 0) / i.invoiced, 1)
    else 0
  end as collection_rate
from invoiced i
full outer join collected c on c.owner_id = i.owner_id and c.month = i.month
order by month desc;

-- ----------------------------------------------------------------------------
-- Occupancy (unit-based, plus a seat-based variant for cottages)
-- ----------------------------------------------------------------------------

create or replace view public.occupancy_report
with (security_invoker = true) as
select
  u.owner_id,
  u.property_id,
  p.name as property_name,
  count(u.id) as total_units,
  count(*) filter (where exists (
    select 1 from public.leases l where l.unit_id = u.id and l.status = 'active'
  )) as occupied_units,
  round(100.0 * count(*) filter (where exists (
    select 1 from public.leases l where l.unit_id = u.id and l.status = 'active'
  )) / nullif(count(u.id), 0), 1) as occupancy_rate
from public.units u
join public.properties p on p.id = u.property_id
where u.is_active
group by u.owner_id, u.property_id, p.name
order by p.name;

create or replace view public.seat_occupancy_report
with (security_invoker = true) as
select
  s.owner_id,
  s.unit_id,
  u.unit_number,
  u.property_id,
  count(s.id) as total_seats,
  count(*) filter (where exists (
    select 1 from public.leases l where l.seat_id = s.id and l.status = 'active'
  )) as occupied_seats,
  round(100.0 * count(*) filter (where exists (
    select 1 from public.leases l where l.seat_id = s.id and l.status = 'active'
  )) / nullif(count(s.id), 0), 1) as seat_occupancy_rate
from public.seats s
join public.units u on u.id = s.unit_id
where s.is_active
group by s.owner_id, s.unit_id, u.unit_number, u.property_id
order by u.unit_number;

-- ----------------------------------------------------------------------------
-- Overdue aging buckets
-- ----------------------------------------------------------------------------

create or replace view public.overdue_aging
with (security_invoker = true) as
select
  i.owner_id,
  i.tenant_id,
  t.first_name || ' ' || t.last_name as tenant_name,
  i.invoice_number,
  i.due_date,
  i.amount,
  i.balance,
  (current_date - i.due_date) as days_overdue,
  case
    when (current_date - i.due_date) between 1 and 30  then '1-30'
    when (current_date - i.due_date) between 31 and 60 then '31-60'
    when (current_date - i.due_date) between 61 and 90 then '61-90'
    else '90+'
  end as bucket
from public.invoices i
join public.tenants t on t.id = i.tenant_id
where not i.is_void and i.balance > 0 and i.due_date < current_date;

create or replace view public.overdue_summary
with (security_invoker = true) as
select owner_id, bucket, count(*) as invoices, sum(balance) as total
from public.overdue_aging
group by owner_id, bucket
order by bucket;

-- ----------------------------------------------------------------------------
-- Year-end statement per tenant
-- ----------------------------------------------------------------------------

create or replace view public.year_end_statement
with (security_invoker = true) as
select
  i.owner_id,
  i.tenant_id,
  t.first_name || ' ' || t.last_name as tenant_name,
  extract(year from i.period_start)::int as year,
  count(i.id)                          as invoices,
  sum(i.amount)                        as billed,
  sum(i.amount_paid)                   as paid,
  sum(i.balance)                       as balance
from public.invoices i
join public.tenants t on t.id = i.tenant_id
where not i.is_void and i.period_start is not null
group by i.owner_id, i.tenant_id, t.first_name, t.last_name, extract(year from i.period_start)
order by year desc;

-- ----------------------------------------------------------------------------
-- Income / expense by month
-- ----------------------------------------------------------------------------

create or replace view public.income_expense
with (security_invoker = true) as
with rows_ as (
  select owner_id, date_trunc('month', paid_at)::date as month, amount as income, 0 as expense
    from public.payments
  union all
  select owner_id, date_trunc('month', incurred_on)::date as month, 0 as income, amount as expense
    from public.expenses
)
select
  owner_id,
  month,
  sum(income)  as income,
  sum(expense) as expense,
  sum(income) - sum(expense) as net
from rows_
group by owner_id, month
order by month desc;

-- ----------------------------------------------------------------------------
-- Renewal-due list
-- ----------------------------------------------------------------------------

create or replace view public.renewal_due_list
with (security_invoker = true) as
select
  l.id,
  l.owner_id,
  l.tenant_id,
  t.first_name || ' ' || t.last_name as tenant_name,
  l.unit_id,
  u.unit_number,
  l.start_date,
  l.end_date,
  l.rent_amount,
  (l.end_date - current_date) as days_until_renewal
from public.leases l
join public.tenants t on t.id = l.tenant_id
join public.units u on u.id = l.unit_id
where l.status = 'active'
  and l.end_date is not null
  and l.end_date >= current_date
  and l.end_date <= current_date + interval '90 days'
order by l.end_date;

-- >>> supabase/migrations/008_super_admin_billing_audit.sql <<<
-- ============================================================================
-- 008_super_admin_billing_audit.sql
-- Super admin role tooling, the recurring monthly billing lifecycle and the
-- platform audit log (auto-deleted after 7 days by a daily DB job).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Billing events (owner-facing history + admin monitoring)
-- ----------------------------------------------------------------------------

create table public.billing_events (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.owners(id) on delete cascade,
  event_type  text not null check (
    event_type in ('trial_started','trial_expired','plan_activated','period_renewed',
                   'payment_received','payment_failed','plan_cancelled','access_revoked')
  ),
  amount      numeric(12,2),
  occurred_at timestamptz not null default now(),
  meta        jsonb not null default '{}'::jsonb
);

alter table public.billing_events enable row level security;

create policy billing_events_select on public.billing_events
  for select using (owner_id = auth.uid() or public.is_super_admin());

create index billing_events_owner_idx on public.billing_events(owner_id);

-- ----------------------------------------------------------------------------
-- Audit log
-- ----------------------------------------------------------------------------

create table public.audit_log (
  id            uuid primary key default gen_random_uuid(),
  actor_type    text not null check (actor_type in ('owner','super_admin','system')),
  actor_user_id uuid,
  action        text not null,
  entity_type   text not null,
  entity_id     uuid,
  metadata      jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);

create index audit_log_created_idx on public.audit_log(created_at);
create index audit_log_actor_idx on public.audit_log(actor_user_id);
create index audit_log_entity_idx on public.audit_log(entity_type, entity_id);

alter table public.audit_log enable row level security;

-- Only super admins read the audit log; writes happen through SECURITY
-- DEFINER functions so RLS never blocks legitimate logging.
create policy audit_log_super_admin_select on public.audit_log
  for select using (public.is_super_admin());

-- ----------------------------------------------------------------------------
-- Logging helpers
-- ----------------------------------------------------------------------------

-- Explicit actor logging (used by internal triggers and jobs).
create or replace function public.log_audit(
  p_actor_type  text,
  p_action      text,
  p_entity_type text,
  p_entity_id   uuid default null,
  p_metadata    jsonb default '{}'::jsonb,
  p_actor_user_id uuid default null
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.audit_log (actor_type, actor_user_id, action, entity_type, entity_id, metadata)
  values (p_actor_type, p_actor_user_id, p_action, p_entity_type, p_entity_id, p_metadata);
$$;

-- Frontend-friendly audit call: actor derived from the current session.
create or replace function public.audit_event(
  p_action      text,
  p_entity_type text,
  p_entity_id   uuid default null,
  p_metadata    jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor text := 'system';
  v_uid   uuid := auth.uid();
begin
  if v_uid is not null then
    v_actor := case when public.is_super_admin() then 'super_admin' else 'owner' end;
  end if;
  perform public.log_audit(v_actor, p_action, p_entity_type, p_entity_id, p_metadata, v_uid);
end;
$$;

-- ----------------------------------------------------------------------------
-- Billing lifecycle
-- ----------------------------------------------------------------------------

-- Track subscription transitions in billing_events + audit_log.
create or replace function public.subscriptions_audit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event text;
begin
  if tg_op = 'INSERT' then
    v_event := 'trial_started';
  elsif new.status = 'active' and (old.status = 'trial' or old.status = 'expired' or old.status = 'cancelled') then
    v_event := 'plan_activated';
  elsif new.status = 'cancelled' then
    v_event := 'plan_cancelled';
  elsif new.status = 'expired' then
    v_event := 'trial_expired';
  elsif old.status = 'active' and new.status = 'past_due' then
    v_event := 'payment_failed';
  elsif new.current_period_end > old.current_period_end then
    v_event := 'period_renewed';
  else
    v_event := null;
  end if;

  if v_event is not null then
    insert into public.billing_events (owner_id, event_type, meta)
    values (new.owner_id, v_event,
            jsonb_build_object('status', new.status, 'period_end', new.current_period_end));
    perform public.log_audit('system', v_event, 'subscription', new.owner_id,
                             jsonb_build_object('status', new.status));
  end if;

  return null;
end;
$$;

create trigger subscriptions_audit
  after insert or update on public.subscriptions
  for each row execute function public.subscriptions_audit();

-- Super admin: activate a monthly plan for an owner.
create or replace function public.admin_activate_plan(p_owner_id uuid, p_monthly_amount numeric(12,2) default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_amount numeric(12,2);
begin
  if not public.is_super_admin() then
    raise exception 'super admin required';
  end if;

  v_amount := coalesce(p_monthly_amount,
                       (select monthly_amount from public.billing_plans where key = 'monthly'),
                       19.00);

  update public.subscriptions
     set status = 'active',
         plan = 'monthly',
         monthly_amount = v_amount,
         trial_ends_at = now(),
         current_period_start = now(),
         current_period_end = now() + interval '1 month'
   where owner_id = p_owner_id;
end;
$$;

-- Super admin: record a successful monthly payment (renews the period).
create or replace function public.admin_record_subscription_payment(p_owner_id uuid, p_amount numeric(12,2))
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sub public.subscriptions;
begin
  if not public.is_super_admin() then
    raise exception 'super admin required';
  end if;

  select * into v_sub from public.subscriptions where owner_id = p_owner_id;
  if v_sub.owner_id is null then
    raise exception 'subscription not found';
  end if;

  update public.subscriptions
     set status = 'active',
         current_period_start = coalesce(v_sub.current_period_end, now()),
         current_period_end   = coalesce(v_sub.current_period_end, now()) + interval '1 month'
   where owner_id = p_owner_id;

  insert into public.billing_events (owner_id, event_type, amount, meta)
  values (p_owner_id, 'payment_received', p_amount, jsonb_build_object('renews_to', now() + interval '1 month'));

  perform public.log_audit('super_admin', 'payment_received', 'subscription', p_owner_id,
                           jsonb_build_object('amount', p_amount));
end;
$$;

-- Super admin: cancel / revoke access.
create or replace function public.admin_set_subscription_status(p_owner_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'super admin required';
  end if;
  if p_status not in ('active','past_due','cancelled','expired','trial') then
    raise exception 'invalid status';
  end if;
  update public.subscriptions set status = p_status where owner_id = p_owner_id;
end;
$$;

-- Daily: expire trials and past-due subscriptions that ran out of time.
create or replace function public.expire_subscriptions()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  update public.subscriptions
     set status = 'expired'
   where status = 'trial' and trial_ends_at < now();
  get diagnostics v_count = row_count;

  update public.subscriptions
     set status = 'expired'
   where status = 'past_due' and current_period_end < now();

  return v_count;
end;
$$;

-- Daily: purge audit log entries older than 7 days.
create or replace function public.delete_old_audit_log()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  delete from public.audit_log where created_at < now() - interval '7 days';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.unschedule('rently-daily-subscriptions');
    exception when others then null; end;
    perform cron.schedule('rently-daily-subscriptions', '0 5 * * *',
      'select public.expire_subscriptions();');
    begin
      perform cron.unschedule('rently-daily-audit-cleanup');
    exception when others then null; end;
    perform cron.schedule('rently-daily-audit-cleanup', '0 1 * * *',
      'select public.delete_old_audit_log();');
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- Super admin monitoring helpers
-- ----------------------------------------------------------------------------

create or replace function public.admin_list_owners()
returns table (
  owner_id uuid, business_name text, property_kind public.property_kind,
  email text, plan text, subscription_status text, trial_ends_at timestamptz,
  current_period_end timestamptz, has_access boolean, created_at timestamptz,
  properties_count bigint, tenants_count bigint, outstanding numeric
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select
    o.id,
    o.business_name,
    o.property_kind,
    o.contact_email,
    s.plan,
    s.status,
    s.trial_ends_at,
    s.current_period_end,
    a.has_access,
    o.created_at,
    (select count(*) from public.properties p where p.owner_id = o.id),
    (select count(*) from public.tenants t where t.owner_id = o.id),
    (select coalesce(sum(i.balance), 0) from public.invoices i
      where i.owner_id = o.id and not i.is_void)
  from public.owners o
  left join public.subscriptions s on s.owner_id = o.id
  left join public.owner_access a on a.owner_id = o.id
  order by o.created_at;
$$;

create or replace function public.admin_owner_snapshot(p_owner_id uuid)
returns jsonb
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select jsonb_build_object(
    'owner', (select to_jsonb(o) from public.owners o where o.id = p_owner_id),
    'subscription', (select to_jsonb(s) from public.subscriptions s where s.owner_id = p_owner_id),
    'counts', jsonb_build_object(
      'properties', (select count(*) from public.properties where owner_id = p_owner_id),
      'units', (select count(*) from public.units where owner_id = p_owner_id),
      'seats', (select count(*) from public.seats where owner_id = p_owner_id),
      'tenants', (select count(*) from public.tenants where owner_id = p_owner_id),
      'invoices', (select count(*) from public.invoices where owner_id = p_owner_id),
      'payments', (select count(*) from public.payments where owner_id = p_owner_id),
      'messages', (select count(*) from public.messages where owner_id = p_owner_id)
    ),
    'outstanding', (select coalesce(sum(i.balance), 0) from public.invoices i
                     where i.owner_id = p_owner_id and not i.is_void),
    'recent_audit', (select jsonb_agg(x order by x.created_at desc)
                       from (select actor_type, action, entity_type, created_at, metadata
                               from public.audit_log
                              where entity_id = p_owner_id or metadata->>'owner_id' = p_owner_id::text
                              order by created_at desc limit 20) x)
  );
$$;

-- ----------------------------------------------------------------------------
-- Core audit triggers: capture platform activity automatically
-- ----------------------------------------------------------------------------

create or replace function public.audit_owner_signup()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.log_audit('owner', 'owner_created', 'owner', new.id,
                           jsonb_build_object('business_name', new.business_name), new.user_id);
  return null;
end;
$$;
create trigger audit_owner_signup after insert on public.owners
  for each row execute function public.audit_owner_signup();

create or replace function public.audit_entity_insert()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.log_audit('system', tg_table_name || '_created', tg_table_name, new.id);
  return null;
end;
$$;
create trigger audit_invoices_insert after insert on public.invoices
  for each row execute function public.audit_entity_insert();
create trigger audit_payments_insert after insert on public.payments
  for each row execute function public.audit_entity_insert();
create trigger audit_rent_history_insert after insert on public.rent_history
  for each row execute function public.audit_entity_insert();
create trigger audit_leases_insert after insert on public.leases
  for each row execute function public.audit_entity_insert();
create trigger audit_tenants_insert after insert on public.tenants
  for each row execute function public.audit_entity_insert();
create trigger audit_units_insert after insert on public.units
  for each row execute function public.audit_entity_insert();

-- ----------------------------------------------------------------------------
-- Realtime publication
-- All owner-scoped base tables the app renders live. Views (reports, ledger)
-- cannot be in a publication; those hooks poll instead.
-- ----------------------------------------------------------------------------
do $$
begin
  begin
    alter publication supabase_realtime add table public.properties, public.units,
      public.seats, public.tenants, public.leases, public.unit_templates,
      public.invoices, public.invoice_lines, public.payments, public.fines,
      public.owner_settings, public.rent_history, public.messages,
      public.notifications, public.billing_events, public.audit_log,
      public.expenses;
  exception when others then null;
  end;
end $$;


-- >>> supabase/migrations/009_feature_expansions.sql <<<
-- ============================================================================
-- 009_feature_expansions.sql
-- Currency setup, lookup-driven room descriptions, richer tenant records
-- (type + occupation) and a create-tenant-with-lease flow that assigns the
-- tenant to an apartment/cottage unit (and seat) in a single step.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Currencies (system lookup; owner rows can be added for future overrides)
-- ----------------------------------------------------------------------------

create table public.currencies (
  id        uuid primary key default gen_random_uuid(),
  owner_id  uuid references public.owners(id) on delete cascade,
  key       text not null,
  name      text not null,
  symbol    text not null,
  is_active boolean not null default true,
  unique (key, owner_id)
);

alter table public.currencies enable row level security;
select public.create_lookup_policies('currencies');

insert into public.currencies (owner_id, key, name, symbol) values
  (null, 'EUR', 'Euro', '€'),
  (null, 'USD', 'US Dollar', '$'),
  (null, 'GBP', 'British Pound', '£'),
  (null, 'PLN', 'Polish Złoty', 'zł'),
  (null, 'CZK', 'Czech Koruna', 'Kč'),
  (null, 'SEK', 'Swedish Krona', 'kr'),
  (null, 'NOK', 'Norwegian Krone', 'kr'),
  (null, 'DKK', 'Danish Krone', 'kr'),
  (null, 'CHF', 'Swiss Franc', 'CHF'),
  (null, 'TRY', 'Turkish Lira', '₺')
on conflict (key, owner_id) do nothing;

-- ----------------------------------------------------------------------------
-- Room types — the lookup table that drives unit room descriptions
-- (bedrooms, bathrooms, balcony, terrace, …). property_kind null = both.
-- ----------------------------------------------------------------------------

create table public.unit_room_types (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid references public.owners(id) on delete cascade,
  key           text not null,
  name          text not null,
  property_kind public.property_kind,
  is_active     boolean not null default true,
  unique (key, owner_id)
);

alter table public.unit_room_types enable row level security;
select public.create_lookup_policies('unit_room_types');

insert into public.unit_room_types (owner_id, key, name, property_kind) values
  (null, 'bedroom',      'Bedroom',      null),
  (null, 'bathroom',     'Bathroom',     null),
  (null, 'living_room',  'Living room',  null),
  (null, 'kitchen',      'Kitchen',      null),
  (null, 'balcony',      'Balcony',      'apartment'),
  (null, 'terrace',      'Terrace',      'cottage'),
  (null, 'garden',       'Garden',       'cottage'),
  (null, 'storage',      'Storage room', null),
  (null, 'dining',       'Dining area',  null),
  (null, 'study',        'Study',        null),
  (null, 'ensuite',      'En-suite',     null)
on conflict (key, owner_id) do nothing;

-- ----------------------------------------------------------------------------
-- Units: rooms jsonb map (room type key -> count), e.g.
--   {"bedroom":2,"bathroom":1,"balcony":1}
-- ----------------------------------------------------------------------------

alter table public.units
  add column rooms jsonb not null default '{}'::jsonb;

alter table public.unit_templates
  add column rooms jsonb not null default '{}'::jsonb;

-- Template snapshot must copy rooms.
create or replace function public.apply_unit_template(p_unit_id uuid, p_template_id uuid)
returns void
language plpgsql
as $$
declare
  v_owner uuid;
  v_tpl   record;
begin
  select owner_id into v_owner from public.units where id = p_unit_id;

  if v_owner is null then
    raise exception 'unit not found';
  end if;

  select * into v_tpl from public.unit_templates where id = p_template_id and owner_id = v_owner;
  if v_tpl is null then
    raise exception 'template not found for this owner';
  end if;

  update public.units
     set dimension        = v_tpl.dimension,
         bedrooms         = v_tpl.bedrooms,
         bathrooms        = v_tpl.bathrooms,
         rooms            = v_tpl.rooms,
         rent_amount      = v_tpl.default_rent,
         deposit_amount   = v_tpl.deposit_amount,
         facilities       = v_tpl.facilities,
         rules            = v_tpl.rules,
         charges          = v_tpl.charges,
         template_id      = p_template_id,
         template_snapshot = jsonb_build_object(
           'template_id',   p_template_id,
           'template_name', v_tpl.name,
           'applied_at',    now()
         )
   where id = p_unit_id;
end;
$$;

-- Bulk creation carries rooms (template default, overridable).
drop function if exists public.create_units_bulk(uuid, integer, text, uuid, text, numeric, numeric);
drop function if exists public.create_units_bulk(uuid, integer, text, uuid, text, numeric, numeric, jsonb);
create or replace function public.create_units_bulk(
  p_property_id uuid,
  p_count       integer,
  p_pattern     text default 'Unit ',
  p_template_id uuid default null,
  p_dimension   text default null,
  p_default_rent numeric(12,2) default null,
  p_deposit     numeric(12,2) default null,
  p_rooms       jsonb default null
)
returns setof public.units
language plpgsql
as $$
declare
  v_owner    uuid;
  v_existing integer;
  v_width    integer;
  v_i        integer;
  v_number   text;
  v_dim      text;
  v_rent     numeric(12,2);
  v_deposit  numeric(12,2);
  v_rooms    jsonb;
  v_tpl      record;
begin
  if p_count is null or p_count < 1 or p_count > 500 then
    raise exception 'p_count must be between 1 and 500';
  end if;

  select owner_id into v_owner from public.properties where id = p_property_id;
  if v_owner is null then
    raise exception 'property not found';
  end if;

  select count(*) into v_existing from public.units where property_id = p_property_id;
  v_width := length((v_existing + p_count)::text);

  if p_template_id is not null then
    select * into v_tpl from public.unit_templates where id = p_template_id and owner_id = v_owner;
    if v_tpl is null then
      raise exception 'template not found for this owner';
    end if;
  end if;

  v_rooms := coalesce(p_rooms, v_tpl.rooms, '{}'::jsonb);

  for v_i in 1..p_count loop
    v_number := public.render_unit_number(p_pattern, v_existing + v_i, v_width);

    v_dim    := coalesce(p_dimension,   v_tpl.dimension);
    v_rent   := coalesce(p_default_rent, v_tpl.default_rent);
    v_deposit:= coalesce(p_deposit,     v_tpl.deposit_amount);

    return query
      insert into public.units
        (owner_id, property_id, template_id, unit_number,
         dimension, rent_amount, deposit_amount,
         rooms, facilities, rules, charges,
         template_snapshot)
      values
        (v_owner, p_property_id, p_template_id, v_number,
         v_dim, v_rent, v_deposit,
         v_rooms,
         coalesce(v_tpl.facilities, '[]'::jsonb),
         coalesce(v_tpl.rules, '[]'::jsonb),
         coalesce(v_tpl.charges, '[]'::jsonb),
         case when v_tpl.id is not null then
           jsonb_build_object(
             'template_id', v_tpl.id,
             'template_name', v_tpl.name,
             'applied_at', now()
           )
         else null end)
      returning *;
  end loop;

  update public.properties
     set unit_count = (select count(*) from public.units where property_id = p_property_id)
   where id = p_property_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- Tenants: type (family/single) + occupation with conditional detail fields
-- ----------------------------------------------------------------------------

alter table public.tenants
  add column tenant_type      text not null default 'single'
        check (tenant_type in ('family','single')),
  add column occupation_type  text
        check (occupation_type in ('student','job_holder','other')),
  add column occupation_details jsonb not null default '{}'::jsonb;

comment on column public.tenants.occupation_details is
  'Conditional per occupation_type. student: {university, course, student_id}; '
  'job_holder: {employer, job_title, income}; other: {note}.';

-- ----------------------------------------------------------------------------
-- Create a tenant AND assign them to an apartment/cottage unit (and optional
-- seat) in a single call. When a unit is supplied a lease is created, which
-- generates the first rent invoice.
-- ----------------------------------------------------------------------------

create or replace function public.create_tenant_with_lease(
  p_first_name text,
  p_last_name  text,
  p_email      text default null,
  p_phone      text default null,
  p_whatsapp   text default null,
  p_join_date  date default current_date,
  p_tenant_type text default 'single',
  p_occupation_type text default null,
  p_occupation_details jsonb default '{}'::jsonb,
  p_unit_id    uuid default null,
  p_seat_id    uuid default null,
  p_start_date date default null,
  p_end_date   date default null,
  p_grace_days integer default null,
  p_notes      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid;
  v_tenant public.tenants;
  v_lease_id uuid;
begin
  v_owner := public.get_current_owner_id();
  if v_owner is null then
    raise exception 'owner not found';
  end if;

  if p_tenant_type is null or p_tenant_type not in ('family','single') then
    raise exception 'tenant_type must be family or single';
  end if;
  if p_occupation_type is not null and p_occupation_type not in ('student','job_holder','other') then
    raise exception 'occupation_type must be student, job_holder or other';
  end if;

  insert into public.tenants
    (owner_id, first_name, last_name, email, phone, whatsapp,
     join_date, note, tenant_type, occupation_type, occupation_details)
  values
    (v_owner, p_first_name, p_last_name, p_email, p_phone, p_whatsapp,
     p_join_date, p_notes, p_tenant_type, p_occupation_type, p_occupation_details)
  returning * into v_tenant;

  if p_unit_id is not null then
    insert into public.leases
      (owner_id, tenant_id, unit_id, seat_id, start_date, end_date,
       rent_amount, grace_days, notes)
    select v_owner, v_tenant.id, p_unit_id, p_seat_id,
           coalesce(p_start_date, p_join_date), p_end_date,
           coalesce(s.rent_amount, u.rent_amount), coalesce(p_grace_days, 3), p_notes
      from public.units u
      left join public.seats s on s.id = p_seat_id
     where u.id = p_unit_id and u.owner_id = v_owner
    returning id into v_lease_id;

    if v_lease_id is null then
      raise exception 'unit not found for this owner';
    end if;

    perform public.ensure_rent_invoice(v_tenant.id);
  end if;

  return jsonb_build_object('tenant_id', v_tenant.id, 'lease_id', v_lease_id);
end;
$$;

-- ----------------------------------------------------------------------------
-- Access view now carries the owner's currency so the app can format money
-- without an extra round trip.
-- ----------------------------------------------------------------------------

drop view if exists public.owner_access;

create or replace view public.owner_access
with (security_invoker = true) as
select
  o.id              as owner_id,
  o.user_id,
  o.business_name,
  o.property_kind,
  s.plan,
  s.status          as subscription_status,
  s.trial_ends_at,
  s.current_period_start,
  s.current_period_end,
  s.monthly_amount,
  st.currency,
  case
    when public.is_super_admin()                                   then true
    when s.status = 'trial' and s.trial_ends_at >= now()           then true
    when s.status in ('active','past_due')
         and (s.current_period_end is null or s.current_period_end >= now()) then true
    else false
  end as has_access,
  case
    when public.is_super_admin()                       then 'super_admin'
    when s.status = 'trial' and s.trial_ends_at >= now() then 'trial'
    when s.status in ('active','past_due')
         and (s.current_period_end is null or s.current_period_end >= now()) then 'active'
    else 'expired'
  end as access_state
from public.owners o
left join public.subscriptions s on s.owner_id = o.id
left join public.owner_settings st on st.owner_id = o.id;



-- >>> supabase/migrations/010_property_type_separation.sql <<<
-- ============================================================================
-- 010_property_type_separation.sql
-- Separation of the two property models everywhere in the schema:
--
--   * Apartment  : property -> unit (a flat) -> rooms composition
--                  (bedroom, drawing room, dining room, bathroom, kitchen,
--                  balcony, ...). Generated units are identical but each unit
--                  can be edited individually (rooms map lives on the unit).
--   * Cottage    : property -> rooms (= units) -> seats.
--                  Each seat has its own rent. Facilities/rules/charges are
--                  applied to the room AND copied onto each seat.
--
-- Also fixes the "duplicate" lookup bug: system rows (owner_id IS NULL) were
-- never protected by `unique (key, owner_id)` because Postgres treats NULLs as
-- distinct, so re-running a seed or migration duplicated rows and the UI
-- showed each room/currency/template twice.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Fix duplicate system lookup rows
-- ----------------------------------------------------------------------------

create unique index if not exists currencies_key_system_uidx
  on public.currencies(key) where owner_id is null;

create unique index if not exists unit_room_types_key_system_uidx
  on public.unit_room_types(key) where owner_id is null;

create unique index if not exists message_templates_key_system_uidx
  on public.message_templates(key) where owner_id is null;

create unique index if not exists facility_templates_name_system_uidx
  on public.facility_templates(name) where owner_id is null;

create unique index if not exists rule_templates_title_system_uidx
  on public.rule_templates(title) where owner_id is null;

-- De-duplicate rows that were already inserted before this migration. Keeps
-- the earliest row per key and drops later copies (system rows only).
delete from public.currencies a using public.currencies b
  where a.owner_id is null and b.owner_id is null
    and a.key = b.key and a.id > b.id;

delete from public.unit_room_types a using public.unit_room_types b
  where a.owner_id is null and b.owner_id is null
    and a.key = b.key and a.id > b.id;

delete from public.message_templates a using public.message_templates b
  where a.owner_id is null and b.owner_id is null
    and a.key = b.key and a.id > b.id;

delete from public.facility_templates a using public.facility_templates b
  where a.owner_id is null and b.owner_id is null
    and a.name = b.name and a.id > b.id;

delete from public.rule_templates a using public.rule_templates b
  where a.owner_id is null and b.owner_id is null
    and a.title = b.title and a.id > b.id;

-- ----------------------------------------------------------------------------
-- 2. Cottage seats get the same descriptive fields units have, so facilities
--    apply to seats exactly like they apply to units.
-- ----------------------------------------------------------------------------

alter table public.seats
  add column if not exists dimension  text,
  add column if not exists facilities jsonb not null default '[]'::jsonb,
  add column if not exists rules      jsonb not null default '[]'::jsonb,
  add column if not exists charges    jsonb not null default '[]'::jsonb;

-- ----------------------------------------------------------------------------
-- 3. Room types for the apartment room composition (bedroom, drawing room,
--    dining room, bathroom, kitchen, balcony, ...) and cottage extras.
-- ----------------------------------------------------------------------------

insert into public.unit_room_types (owner_id, key, name, property_kind) values
  (null, 'drawing',  'Drawing room', 'apartment'),
  (null, 'corridor', 'Corridor',     'apartment'),
  (null, 'hall',     'Hall',         'apartment'),
  (null, 'utility',  'Utility room', null),
  (null, 'porch',    'Porch',        'cottage')
on conflict (key) where owner_id is null do nothing;

-- ----------------------------------------------------------------------------
-- 4. create_units_bulk — fixed no-template path (previously crashed on the
--    unassigned record) and optional cottage seat generation (each room is
--    created together with its seats; every seat gets the room's rent and a
--    copy of the room's facilities).
-- ----------------------------------------------------------------------------

drop function if exists public.create_units_bulk(uuid, integer, text, uuid, text, numeric, numeric);
drop function if exists public.create_units_bulk(uuid, integer, text, uuid, text, numeric, numeric, jsonb);

create or replace function public.create_units_bulk(
  p_property_id    uuid,
  p_count          integer,
  p_pattern        text default 'Unit ',
  p_template_id    uuid default null,
  p_dimension      text default null,
  p_default_rent   numeric(12,2) default null,
  p_deposit        numeric(12,2) default null,
  p_rooms          jsonb default null,
  p_seats_per_unit integer default 0,
  p_seat_rent      numeric(12,2) default null
)
returns setof public.units
language plpgsql
as $$
declare
  v_owner    uuid;
  v_existing integer;
  v_width    integer;
  v_i        integer;
  v_s        integer;
  v_number   text;
  v_dim      text;
  v_rent     numeric(12,2);
  v_deposit  numeric(12,2);
  v_rooms    jsonb;
  v_unit     public.units;
  v_tpl      public.unit_templates;
begin
  if p_count is null or p_count < 1 or p_count > 500 then
    raise exception 'p_count must be between 1 and 500';
  end if;

  select owner_id into v_owner from public.properties where id = p_property_id;
  if v_owner is null then
    raise exception 'property not found';
  end if;

  select count(*) into v_existing from public.units where property_id = p_property_id;
  v_width := length((v_existing + p_count)::text);

  if p_template_id is not null then
    select * into v_tpl from public.unit_templates where id = p_template_id and owner_id = v_owner;
    if v_tpl is null then
      raise exception 'template not found for this owner';
    end if;
  else
    v_tpl.dimension      := null;
    v_tpl.default_rent   := null;
    v_tpl.deposit_amount := null;
    v_tpl.rooms          := '{}'::jsonb;
    v_tpl.facilities     := '[]'::jsonb;
    v_tpl.rules          := '[]'::jsonb;
    v_tpl.charges        := '[]'::jsonb;
  end if;

  v_rooms := coalesce(p_rooms, v_tpl.rooms, '{}'::jsonb);

  for v_i in 1..p_count loop
    v_number := public.render_unit_number(p_pattern, v_existing + v_i, v_width);

    v_dim    := coalesce(p_dimension,   v_tpl.dimension);
    v_rent   := coalesce(p_default_rent, v_tpl.default_rent);
    v_deposit:= coalesce(p_deposit,     v_tpl.deposit_amount);

    insert into public.units
      (owner_id, property_id, template_id, unit_number,
       dimension, rent_amount, deposit_amount,
       rooms, facilities, rules, charges,
       template_snapshot)
    values
      (v_owner, p_property_id, p_template_id, v_number,
       v_dim, coalesce(v_rent, 0), coalesce(v_deposit, 0),
       v_rooms,
       coalesce(v_tpl.facilities, '[]'::jsonb),
       coalesce(v_tpl.rules, '[]'::jsonb),
       coalesce(v_tpl.charges, '[]'::jsonb),
       case when p_template_id is not null then
         jsonb_build_object(
           'template_id',   p_template_id,
           'template_name', v_tpl.name,
           'applied_at',    now()
         )
       else null end)
    returning * into v_unit;

    if p_seats_per_unit > 0 then
      for v_s in 1..p_seats_per_unit loop
        insert into public.seats
          (owner_id, unit_id, seat_number, rent_amount, facilities, rules, charges)
        values
          (v_owner, v_unit.id,
           v_number || '-' || lpad(v_s::text, 2, '0'),
           coalesce(p_seat_rent, v_rent, 0),
           coalesce(v_tpl.facilities, '[]'::jsonb),
           coalesce(v_tpl.rules, '[]'::jsonb),
           coalesce(v_tpl.charges, '[]'::jsonb));
      end loop;
    end if;

    return next v_unit;
  end loop;

  update public.properties
     set unit_count = (select count(*) from public.units where property_id = p_property_id)
   where id = p_property_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. Security guards — SECURITY DEFINER functions that mutate money/history
--    must verify ownership of the target row.
-- ----------------------------------------------------------------------------

create or replace function public.set_manual_rent(
  p_lease_id     uuid,
  p_new_amount   numeric(12,2),
  p_note         text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_lease public.leases;
  v_old   numeric(12,2);
begin
  select * into v_lease from public.leases where id = p_lease_id;
  if v_lease.id is null then
    raise exception 'lease not found';
  end if;

  if not (v_lease.owner_id = auth.uid() or public.is_super_admin()) then
    raise exception 'not allowed to change rent for this lease';
  end if;

  v_old := v_lease.rent_amount;

  update public.leases set rent_amount = p_new_amount where id = p_lease_id;

  if v_lease.seat_id is not null then
    update public.seats set rent_amount = p_new_amount where id = v_lease.seat_id;
  else
    update public.units set rent_amount = p_new_amount where id = v_lease.unit_id;
  end if;

  insert into public.rent_history
    (owner_id, tenant_id, lease_id, seat_id, old_amount, new_amount,
     change_type, effective_date, applied_by, note)
  values
    (v_lease.owner_id, v_lease.tenant_id, v_lease.id, v_lease.seat_id,
     v_old, p_new_amount, 'manual', current_date, 'owner', p_note);
end;
$$;

create or replace function public.set_tenant_rent_increase(
  p_tenant_id uuid,
  p_enabled   boolean default null,
  p_amount    numeric(12,2) default null,
  p_percent   numeric(5,2) default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant public.tenants;
begin
  select * into v_tenant from public.tenants where id = p_tenant_id;
  if v_tenant.id is null then
    raise exception 'tenant not found';
  end if;

  if not (v_tenant.owner_id = auth.uid() or public.is_super_admin()) then
    raise exception 'not allowed to change rent settings for this tenant';
  end if;

  update public.tenants
     set rent_increase_enabled = coalesce(p_enabled, rent_increase_enabled),
         rent_increase_amount   = coalesce(p_amount, rent_increase_amount),
         rent_increase_percent  = coalesce(p_percent, rent_increase_percent)
   where id = p_tenant_id;

  insert into public.rent_history
    (owner_id, tenant_id, old_amount, new_amount, change_type, effective_date, applied_by, note)
  values
    (v_tenant.owner_id, v_tenant.id,
     coalesce(v_tenant.rent_increase_amount, 0),
     coalesce(p_amount, v_tenant.rent_increase_amount, 0),
     'override', current_date, 'owner',
     'Rent increase configuration changed (enabled=' || coalesce(p_enabled, v_tenant.rent_increase_enabled) || ')');
end;
$$;

-- The messaging notice must not be usable to inject messages for another
-- owner's tenant. The guard is skipped for cron jobs (auth.uid() is null).
create or replace function public.queue_rent_increase_notice(
  p_tenant_id      uuid,
  p_amount         numeric(12,2),
  p_percent        numeric(5,2),
  p_effective_date date
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant public.tenants;
  v_body   text;
begin
  select * into v_tenant from public.tenants where id = p_tenant_id;
  if v_tenant.id is null then
    return;
  end if;

  if auth.uid() is not null
     and not (v_tenant.owner_id = auth.uid() or public.is_super_admin()) then
    raise exception 'not allowed to message this tenant';
  end if;

  v_body := 'Dear ' || v_tenant.first_name || ', as of ' || p_effective_date
            || ' your rent will increase'
            || case
                 when p_amount > 0 and p_percent > 0 then ' by ' || p_amount || ' plus ' || p_percent || '%'
                 when p_percent > 0 then ' by ' || p_percent || '%'
                 when p_amount > 0 then ' by ' || p_amount
                 else ''
               end || '. Regards, your landlord.';

  perform public.queue_tenant_message(p_tenant_id, 'Rent increase notice', v_body, 'rent_increase');
end;
$$;

-- Super-admin helpers must be callable only by super admins. Cron-run jobs
-- (auth.uid() IS NULL) keep working.
create or replace function public.expire_subscriptions()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
  v_rows  integer;
begin
  if auth.uid() is not null and not public.is_super_admin() then
    raise exception 'super admin only';
  end if;

  update public.subscriptions
     set status = 'expired'
   where status = 'trial' and trial_ends_at < now();
  get diagnostics v_count = row_count;

  update public.subscriptions
     set status = 'expired'
   where status = 'past_due' and current_period_end < now();
  get diagnostics v_rows = row_count;
  v_count := v_count + v_rows;

  return v_count;
end;
$$;

create or replace function public.delete_old_audit_log()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  if auth.uid() is not null and not public.is_super_admin() then
    raise exception 'super admin only';
  end if;

  delete from public.audit_log where created_at < now() - interval '7 days';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.admin_list_owners()
returns table (
  owner_id uuid, business_name text, property_kind public.property_kind,
  email text, plan text, subscription_status text, trial_ends_at timestamptz,
  current_period_end timestamptz, has_access boolean, created_at timestamptz,
  properties_count bigint, tenants_count bigint, outstanding numeric
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if not public.is_super_admin() then
    raise exception 'super admin only';
  end if;

  return query
    select
      o.id,
      o.business_name,
      o.property_kind,
      o.contact_email,
      s.plan,
      s.status,
      s.trial_ends_at,
      s.current_period_end,
      a.has_access,
      o.created_at,
      (select count(*) from public.properties p where p.owner_id = o.id),
      (select count(*) from public.tenants t where t.owner_id = o.id),
      (select coalesce(sum(i.balance), 0) from public.invoices i
        where i.owner_id = o.id and not i.is_void)
    from public.owners o
    left join public.subscriptions s on s.owner_id = o.id
    left join public.owner_access a on a.owner_id = o.id
    order by o.created_at;
end;
$$;

create or replace function public.admin_owner_snapshot(p_owner_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if not public.is_super_admin() then
    raise exception 'super admin only';
  end if;

  return (
    select jsonb_build_object(
      'owner', (select to_jsonb(o) from public.owners o where o.id = p_owner_id),
      'subscription', (select to_jsonb(s) from public.subscriptions s where s.owner_id = p_owner_id),
      'counts', jsonb_build_object(
        'properties', (select count(*) from public.properties where owner_id = p_owner_id),
        'units', (select count(*) from public.units where owner_id = p_owner_id),
        'seats', (select count(*) from public.seats where owner_id = p_owner_id),
        'tenants', (select count(*) from public.tenants where owner_id = p_owner_id),
        'invoices', (select count(*) from public.invoices where owner_id = p_owner_id),
        'payments', (select count(*) from public.payments where owner_id = p_owner_id),
        'messages', (select count(*) from public.messages where owner_id = p_owner_id)
      ),
      'outstanding', (select coalesce(sum(i.balance), 0) from public.invoices i
                       where i.owner_id = p_owner_id and not i.is_void),
      'recent_audit', (select jsonb_agg(x order by x.created_at desc)
                         from (select actor_type, action, entity_type, created_at, metadata
                                 from public.audit_log
                                where entity_id = p_owner_id or metadata->>'owner_id' = p_owner_id::text
                                order by created_at desc limit 20) x)
    )
  );
end;
$$;

-- ============================================================================
-- >>> supabase/migrations/011_public_directory.sql <<<
-- ============================================================================
-- ============================================================================
-- 011_public_directory.sql
-- Public renter-facing directory plus the data the listing UI needs:
--
--   * properties get an `is_public` switch, an image list and a description
--   * units and seats get `applicable_for` (male / female / both) so a cottage
--     room (and each seat) is explicitly marked who may rent it, plus images
--     for units
--   * `public_settings` (single row, super-admin controlled) gates the public
--     page behind a name/phone check and toggles the whole directory
--   * `feedback` lets renters/visitors send system feedback; super admins
--     review it
--   * SECURITY DEFINER RPCs expose a read-only, filtered snapshot of published
--     properties to the `anon` role (public page) without weakening RLS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Property / unit / seat columns for the public directory
-- ----------------------------------------------------------------------------

alter table public.properties
  add column if not exists is_public   boolean not null default false,
  add column if not exists images      jsonb    not null default '[]'::jsonb,
  add column if not exists description text;

alter table public.units
  add column if not exists applicable_for text not null default 'both'
    check (applicable_for in ('male','female','both')),
  add column if not exists images      jsonb not null default '[]'::jsonb;

alter table public.seats
  add column if not exists applicable_for text not null default 'both'
    check (applicable_for in ('male','female','both'));

create index if not exists properties_is_public_idx on public.properties(is_public)
  where is_public;
create index if not exists units_applicable_for_idx on public.units(applicable_for);
create index if not exists seats_applicable_for_idx on public.seats(applicable_for);

-- ----------------------------------------------------------------------------
-- 2. Public directory settings (super admin controlled)
-- ----------------------------------------------------------------------------

create table if not exists public.public_settings (
  id             boolean primary key default true check (id),
  enabled        boolean not null default true,
  gate_enabled   boolean not null default true,
  name_required  boolean not null default true,
  phone_required boolean not null default true,
  updated_at     timestamptz not null default now(),
  updated_by     uuid
);

insert into public.public_settings (id) values (true)
on conflict (id) do nothing;

alter table public.public_settings enable row level security;

create policy public_settings_admin_all on public.public_settings
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

-- ----------------------------------------------------------------------------
-- 3. Feedback from renters / public visitors
-- ----------------------------------------------------------------------------

create table if not exists public.feedback (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  phone      text,
  email      text,
  rating     integer check (rating between 1 and 5),
  category   text,
  message    text not null,
  status     text not null default 'new' check (status in ('new','reviewed','archived')),
  created_at timestamptz not null default now()
);

alter table public.feedback enable row level security;

-- Anyone may submit feedback; nobody (except super admins) may read it back.
create policy feedback_insert_public on public.feedback
  for insert with check (true);

create policy feedback_admin_all on public.feedback
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

create index feedback_status_idx on public.feedback(status);
create index feedback_created_idx on public.feedback(created_at desc);

-- ----------------------------------------------------------------------------
-- 4. Read-only public RPCs (available to the anon role)
-- ----------------------------------------------------------------------------

-- Directory settings the public page needs to decide whether to show the
-- name/phone gate.
create or replace function public.public_directory_settings()
returns jsonb
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select jsonb_build_object(
    'enabled',
      coalesce((select enabled from public.public_settings limit 1), true),
    'gate_enabled',
      coalesce((select gate_enabled from public.public_settings limit 1), true),
    'name_required',
      coalesce((select name_required from public.public_settings limit 1), true),
    'phone_required',
      coalesce((select phone_required from public.public_settings limit 1), true)
  );
$$;

-- Published properties with live availability and rent. Availability is
-- derived from ACTIVE leases (whole-unit lease blocks a unit; a seat is free
-- unless it or its unit is leased out). `p_gender` filters rentables to the
-- matching `applicable_for`; `p_min_price` / `p_max_price` filter on the
-- cheapest currently available rentable.
create or replace function public.public_listings(
  p_min_price numeric(12,2) default null,
  p_max_price numeric(12,2) default null,
  p_gender    text default null
)
returns table (
  id                 uuid,
  name               text,
  description        text,
  images             jsonb,
  address_line1      text,
  city               text,
  state              text,
  country            text,
  property_type_key  text,
  property_type_name text,
  unit_count         bigint,
  available_rooms    bigint,
  available_seats    bigint,
  min_rent           numeric(12,2),
  applicable_for     text[],
  facilities         text[],
  created_at         timestamptz
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  with avail_units as (
    select u.*
      from public.units u
     where u.is_active
       and u.status = 'available'
       and (p_gender is null or u.applicable_for = 'both' or u.applicable_for = p_gender)
       and not exists (
         select 1 from public.leases l
          where l.unit_id = u.id and l.status = 'active' and l.seat_id is null
       )
  ),
  avail_seats as (
    select s.*, u.property_id
      from public.seats s
      join public.units u on u.id = s.unit_id
     where s.is_active
       and u.is_active
       and u.status = 'available'
       and (p_gender is null or s.applicable_for = 'both' or s.applicable_for = p_gender)
       and not exists (
         select 1 from public.leases l
          where l.unit_id = u.id and l.status = 'active' and l.seat_id is null
       )
       and not exists (
         select 1 from public.leases l2
          where l2.seat_id = s.id and l2.status = 'active'
       )
  )
  select
    p.id,
    p.name,
    p.description,
    p.images,
    p.address_line1,
    p.city,
    p.state,
    p.country,
    pt.key   as property_type_key,
    pt.name  as property_type_name,
    p.unit_count,
    case when pt.key = 'cottage' then
      (select count(distinct ase.unit_id)::bigint from avail_seats ase where ase.property_id = p.id)
    else
      (select count(*)::bigint from avail_units au where au.property_id = p.id)
    end as available_rooms,
    (select count(*)::bigint from avail_seats ase where ase.property_id = p.id) as available_seats,
    coalesce(
      (select min(ase.rent_amount) from avail_seats ase where ase.property_id = p.id),
      (select min(au.rent_amount)  from avail_units au where au.property_id = p.id)
    ) as min_rent,
    case when pt.key = 'cottage' then
      (select coalesce(array_agg(distinct ase.applicable_for), '{}'::text[])
         from avail_seats ase where ase.property_id = p.id)
    else
      (select coalesce(array_agg(distinct au.applicable_for), '{}'::text[])
         from avail_units au where au.property_id = p.id)
    end as applicable_for,
    (select coalesce(array_agg(distinct f.name), '{}'::text[])
       from (
         select jsonb_array_elements_text(u2.facilities)::jsonb ->> 'name' as name
           from public.units u2 where u2.property_id = p.id and u2.is_active
         union
         select jsonb_array_elements_text(s2.facilities)::jsonb ->> 'name' as name
           from public.seats s2
           join public.units u3 on u3.id = s2.unit_id
          where u3.property_id = p.id and s2.is_active and u3.is_active
       ) f
    ) as facilities,
    p.created_at
  from public.properties p
  join public.property_types pt on pt.key = p.property_type_id
  where p.is_public and p.is_active
    and (
      exists (select 1 from avail_units au where au.property_id = p.id)
      or exists (select 1 from avail_seats ase where ase.property_id = p.id)
    )
    and (p_min_price is null or coalesce(
      (select min(ase.rent_amount) from avail_seats ase where ase.property_id = p.id),
      (select min(au.rent_amount)  from avail_units au where au.property_id = p.id)
    ) >= p_min_price)
    and (p_max_price is null or coalesce(
      (select min(ase.rent_amount) from avail_seats ase where ase.property_id = p.id),
      (select min(au.rent_amount)  from avail_units au where au.property_id = p.id)
    ) <= p_max_price)
  order by p.created_at desc;
$$;

-- Full detail for one published property (used by the public property page).
create or replace function public.public_property_detail(p_property_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_result jsonb;
begin
  select jsonb_build_object(
    'id', p.id,
    'name', p.name,
    'description', p.description,
    'images', p.images,
    'address_line1', p.address_line1,
    'address_line2', p.address_line2,
    'city', p.city,
    'state', p.state,
    'postal_code', p.postal_code,
    'country', p.country,
    'property_type_key', pt.key,
    'property_type_name', pt.name,
    'unit_count', p.unit_count,
    'created_at', p.created_at,
    'facilities', (
      select coalesce(array_agg(distinct f.name), '{}'::text[])
      from (
        select jsonb_array_elements_text(u.facilities)::jsonb ->> 'name' as name
          from public.units u where u.property_id = p.id and u.is_active
        union
        select jsonb_array_elements_text(s.facilities)::jsonb ->> 'name' as name
          from public.seats s join public.units uu on uu.id = s.unit_id
         where uu.property_id = p.id and s.is_active and uu.is_active
      ) f
    ),
    'units', (
      select jsonb_agg(x order by x->>'unit_number')
      from (
        select jsonb_build_object(
          'id', u.id,
          'unit_number', u.unit_number,
          'floor', u.floor,
          'dimension', u.dimension,
          'rent_amount', u.rent_amount,
          'deposit_amount', u.deposit_amount,
          'applicable_for', u.applicable_for,
          'images', u.images,
          'facilities', u.facilities,
          'rooms', u.rooms,
          'available', (
            u.status = 'available'
            and not exists (
              select 1 from public.leases l
               where l.unit_id = u.id and l.status = 'active' and l.seat_id is null
            )
          ),
          'seats', (
            select jsonb_agg(y order by y->>'seat_number')
            from (
              select jsonb_build_object(
                'id', s.id,
                'seat_number', s.seat_number,
                'name', s.name,
                'rent_amount', s.rent_amount,
                'applicable_for', s.applicable_for,
                'facilities', s.facilities,
                'available', (
                  s.is_active
                  and u.status = 'available'
                  and not exists (
                    select 1 from public.leases l
                     where l.unit_id = u.id and l.status = 'active' and l.seat_id is null
                  )
                  and not exists (
                    select 1 from public.leases l2
                     where l2.seat_id = s.id and l2.status = 'active'
                  )
                )
              ) y
              from public.seats s where s.unit_id = u.id and s.is_active
            ) y
          )
        ) x
        from public.units u where u.property_id = p.id and u.is_active
      ) x
    )
  ) into v_result
  from public.properties p
  join public.property_types pt on pt.key = p.property_type_id
  where p.id = p_property_id and p.is_public and p.is_active;

  if v_result is null then
    raise exception 'property not found or not published';
  end if;
  return v_result;
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. Grants for the anon (public page) role
-- ----------------------------------------------------------------------------

grant usage on schema public to anon, authenticated;
grant execute on function public.public_directory_settings() to anon, authenticated;
grant execute on function public.public_listings(numeric, numeric, text) to anon, authenticated;
grant execute on function public.public_property_detail(uuid) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 6. create_units_bulk — extended for `applicable_for` (male/female/both) and
--    explicit facilities so a new property can stamp gender + facilities onto
--    every generated unit (and cottage seat) in one call.
-- ----------------------------------------------------------------------------

drop function if exists public.create_units_bulk(uuid, integer, text, uuid, text, numeric, numeric);
drop function if exists public.create_units_bulk(uuid, integer, text, uuid, text, numeric, numeric, jsonb);
drop function if exists public.create_units_bulk(uuid, integer, text, uuid, text, numeric, numeric, jsonb, integer, numeric);

create or replace function public.create_units_bulk(
  p_property_id    uuid,
  p_count          integer,
  p_pattern        text default 'Unit ',
  p_template_id    uuid default null,
  p_dimension      text default null,
  p_default_rent   numeric(12,2) default null,
  p_deposit        numeric(12,2) default null,
  p_rooms          jsonb default null,
  p_seats_per_unit integer default 0,
  p_seat_rent      numeric(12,2) default null,
  p_applicable_for text default 'both',
  p_facilities     jsonb default null
)
returns setof public.units
language plpgsql
as $$
declare
  v_owner          uuid;
  v_existing       integer;
  v_width          integer;
  v_i              integer;
  v_s              integer;
  v_number         text;
  v_dim            text;
  v_rent           numeric(12,2);
  v_deposit        numeric(12,2);
  v_rooms          jsonb;
  v_facilities     jsonb;
  v_applicable     text;
  v_unit           public.units;
  v_tpl            public.unit_templates;
begin
  if p_count is null or p_count < 1 or p_count > 500 then
    raise exception 'p_count must be between 1 and 500';
  end if;

  v_applicable := coalesce(p_applicable_for, 'both');
  if v_applicable not in ('male','female','both') then
    raise exception 'applicable_for must be male, female or both';
  end if;

  select owner_id into v_owner from public.properties where id = p_property_id;
  if v_owner is null then
    raise exception 'property not found';
  end if;

  select count(*) into v_existing from public.units where property_id = p_property_id;
  v_width := length((v_existing + p_count)::text);

  if p_template_id is not null then
    select * into v_tpl from public.unit_templates where id = p_template_id and owner_id = v_owner;
    if v_tpl is null then
      raise exception 'template not found for this owner';
    end if;
  else
    v_tpl.dimension      := null;
    v_tpl.default_rent   := null;
    v_tpl.deposit_amount := null;
    v_tpl.rooms          := '{}'::jsonb;
    v_tpl.facilities     := '[]'::jsonb;
    v_tpl.rules          := '[]'::jsonb;
    v_tpl.charges        := '[]'::jsonb;
  end if;

  v_rooms      := coalesce(p_rooms, v_tpl.rooms, '{}'::jsonb);
  v_facilities := coalesce(p_facilities, v_tpl.facilities, '[]'::jsonb);

  for v_i in 1..p_count loop
    v_number := public.render_unit_number(p_pattern, v_existing + v_i, v_width);

    v_dim    := coalesce(p_dimension,   v_tpl.dimension);
    v_rent   := coalesce(p_default_rent, v_tpl.default_rent);
    v_deposit:= coalesce(p_deposit,     v_tpl.deposit_amount);

    insert into public.units
      (owner_id, property_id, template_id, unit_number,
       dimension, rent_amount, deposit_amount,
       rooms, facilities, rules, charges,
       applicable_for, template_snapshot)
    values
      (v_owner, p_property_id, p_template_id, v_number,
       v_dim, coalesce(v_rent, 0), coalesce(v_deposit, 0),
       v_rooms,
       v_facilities,
       coalesce(v_tpl.rules, '[]'::jsonb),
       coalesce(v_tpl.charges, '[]'::jsonb),
       v_applicable,
       case when p_template_id is not null then
         jsonb_build_object(
           'template_id',   p_template_id,
           'template_name', v_tpl.name,
           'applied_at',    now()
         )
       else null end)
    returning * into v_unit;

    if p_seats_per_unit > 0 then
      for v_s in 1..p_seats_per_unit loop
        insert into public.seats
          (owner_id, unit_id, seat_number, rent_amount, facilities, rules, charges, applicable_for)
        values
          (v_owner, v_unit.id,
           v_number || '-' || lpad(v_s::text, 2, '0'),
           coalesce(p_seat_rent, v_rent, 0),
           v_facilities,
           coalesce(v_tpl.rules, '[]'::jsonb),
           coalesce(v_tpl.charges, '[]'::jsonb),
           v_applicable);
      end loop;
    end if;

    return next v_unit;
  end loop;

  update public.properties
     set unit_count = (select count(*) from public.units where property_id = p_property_id)
   where id = p_property_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- 7. Extra common facility templates for the directory / seat pickers
-- ----------------------------------------------------------------------------

insert into public.facility_templates (owner_id, name, category) values
  (null, 'Attached bathroom', 'bathroom'),
  (null, 'Running water', 'water'),
  (null, 'Electricity', 'utility'),
  (null, 'CCTV surveillance', 'security'),
  (null, 'Balcony', 'structure'),
  (null, 'Kitchen access', 'kitchen'),
  (null, 'Bed & mattress', 'furnishing'),
  (null, 'Room cleaner', 'service'),
  (null, 'Geyser / hot water', 'water'),
  (null, 'Gym access', 'facility'),
  (null, 'Study table', 'furnishing'),
  (null, 'Cupboard / wardrobe', 'furnishing'),
  (null, 'Guard / doorman', 'security'),
  (null, 'Generator backup', 'utility')
on conflict (name) where owner_id is null do nothing;


-- ============================================================================
-- >>> supabase/migrations/012_publication_approval.sql <<<
-- ============================================================================
-- 012_publication_approval.sql
-- Property publication approval workflow plus the BDT default currency.
--
--   * properties gain `publication_status` (private / pending / approved /
--     rejected) with a review trail (note, reviewed_at, reviewed_by)
--   * toggling `is_public` on submits the property for review (trigger); the
--     public directory only ever shows `approved` listings
--   * super admins review pending properties via RPCs
--     (`public_directory_pending`, `public_review_property`)
--   * owners may re-submit a rejected property via `resubmit_publication`
--   * default owner currency switches from EUR to BDT and BDT is seeded into
--     the `currencies` lookup
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Publication approval columns on properties
-- ----------------------------------------------------------------------------

alter table public.properties
  add column if not exists publication_status text not null default 'private'
    check (publication_status in ('private','pending','approved','rejected')),
  add column if not exists review_note     text,
  add column if not exists reviewed_at     timestamptz,
  add column if not exists reviewed_by     uuid references auth.users(id);

create index if not exists properties_publication_status_idx
  on public.properties(publication_status) where is_public;

-- Properties already switched on before this migration shipped are treated as
-- approved (they were visible and should not be yanked off the directory).
update public.properties
   set publication_status = 'approved'
 where is_public;

-- ----------------------------------------------------------------------------
-- 2. Workflow trigger — listing a property requests publication
-- ----------------------------------------------------------------------------

create or replace function public.properties_publication_status()
returns trigger
language plpgsql
as $$
begin
  if new.is_public and old.is_public is distinct from new.is_public then
    new.publication_status := 'pending';
    new.review_note        := null;
    new.reviewed_at        := null;
    new.reviewed_by        := null;
  elsif not new.is_public then
    new.publication_status := 'private';
    new.review_note        := null;
    new.reviewed_at        := null;
    new.reviewed_by        := null;
  end if;
  return new;
end;
$$;

drop trigger if exists properties_publication_status on public.properties;
create trigger properties_publication_status
  before update of is_public on public.properties
  for each row execute function public.properties_publication_status();

-- ----------------------------------------------------------------------------
-- 3. Public RPCs now only expose APPROVED properties
-- ----------------------------------------------------------------------------

create or replace function public.public_listings(
  p_min_price numeric(12,2) default null,
  p_max_price numeric(12,2) default null,
  p_gender    text default null
)
returns table (
  id                 uuid,
  name               text,
  description        text,
  images             jsonb,
  address_line1      text,
  city               text,
  state              text,
  country            text,
  property_type_key  text,
  property_type_name text,
  unit_count         bigint,
  available_rooms    bigint,
  available_seats    bigint,
  min_rent           numeric(12,2),
  applicable_for     text[],
  facilities         text[],
  created_at         timestamptz
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  with avail_units as (
    select u.*
      from public.units u
     where u.is_active
       and u.status = 'available'
       and (p_gender is null or u.applicable_for = 'both' or u.applicable_for = p_gender)
       and not exists (
         select 1 from public.leases l
          where l.unit_id = u.id and l.status = 'active' and l.seat_id is null
       )
  ),
  avail_seats as (
    select s.*, u.property_id
      from public.seats s
      join public.units u on u.id = s.unit_id
     where s.is_active
       and u.is_active
       and u.status = 'available'
       and (p_gender is null or s.applicable_for = 'both' or s.applicable_for = p_gender)
       and not exists (
         select 1 from public.leases l
          where l.unit_id = u.id and l.status = 'active' and l.seat_id is null
       )
       and not exists (
         select 1 from public.leases l2
          where l2.seat_id = s.id and l2.status = 'active'
       )
  )
  select
    p.id,
    p.name,
    p.description,
    p.images,
    p.address_line1,
    p.city,
    p.state,
    p.country,
    pt.key   as property_type_key,
    pt.name  as property_type_name,
    p.unit_count,
    case when pt.key = 'cottage' then
      (select count(distinct ase.unit_id)::bigint from avail_seats ase where ase.property_id = p.id)
    else
      (select count(*)::bigint from avail_units au where au.property_id = p.id)
    end as available_rooms,
    (select count(*)::bigint from avail_seats ase where ase.property_id = p.id) as available_seats,
    coalesce(
      (select min(ase.rent_amount) from avail_seats ase where ase.property_id = p.id),
      (select min(au.rent_amount)  from avail_units au where au.property_id = p.id)
    ) as min_rent,
    case when pt.key = 'cottage' then
      (select coalesce(array_agg(distinct ase.applicable_for), '{}'::text[])
         from avail_seats ase where ase.property_id = p.id)
    else
      (select coalesce(array_agg(distinct au.applicable_for), '{}'::text[])
         from avail_units au where au.property_id = p.id)
    end as applicable_for,
    (select coalesce(array_agg(distinct f.name), '{}'::text[])
       from (
         select jsonb_array_elements_text(u2.facilities)::jsonb ->> 'name' as name
           from public.units u2 where u2.property_id = p.id and u2.is_active
         union
         select jsonb_array_elements_text(s2.facilities)::jsonb ->> 'name' as name
           from public.seats s2
           join public.units u3 on u3.id = s2.unit_id
          where u3.property_id = p.id and s2.is_active and u3.is_active
       ) f
    ) as facilities,
    p.created_at
  from public.properties p
  join public.property_types pt on pt.key = p.property_type_id
  where p.is_public and p.publication_status = 'approved' and p.is_active
    and (
      exists (select 1 from avail_units au where au.property_id = p.id)
      or exists (select 1 from avail_seats ase where ase.property_id = p.id)
    )
    and (p_min_price is null or coalesce(
      (select min(ase.rent_amount) from avail_seats ase where ase.property_id = p.id),
      (select min(au.rent_amount)  from avail_units au where au.property_id = p.id)
    ) >= p_min_price)
    and (p_max_price is null or coalesce(
      (select min(ase.rent_amount) from avail_seats ase where ase.property_id = p.id),
      (select min(au.rent_amount)  from avail_units au where au.property_id = p.id)
    ) <= p_max_price)
  order by p.created_at desc;
$$;

create or replace function public.public_property_detail(p_property_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_result jsonb;
begin
  select jsonb_build_object(
    'id', p.id,
    'name', p.name,
    'description', p.description,
    'images', p.images,
    'address_line1', p.address_line1,
    'address_line2', p.address_line2,
    'city', p.city,
    'state', p.state,
    'postal_code', p.postal_code,
    'country', p.country,
    'property_type_key', pt.key,
    'property_type_name', pt.name,
    'unit_count', p.unit_count,
    'created_at', p.created_at,
    'facilities', (
      select coalesce(array_agg(distinct f.name), '{}'::text[])
      from (
        select jsonb_array_elements_text(u.facilities)::jsonb ->> 'name' as name
          from public.units u where u.property_id = p.id and u.is_active
        union
        select jsonb_array_elements_text(s.facilities)::jsonb ->> 'name' as name
          from public.seats s join public.units uu on uu.id = s.unit_id
         where uu.property_id = p.id and s.is_active and uu.is_active
      ) f
    ),
    'units', (
      select jsonb_agg(x order by x->>'unit_number')
      from (
        select jsonb_build_object(
          'id', u.id,
          'unit_number', u.unit_number,
          'floor', u.floor,
          'dimension', u.dimension,
          'rent_amount', u.rent_amount,
          'deposit_amount', u.deposit_amount,
          'applicable_for', u.applicable_for,
          'images', u.images,
          'facilities', u.facilities,
          'rooms', u.rooms,
          'available', (
            u.status = 'available'
            and not exists (
              select 1 from public.leases l
               where l.unit_id = u.id and l.status = 'active' and l.seat_id is null
            )
          ),
          'seats', (
            select jsonb_agg(y order by y->>'seat_number')
            from (
              select jsonb_build_object(
                'id', s.id,
                'seat_number', s.seat_number,
                'name', s.name,
                'rent_amount', s.rent_amount,
                'applicable_for', s.applicable_for,
                'facilities', s.facilities,
                'available', (
                  s.is_active
                  and u.status = 'available'
                  and not exists (
                    select 1 from public.leases l
                     where l.unit_id = u.id and l.status = 'active' and l.seat_id is null
                  )
                  and not exists (
                    select 1 from public.leases l2
                     where l2.seat_id = s.id and l2.status = 'active'
                  )
                )
              ) y
              from public.seats s where s.unit_id = u.id and s.is_active
            ) y
          )
        ) x
        from public.units u where u.property_id = p.id and u.is_active
      ) x
    )
  ) into v_result
  from public.properties p
  join public.property_types pt on pt.key = p.property_type_id
  where p.id = p_property_id and p.is_public and p.publication_status = 'approved' and p.is_active;

  if v_result is null then
    raise exception 'property not found or not published';
  end if;
  return v_result;
end;
$$;

grant execute on function public.public_listings(numeric, numeric, text) to anon, authenticated;
grant execute on function public.public_property_detail(uuid) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4. Super-admin review RPCs
-- ----------------------------------------------------------------------------

-- Pending publication requests (super admins only).
create or replace function public.public_directory_pending()
returns table (
  id                 uuid,
  name               text,
  business_name      text,
  city               text,
  country            text,
  property_type_name text,
  unit_count         integer,
  is_public          boolean,
  created_at         timestamptz
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select p.id, p.name, o.business_name, p.city, p.country,
         pt.name as property_type_name, p.unit_count, p.is_public, p.created_at
    from public.properties p
    join public.owners o on o.id = p.owner_id
    join public.property_types pt on pt.key = p.property_type_id
   where p.publication_status = 'pending'
     and public.is_super_admin()
   order by p.created_at asc;
$$;

-- Approve / reject a pending publication (super admins only).
create or replace function public.public_review_property(
  p_property_id uuid,
  p_approve    boolean,
  p_note       text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'only super admins may review publications';
  end if;
  update public.properties
     set publication_status = case when p_approve then 'approved' else 'rejected' end,
         review_note       = case when p_approve then null else coalesce(p_note, 'Not approved') end,
         reviewed_at       = now(),
         reviewed_by       = auth.uid()
   where id = p_property_id;
  if not found then
    raise exception 'property not found';
  end if;
end;
$$;

grant execute on function public.public_directory_pending() to authenticated;
grant execute on function public.public_review_property(uuid, boolean, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. Owner re-submission
-- ----------------------------------------------------------------------------

-- Lets the owning owner send a rejected property back into the review queue.
create or replace function public.resubmit_publication(p_property_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid;
begin
  select owner_id into v_owner from public.properties where id = p_property_id;
  if v_owner is null or v_owner <> auth.uid() then
    raise exception 'not allowed';
  end if;
  update public.properties
     set is_public = true,
         publication_status = 'pending',
         review_note = null,
         reviewed_at = null,
         reviewed_by = null
   where id = p_property_id;
end;
$$;

grant execute on function public.resubmit_publication(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 6. BDT default currency
-- ----------------------------------------------------------------------------

alter table public.owner_settings alter column currency set default 'BDT';

insert into public.currencies (owner_id, key, name, symbol) values
  (null, 'BDT', 'Bangladeshi Taka', '৳')
on conflict (key, owner_id) do nothing;

-- >>> supabase/migrations/013_bulksms_owner_phone.sql <<<
-- ============================================================================
-- 013_bulksms_owner_phone.sql
-- 1) Captures the owner's phone number at signup so renters can contact them.
-- 2) Defaults the messaging provider to bulkSMSBD (Bangladesh).
--
-- bulkSMSBD is dispatched by the Vercel serverless function /api/dispatch-sms
-- (see README). Set on Vercel: BULKSMSBD_API_KEY, BULKSMSBD_SENDER_ID,
-- SUPABASE_SERVICE_ROLE_KEY.
-- ============================================================================

-- Store the phone number provided at registration on the owner record.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_business_name text;
  v_kind          text;
  v_phone         text;
  v_owner_id      uuid;
  v_kind_ok       text;
begin
  v_business_name := coalesce(new.raw_user_meta_data->>'business_name', 'My Property Business');
  v_kind          := coalesce(new.raw_user_meta_data->>'property_kind', 'apartment');
  v_kind_ok       := case when v_kind in ('apartment','cottage','both') then v_kind else 'apartment' end;
  v_phone         := nullif(btrim(new.raw_user_meta_data->>'phone'), '');

  insert into public.owners (id, user_id, business_name, contact_email, contact_phone, property_kind)
  values (new.id, new.id, v_business_name, new.email, v_phone, v_kind_ok::public.property_kind)
  on conflict (user_id) do nothing
  returning id into v_owner_id;

  if v_owner_id is null then
    select id into v_owner_id from public.owners where user_id = new.id;
  end if;

  insert into public.owner_settings (owner_id)
  values (v_owner_id)
  on conflict (owner_id) do nothing;

  insert into public.subscriptions (owner_id)
  values (v_owner_id)
  on conflict (owner_id) do nothing;

  return new;
end;
$$;

-- New owner accounts default to the bulkSMSBD provider.
alter table public.owner_settings alter column message_provider set default 'bulksmsbd';

-- >>> supabase/migrations/014_public_owner_contact.sql <<<
-- ============================================================================
-- 014_public_owner_contact.sql
-- Exposes the owner's contact details on the public property page so renters
-- can reach the owner directly and send a WhatsApp enquiry about a unit.
-- ============================================================================

create or replace function public.public_property_detail(p_property_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_result jsonb;
begin
  select jsonb_build_object(
    'id', p.id,
    'name', p.name,
    'description', p.description,
    'images', p.images,
    'address_line1', p.address_line1,
    'address_line2', p.address_line2,
    'city', p.city,
    'state', p.state,
    'postal_code', p.postal_code,
    'country', p.country,
    'property_type_key', pt.key,
    'property_type_name', pt.name,
    'unit_count', p.unit_count,
    'created_at', p.created_at,
    'owner_name', o.business_name,
    'owner_phone', o.contact_phone,
    'owner_email', o.contact_email,
    'facilities', (
      select coalesce(array_agg(distinct f.name), '{}'::text[])
      from (
        select jsonb_array_elements_text(u.facilities)::jsonb ->> 'name' as name
          from public.units u where u.property_id = p.id and u.is_active
        union
        select jsonb_array_elements_text(s.facilities)::jsonb ->> 'name' as name
          from public.seats s join public.units uu on uu.id = s.unit_id
         where uu.property_id = p.id and s.is_active and uu.is_active
      ) f
    ),
    'units', (
      select jsonb_agg(x order by x->>'unit_number')
      from (
        select jsonb_build_object(
          'id', u.id,
          'unit_number', u.unit_number,
          'floor', u.floor,
          'dimension', u.dimension,
          'rent_amount', u.rent_amount,
          'deposit_amount', u.deposit_amount,
          'applicable_for', u.applicable_for,
          'images', u.images,
          'facilities', u.facilities,
          'rooms', u.rooms,
          'available', (
            u.status = 'available'
            and not exists (
              select 1 from public.leases l
               where l.unit_id = u.id and l.status = 'active' and l.seat_id is null
            )
          ),
          'seats', (
            select jsonb_agg(y order by y->>'seat_number')
            from (
              select jsonb_build_object(
                'id', s.id,
                'seat_number', s.seat_number,
                'name', s.name,
                'rent_amount', s.rent_amount,
                'applicable_for', s.applicable_for,
                'facilities', s.facilities,
                'available', (
                  s.is_active
                  and u.status = 'available'
                  and not exists (
                    select 1 from public.leases l
                     where l.unit_id = u.id and l.status = 'active' and l.seat_id is null
                  )
                  and not exists (
                    select 1 from public.leases l2
                     where l2.seat_id = s.id and l2.status = 'active'
                  )
                )
              ) y
              from public.seats s where s.unit_id = u.id and s.is_active
            ) y
          )
        ) x
        from public.units u where u.property_id = p.id and u.is_active
      ) x
    )
  ) into v_result
  from public.properties p
  join public.property_types pt on pt.key = p.property_type_id
  join public.owners o on o.id = p.owner_id
  where p.id = p_property_id and p.is_public and p.is_active;

  if v_result is null then
    raise exception 'property not found or not published';
  end if;
  return v_result;
end;
$$;

grant execute on function public.public_property_detail(uuid) to anon, authenticated;

-- >>> supabase/migrations/015_default_message_templates.sql <<<
-- ============================================================================
-- 015_default_message_templates.sql
-- Guarantees the default tenant-facing message templates exist so the
-- tenant-detail "Send message" picker always has templates to offer,
-- even when seed.sql was not run (idempotent: keeps the seed inserts).
-- ============================================================================

insert into public.message_templates (owner_id, key, channel_group, subject, body) values
  (null, 'payment_reminder', 'tenant_facing', 'Payment reminder',
   'Dear {name}, this is a friendly reminder that invoice {invoice} of {amount} is due. Balance: {balance}.'),
  (null, 'payment_warning', 'tenant_facing', 'Payment warning',
   'Dear {name}, invoice {invoice} is {days} days overdue. Please settle the balance of {balance}.'),
  (null, 'overdue_escalation', 'tenant_facing', 'Overdue escalation',
   'Dear {name}, your account is significantly overdue. Please arrange payment of {balance} immediately.'),
  (null, 'rent_increase', 'tenant_facing', 'Rent increase notice',
   'Dear {name}, as of {date} your rent will increase. Regards, your landlord.'),
  (null, 'announcement', 'tenant_facing', 'Announcement', '{body}')
on conflict (key) where owner_id is null do nothing;


-- >>> seed.sql <<<
-- ============================================================================
-- seed.sql
-- System lookup defaults, default billing plan and message templates.
-- Run once after migrations (e.g. `supabase db seed` or in the SQL editor).
-- ============================================================================

-- ============================================================================
-- seed.sql
-- System lookup defaults, default billing plan and message templates.
-- Run once after migrations (e.g. `supabase db seed` or in the SQL editor).
-- ============================================================================

insert into public.property_types (key, name) values
  ('apartment', 'Apartment'),
  ('cottage', 'Cottage')
on conflict (key) do nothing;

insert into public.charge_types (key, name) values
  ('rent', 'Rent'),
  ('deposit', 'Deposit'),
  ('utility', 'Utilities'),
  ('fine', 'Fine'),
  ('late_fee', 'Late fee'),
  ('other', 'Other')
on conflict (key) do nothing;

insert into public.invoice_types (key, name) values
  ('rent', 'Rent'),
  ('fine', 'Fine'),
  ('deposit', 'Deposit'),
  ('utility', 'Utility'),
  ('other', 'Other')
on conflict (key) do nothing;

insert into public.invoice_statuses (key, name) values
  ('draft', 'Draft'),
  ('open', 'Open'),
  ('partially_paid', 'Partially paid'),
  ('paid', 'Paid'),
  ('overdue', 'Overdue'),
  ('void', 'Void')
on conflict (key) do nothing;

insert into public.payment_methods (key, name) values
  ('cash', 'Cash'),
  ('bank_transfer', 'Bank transfer'),
  ('card', 'Card'),
  ('mobile_money', 'Mobile money'),
  ('other', 'Other')
on conflict (key) do nothing;

insert into public.numbering_patterns (key, pattern, description) values
  ('unit', 'Unit ', 'Unit 01, Unit 02, …'),
  ('apartment_a', 'A-', 'A-01, A-02, …'),
  ('apartment_b', 'B-', 'B-01, B-02, …'),
  ('room', 'Room ', 'Room 01, Room 02, …'),
  ('number', '{n}', '01, 02, …'),
  ('wing', 'W-{n}-1', 'W-01-1, W-02-1, …')
on conflict (key) do nothing;

insert into public.currencies (owner_id, key, name, symbol) values
  (null, 'BDT', 'Bangladeshi Taka', '৳'),
  (null, 'EUR', 'Euro', '€'),
  (null, 'USD', 'US Dollar', '$'),
  (null, 'GBP', 'British Pound', '£'),
  (null, 'PLN', 'Polish Złoty', 'zł'),
  (null, 'CZK', 'Czech Koruna', 'Kč'),
  (null, 'SEK', 'Swedish Krona', 'kr'),
  (null, 'NOK', 'Norwegian Krone', 'kr'),
  (null, 'DKK', 'Danish Krone', 'kr'),
  (null, 'CHF', 'Swiss Franc', 'CHF'),
  (null, 'TRY', 'Turkish Lira', '₺')
on conflict (key) where owner_id is null do nothing;

insert into public.unit_room_types (owner_id, key, name, property_kind) values
  (null, 'bedroom',      'Bedroom',      null),
  (null, 'drawing',      'Drawing room', 'apartment'),
  (null, 'dining',       'Dining area',  null),
  (null, 'living_room',  'Living room',  null),
  (null, 'bathroom',     'Bathroom',     null),
  (null, 'kitchen',      'Kitchen',      null),
  (null, 'balcony',      'Balcony',      'apartment'),
  (null, 'hall',         'Hall',         'apartment'),
  (null, 'corridor',     'Corridor',     'apartment'),
  (null, 'utility',      'Utility room', null),
  (null, 'terrace',      'Terrace',      'cottage'),
  (null, 'garden',       'Garden',       'cottage'),
  (null, 'porch',        'Porch',        'cottage'),
  (null, 'storage',      'Storage room', null),
  (null, 'study',        'Study',        null),
  (null, 'ensuite',      'En-suite',     null)
on conflict (key) where owner_id is null do nothing;

insert into public.facility_templates (owner_id, name, category) values
  (null, 'Parking spot', 'parking'),
  (null, 'WiFi included', 'internet'),
  (null, 'Garden access', 'outdoor'),
  (null, 'Furnished', 'furnishing'),
  (null, 'Washing machine', 'appliance')
on conflict (name) where owner_id is null do nothing;

insert into public.rule_templates (owner_id, title, body) values
  (null, 'No smoking', 'Smoking is not permitted inside the unit.'),
  (null, 'Pets on request', 'Pets are allowed only with prior written approval.'),
  (null, 'No subletting', 'Subletting or short-term rentals are prohibited.')
on conflict (title) where owner_id is null do nothing;

insert into public.billing_plans (key, name, monthly_amount, description) values
  ('monthly', 'Monthly', 19.00, 'Recurring monthly plan after the free trial'),
  ('annual', 'Annual', 190.00, 'Discounted annual plan (not used by default)')
on conflict (key) do nothing;

insert into public.message_templates (owner_id, key, channel_group, subject, body) values
  (null, 'payment_reminder', 'tenant_facing', 'Payment reminder',
   'Dear {name}, this is a friendly reminder that invoice {invoice} of {amount} is due. Balance: {balance}.'),
  (null, 'payment_warning', 'tenant_facing', 'Payment warning',
   'Dear {name}, invoice {invoice} is {days} days overdue. Please settle the balance of {balance}.'),
  (null, 'overdue_escalation', 'tenant_facing', 'Overdue escalation',
   'Dear {name}, your account is significantly overdue. Please arrange payment of {balance} immediately.'),
  (null, 'rent_increase', 'tenant_facing', 'Rent increase notice',
   'Dear {name}, as of {date} your rent will increase. Regards, your landlord.'),
  (null, 'announcement', 'tenant_facing', 'Announcement', '{body}')
on conflict (key) where owner_id is null do nothing;
