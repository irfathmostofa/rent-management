import { NavLink } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import Icon from '../ui/Icon'
import { navItems } from './navItems'
import LanguageSwitcher from './LanguageSwitcher'
import { useAuth } from '../../auth/AuthContext'

export default function Sidebar() {
  const { t } = useTranslation()
  const { owner, access, signOut } = useAuth()
  const isAdmin = access?.access_state === 'super_admin'

  return (
    <aside className="sidebar">
      <div className="sidebar-logo">
        <div className="logo-mark">R</div>
        <div className="logo-text">Rently</div>
      </div>

      <nav className="sidebar-nav">
        {navItems.map((item) => (
          <NavLink
            key={item.path}
            to={item.path}
            end={item.path === '/admin'}
            className={({ isActive }) => `side-link${isActive ? ' active' : ''}`}
          >
            <span className="ico">
              <Icon name={item.icon} size={17} />
            </span>
            {t(item.labelKey)}
          </NavLink>
        ))}

        {isAdmin && (
          <NavLink to="/admin/super" className={({ isActive }) => `side-link${isActive ? ' active' : ''}`}>
            <span className="ico">
              <Icon name="shield" size={17} />
            </span>
            {t('nav.superAdmin')}
          </NavLink>
        )}

        <NavLink to="/admin/billing" className={({ isActive }) => `side-link${isActive ? ' active' : ''}`}>
          <span className="ico">
            <Icon name="key" size={17} />
          </span>
          {t('nav.billing')}
        </NavLink>
      </nav>

      <div className="sidebar-lang">
        <LanguageSwitcher />
      </div>

      <div className="sidebar-footer">
        <div className="side-user">
          <div className="avatar">{owner?.business_name?.[0]?.toUpperCase() || 'O'}</div>
          <div className="meta">
            <div className="name">{owner?.business_name || t('sidebar.account')}</div>
            <div className="plan">{access?.access_state || '—'}</div>
          </div>
          <button
            className="btn btn-ghost btn-icon side-logout"
            onClick={signOut}
            title={t('sidebar.signOut')}
          >
            <Icon name="logout" size={17} />
          </button>
        </div>
      </div>
    </aside>
  )
}
