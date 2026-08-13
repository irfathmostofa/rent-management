-- ============================================================================
-- 004_invoicing_engine.sql
-- Rent cycles (30-day fixed), auto invoice generation, the one-non-void-
-- rent-invoice-per-period constraint, partial payments, fines and the
-- per-tenant running ledger.
-- ============================================================================

alter table public.properties add column grace_days integer not null default 3 check (grace_days >= 0);

create sequence if not exists public.invoice_seq;

-- ----------------------------------------------------------------------------
-- Invoices
-- ----------------------------------------------------------------------------

create table public.invoices (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null references public.owners(id) on delete cascade,
  tenant_id        uuid not null references public.tenants(id) on delete cascade,
  property_id      uuid references public.properties(id) on delete set null,
  invoice_number   text not null default
                     ('INV-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.invoice_seq')::text, 5, '0')),
  invoice_type_key text not null references public.invoice_types(key),
  status_key       text not null default 'open' references public.invoice_statuses(key),
  period_start     date,
  period_end       date,
  issue_date       date not null default current_date,
  due_date         date,
  amount           numeric(12,2) not null default 0 check (amount >= 0),
  amount_paid      numeric(12,2) not null default 0 check (amount_paid >= 0),
  balance          numeric(12,2) generated always as (amount - amount_paid) stored,
  description      text,
  rent_invoice_id  uuid references public.invoices(id) on delete set null,
  fine_reason      text,
  is_void          boolean not null default false,
  void_reason      text,
  voided_at        timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (amount_paid <= amount),
  check (rent_invoice_id is null or invoice_type_key = 'fine'),
  check (invoice_type_key = 'fine' or (rent_invoice_id is null and fine_reason is null))
);

create index invoices_tenant_idx on public.invoices(tenant_id);
create index invoices_owner_idx on public.invoices(owner_id);
create index invoices_due_date_idx on public.invoices(due_date) where not is_void;

