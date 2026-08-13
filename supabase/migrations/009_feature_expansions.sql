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

