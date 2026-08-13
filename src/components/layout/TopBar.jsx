import Icon from '../ui/Icon'
import { useAuth } from '../../auth/AuthContext'
import { useNotifications } from '../../hooks/useMessaging'
import { useNavigate } from 'react-router-dom'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabase } from '../../lib/supabase'
import LanguageSwitcher from './LanguageSwitcher'

export default function TopBar({ title }) {
  const { t } = useTranslation()
  const { user } = useAuth()
  const { data: notifications } = useNotifications()
  const [open, setOpen] = useState(false)
  const navigate = useNavigate()

  const unread = (notifications ?? []).filter((n) => !n.read_at).length

  const markRead = async (n) => {
    await supabase.from('notifications').update({ read_at: new Date().toISOString() }).eq('id', n.id)
    if (n.link) navigate(n.link)
  }

  return (
    <header className="topbar">
      <div className="title">{title}</div>
      <div className="row">
        <LanguageSwitcher compact />
        <div className="notif-wrap" style={{ position: 'relative' }}>
          <button className="btn btn-secondary btn-icon" onClick={() => setOpen((o) => !o)}>
            <Icon name="bell" size={17} />
            {unread > 0 && (
              <span
                style={{
                  position: 'absolute',
                  top: 2,
                  right: 2,
                  background: 'var(--danger)',
                  color: '#fff',
                  borderRadius: 999,
                  fontSize: 10,
                  minWidth: 15,
                  height: 15,
                  display: 'grid',
                  placeItems: 'center',
                  padding: '0 3px',
                }}
              >
                {unread}
              </span>
            )}
          </button>
          {open && (
            <div
              className="card"
              style={{
                position: 'absolute',
                right: 0,
                top: 46,
                width: 320,
                maxHeight: 360,
                overflowY: 'auto',
                zIndex: 50,
                boxShadow: 'var(--shadow-lg)',
              }}
            >
              {(notifications ?? []).length === 0 ? (
                <div className="empty">
                  <div className="small">{t('topbar.noNotifications')}</div>
                </div>
              ) : (
                (notifications ?? []).slice(0, 30).map((n) => (
                  <button
                    key={n.id}
                    onClick={() => markRead(n)}
                    style={{
                      display: 'block',
                      width: '100%',
                      textAlign: 'left',
                      padding: '10px 14px',
                      border: 'none',
                      borderBottom: '1px solid var(--border)',
                      background: n.read_at ? 'transparent' : 'var(--primary-soft)',
                      cursor: 'pointer',
                    }}
                  >
                    <div style={{ fontWeight: 600, fontSize: 14 }}>{n.title}</div>
                    <div className="small muted" style={{ fontSize: 13 }}>
                      {n.body}
                    </div>
                  </button>
                ))
              )}
            </div>
          )}
        </div>
        <div className="avatar" style={{ width: 34, height: 34, fontSize: 13 }}>
          {user?.email?.[0]?.toUpperCase() || 'U'}
        </div>
      </div>
    </header>
  )
}
