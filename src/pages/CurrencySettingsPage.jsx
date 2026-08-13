import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { supabase } from '../lib/supabase'
import { useOwnerId } from '../auth/AuthContext'
import { useLookups } from '../hooks/useLookups'
import { useOwnerSettings } from '../hooks/useSettings'
import Button from '../components/ui/Button'
import { Field, Input } from '../components/ui/Input'
import Spinner from '../components/ui/Spinner'
import EmptyState from '../components/ui/EmptyState'
import Icon from '../components/ui/Icon'
import { useToast } from '../components/ui/Toast'
import { setActiveCurrency, useActiveCurrency } from '../lib/format'

export default function CurrencySettingsPage() {
  const { t } = useTranslation()
  const ownerId = useOwnerId()
  const lookups = useLookups()
  const settings = useOwnerSettings()
  const toast = useToast()
  const activeCurrency = useActiveCurrency()

  const [showForm, setShowForm] = useState(false)
  const [form, setForm] = useState({ key: '', name: '', symbol: '' })
  const [saving, setSaving] = useState(false)

  const currencies = lookups.currencies ?? []
  const systemCurrencies = currencies.filter((c) => !c.owner_id)
  const ownCurrencies = currencies.filter((c) => c.owner_id === ownerId)

  const addCurrency = async (e) => {
    e.preventDefault()
    setSaving(true)
    try {
      const key = form.key.trim().toUpperCase()
      const { error } = await supabase.from('currencies').insert({
        owner_id: ownerId,
        key,
        name: form.name.trim() || key,
        symbol: form.symbol.trim() || key,
      })
      if (error) throw error
      toast.success(t('currency.toastAdded'))
      setForm({ key: '', name: '', symbol: '' })
      setShowForm(false)
    } catch (err) {
      toast.error(err.message)
    } finally {
      setSaving(false)
    }
  }

  const setDefault = async (key) => {
    setSaving(true)
    try {
      const { error } = await supabase.from('owner_settings').update({ currency: key }).eq('owner_id', ownerId)
      if (error) throw error
      setActiveCurrency(key)
      toast.success(t('currency.toastDefault', { key }))
    } catch (err) {
      toast.error(err.message)
    } finally {
      setSaving(false)
    }
  }

  const removeCurrency = async (id) => {
    if (!window.confirm(t('currency.confirmRemove'))) return
    setSaving(true)
    try {
      const { error } = await supabase.from('currencies').delete().eq('id', id).eq('owner_id', ownerId)
      if (error) throw error
      toast.success(t('currency.toastRemoved'))
    } catch (err) {
      toast.error(err.message)
    } finally {
      setSaving(false)
    }
  }

  const CurrencyRow = ({ c, isOwn }) => {
    const isActive = c.key === activeCurrency
    return (
      <div className="row-between" style={{ padding: '12px 20px', borderBottom: '1px solid var(--border)' }}>
        <div className="row" style={{ gap: 12 }}>
          <span className="mono bold" style={{ minWidth: 48 }}>{c.symbol}</span>
          <div>
            <div className="bold small">
              {c.name} <span className="muted">({c.key})</span>
              {isActive && <span className="badge badge-green" style={{ marginLeft: 8 }}>{t('currency.default')}</span>}
            </div>
            <div className="small muted">{isOwn ? t('currency.yourCustom') : t('currency.system')}</div>
          </div>
        </div>
        <div className="row" style={{ gap: 8 }}>
          {!isActive && (
            <Button variant="secondary" size="sm" onClick={() => setDefault(c.key)} disabled={saving}>
              {t('currency.setDefault')}
            </Button>
          )}
          {isOwn && (
            <Button variant="ghost" size="sm" onClick={() => removeCurrency(c.id)} disabled={saving}>
              <Icon name="trash" size={14} />
            </Button>
          )}
        </div>
      </div>
    )
  }

  return (
    <div>
      <Link to="/admin/settings" className="btn btn-ghost btn-sm mb-2">
        <Icon name="arrowLeft" size={15} /> {t('currency.backToSettings')}
      </Link>

      <div className="page-head">
        <div>
          <h1 className="page-title">{t('currency.title')}</h1>
          <div className="page-sub">
            {t('currency.subtitle')}
          </div>
        </div>
        <Button onClick={() => setShowForm((v) => !v)}>
          <Icon name="plus" size={14} /> {t('currency.add')}
        </Button>
      </div>

      {showForm && (
        <form onSubmit={addCurrency} className="card card-pad mb-3" style={{ maxWidth: 720 }}>
          <div className="bold small mb-2">{t('currency.newCurrency')}</div>
          <div className="form-grid-3">
            <Field label={t('currency.code')}>
              <Input
                required
                maxLength={8}
                placeholder="e.g. INR"
                value={form.key}
                onChange={(e) => setForm({ ...form, key: e.target.value })}
              />
            </Field>
            <Field label={t('currency.name')}>
              <Input
                placeholder="e.g. Indian Rupee"
                value={form.name}
                onChange={(e) => setForm({ ...form, name: e.target.value })}
              />
            </Field>
            <Field label={t('currency.symbol')}>
              <Input
                placeholder="e.g. ₹"
                value={form.symbol}
                onChange={(e) => setForm({ ...form, symbol: e.target.value })}
              />
            </Field>
          </div>
          <div className="modal-actions" style={{ marginTop: 8 }}>
            <Button type="button" variant="secondary" onClick={() => setShowForm(false)}>{t('common.cancel')}</Button>
            <Button type="submit" disabled={saving}>{t('currency.add')}</Button>
          </div>
        </form>
      )}

      {settings.loading ? (
        <Spinner />
      ) : (
        <div className="card">
          <div className="card-header">
            <div className="card-title">{t('currency.available')}</div>
            <span className="tiny muted">{currencies.length} {t('currency.total')}</span>
          </div>
          {currencies.length === 0 ? (
            <EmptyState icon="wallet" title={t('currency.noCurrencies')} body={t('currency.noCurrenciesBody')} />
          ) : (
            <div>
              {systemCurrencies.map((c) => (
                <CurrencyRow key={c.id} c={c} isOwn={false} />
              ))}
              {ownCurrencies.map((c) => (
                <CurrencyRow key={c.id} c={c} isOwn />
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  )
}
