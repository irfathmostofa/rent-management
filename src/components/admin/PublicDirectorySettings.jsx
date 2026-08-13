import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { supabase } from "../../lib/supabase";
import { useToast } from "../ui/Toast";
import Spinner from "../ui/Spinner";
import Icon from "../ui/Icon";

function Toggle({ checked, disabled, onChange, label, hint }) {
  return (
    <button
      type="button"
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className="flex w-full items-center justify-between gap-4 rounded-xl border border-slate-200 bg-white px-4 py-3.5 text-left transition hover:border-indigo-200 disabled:opacity-50"
    >
      <span>
        <span className="block text-sm font-bold text-slate-800">{label}</span>
        {hint && <span className="mt-0.5 block text-xs text-slate-500">{hint}</span>}
      </span>
      <span
        className={`relative h-6 w-11 shrink-0 rounded-full transition ${
          checked ? "bg-indigo-600" : "bg-slate-300"
        }`}
      >
        <span
          className={`absolute top-0.5 h-5 w-5 rounded-full bg-white shadow transition-all ${
            checked ? "left-[22px]" : "left-0.5"
          }`}
        />
      </span>
    </button>
  );
}

export default function PublicDirectorySettings() {
  const { t } = useTranslation();
  const toast = useToast();
  const [settings, setSettings] = useState(null);
  const [savingKey, setSavingKey] = useState(null);

  useEffect(() => {
    let mounted = true;
    supabase
      .from("public_settings")
      .select("*")
      .limit(1)
      .maybeSingle()
      .then(({ data, error }) => {
        if (!mounted) return;
        if (error) toast.error(error.message);
        else setSettings(data);
      });
    return () => {
      mounted = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const setField = async (key, value) => {
    const next = { ...settings, [key]: value };
    setSettings(next);
    setSavingKey(key);
    try {
      const { error } = await supabase
        .from("public_settings")
        .update({ [key]: value, updated_at: new Date().toISOString() })
        .eq("id", true);
      if (error) throw error;
      toast.success(t("admin.settingsSaved"));
    } catch (err) {
      toast.error(err.message);
      setSettings(settings);
    } finally {
      setSavingKey(null);
    }
  };

  if (!settings) return <Spinner />;

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2">
        <Icon name="external" size={16} className="text-indigo-600" />
        <div>
          <div className="text-sm font-bold text-slate-800">
            {t("admin.publicUrl")}
          </div>
          <div className="mono text-xs text-slate-500">/rent</div>
        </div>
      </div>

      <Toggle
        checked={settings.enabled}
        disabled={savingKey === "enabled"}
        onChange={(v) => setField("enabled", v)}
        label={t("admin.directoryEnabled")}
        hint={t("admin.directoryEnabledHint")}
      />
      <Toggle
        checked={settings.gate_enabled}
        disabled={savingKey === "gate_enabled"}
        onChange={(v) => setField("gate_enabled", v)}
        label={t("admin.gateEnabled")}
        hint={t("admin.gateEnabledHint")}
      />
      <Toggle
        checked={settings.name_required}
        disabled={savingKey === "name_required" || !settings.gate_enabled}
        onChange={(v) => setField("name_required", v)}
        label={t("admin.nameRequired")}
        hint={t("admin.nameRequiredHint")}
      />
      <Toggle
        checked={settings.phone_required}
        disabled={savingKey === "phone_required" || !settings.gate_enabled}
        onChange={(v) => setField("phone_required", v)}
        label={t("admin.phoneRequired")}
        hint={t("admin.phoneRequiredHint")}
      />

      <p className="rounded-xl bg-slate-100 px-4 py-3 text-xs text-slate-500">
        {t("admin.publicNote")}
      </p>
    </div>
  );
}