-- Enforce at the database level that a tenant cannot hold more than one
-- non-void rent invoice per billing period (period_start identifies the
-- cycle, because cycles are anchored to the tenant's join date).
create unique index invoices_one_rent_per_period
  on public.invoices(tenant_id, period_start)
  where invoice_type_key = 'rent' and not is_void;

-- Invoice line items (seat-level rent breakdown for a tenant-level invoice).
create table public.invoice_lines (
  id         uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  unit_id    uuid not null references public.units(id) on delete cascade,
  seat_id    uuid references public.seats(id) on delete set null,
  description text,
  amount     numeric(12,2) not null default 0 check (amount >= 0)
);

create index invoice_lines_invoice_idx on public.invoice_lines(invoice_id);

-- ----------------------------------------------------------------------------
-- Payments (partial payments supported; invoice status derives from them)
-- ----------------------------------------------------------------------------

create table public.payments (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.owners(id) on delete cascade,
  invoice_id  uuid not null references public.invoices(id) on delete cascade,
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  amount      numeric(12,2) not null check (amount > 0),
  paid_at     timestamptz not null default now(),
  method_key  text not null references public.payment_methods(key),
  reference   text,
  note        text,
  created_at  timestamptz not null default now()
);

create index payments_invoice_idx on public.payments(invoice_id);
create index payments_tenant_idx on public.payments(tenant_id);
create index payments_owner_idx on public.payments(owner_id);

alter table public.invoices enable row level security;
alter table public.invoice_lines enable row level security;
alter table public.payments enable row level security;

create policy invoices_select on public.invoices
  for select using (owner_id = auth.uid() or public.is_super_admin());
create policy invoices_insert on public.invoices
  for insert with check (owner_id = auth.uid() or public.is_super_admin());
create policy invoices_update on public.invoices
  for update using (owner_id = auth.uid() or public.is_super_admin());

create policy invoice_lines_select on public.invoice_lines
  for select using (
    exists (select 1 from public.invoices i where i.id = invoice_id and (i.owner_id = auth.uid() or public.is_super_admin()))
  );
create policy invoice_lines_insert on public.invoice_lines
  for insert with check (
    exists (select 1 from public.invoices i where i.id = invoice_id and (i.owner_id = auth.uid() or public.is_super_admin()))
  );

create policy payments_select on public.payments
  for select using (owner_id = auth.uid() or public.is_super_admin());
create policy payments_insert on public.payments
  for insert with check (owner_id = auth.uid() or public.is_super_admin());
create policy payments_delete on public.payments
  for delete using (owner_id = auth.uid() or public.is_super_admin());

-- ----------------------------------------------------------------------------
-- Cycle helpers
-- ----------------------------------------------------------------------------

-- The 30-day billing cycle (anchored to the tenant join date) that contains
-- p_anchor.
create or replace function public.tenant_cycle_bounds(p_tenant_id uuid, p_anchor date default current_date)
returns table (period_start date, period_end date)
language sql
stable
as $$
  select
    (t.join_date + ((p_anchor - t.join_date) / 30) * 30)::date as period_start,
    (t.join_date + ((p_anchor - t.join_date) / 30) * 30 + 29)::date as period_end
  from public.tenants t
  where t.id = p_tenant_id;
$$;

-- Total snapshot rent and resolved grace days for a tenant's active leases.
create or replace function public.tenant_billing(p_tenant_id uuid)
returns table (rent_amount numeric, grace_days integer)
language sql
stable
as $$
  select
    coalesce(sum(l.rent_amount), 0)::numeric(12,2) as rent_amount,
    greatest(coalesce(max(coalesce(l.grace_days, p.grace_days)), 0))::integer as grace_days
  from public.leases l
  left join public.units u on u.id = l.unit_id
  left join public.properties p on p.id = u.property_id
  where l.tenant_id = p_tenant_id and l.status = 'active';
$$;

-- ----------------------------------------------------------------------------
-- Invoice generation
-- ----------------------------------------------------------------------------

-- Create the rent invoice for a tenant's current cycle if one does not yet
-- exist. Idempotent: the partial unique index makes duplicate inserts no-ops.
create or replace function public.ensure_rent_invoice(p_tenant_id uuid)
returns public.invoices
language plpgsql
as $$
declare
  v_invoice public.invoices;
  v_owner   uuid;
  v_bounds  record;
  v_bill    record;
  v_lease   record;
begin
  select owner_id into v_owner from public.tenants where id = p_tenant_id;
  if v_owner is null then
    return null;
  end if;

  select * into v_bounds from public.tenant_cycle_bounds(p_tenant_id, current_date);
  if v_bounds.period_start is null or v_bounds.period_start > current_date then
    return null;
  end if;

  select * into v_invoice from public.invoices
   where tenant_id = p_tenant_id and invoice_type_key = 'rent' and not is_void
     and period_start = v_bounds.period_start;

  if v_invoice.id is not null then
    return v_invoice;
  end if;

  select * into v_bill from public.tenant_billing(p_tenant_id);
  if v_bill.rent_amount <= 0 then
    return null;
  end if;

  insert into public.invoices
    (owner_id, tenant_id, invoice_type_key, status_key,
     period_start, period_end, issue_date, due_date, amount, description)
  values
    (v_owner, p_tenant_id, 'rent', 'open',
     v_bounds.period_start, v_bounds.period_end, v_bounds.period_start,
     v_bounds.period_end + v_bill.grace_days, v_bill.rent_amount,
     'Rent ' || to_char(v_bounds.period_start, 'YYYY-MM-DD'))
  on conflict do nothing
  returning * into v_invoice;

  if v_invoice.id is null then
    select * into v_invoice from public.invoices
     where tenant_id = p_tenant_id and invoice_type_key = 'rent' and not is_void
       and period_start = v_bounds.period_start;
    return v_invoice;
  end if;

  for v_lease in
    select l.*, u.property_id,
           coalesce(s.rent_amount, l.rent_amount) as billed_amount,
           l.unit_id, l.seat_id
      from public.leases l
      left join public.units u on u.id = l.unit_id
      left join public.seats s on s.id = l.seat_id
     where l.tenant_id = p_tenant_id and l.status = 'active'
  loop
    insert into public.invoice_lines (invoice_id, unit_id, seat_id, description, amount)
    values (v_invoice.id, v_lease.unit_id, v_lease.seat_id,
            'Rent · ' || (select unit_number from public.units where id = v_lease.unit_id),
            v_lease.billed_amount);
  end loop;

  return v_invoice;
end;
$$;

-- Generate due invoices for every active tenant (optionally scoped to one
-- owner). Called daily by pg_cron and on lease creation.
create or replace function public.generate_due_invoices(p_owner_id uuid default null)
returns integer
language plpgsql
as $$
declare
  v_count integer := 0;
  v_tenant uuid;
begin
  for v_tenant in
    select t.id
      from public.tenants t
     where t.status = 'active'
       and (p_owner_id is null or t.owner_id = p_owner_id)
  loop
    perform public.ensure_rent_invoice(v_tenant);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- Create a fine (separate invoice type, optionally linked to a rent invoice).
-- Fine stacking is configurable per owner; when disabled, at most one
-- non-void fine is allowed per tenant per billing cycle.
create or replace function public.create_fine(
  p_tenant_id      uuid,
  p_amount         numeric(12,2),
  p_reason         text,
  p_rent_invoice_id uuid default null,
  p_description    text default null
)
returns public.invoices
language plpgsql
as $$
declare
  v_owner   uuid;
  v_settings record;
  v_period  record;
  v_fine    public.invoices;
begin
  select owner_id into v_owner from public.tenants where id = p_tenant_id;
  if v_owner is null then
    raise exception 'tenant not found';
  end if;

  select * into v_settings from public.owner_settings where owner_id = v_owner;

  select * into v_period from public.tenant_cycle_bounds(p_tenant_id, current_date);

  if not coalesce(v_settings.fine_stacking_allowed, true) then
    if exists (
      select 1 from public.invoices
       where tenant_id = p_tenant_id and invoice_type_key = 'fine' and not is_void
         and period_start = v_period.period_start
    ) then
      raise exception 'fine stacking is disabled for this owner';
    end if;
  end if;

  if p_rent_invoice_id is not null then
    if not exists (
      select 1 from public.invoices
       where id = p_rent_invoice_id and tenant_id = p_tenant_id and invoice_type_key = 'rent' and not is_void
    ) then
      raise exception 'linked rent invoice not found for tenant';
    end if;
  end if;

  insert into public.invoices
    (owner_id, tenant_id, invoice_type_key, status_key, period_start, period_end,
     issue_date, due_date, amount, description, rent_invoice_id, fine_reason)
  values
    (v_owner, p_tenant_id, 'fine', 'open', v_period.period_start, v_period.period_end,
     current_date, current_date + coalesce(v_settings.default_grace_days, 3),
     p_amount, coalesce(p_description, 'Fine: ' || p_reason), p_rent_invoice_id, p_reason)
  returning * into v_fine;

  return v_fine;
end;
$$;

-- ----------------------------------------------------------------------------
-- Payments
-- ----------------------------------------------------------------------------

create or replace function public.record_payment(
  p_invoice_id  uuid,
  p_amount      numeric(12,2),
  p_method_key  text default 'bank_transfer',
  p_paid_at     timestamptz default now(),
  p_reference   text default null,
  p_note        text default null
)
returns public.payments
language plpgsql
as $$
declare
  v_invoice  public.invoices;
  v_owner    uuid;
  v_payment  public.payments;
begin
  select * into v_invoice from public.invoices where id = p_invoice_id;
  if v_invoice.id is null then
    raise exception 'invoice not found';
  end if;
  if v_invoice.is_void then
    raise exception 'cannot pay a voided invoice';
  end if;

  v_owner := v_invoice.owner_id;

  insert into public.payments
    (owner_id, invoice_id, tenant_id, amount, paid_at, method_key, reference, note)
  values
    (v_owner, p_invoice_id, v_invoice.tenant_id, p_amount, p_paid_at, p_method_key, p_reference, p_note)
  returning * into v_payment;

  return v_payment;
end;
$$;

-- Keep invoice.amount_paid and status_key in sync after every payment.
create or replace function public.payments_sync_invoice()
returns trigger
language plpgsql
as $$
declare
  v_paid numeric(12,2);
  v_inv public.invoices;
begin
  select coalesce(sum(p.amount), 0) into v_paid
    from public.payments p where p.invoice_id = coalesce(new.invoice_id, old.invoice_id);

  select * into v_inv from public.invoices
    where id = coalesce(new.invoice_id, old.invoice_id);

  update public.invoices
     set amount_paid = v_paid,
         status_key = case
           when v_paid >= v_inv.amount then 'paid'
           when v_paid > 0 then 'partially_paid'
           else 'open'
         end
   where id = v_inv.id;

  return null;
end;
$$;

create trigger payments_sync_invoice
  after insert or delete on public.payments
  for each row execute function public.payments_sync_invoice();

-- ----------------------------------------------------------------------------
-- Voiding
-- ----------------------------------------------------------------------------

create or replace function public.void_invoice(p_invoice_id uuid, p_reason text)
returns void
language plpgsql
as $$
declare
  v_invoice public.invoices;
begin
  select * into v_invoice from public.invoices where id = p_invoice_id;
  if v_invoice.id is null then
    raise exception 'invoice not found';
  end if;
  if v_invoice.amount_paid > 0 then
    raise exception 'cannot void an invoice with recorded payments';
  end if;
  if v_invoice.invoice_type_key = 'rent' and exists (
    select 1 from public.invoices f
     where f.rent_invoice_id = v_invoice.id and not f.is_void
  ) then
    raise exception 'cannot void a rent invoice with attached fines';
  end if;

  update public.invoices
     set is_void = true, void_reason = p_reason, voided_at = now(), status_key = 'void'
   where id = p_invoice_id;
end;
$$;

-- Daily: mark invoices past their due date as overdue.
create or replace function public.recompute_overdue()
returns integer
language plpgsql
as $$
declare
  v_count integer;
begin
  update public.invoices
     set status_key = 'overdue'
   where not is_void
     and due_date < current_date
     and balance > 0
     and status_key in ('open','partially_paid');
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ----------------------------------------------------------------------------
-- Running per-tenant ledger
-- ----------------------------------------------------------------------------

create or replace view public.ledger_entries
with (security_invoker = true) as
select
  'invoice'::text       as entry_type,
  i.id                  as entry_id,
  i.owner_id,
  i.tenant_id,
  i.invoice_type_key    as kind,
  i.description         as description,
  i.amount              as delta,
  i.period_start,
  i.due_date,
  i.issue_date          as effective_at,
  i.created_at
from public.invoices i
where not i.is_void

union all

select
  'payment'::text       as entry_type,
  p.id                  as entry_id,
  p.owner_id,
  p.tenant_id,
  p.method_key          as kind,
  coalesce(p.reference, p.note, 'Payment') as description,
  -p.amount             as delta,
  null                  as period_start,
  null                  as due_date,
  p.paid_at             as effective_at,
  p.created_at
from public.payments p

order by effective_at, created_at, entry_id;

-- Running balance per tenant after each entry.
create or replace view public.tenant_ledger
with (security_invoker = true) as
select
  le.entry_type,
  le.entry_id,
  le.owner_id,
  le.tenant_id,
  le.kind,
  le.description,
  le.delta,
  le.period_start,
  le.due_date,
  le.effective_at,
  le.created_at,
  sum(le.delta) over (
    partition by le.tenant_id
    order by le.effective_at, le.created_at, le.entry_id
    rows between unbounded preceding and current row
  ) as running_balance
from public.ledger_entries le;

-- ----------------------------------------------------------------------------
-- Lease creation (snapshots rent, triggers first invoice)
-- ----------------------------------------------------------------------------

create or replace function public.create_lease(
  p_tenant_id   uuid,
  p_unit_id     uuid,
  p_seat_id     uuid default null,
  p_start_date  date default current_date,
  p_end_date    date default null,
  p_grace_days  integer default null,
  p_billing_cycle integer default 30,
  p_notes       text default null
)
returns public.leases
language plpgsql
as $$
declare
  v_owner    uuid;
  v_rent     numeric(12,2);
  v_lease    public.leases;
begin
  select owner_id into v_owner from public.tenants where id = p_tenant_id;
  if v_owner is null then
    raise exception 'tenant not found';
  end if;

  if not exists (
    select 1 from public.units where id = p_unit_id and owner_id = v_owner
  ) then
    raise exception 'unit not found for this owner';
  end if;

  select coalesce(s.rent_amount, u.rent_amount) into v_rent
    from public.units u
    left join public.seats s on s.id = p_seat_id
   where u.id = p_unit_id;

  insert into public.leases
    (owner_id, tenant_id, unit_id, seat_id, start_date, end_date,
     rent_amount, grace_days, billing_cycle, notes)
  values
    (v_owner, p_tenant_id, p_unit_id, p_seat_id, p_start_date, p_end_date,
     coalesce(v_rent, 0), coalesce(p_grace_days, 3), p_billing_cycle, p_notes)
  returning * into v_lease;

  perform public.ensure_rent_invoice(p_tenant_id);

  return v_lease;
end;
$$;

-- End a lease (e.g. move-out). Sets status to ended.
create or replace function public.end_lease(p_lease_id uuid, p_end_date date default current_date)
returns void
language plpgsql
as $$
begin
  update public.leases
     set status = 'ended', end_date = coalesce(p_end_date, end_date)
   where id = p_lease_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- Realtime + scheduled jobs
-- ----------------------------------------------------------------------------

do $$
begin
  begin
    alter publication supabase_realtime add table public.invoices, public.payments;
  exception when others then null;
  end;
end $$;

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
