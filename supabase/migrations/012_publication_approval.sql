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
