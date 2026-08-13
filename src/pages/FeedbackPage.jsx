import { useState } from "react";
import { useTranslation } from "react-i18next";
import PublicShell from "../components/public/PublicShell";
import Icon from "../components/ui/Icon";
import { submitFeedback } from "../lib/publicDirectory";

const RATINGS = [1, 2, 3, 4, 5];

export default function FeedbackPage() {
  const { t } = useTranslation();
  const [form, setForm] = useState({
    name: "",
    phone: "",
    email: "",
    rating: 0,
    category: "general",
    message: "",
  });
  const [errors, setErrors] = useState({});
  const [saving, setSaving] = useState(false);
  const [sent, setSent] = useState(false);

  const set = (field) => (e) =>
    setForm({ ...form, [field]: e.target.value });

  const submit = async (e) => {
    e.preventDefault();
    const errs = {};
    if (form.name.trim().length < 2) errs.name = "nameTooShort";
    if (form.message.trim().length < 10) errs.message = "messageTooShort";
    if (form.phone && !/^\+?[\d\s\-()]{7,}$/.test(form.phone)) errs.phone = "phoneInvalid";
    if (form.email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(form.email)) errs.email = "emailInvalid";
    if (form.rating < 1) errs.rating = "ratingRequired";
    setErrors(errs);
    if (Object.keys(errs).length > 0) return;

    setSaving(true);
    try {
      await submitFeedback({
        name: form.name.trim(),
        phone: form.phone.trim() || null,
        email: form.email.trim() || null,
        rating: form.rating,
        category: form.category,
        message: form.message.trim(),
      });
      setSent(true);
    } catch (err) {
      setErrors({ submit: err.message });
    } finally {
      setSaving(false);
    }
  };

  const inputCls = (field) =>
    `w-full rounded-xl border bg-white px-3.5 py-2.5 text-sm text-slate-900 outline-none transition focus:ring-2 ${
      errors[field]
        ? "border-red-400 focus:ring-red-200"
        : "border-slate-300 focus:border-indigo-500 focus:ring-indigo-200"
    }`;

  return (
    <PublicShell>
      <div className="mx-auto max-w-2xl">
        <div className="mb-6 text-center">
          <div className="mx-auto mb-3 grid h-14 w-14 place-items-center rounded-2xl bg-gradient-to-br from-indigo-500 to-violet-500 text-white">
            <Icon name="chat" size={26} />
          </div>
          <h1 className="text-2xl font-extrabold text-slate-900 sm:text-3xl">
            {t("feedback.title")}
          </h1>
          <p className="mt-2 text-sm text-slate-500">{t("feedback.subtitle")}</p>
        </div>

        {sent ? (
          <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-8 text-center">
            <div className="mx-auto mb-3 grid h-12 w-12 place-items-center rounded-full bg-emerald-500 text-white">
              <Icon name="check" size={22} />
            </div>
            <div className="text-lg font-extrabold text-emerald-800">
              {t("feedback.sentTitle")}
            </div>
            <p className="mt-1 text-sm text-emerald-700">{t("feedback.sentBody")}</p>
          </div>
        ) : (
          <form
            onSubmit={submit}
            className="space-y-4 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm"
          >
            {errors.submit && (
              <div className="rounded-xl bg-red-50 px-4 py-3 text-sm font-semibold text-red-700">
                {errors.submit}
              </div>
            )}

            <div className="grid gap-4 sm:grid-cols-2">
              <div>
                <label className="mb-1.5 block text-sm font-semibold text-slate-700">
                  {t("feedback.name")} *
                </label>
                <input
                  type="text"
                  value={form.name}
                  onChange={set("name")}
                  className={inputCls("name")}
                  placeholder={t("feedback.namePlaceholder")}
                />
                {errors.name && (
                  <p className="mt-1 text-xs font-medium text-red-600">
                    {t(`public.${errors.name}`)}
                  </p>
                )}
              </div>
              <div>
                <label className="mb-1.5 block text-sm font-semibold text-slate-700">
                  {t("feedback.phone")}
                </label>
                <input
                  type="tel"
                  value={form.phone}
                  onChange={set("phone")}
                  className={inputCls("phone")}
                  placeholder="+8801XXXXXXXXX"
                />
                {errors.phone && (
                  <p className="mt-1 text-xs font-medium text-red-600">
                    {t(`public.${errors.phone}`)}
                  </p>
                )}
              </div>
            </div>

            <div className="grid gap-4 sm:grid-cols-2">
              <div>
                <label className="mb-1.5 block text-sm font-semibold text-slate-700">
                  {t("feedback.email")}
                </label>
                <input
                  type="email"
                  value={form.email}
                  onChange={set("email")}
                  className={inputCls("email")}
                  placeholder="you@example.com"
                />
                {errors.email && (
                  <p className="mt-1 text-xs font-medium text-red-600">
                    {t(`public.${errors.email}`)}
                  </p>
                )}
              </div>
              <div>
                <label className="mb-1.5 block text-sm font-semibold text-slate-700">
                  {t("feedback.category")}
                </label>
                <select
                  value={form.category}
                  onChange={set("category")}
                  className={inputCls("category")}
                >
                  <option value="general">{t("feedback.categoryGeneral")}</option>
                  <option value="suggestion">{t("feedback.categorySuggestion")}</option>
                  <option value="issue">{t("feedback.categoryIssue")}</option>
                  <option value="praise">{t("feedback.categoryPraise")}</option>
                </select>
              </div>
            </div>

            <div>
              <label className="mb-1.5 block text-sm font-semibold text-slate-700">
                {t("feedback.rating")} *
              </label>
              <div className="flex gap-1.5">
                {RATINGS.map((r) => (
                  <button
                    key={r}
                    type="button"
                    onClick={() => setForm({ ...form, rating: r })}
                    className={`rounded-lg p-1.5 transition ${
                      r <= form.rating
                        ? "text-amber-400"
                        : "text-slate-300 hover:text-amber-300"
                    }`}
                    aria-label={`${r} star`}
                  >
                    <Icon name="star" size={26} />
                  </button>
                ))}
                {form.rating > 0 && (
                  <span className="ml-2 self-center text-sm font-semibold text-slate-500">
                    {t(`feedback.ratingLabel${form.rating}`)}
                  </span>
                )}
              </div>
              {errors.rating && (
                <p className="mt-1 text-xs font-medium text-red-600">
                  {t(`public.${errors.rating}`)}
                </p>
              )}
            </div>

            <div>
              <label className="mb-1.5 block text-sm font-semibold text-slate-700">
                {t("feedback.message")} *
              </label>
              <textarea
                rows={5}
                value={form.message}
                onChange={set("message")}
                className={inputCls("message")}
                placeholder={t("feedback.messagePlaceholder")}
              />
              {errors.message && (
                <p className="mt-1 text-xs font-medium text-red-600">
                  {t(`public.${errors.message}`)}
                </p>
              )}
            </div>

            <button
              type="submit"
              disabled={saving}
              className="w-full rounded-xl bg-indigo-600 px-4 py-3 text-sm font-bold text-white transition hover:bg-indigo-500 disabled:opacity-50"
            >
              {saving ? t("common.saving") : t("feedback.submit")}
            </button>
          </form>
        )}
      </div>
    </PublicShell>
  );
}
