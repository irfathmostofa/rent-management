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
