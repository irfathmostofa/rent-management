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
