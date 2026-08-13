import Icon from '../ui/Icon'

// Mobile-only floating action button.
export default function QuickAction({ onClick, label, icon = 'plus' }) {
  return (
    <button className="fab" onClick={onClick} aria-label={label} title={label}>
      <Icon name={icon} size={24} />
    </button>
  )
}
