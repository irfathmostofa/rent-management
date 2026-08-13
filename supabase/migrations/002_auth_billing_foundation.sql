-- ============================================================================
-- 002_auth_billing_foundation.sql
-- Owner provisioning on signup, owner preferences, trial subscription and
-- the single access-gate view that the whole app checks.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Owner preferences / settings
-- ----------------------------------------------------------------------------

create table public.owner_settings (
  id                         uuid primary key default gen_random_uuid(),
  owner_id                   uuid not null unique references public.owners(id) on delete cascade,
  default_grace_days         integer not null default 3 check (default_grace_days >= 0),
  fine_stacking_allowed      boolean not null default true,
  rent_increase_enabled      boolean not null default false,
  rent_increase_amount       numeric(12,2),
  rent_increase_percent      numeric(5,2),
  tenant_messaging_channels  jsonb not null default '["whatsapp","sms"]'::jsonb,
  owner_notification_channels jsonb not null default '["email","in_app"]'::jsonb,
  message_provider           text not null default 'none',
  currency                   text not null default 'EUR',
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now()
);

create trigger owner_settings_updated_at
  before update on public.owner_settings
  for each row execute function public.set_updated_at();

alter table public.owner_settings enable row level security;

create trigger owner_settings_set_owner
  before insert on public.owner_settings
  for each row execute function public.set_owner_id();

create policy owner_settings_select on public.owner_settings
  for select using (owner_id = auth.uid() or public.is_super_admin());

create policy owner_settings_insert on public.owner_settings
  for insert with check (owner_id = auth.uid() or public.is_super_admin());

create policy owner_settings_update on public.owner_settings
  for update using (owner_id = auth.uid() or public.is_super_admin());

-- ----------------------------------------------------------------------------
-- Billing plans (platform-defined, read-only)
-- ----------------------------------------------------------------------------

create table public.billing_plans (
  key            text primary key,
  name           text not null,
  monthly_amount numeric(12,2) not null,
  description    text,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- Subscriptions (one per owner; trial auto-created on signup)
-- ----------------------------------------------------------------------------

create table public.subscriptions (
  owner_id            uuid primary key references public.owners(id) on delete cascade,
  plan                text not null default 'trial',
  status              text not null default 'trial'
                      check (status in ('trial','active','past_due','cancelled','expired')),
  trial_started_at    timestamptz not null default now(),
  trial_ends_at       timestamptz not null default (now() + interval '14 days'),
  current_period_start timestamptz,
  current_period_end  timestamptz,
  monthly_amount      numeric(12,2) not null default 19.00,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create trigger subscriptions_updated_at
  before update on public.subscriptions
  for each row execute function public.set_updated_at();

alter table public.subscriptions enable row level security;

create policy subscriptions_select on public.subscriptions
  for select using (owner_id = auth.uid() or public.is_super_admin());

create policy subscriptions_insert on public.subscriptions
  for insert with check (owner_id = auth.uid() or public.is_super_admin());

create policy subscriptions_update on public.subscriptions
  for update using (owner_id = auth.uid() or public.is_super_admin());

-- ----------------------------------------------------------------------------
-- Owner provisioning on signup
-- ----------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_business_name text;
  v_kind          text;
  v_owner_id      uuid;
  v_kind_ok       text;
begin
  v_business_name := coalesce(new.raw_user_meta_data->>'business_name', 'My Property Business');
  v_kind          := coalesce(new.raw_user_meta_data->>'property_kind', 'apartment');
  v_kind_ok       := case when v_kind in ('apartment','cottage','both') then v_kind else 'apartment' end;

  insert into public.owners (id, user_id, business_name, contact_email, property_kind)
  values (new.id, new.id, v_business_name, new.email, v_kind_ok::public.property_kind)
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

drop trigger if exists on_owner_signup on auth.users;
create trigger on_owner_signup
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ----------------------------------------------------------------------------
-- Current owner helper
-- ----------------------------------------------------------------------------

create or replace function public.get_current_owner()
returns public.owners
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select * from public.owners where user_id = auth.uid();
$$;

create or replace function public.get_current_owner_id()
returns uuid
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select id from public.owners where user_id = auth.uid();
$$;

-- ----------------------------------------------------------------------------
-- Access gate
-- A single view combining subscription status, trial end date and current
-- billing period. security_invoker=true so each owner only sees their own
-- row (super admins see everything). The frontend calls this once.
-- ----------------------------------------------------------------------------

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
left join public.subscriptions s on s.owner_id = o.id;

create or replace function public.get_access_status()
returns jsonb
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select to_jsonb(a) from public.owner_access a where a.user_id = auth.uid();
$$;

create or replace function public.can_access_app()
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select exists (
    select 1 from public.owner_access a where a.user_id = auth.uid() and a.has_access
  );
$$;
