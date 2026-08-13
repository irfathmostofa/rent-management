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
