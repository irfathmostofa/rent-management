import { useRealtimeList } from './useRealtimeList'

export function useMessages() {
  return useRealtimeList({
    table: 'messages',
    select: '*',
    order: 'created_at',
    orderAsc: false,
  })
}

export function useNotifications() {
  return useRealtimeList({
    table: 'notifications',
    select: '*',
    order: 'created_at',
    orderAsc: false,
    realtimeFilter: null,
  })
}

export function useMessageTemplates() {
  // Templates are a lookup table: system rows (owner_id null) plus per-owner
  // rows. realtimeFilter null so both are tracked live.
  return useRealtimeList({
    table: 'message_templates',
    order: 'key',
    realtimeFilter: null,
  })
}
