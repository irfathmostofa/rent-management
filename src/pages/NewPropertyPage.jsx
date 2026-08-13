import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { supabase, callRpc } from '../lib/supabase'
import { useLookups } from '../hooks/useLookups'
import { useUnitTemplates } from '../hooks/useProperties'
import Button from '../components/ui/Button'
import { Field, Input, Select } from '../components/ui/Input'
import { GenderSelect, FacilityPicker } from '../components/ui/FacilityPicker'
import Spinner from '../components/ui/Spinner'
import Icon from '../components/ui/Icon'
import { useToast } from '../components/ui/Toast'
import { money } from '../lib/format'
import { COUNTRIES } from '../lib/countries'

const KINDS = {
  apartment: { type: 'apartment' },
  cottage: { type: 'cottage' },
}

export default function NewPropertyPage() {
  const { t } = useTranslation()
  const { kind } = useParams()
  const meta = KINDS[kind] || KINDS.apartment
  const isCottage = meta.type === 'cottage'
  const noun = isCottage ? t('newProperty.room') : t('newProperty.unit')
  const nounPlural = isCottage ? t('newProperty.rooms') : t('newProperty.units')
  const metaTitle = isCottage ? t('newProperty.titleCottage') : t('newProperty.titleApartment')
  const metaSub = isCottage ? t('newProperty.subCottage') : t('newProperty.subApartment')
  const navigate = useNavigate()
  const lookups = useLookups()
  const templates = useUnitTemplates()
  const toast = useToast()
  const [saving, setSaving] = useState(false)

  const [form, setForm] = useState({
    name: '',
    address_line1: '',
    city: '',
    country: '',
    grace_days: 3,
    count: 1,
    pattern: 'Unit ',
    dimension: '',
    default_rent: '',
    deposit: '',
    template_id: '',
    rooms: {},
    seats_per_unit: 0,
    seat_rent: '',
    applicable_for: 'both',
    facilities: [],
  })

  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }))
  const setRoom = (key) => (e) =>
    setForm((f) => ({ ...f, rooms: { ...f.rooms, [key]: Number(e.target.value) || 0 } }))

  const roomTypes = (lookups.roomTypes ?? []).filter(
    (r) => !r.property_kind || r.property_kind === meta.type
  )

  const create = async (e) => {
    e.preventDefault()
    setSaving(true)
    try {
      const { data: prop, error } = await supabase
        .from('properties')
        .insert({
          name: form.name,
          property_type_id: meta.type,
          address_line1: form.address_line1,
          city: form.city,
          country: form.country,
          grace_days: Number(form.grace_days),
        })
        .select()
        .single()
      if (error) throw error

      await callRpc('audit_event', {
        p_action: 'property_created',
        p_entity_type: 'property',
        p_entity_id: prop.id,
        p_metadata: { name: form.name, kind: meta.type },
      }).catch(() => {})

      if (Number(form.count) > 0) {
        await callRpc('create_units_bulk', {
          p_property_id: prop.id,
          p_count: Number(form.count),
          p_pattern: form.pattern,
          p_template_id: form.template_id || null,
          p_dimension: form.dimension || null,
          p_default_rent: form.default_rent === '' ? null : Number(form.default_rent),
          p_deposit: form.deposit === '' ? null : Number(form.deposit),
          p_rooms: Object.keys(form.rooms).length ? form.rooms : null,
          p_seats_per_unit: isCottage ? Number(form.seats_per_unit) || 0 : 0,
          p_seat_rent: isCottage && form.seat_rent !== '' ? Number(form.seat_rent) : null,
          p_applicable_for: form.applicable_for,
          p_facilities: form.facilities.length ? form.facilities.map((n) => ({ name: n })) : null,
        })
      }

      toast.success(t('newProperty.created', { title: metaTitle }))
      navigate(`/admin/properties/${prop.id}`)
    } catch (err) {
      toast.error(err.message)
    } finally {
      setSaving(false)
    }
  }

  if (lookups.loading) return <Spinner />

  return (
    <div>
      <Link to="/admin/properties" className="btn btn-ghost btn-sm mb-2">
        <Icon name="arrowLeft" size={15} /> {t('newProperty.backToProperties')}
      </Link>

      <div className="page-head">
        <div>
          <h1 className="page-title">{metaTitle}</h1>
          <div className="page-sub">{metaSub}</div>
        </div>
      </div>

      <form onSubmit={create} className="card card-pad" style={{ maxWidth: 720 }}>
        <div className="form-grid">
          <Field label={t('newProperty.propertyName')}>
            <Input required value={form.name} onChange={set('name')} placeholder={t('newProperty.namePlaceholder')} />
          </Field>
          <Field label={t('newProperty.gracePeriod')}>
            <Input type="number" min={0} value={form.grace_days} onChange={set('grace_days')} />
          </Field>
        </div>
        <Field label={t('newProperty.addressLine1')}>
          <Input value={form.address_line1} onChange={set('address_line1')} />
        </Field>
        <div className="form-grid">
          <Field label={t('newProperty.city')}>
            <Input value={form.city} onChange={set('city')} />
          </Field>
          <Field label={t('newProperty.country')}>
            <Select value={form.country} onChange={set('country')} required>
              <option value="">{t('newProperty.selectCountry')}</option>
              {COUNTRIES.map((c) => (
                <option key={c.code} value={c.code}>
                  {c.name} ({c.code})
                </option>
              ))}
            </Select>
          </Field>
        </div>

        <hr className="divider" />
        <div className="bold small mb-2">{t('newProperty.firstUnits', { nounPlural })}</div>

        <div className="form-grid">
          <Field label={t('newProperty.numberOfUnits', { nounPlural })}>
            <Input type="number" min={1} max={500} value={form.count} onChange={set('count')} />
          </Field>
          <Field label={t('newProperty.numberingPattern')}>
            <Input value={form.pattern} onChange={set('pattern')} placeholder="Unit  / A- / Room {n}" />
          </Field>
        </div>
        <div className="form-grid-3">
          <Field label={t('newProperty.dimension')}>
            <Input value={form.dimension} onChange={set('dimension')} placeholder="e.g. 42 m²" />
          </Field>
          <Field label={t('newProperty.rentPer', { noun })}>
            <Input type="number" min={0} step="0.01" value={form.default_rent} onChange={set('default_rent')} />
          </Field>
          <Field label={t('newProperty.deposit')}>
            <Input type="number" min={0} step="0.01" value={form.deposit} onChange={set('deposit')} />
          </Field>
        </div>
        <Field label={t('newProperty.template')}>
          <Select value={form.template_id} onChange={set('template_id')}>
            <option value="">{t('newProperty.noTemplate')}</option>
            {(templates.data ?? []).map((t) => (
              <option key={t.id} value={t.id}>
                {t.name} · {money(t.default_rent)}/mo
              </option>
            ))}
          </Select>
        </Field>

        {!isCottage && roomTypes.length > 0 && (
          <>
            <hr className="divider" />
            <div className="bold small mb-2">{t('newProperty.roomsDescription')}</div>
            <p className="hint" style={{ marginTop: 0 }}>
              {t('newProperty.roomsHint')}
            </p>
            <div className="grid-2">
              {roomTypes.map((r) => (
                <Field key={r.key} label={`${r.name} (${t('newProperty.count')})`}>
                  <Input
                    type="number"
                    min={0}
                    value={form.rooms[r.key] ?? 0}
                    onChange={setRoom(r.key)}
                  />
                </Field>
              ))}
            </div>
          </>
        )}

        {isCottage && (
          <>
            <hr className="divider" />
            <div className="bold small mb-2">{t('newProperty.seatsPerRoom')}</div>
            <div className="form-grid">
              <Field label={t('newProperty.seatsPerRoom')}>
                <Input type="number" min={0} max={100} value={form.seats_per_unit} onChange={set('seats_per_unit')} />
              </Field>
              <Field label={t('newProperty.seatRent')}>
                <Input type="number" min={0} step="0.01" value={form.seat_rent} onChange={set('seat_rent')} placeholder="e.g. 150" />
              </Field>
            </div>
            <p className="hint" style={{ marginTop: 8 }}>
              {t('newProperty.seatsHint')}
            </p>
          </>
        )}

        <hr className="divider" />
        <div className="bold small mb-2">{t('newProperty.applicableFor')}</div>
        <p className="hint" style={{ marginTop: 0 }}>
          {t('newProperty.applicableHint')}
        </p>
        <div className="form-grid">
          <Field label={t('newProperty.gender')}>
            <GenderSelect value={form.applicable_for} onChange={(v) => setForm((f) => ({ ...f, applicable_for: v }))} t={t} />
          </Field>
        </div>
        <Field label={t('newProperty.facilities')} hint={t('newProperty.facilitiesHint')}>
          <FacilityPicker
            t={t}
            facilities={lookups.facilities ?? []}
            selected={form.facilities}
            onChange={(names) => setForm((f) => ({ ...f, facilities: names }))}
          />
        </Field>

        <div className="modal-actions" style={{ marginTop: 14 }}>
          <Link to="/admin/properties" className="btn btn-secondary">
            {t('common.cancel')}
          </Link>
          <Button type="submit" disabled={saving}>
            {saving ? t('newProperty.creating') : t('newProperty.createAction', { type: meta.type })}
          </Button>
        </div>
      </form>
    </div>
  )
}
