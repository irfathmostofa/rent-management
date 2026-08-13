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
