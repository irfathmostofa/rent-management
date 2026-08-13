import { useTranslation } from 'react-i18next'
import Modal from './Modal'
import Button from './Button'

export default function ConfirmDialog({ open, onClose, onConfirm, title, body, confirmLabel, danger }) {
  const { t } = useTranslation()
  return (
    <Modal
      open={open}
      onClose={onClose}
      title={title}
      footer={
        <>
          <Button variant="secondary" onClick={onClose}>
            {t('common.cancel')}
          </Button>
          <Button
            variant={danger ? 'danger' : 'primary'}
            onClick={async () => {
              try {
                await onConfirm()
                onClose()
              } catch {
                /* errors surfaced by caller */
              }
            }}
          >
            {confirmLabel || t('common.confirm')}
          </Button>
        </>
      }
    >
      <p className="muted" style={{ marginTop: 0 }}>
        {body}
      </p>
    </Modal>
  )
}
