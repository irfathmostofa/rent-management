import { useRealtimeList } from './useRealtimeList'

const REPORT_OPTS = { realtime: false }

export function useReports() {
  const monthlyCollection = useRealtimeList({
    table: 'monthly_collection_summary',
    select: '*',
    order: 'month',
    orderAsc: false,
    realtimeFilter: null,
    ...REPORT_OPTS,
  })
  const occupancy = useRealtimeList({
    table: 'occupancy_report',
    select: '*',
    realtimeFilter: null,
    ...REPORT_OPTS,
  })
  const seatOccupancy = useRealtimeList({
    table: 'seat_occupancy_report',
    select: '*',
    realtimeFilter: null,
    ...REPORT_OPTS,
  })
  const overdue = useRealtimeList({
    table: 'overdue_aging',
    select: '*',
    order: 'days_overdue',
    orderAsc: false,
    realtimeFilter: null,
    ...REPORT_OPTS,
  })
  const overdueSummary = useRealtimeList({
    table: 'overdue_summary',
    select: '*',
    realtimeFilter: null,
    ...REPORT_OPTS,
  })
  const yearEnd = useRealtimeList({
    table: 'year_end_statement',
    select: '*',
    realtimeFilter: null,
    ...REPORT_OPTS,
  })
  const incomeExpense = useRealtimeList({
    table: 'income_expense',
    select: '*',
    order: 'month',
    orderAsc: false,
    realtimeFilter: null,
    ...REPORT_OPTS,
  })
  const renewals = useRealtimeList({
    table: 'renewal_due_list',
    select: '*',
    realtimeFilter: null,
    ...REPORT_OPTS,
  })

  return {
    monthlyCollection: monthlyCollection.data ?? [],
    occupancy: occupancy.data ?? [],
    seatOccupancy: seatOccupancy.data ?? [],
    overdue: overdue.data ?? [],
    overdueSummary: overdueSummary.data ?? [],
    yearEnd: yearEnd.data ?? [],
    incomeExpense: incomeExpense.data ?? [],
    renewals: renewals.data ?? [],
    loading:
      monthlyCollection.loading ||
      occupancy.loading ||
      overdue.loading ||
      incomeExpense.loading ||
      renewals.loading,
    refreshAll: () => {
      monthlyCollection.refresh()
      occupancy.refresh()
      overdue.refresh()
      yearEnd.refresh()
      incomeExpense.refresh()
      renewals.refresh()
    },
  }
}

export function useExpenses() {
  return useRealtimeList({ table: 'expenses', order: 'incurred_on', orderAsc: false })
}
