import { useAuth } from '../auth/AuthContext'
import { useTranslation } from 'react-i18next'
import { useBillingEvents } from '../hooks/useSettings'
import Button from '../components/ui/Button'
import Badge from '../components/ui/Badge'
import Spinner from '../components/ui/Spinner'
import EmptyState from '../components/ui/EmptyState'
import { money, formatDate, formatDateTime } from '../lib/format'

export default function BillingPage() {
  const { t } = useTranslation()
  const { owner, access, refreshAccess } = useAuth()
  const billing = useBillingEvents()

  if (!access || !owner) return <Spinner />

  const { has_access, access_state, trial_ends_at, current_period_end, monthly_amount } = access

  if (!has_access) {
    return (
      <div className="paywall">
        <div className="paywall-card">
          <div className="logo-mark" style={{ width: 46, height: 46, borderRadius: 12, background: 'linear-gradient(135deg,#6366f1,#8b5cf6)', display: 'inline-grid', placeItems: 'center', color: '#fff', fontWeight: 800, fontSize: 20 }}>
            R
          </div>
          <h1 className="mt-2">{t('billing.trialEnded')}</h1>
          <p className="muted small">
            {t('billing.trialEndedBody', { name: owner.business_name })}
          </p>
          <div className="price">
            {money(monthly_amount || 19)}
            <small>{t('billing.perMonth')}</small>
          </div>
          <ul style={{ textAlign: 'left', fontSize: 13, lineHeight: 1.9, color: 'var(--muted)', paddingLeft: 18 }}>
            <li>{t('billing.feature1')}</li>
            <li>{t('billing.feature2')}</li>
            <li>{t('billing.feature3')}</li>
          </ul>
          <Button size="lg" block onClick={async () => { await refreshAccess(); }}>
            {t('billing.contactBilling')}
          </Button>
          <p className="tiny muted" style={{ marginTop: 10 }}>
            {t('billing.paymentsNote')}
          </p>
        </div>
      </div>
    )
  }

  return (
    <div>
      <div className="page-head">
        <div>
          <h1 className="page-title">{t('billing.title')}</h1>
          <div className="page-sub">{t('billing.subtitle')}</div>
        </div>
      </div>

      <div className="stats-grid mb-3">
        <div className="stat">
          <div className="stat-label">{t('billing.plan')}</div>
          <div className="stat-value" style={{ fontSize: 20, paddingTop: 6 }}>
            <Badge value={access_state} />
          </div>
        </div>
        <div className="stat">
          <div className="stat-label">{t('billing.trialEnds')}</div>
          <div className="stat-value" style={{ fontSize: 20, paddingTop: 6 }}>
            {formatDate(trial_ends_at)}
          </div>
        </div>
        <div className="stat">
          <div className="stat-label">{t('billing.currentPeriodEnds')}</div>
          <div className="stat-value" style={{ fontSize: 20, paddingTop: 6 }}>
            {formatDate(current_period_end)}
          </div>
        </div>
        <div className="stat">
          <div className="stat-label">{t('billing.monthlyPrice')}</div>
          <div className="stat-value" style={{ fontSize: 20, paddingTop: 6 }}>
            {money(monthly_amount || 19)}
          </div>
        </div>
      </div>

      <div className="card">
        <div className="card-header">
          <div className="card-title">{t('billing.history')}</div>
        </div>
        {(billing.data ?? []).length === 0 ? (
          <EmptyState icon="key" title={t('billing.emptyTitle')} body={t('billing.emptyBody')} />
        ) : (
          <div className="table-wrap desktop-table">
            <table className="table">
              <thead>
                <tr>
                  <th>{t('billing.colWhen')}</th>
                  <th>{t('billing.colEvent')}</th>
                  <th>{t('billing.colAmount')}</th>
                  <th>{t('billing.colDetails')}</th>
                </tr>
              </thead>
              <tbody>
                {(billing.data ?? []).map((b) => (
                  <tr key={b.id}>
                    <td className="small muted">{formatDateTime(b.occurred_at)}</td>
                    <td>
                      <Badge value={b.event_type} tone={b.event_type === 'payment_received' || b.event_type === 'plan_activated' || b.event_type === 'period_renewed' ? 'green' : b.event_type.includes('fail') || b.event_type.includes('expired') || b.event_type.includes('revoked') ? 'red' : 'blue'}>
                        {b.event_type.replace(/_/g, ' ')}
                      </Badge>
                    </td>
                    <td className="mono">{b.amount ? money(b.amount) : '—'}</td>
                    <td className="small muted">{JSON.stringify(b.meta)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  )
}
