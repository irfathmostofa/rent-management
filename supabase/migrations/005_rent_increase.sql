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
