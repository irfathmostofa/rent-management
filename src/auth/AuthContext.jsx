import { createContext, useContext, useEffect, useState } from 'react'
import { supabase, callRpc } from '../lib/supabase'
import { setActiveCurrency } from '../lib/format'

const AuthContext = createContext(null)

export function AuthProvider({ children }) {
  const [session, setSession] = useState(null)
  const [user, setUser] = useState(null)
  const [owner, setOwner] = useState(null)
  const [access, setAccess] = useState(null) // { has_access, access_state, ... }
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (!supabase) {
      setLoading(false)
      return
    }
    let mounted = true

    supabase.auth.getSession().then(({ data }) => {
      if (!mounted) return
      setSession(data.session)
      setUser(data.session?.user ?? null)
      setLoading(false)
    })

    const { data: sub } = supabase.auth.onAuthStateChange((_event, newSession) => {
      if (!mounted) return
      setSession(newSession)
      setUser(newSession?.user ?? null)
      setLoading(false)
    })

    return () => {
      mounted = false
      sub?.subscription?.unsubscribe()
    }
  }, [])

  useEffect(() => {
    if (!user) {
      setOwner(null)
      setAccess(null)
      return
    }
    let mounted = true

    const loadOwner = async () => {
      try {
        const [ownerRow, accessRow] = await Promise.all([
          callRpc('get_current_owner'),
          callRpc('get_access_status'),
        ])
        if (!mounted) return
        setActiveCurrency(accessRow?.currency)
        setOwner(ownerRow ?? null)
        setAccess(accessRow?.has_access !== undefined ? accessRow : null)
      } catch {
        if (!mounted) return
        setOwner(null)
        setAccess(null)
      }
    }
    loadOwner()

    return () => {
      mounted = false
    }
  }, [user])

  const signOut = async () => {
    await supabase?.auth.signOut()
  }

  return (
    <AuthContext.Provider
      value={{
        session,
        user,
        owner,
        access,
        isSuperAdmin: access?.access_state === 'super_admin',
        loading,
        signOut,
        refreshAccess: async () => {
          const accessRow = await callRpc('get_access_status')
          setActiveCurrency(accessRow?.currency)
          setAccess(accessRow ?? null)
        },
      }}
    >
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth() {
  return useContext(AuthContext)
}

export function useOwnerId() {
  const { owner } = useAuth()
  return owner?.id ?? null
}
