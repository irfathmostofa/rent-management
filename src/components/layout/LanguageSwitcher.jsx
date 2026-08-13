import { useTranslation } from 'react-i18next'

export default function LanguageSwitcher({ compact = false }) {
  const { t, i18n } = useTranslation()
  const isBn = i18n.language === 'bn'

  const toggle = () => {
    i18n.changeLanguage(isBn ? 'en' : 'bn')
  }

  if (compact) {
    return (
      <button
        type="button"
        className="btn btn-secondary btn-icon"
        onClick={toggle}
        title={isBn ? t('lang.english') : t('lang.bangla')}
        style={{ minWidth: 40 }}
      >
        {isBn ? 'EN' : 'বাং'}
      </button>
    )
  }

  return (
    <div className="lang-switch" role="group" aria-label={t('lang.switcher')}>
      <button
        type="button"
        className={`lang-btn${!isBn ? ' active' : ''}`}
        onClick={() => i18n.changeLanguage('en')}
      >
        EN
      </button>
      <button
        type="button"
        className={`lang-btn${isBn ? ' active' : ''}`}
        onClick={() => i18n.changeLanguage('bn')}
      >
        বাংলা
      </button>
    </div>
  )
}
