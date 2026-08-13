import { useLocation, Outlet } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import Sidebar from './Sidebar'
import BottomNav from './BottomNav'
import TopBar from './TopBar'

const titles = {
  '/admin': 'app.dashboard',
  '/admin/properties': 'app.properties',
  '/admin/tenants': 'app.tenants',
  '/admin/invoices': 'app.invoices',
  '/admin/ledger': 'app.ledger',
  '/admin/messaging': 'app.messaging',
  '/admin/reports': 'app.reports',
  '/admin/settings': 'app.settings',
  '/admin/settings/currencies': 'app.currencies',
  '/admin/billing': 'app.billing',
  '/admin/super': 'app.admin',
}

export default function AppShell() {
  const { t } = useTranslation()
  const { pathname } = useLocation()
  const titleKey = titles[pathname]
  const title = titleKey ? t(titleKey) : 'Rently'

  return (
    <div className="app">
      <Sidebar />
      <main className="main">
        <TopBar title={title} />
        <Outlet />
      </main>
      <BottomNav />
    </div>
  )
}
