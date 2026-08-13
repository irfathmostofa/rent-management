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
