import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { supabase } from '../lib/supabase'
import { useAuth, useOwnerId } from '../auth/AuthContext'
import { useOwnerSettings } from '../hooks/useSettings'
import { useUnitTemplates } from '../hooks/useProperties'
import { useLookups } from '../hooks/useLookups'
import Button from '../components/ui/Button'
import { Field, Input, Select } from '../components/ui/Input'
import Modal from '../components/ui/Modal'
import Spinner from '../components/ui/Spinner'
import EmptyState from '../components/ui/EmptyState'
import Icon from '../components/ui/Icon'
import LanguageSwitcher from '../components/layout/LanguageSwitcher'
import { useToast } from '../components/ui/Toast'
import { money, setActiveCurrency, useActiveCurrency } from '../lib/format'

export default function SettingsPage() {
  const { t } = useTranslation()
  const { owner } = useAuth()
  const ownerId = useOwnerId()
  const settings = useOwnerSettings()
  const templates = useUnitTemplates()
  const lookups = useLookups()
  const toast = useToast()
  const activeCurrency = useActiveCurrency()

  const [profile, setProfile] = useState(null)
  const [prefForm, setPrefForm] = useState(null)
  const [msgForm, setMsgForm] = useState(null)
  const [tplOpen, setTplOpen] = useState(false)
  const [saving, setSaving] = useState(false)

  const s = settings.settings

  const saveProfile = async (e) => {
    e.preventDefault()
    setSaving(true)
    try {
      const { error } = await supabase.from('owners').update(profile).eq('id', ownerId)
      if (error) throw error
      toast.success(t('settings.accountUpdated'))
    } catch (err) {
      toast.error(err.message)
    } finally {
      setSaving(false)
    }
  }

  const savePrefs = async (e) => {
    e.preventDefault()
    setSaving(true)
    try {
      const { error } = await supabase.from('owner_settings').update(prefForm).eq('owner_id', ownerId)
      if (error) throw error
      setActiveCurrency(prefForm.currency)
      toast.success(t('settings.prefsSaved'))
    } catch (err) {
      toast.error(err.message)
    } finally {
      setSaving(false)
    }
  }

  if (!owner || !s) return <Spinner />

  return (
    <div>
      <div className="page-head">
        <div>
          <h1 className="page-title">{t('settings.title')}</h1>
          <div className="page-sub">{t('settings.subtitle')}</div>
        </div>
      </div>

      <div className="grid-2">
        <div className="card">
          <div className="card-header">
            <div className="card-title">{t('settings.account')}</div>
          </div>
          <div className="card-pad">
            {profile === null && (
              <div>
                <p className="bold">{owner.business_name}</p>
                <p className="small muted">
                  {owner.property_kind} · {owner.contact_email}
                </p>
                <Button variant="secondary" size="sm" onClick={() => setProfile({ ...owner })}>
                  {t('settings.edit')}
                </Button>
              </div>
            )}
            {profile && (
              <form onSubmit={saveProfile}>
                <Field label={t('settings.businessName')}>
                  <Input value={profile.business_name} onChange={(e) => setProfile({ ...profile, business_name: e.target.value })} required />
                </Field>
                <Field label={t('settings.contactEmail')}>
                  <Input value={profile.contact_email} onChange={(e) => setProfile({ ...profile, contact_email: e.target.value })} />
                </Field>
                <Field label={t('settings.manageWhat')}>
                  <Select value={profile.property_kind} onChange={(e) => setProfile({ ...profile, property_kind: e.target.value })}>
                    <option value="apartment">{t('settings.apartments')}</option>
                    <option value="cottage">{t('settings.cottages')}</option>
                    <option value="both">{t('settings.both')}</option>
                  </Select>
                </Field>
                <div className="modal-actions" style={{ marginTop: 8 }}>
                  <Button type="button" variant="secondary" onClick={() => setProfile(null)}>{t('common.cancel')}</Button>
                  <Button type="submit" disabled={saving}>{t('common.save')}</Button>
                </div>
              </form>
            )}
          </div>
        </div>

        <div className="card">
          <div className="card-header">
            <div className="card-title">{t('settings.language')}</div>
          </div>
          <div className="card-pad">
            <div className="row-between">
              <span className="small muted">{t('settings.languageHint')}</span>
              <LanguageSwitcher />
            </div>
          </div>
        </div>

        <div className="card">
          <div className="card-header">
            <div className="card-title">{t('settings.billingPrefs')}</div>
          </div>
          <div className="card-pad">
            {prefForm === null && (
              <div>
                <p className="small">
                  {t('settings.currency')}: <b>{s.currency || 'EUR'}</b>
                  <br />
                  {t('settings.gracePeriod')}: <b>{s.default_grace_days} {t('settings.days')}</b>
                  <br />
                  {t('settings.fineStacking')}: <b>{s.fine_stacking_allowed ? t('settings.allowed') : t('settings.disabled')}</b>
                  <br />
                  {t('settings.annualIncrease')}: <b>{s.rent_increase_enabled ? `${t('settings.on')}${s.rent_increase_amount ? ` (+${money(s.rent_increase_amount)})` : ''}${s.rent_increase_percent ? ` (+${s.rent_increase_percent}%)` : ''}` : t('settings.off')}</b>
                </p>
                <Button variant="secondary" size="sm" onClick={() => setPrefForm({ ...s })}>
                  {t('settings.edit')}
                </Button>
                <Link to="/admin/settings/currencies" className="btn btn-ghost btn-sm">
                  {t('settings.manageCurrencies')}
                </Link>
              </div>
            )}
            {prefForm && (
              <form onSubmit={savePrefs}>
                <Field label={t('settings.currency')} hint={t('settings.currencyHint')}>
                  <Select value={prefForm.currency ?? 'EUR'} onChange={(e) => setPrefForm({ ...prefForm, currency: e.target.value })}>
                    {(lookups.currencies ?? []).map((c) => (
                      <option key={c.key} value={c.key}>
                        {c.symbol} · {c.name} ({c.key})
                      </option>
                    ))}
                  </Select>
                </Field>
                <Field label={t('settings.graceDays')}>
                  <Input type="number" min={0} value={prefForm.default_grace_days} onChange={(e) => setPrefForm({ ...prefForm, default_grace_days: e.target.value })} />
                </Field>
                <label className="row" style={{ gap: 8, marginBottom: 12 }}>
                  <input type="checkbox" checked={prefForm.fine_stacking_allowed} onChange={(e) => setPrefForm({ ...prefForm, fine_stacking_allowed: e.target.checked })} />
                  <span className="small">{t('settings.allowMultipleFines')}</span>
                </label>
                <label className="row" style={{ gap: 8, marginBottom: 12 }}>
                  <input type="checkbox" checked={prefForm.rent_increase_enabled} onChange={(e) => setPrefForm({ ...prefForm, rent_increase_enabled: e.target.checked })} />
                  <span className="small">{t('settings.enableAnnualIncrease')}</span>
                </label>
                <div className="form-grid">
                  <Field label={`${t('settings.fixedIncrease')} (${activeCurrency})`}>
                    <Input type="number" min={0} step="0.01" value={prefForm.rent_increase_amount ?? ''} onChange={(e) => setPrefForm({ ...prefForm, rent_increase_amount: e.target.value === '' ? null : Number(e.target.value) })} />
                  </Field>
                  <Field label={t('settings.percentIncrease')}>
                    <Input type="number" min={0} step="0.1" value={prefForm.rent_increase_percent ?? ''} onChange={(e) => setPrefForm({ ...prefForm, rent_increase_percent: e.target.value === '' ? null : Number(e.target.value) })} />
                  </Field>
                </div>
                <div className="modal-actions" style={{ marginTop: 8 }}>
                  <Button type="button" variant="secondary" onClick={() => setPrefForm(null)}>{t('common.cancel')}</Button>
                  <Button type="submit" disabled={saving}>{t('common.save')}</Button>
                </div>
              </form>
            )}
          </div>
        </div>
      </div>

      <div className="card mt-3">
        <div className="card-header">
          <div className="card-title">{t('settings.messagingChannels')}</div>
        </div>
        <div className="card-pad">
          {msgForm === null ? (
            <div>
              <p className="small">
                {t('settings.tenantFacing')}: <b>{JSON.stringify(s.tenant_messaging_channels)}</b>
                <br />
                {t('settings.ownerNotifications')}: <b>{JSON.stringify(s.owner_notification_channels)}</b>
                <br />
                {t('settings.provider')}: <b>{s.message_provider}</b>
              </p>
              <Button variant="secondary" size="sm" onClick={() => setMsgForm({ ...s })}>
                {t('settings.edit')}
              </Button>
            </div>
          ) : (
            <form
              onSubmit={async (e) => {
                e.preventDefault()
                setSaving(true)
                try {
                  const { error } = await supabase
                    .from('owner_settings')
                    .update({ tenant_messaging_channels: msgForm.tenant_messaging_channels, owner_notification_channels: msgForm.owner_notification_channels, message_provider: msgForm.message_provider })
                    .eq('owner_id', ownerId)
                  if (error) throw error
                  toast.success(t('settings.messagingSaved'))
                  setMsgForm(null)
                } catch (err) {
                  toast.error(err.message)
                } finally {
                  setSaving(false)
                }
              }}
            >
              <Field label={t('settings.tenantChannels')}>
                <MultiChannelPicker
                  value={msgForm.tenant_messaging_channels}
                  onChange={(v) => setMsgForm({ ...msgForm, tenant_messaging_channels: v })}
                  options={['whatsapp', 'sms', 'email']}
                />
              </Field>
              <Field label={t('settings.ownerChannels')}>
                <MultiChannelPicker
                  value={msgForm.owner_notification_channels}
                  onChange={(v) => setMsgForm({ ...msgForm, owner_notification_channels: v })}
                  options={['email', 'in_app']}
                />
              </Field>
              <Field label={t('settings.providerAdapter')} hint={t('settings.providerHint')}>
                <Select value={msgForm.message_provider} onChange={(e) => setMsgForm({ ...msgForm, message_provider: e.target.value })}>
                  <option value="none">{t('settings.simulated')}</option>
                  <option value="bulksmsbd">{t('settings.bulksmsbd')}</option>
                  <option value="twilio">{t('settings.twilio')}</option>
                  <option value="whatsapp_business">{t('settings.whatsappBusiness')}</option>
                  <option value="resend">{t('settings.resend')}</option>
                </Select>
              </Field>
              <div className="modal-actions" style={{ marginTop: 8 }}>
                <Button type="button" variant="secondary" onClick={() => setMsgForm(null)}>{t('common.cancel')}</Button>
                <Button type="submit" disabled={saving}>{t('common.save')}</Button>
              </div>
            </form>
          )}
        </div>
      </div>

      <div className="card mt-3">
        <div className="card-header">
          <div className="card-title">{t('settings.unitTemplates')}</div>
          <Button variant="secondary" size="sm" onClick={() => setTplOpen(true)}>
            <Icon name="plus" size={14} /> {t('settings.newTemplate')}
          </Button>
        </div>
        {(templates.data ?? []).length === 0 ? (
          <EmptyState icon="fileText" title={t('settings.noTemplates')} body={t('settings.noTemplatesBody')} />
        ) : (
          (templates.data ?? []).map((tpl) => (
            <div key={tpl.id} className="row-between" style={{ padding: '12px 20px', borderBottom: '1px solid var(--border)' }}>
              <div>
                <div className="bold small">{tpl.name}</div>
                <div className="small muted">
                  {money(tpl.default_rent)}/mo · {t('settings.deposit')} {money(tpl.deposit_amount)} · {tpl.dimension || t('settings.noDimension')}
                  {tpl.charges?.length ? ` · ${tpl.charges.length} ${t('settings.charges')}` : ''}
                </div>
              </div>
              <span className="tiny muted">{t('settings.snapshotsOnUse')}</span>
            </div>
          ))
        )}
      </div>

      <TemplateModal open={tplOpen} onClose={() => setTplOpen(false)} lookups={lookups} toast={toast} t={t} />
    </div>
  )
}

