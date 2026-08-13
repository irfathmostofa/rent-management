import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const anon = import.meta.env.VITE_SUPABASE_ANON_KEY

export const isConfigured = Boolean(
  url && anon && !url.includes('YOUR_PROJECT_REF') && !anon.includes('YOUR_ANON_KEY')
)

export const supabase = isConfigured
  ? createClient(url, anon, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
      realtime: { params: { eventsPerSecond: 20 } },
    })
  : null

// Run business-logic functions against the DB.
export async function callRpc(fn, args = {}) {
  if (!supabase) throw new Error('Supabase is not configured')
  const { data, error } = await supabase.rpc(fn, args)
  if (error) throw error
  return data
}
