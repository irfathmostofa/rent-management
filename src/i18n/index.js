import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'
import en from './locales/en'
import bn from './locales/bn'

const BN_DIGITS = '০১২৩৪৫৬৭৮৯'
const toBnDigits = (value) =>
  String(value).replace(/[0-9]/g, (d) => BN_DIGITS[Number(d)])

const saved = (() => {
  try {
    return localStorage.getItem('rently.lang') || null
  } catch {
    return null
  }
})()

i18n.use(initReactI18next).init({
  resources: {
    en: { translation: en },
    bn: { translation: bn },
  },
  lng: saved || 'en',
  fallbackLng: 'en',
  supportedLngs: ['en', 'bn'],
  interpolation: {
    escapeValue: false,
    alwaysFormat: true,
  },
  react: {
    useSuspense: false,
  },
})

// Convert every interpolated number to Bengali digits when in Bengali.
// i18next v26 uses its built-in Formatter for interpolation.format, so we
// wrap the interpolator's format hook instead.
const bnDigitFormatter = (() => {
  const builtin = i18n.services.formatter.format.bind(i18n.services.formatter)
  return (value, format, lng, options) => {
    if (lng === 'bn' && !format && typeof value === 'number') {
      return toBnDigits(value)
    }
    return builtin(value, format, lng, options)
  }
})()
i18n.services.interpolator.format = bnDigitFormatter

const applyLang = (lng) => {
  if (typeof document !== 'undefined') {
    document.documentElement.lang = lng
  }
  try {
    localStorage.setItem('rently.lang', lng)
  } catch {
    // ignore
  }
}

applyLang(i18n.language)

i18n.on('languageChanged', applyLang)

export default i18n