function MultiChannelPicker({ value, onChange, options }) {
  const toggle = (opt) => {
    if (value.includes(opt)) onChange(value.filter((x) => x !== opt))
    else onChange([...value, opt])
  }
  return (
    <div className="row" style={{ flexWrap: 'wrap', gap: 8 }}>
      {options.map((opt) => (
        <label key={opt} className="row" style={{ gap: 6, background: 'var(--surface-2)', border: '1px solid var(--border)', borderRadius: 8, padding: '6px 10px' }}>
          <input type="checkbox" checked={value.includes(opt)} onChange={() => toggle(opt)} />
          <span className="small">{opt}</span>
        </label>
      ))}
    </div>
  )
}

function CheckboxPicker({ options, selected, onChange, t }) {
  const toggle = (key) => {
    if (selected.includes(key)) onChange(selected.filter((x) => x !== key))
    else onChange([...selected, key])
  }
  return (
    <div style={{ maxHeight: 160, overflowY: 'auto', border: '1px solid var(--border)', borderRadius: 10 }}>
      {options.map((o) => (
        <label key={o.key} className="row" style={{ padding: '8px 12px', gap: 10, borderBottom: '1px solid var(--border)' }}>
          <input type="checkbox" checked={selected.includes(o.key)} onChange={() => toggle(o.key)} />
          <span className="small">{o.label}</span>
        </label>
      ))}
      {options.length === 0 && <div className="hint" style={{ padding: 10 }}>{t('settings.noOptionsYet')}</div>}
    </div>
  )
}

