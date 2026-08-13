import { useRealtimeList } from './useRealtimeList'

export function useLookups() {
  const types = useRealtimeList({ table: 'property_types', order: 'name', realtimeFilter: null })
  const invoiceTypes = useRealtimeList({ table: 'invoice_types', order: 'name' })
  const invoiceStatuses = useRealtimeList({ table: 'invoice_statuses', order: 'name' })
  const paymentMethods = useRealtimeList({ table: 'payment_methods', order: 'name' })
  const numberingPatterns = useRealtimeList({ table: 'numbering_patterns', order: 'name' })
  const facilities = useRealtimeList({ table: 'facility_templates', order: 'name' })
  const rules = useRealtimeList({ table: 'rule_templates', order: 'title' })
  const charges = useRealtimeList({ table: 'charge_types', order: 'name' })
  const currencies = useRealtimeList({ table: 'currencies', order: 'name', realtimeFilter: null })
  const roomTypes = useRealtimeList({ table: 'unit_room_types', order: 'name', realtimeFilter: null })

  return {
    propertyTypes: types.data ?? [],
    invoiceTypes: invoiceTypes.data ?? [],
    invoiceStatuses: invoiceStatuses.data ?? [],
    paymentMethods: paymentMethods.data ?? [],
    numberingPatterns: numberingPatterns.data ?? [],
    facilities: facilities.data ?? [],
    rules: rules.data ?? [],
    charges: charges.data ?? [],
    currencies: currencies.data ?? [],
    roomTypes: roomTypes.data ?? [],
    loading: types.loading || invoiceTypes.loading,
  }
}
