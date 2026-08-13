import { useTranslation } from 'react-i18next'
import Icon from './Icon'

export default function EmptyState({ icon = 'search', title, body, action }) {
  const { t } = useTranslation()
  return (
    <div className="empty">
      <div className="ico">
        <Icon name={icon} size={34} />
      </div>
      <div className="title">{title || t('common.nothingHereYet')}</div>
      {body && <div className="small muted">{body}</div>}
      {action && <div className="mt-2">{action}</div>}
    </div>
  )
}
