import { useEffect, useState } from "react";
import { useNavigate, Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { supabase } from "../lib/supabase";
import Button from "../components/ui/Button";
import { Field, Input } from "../components/ui/Input";
import { useToast } from "../components/ui/Toast";

// Landed on via the link from resetPasswordForEmail. Supabase's client
// detects the recovery token in the URL (detectSessionInUrl: true) and
// fires a PASSWORD_RECOVERY auth event with a temporary session — we just
// wait for that, then let the user set a new password with updateUser.
export default function ResetPasswordPage() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const toast = useToast();

  const [ready, setReady] = useState(false);
  const [invalid, setInvalid] = useState(false);
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [loading, setLoading] = useState(false);
  const [done, setDone] = useState(false);

  useEffect(() => {
    if (!supabase) return;
    let mounted = true;
    let settled = false;

    const { data: sub } = supabase.auth.onAuthStateChange((event) => {
      if (event === "PASSWORD_RECOVERY") {
        settled = true;
        if (mounted) setReady(true);
      }
    });

    // If the recovery event already fired before this listener attached,
    // fall back to checking for an existing session.
    supabase.auth.getSession().then(({ data }) => {
      if (!mounted || settled) return;
      if (data.session) {
        setReady(true);
      } else {
        setInvalid(true);
      }
    });

    return () => {
      mounted = false;
      sub?.subscription?.unsubscribe();
    };
  }, []);

  const submit = async (e) => {
    e.preventDefault();
    if (password !== confirm) {
      toast.error(t("auth.passwordsDontMatch"));
      return;
    }
    setLoading(true);
    try {
      const { error } = await supabase.auth.updateUser({ password });
      if (error) throw error;
      setDone(true);
      toast.success(t("auth.passwordUpdated"));
    } catch (err) {
      toast.error(err.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="paywall">
      <div
        className="paywall-card"
        style={{ textAlign: "left", maxWidth: 420 }}
      >
        <div className="sidebar-logo" style={{ padding: 0, marginBottom: 18 }}>
          <div className="logo-mark">R</div>
          <div className="logo-text" style={{ color: "var(--text)" }}>
            Rently
          </div>
        </div>

        {invalid && (
          <>
            <h1 style={{ fontSize: 22 }}>{t("auth.linkExpired")}</h1>
            <p className="muted small" style={{ margin: "6px 0 20px" }}>
              {t("auth.linkExpiredBody")}
            </p>
            <Link to="/admin/login">
              <Button block size="lg">
                {t("auth.backToSignIn")}
              </Button>
            </Link>
          </>
        )}

        {!invalid && done && (
          <>
            <div
              style={{
                width: 48,
                height: 48,
                borderRadius: "50%",
                background: "var(--success-soft)",
                color: "var(--success)",
                fontSize: 22,
                fontWeight: 800,
                display: "grid",
                placeItems: "center",
                margin: "0 auto 16px",
              }}
            >
              ✓
            </div>
            <h1 style={{ fontSize: 22, textAlign: "center" }}>
              {t("auth.passwordUpdated")}
            </h1>
            <p
              className="muted small text-center"
              style={{ margin: "6px 0 20px" }}
            >
              {t("auth.passwordUpdatedBody")}
            </p>
            <Button
              block
              size="lg"
              onClick={async () => {
                await supabase.auth.signOut();
                navigate("/admin/login", { replace: true });
              }}
            >
              {t("auth.goToSignIn")}
            </Button>
          </>
        )}

        {!invalid && !done && (
          <>
            <h1 style={{ fontSize: 22 }}>{t("auth.setNewPassword")}</h1>
            <p className="muted small" style={{ margin: "6px 0 20px" }}>
              {ready
                ? t("auth.chooseNewPassword")
                : t("auth.verifyingResetLink")}
            </p>

            <form onSubmit={submit}>
              <Field label={t("auth.newPassword")}>
                <Input
                  type="password"
                  required
                  minLength={6}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="••••••••"
                  autoComplete="new-password"
                  disabled={!ready}
                />
              </Field>
              <Field label={t("auth.confirmPassword")}>
                <Input
                  type="password"
                  required
                  minLength={6}
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                  placeholder="••••••••"
                  autoComplete="new-password"
                  disabled={!ready}
                />
              </Field>
              <Button
                type="submit"
                block
                size="lg"
                disabled={!ready || loading}
                className="mt-2"
              >
                {loading ? t("auth.saving") : t("auth.updatePassword")}
              </Button>
            </form>
          </>
        )}
      </div>
    </div>
  );
}
