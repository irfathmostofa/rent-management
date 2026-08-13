import { useState } from "react";
import { useTranslation } from "react-i18next";
import { validateGate } from "../../lib/publicDirectory";
import Icon from "../ui/Icon";

// Super-admin-controlled gate: the visitor must provide a valid name and/or
// phone number before browsing the public directory.
export default function GateModal({
  nameRequired = true,
  phoneRequired = true,
  onApproved,
}) {
  const { t } = useTranslation();
  const [form, setForm] = useState({ name: "", phone: "" });
  const [errors, setErrors] = useState({});
  const [saving, setSaving] = useState(false);

  const submit = (e) => {
    e.preventDefault();
    const errs = validateGate(form, { nameRequired, phoneRequired });
    if (Object.keys(errs).length > 0) {
      setErrors(errs);
      return;
    }
    setSaving(true);
    onApproved({
      name: form.name.trim(),
      phone: form.phone.trim(),
      at: new Date().toISOString(),
    });
    setSaving(false);
  };

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-slate-900/60 p-4 backdrop-blur-sm">
      <div className="w-full max-w-md rounded-2xl bg-white p-6 shadow-2xl sm:p-8">
        <div className="mb-2 flex items-center gap-3">
          <span className="grid h-11 w-11 place-items-center rounded-xl bg-gradient-to-br from-indigo-500 to-violet-500 text-white">
            <Icon name="shield" size={20} />
          </span>
          <div>
            <h2 className="text-lg font-extrabold text-slate-900">
              {t("public.gateTitle")}
            </h2>
            <p className="text-sm text-slate-500">{t("public.gateSubtitle")}</p>
          </div>
        </div>

        <form onSubmit={submit} className="mt-5 space-y-4">
          {nameRequired && (
            <div>
              <label className="mb-1.5 block text-sm font-semibold text-slate-700">
                {t("public.yourName")}
              </label>
              <input
                type="text"
                value={form.name}
                onChange={(e) =>
                  setForm({ ...form, name: e.target.value })
                }
                placeholder={t("public.namePlaceholder")}
                className={`w-full rounded-xl border bg-white px-3.5 py-2.5 text-sm text-slate-900 outline-none transition focus:ring-2 ${
                  errors.name
                    ? "border-red-400 focus:ring-red-200"
                    : "border-slate-300 focus:border-indigo-500 focus:ring-indigo-200"
                }`}
              />
              {errors.name && (
                <p className="mt-1 text-xs font-medium text-red-600">
                  {t(`public.${errors.name}`)}
                </p>
              )}
            </div>
          )}

          {phoneRequired && (
            <div>
              <label className="mb-1.5 block text-sm font-semibold text-slate-700">
                {t("public.phoneNumber")}
              </label>
              <input
                type="tel"
                value={form.phone}
                onChange={(e) => setForm({ ...form, phone: e.target.value })}
                placeholder="+8801XXXXXXXXX"
                className={`w-full rounded-xl border bg-white px-3.5 py-2.5 text-sm text-slate-900 outline-none transition focus:ring-2 ${
                  errors.phone
                    ? "border-red-400 focus:ring-red-200"
                    : "border-slate-300 focus:border-indigo-500 focus:ring-indigo-200"
                }`}
              />
              {errors.phone && (
                <p className="mt-1 text-xs font-medium text-red-600">
                  {t(`public.${errors.phone}`)}
                </p>
              )}
            </div>
          )}

          <button
            type="submit"
            disabled={saving}
            className="w-full rounded-xl bg-indigo-600 px-4 py-2.5 text-sm font-bold text-white transition hover:bg-indigo-500 disabled:opacity-50"
          >
            {saving ? t("common.saving") : t("public.continue")}
          </button>
          <p className="text-center text-xs text-slate-400">
            {t("public.gateNote")}
          </p>
        </form>
      </div>
    </div>
  );
}
