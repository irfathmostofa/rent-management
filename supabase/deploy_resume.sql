-- ============================================================================
-- Rently — RESUME script (run this if deploy_all.sql failed partway through)
-- ============================================================================
-- If your earlier run of deploy_all.sql stopped at the pg_cron step in
-- migration 004 ("could not find valid entry for job"), migrations 001-004
-- are already applied. Run THIS script to apply the remainder (004 cron jobs,
-- migrations 005-010, and the seed data).
--
-- NOTE: If your project is still completely empty (no Rently tables yet), run
-- deploy_all.sql instead — do not use this resume script.
-- ============================================================================

-- >>> migration 004: pg_cron jobs (unschedule is now guarded) <<<
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

-- >>> migration 005: annual rent increases <<<
-- >>> migration 006: messaging engine <<<
-- >>> migration 007: reports + expenses <<<
-- >>> migration 008: super admin, billing lifecycle, audit log <<<

-- >>> seed data <<<

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
