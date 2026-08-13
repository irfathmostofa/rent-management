import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useOwnerId } from '../auth/AuthContext'

// Apply a postgres_changes payload to local state.
export function applyChange(rows, payload) {
  const { eventType, new: fresh, old } = payload
  if (eventType === 'INSERT') {
    if (rows.some((r) => r.id === fresh.id)) return rows
    return [fresh, ...rows]
  }
  if (eventType === 'UPDATE') {
    return rows.map((r) => (r.id === fresh.id ? { ...r, ...fresh } : r))
  }
  if (eventType === 'DELETE') {
    return rows.filter((r) => r.id !== old.id)
  }
  return rows
}

/**
 * Fetch rows from a table and keep them live via Realtime.
 * Returns { data, setData, loading, error, refresh }.
 *
 * setData is exposed so callers can implement optimistic updates (mutate
 * local state, call Supabase, roll back on error).
 */
export function useRealtimeList({
  table,
  select = '*',
  eq = null,
  order = null,
  orderAsc = true,
  realtimeFilter = null,
  enabled = true,
  realtime = true,
}) {
  const ownerId = useOwnerId()
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const mountedRef = useRef(true)

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  const queryKey = useMemo(
    () => JSON.stringify({ table, select, eq, order, orderAsc }),
    [table, select, eq, order, orderAsc]
  )

  const refresh = useCallback(async () => {
    if (!supabase) return
    if (!enabled) {
      setData([])
      setLoading(false)
      return
    }
    setLoading(true)
    try {
      let q = supabase.from(table).select(select)
      if (eq) q = q.eq(eq[0], eq[1])
      if (order) q = q.order(order, { ascending: orderAsc })
      const { data: rows, error: err } = await q
      if (mountedRef.current) {
        if (err) {
          setError(err.message)
          setData(null)
        } else {
          setError(null)
          setData(rows ?? [])
        }
        setLoading(false)
      }
    } catch (err) {
      if (mountedRef.current) {
        setError(err.message)
        setData(null)
        setLoading(false)
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [queryKey, enabled])

  useEffect(() => {
    refresh()
  }, [refresh])

  // Realtime subscription
  useEffect(() => {
    if (!supabase || !enabled || !realtime || !ownerId) return undefined
    const filter =
      realtimeFilter ?? (table === 'notifications' ? undefined : `owner_id=eq.${ownerId}`)
    const channel = supabase
      .channel(`realtime-${table}-${ownerId}-${Date.now()}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table, ...(filter ? { filter } : {}) },
        (payload) => {
          setData((prev) => (prev ? applyChange(prev, payload) : prev))
        }
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [table, ownerId, realtimeFilter, enabled, realtime])

  return { data, setData, loading, error, refresh }
}
