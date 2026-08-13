import { useRealtimeList } from './useRealtimeList'

export function useOwnerSettings() {
  const res = useRealtimeList({
    table: 'owner_settings',
    select: '*',
    realtimeFilter: null,
  })
  return { ...res, settings: res.data?.[0] ?? null }
}

export function useAuditLog() {
  const res = useRealtimeList({
    table: 'audit_log',
    select: '*',
    order: 'created_at',
    orderAsc: false,
    realtimeFilter: null,
    realtime: false,
  })
  return { ...res, logs: res.data ?? [] }
}

export function useBillingEvents() {
  return useRealtimeList({ table: 'billing_events', select: '*', order: 'occurred_at', orderAsc: false })
}
