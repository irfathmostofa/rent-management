import { useRealtimeList } from './useRealtimeList'

export function useInvoices() {
  return useRealtimeList({
    table: 'invoices',
    select:
      '*, tenant:tenants(first_name, last_name), property:properties(name), invoice_types!inner(key, name), payments(*)',
    order: 'period_start',
    orderAsc: false,
  })
}

export function useInvoice(id) {
  return useRealtimeList({
    table: 'invoices',
    select:
      '*, tenant:tenants(*), property:properties(name), invoice_types(key, name), lines:invoice_lines(*), payments(*)',
    eq: id ? ['id', id] : null,
    realtimeFilter: null,
    enabled: Boolean(id),
  })
}

export function useLedger(tenantId) {
  return useRealtimeList({
    table: 'tenant_ledger',
    select: '*',
    eq: tenantId ? ['tenant_id', tenantId] : null,
    order: 'effective_at',
    orderAsc: false,
    realtimeFilter: null,
    enabled: Boolean(tenantId),
    realtime: false,
  })
}
