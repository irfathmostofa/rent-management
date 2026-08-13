const toneFor = {
  paid: 'green',
  open: 'blue',
  partially_paid: 'amber',
  overdue: 'red',
  draft: 'gray',
  void: 'gray',
  rent: 'indigo',
  fine: 'red',
  deposit: 'blue',
  utility: 'amber',
  other: 'gray',
  active: 'green',
  ended: 'gray',
  available: 'blue',
  occupied: 'green',
  maintenance: 'amber',
  off_market: 'gray',
  queued: 'blue',
  sent: 'green',
  failed: 'red',
  cancelled: 'gray',
  trial: 'indigo',
  expired: 'red',
  past_due: 'amber',
  super_admin: 'purple',
  owner: 'indigo',
  system: 'gray',
}

export default function Badge({ value, tone, children }) {
  const t = tone || toneFor[value] || 'gray'
  return <span className={`badge badge-${t}`}>{children ?? value}</span>
}

export function invoiceStatusTone(status) {
  return toneFor[status] || 'gray'
}
