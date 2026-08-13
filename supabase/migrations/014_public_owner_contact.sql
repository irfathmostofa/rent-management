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