function TemplateModal({ open, onClose, lookups, toast, t }) {
  const [saving, setSaving] = useState(false)
  const [form, setForm] = useState({
    name: '',
    property_type_id: 'cottage',
    dimension: '',
    deposit_amount: 0,
    default_rent: 0,
    facilities: [],
    rules: [],
    charges: [],
    rooms: {},
  })

  const roomTypes = (lookups.roomTypes ?? []).filter(
    (r) => !r.property_kind || r.property_kind === form.property_type_id
  )

  const setRoom = (key) => (e) =>
    setForm((f) => ({ ...f, rooms: { ...f.rooms, [key]: Number(e.target.value) || 0 } }))

  const submit = async (e) => {
    e.preventDefault()
    setSaving(true)
    try {
      const { error } = await supabase.from('unit_templates').insert({
        name: form.name,
        property_type_id: form.property_type_id || null,
        dimension: form.dimension,
        deposit_amount: Number(form.deposit_amount),
        default_rent: Number(form.default_rent),
        facilities: form.facilities,
        rules: form.rules,
        charges: form.charges,
        rooms: form.rooms,
      })
      if (error) throw error
      toast.success(t('settings.templateCreated'))
      onClose()
    } catch (err) {
      toast.error(err.message)
    } finally {
      setSaving(false)
    }
  }

  return (
    <Modal open={open} onClose={onClose} title={t('settings.newUnitTemplate')}>
      <form onSubmit={submit}>
        <Field label={t('settings.templateName')}>
          <Input required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="e.g. Standard cottage room" />
        </Field>
        <div className="form-grid">
          <Field label={t('settings.for')}>
            <Select value={form.property_type_id} onChange={(e) => setForm({ ...form, property_type_id: e.target.value })}>
              {(lookups.propertyTypes ?? []).map((pt) => (
                <option key={pt.key} value={pt.key}>{pt.name}</option>
              ))}
            </Select>
          </Field>
          <Field label={t('settings.dimension')}>
            <Input value={form.dimension} onChange={(e) => setForm({ ...form, dimension: e.target.value })} placeholder="e.g. 42 m²" />
          </Field>
        </div>
        <div className="form-grid">
          <Field label={t('settings.defaultRent')}>
            <Input type="number" min={0} step="0.01" value={form.default_rent} onChange={(e) => setForm({ ...form, default_rent: e.target.value })} />
          </Field>
          <Field label={t('settings.deposit')}>
            <Input type="number" min={0} step="0.01" value={form.deposit_amount} onChange={(e) => setForm({ ...form, deposit_amount: e.target.value })} />
          </Field>
        </div>
        {roomTypes.length > 0 && (
          <div className="mb-2">
            <div className="bold small mb-2">{t('settings.roomsDescription')}</div>
            <div className="grid-2">
              {roomTypes.map((r) => (
                <Field key={r.key} label={`${r.name} (${t('settings.count')})`}>
                  <Input type="number" min={0} value={form.rooms[r.key] ?? 0} onChange={setRoom(r.key)} />
                </Field>
              ))}
            </div>
          </div>
        )}
        <Field label={t('settings.facilities')}>
          <CheckboxPicker
            t={t}
            options={(lookups.facilities ?? []).map((f) => ({ key: f.name, label: f.name }))}
            selected={form.facilities.map((f) => f.name)}
            onChange={(names) =>
              setForm({
                ...form,
                facilities: names.map((n) => ({ name: n })),
              })
            }
          />
        </Field>
        <Field label={t('settings.rules')}>
          <CheckboxPicker
            t={t}
            options={(lookups.rules ?? []).map((r) => ({ key: r.title, label: r.title }))}
            selected={form.rules.map((r) => r.title)}
            onChange={(titles) =>
              setForm({
                ...form,
                rules: titles.map((title) => ({ title })),
              })
            }
          />
        </Field>
        <div className="modal-actions">
          <Button type="button" variant="secondary" onClick={onClose}>{t('common.cancel')}</Button>
          <Button type="submit" disabled={saving}>{saving ? t('settings.saving') : t('settings.createTemplate')}</Button>
        </div>
      </form>
    </Modal>
  )
}
