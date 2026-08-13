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
