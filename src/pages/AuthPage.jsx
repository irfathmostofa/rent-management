import { useState, useEffect } from "react";
import { useNavigate, Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { supabase } from "../lib/supabase";
import { useAuth } from "../auth/AuthContext";
import Button from "../components/ui/Button";
import { Field, Input, Select } from "../components/ui/Input";
import { useToast } from "../components/ui/Toast";
import LanguageSwitcher from "../components/layout/LanguageSwitcher";

export default function AuthPage({ mode }) {
  const { t } = useTranslation();
  const isLogin = mode === "login";
  const navigate = useNavigate();
  const { session } = useAuth();
  const toast = useToast();

  useEffect(() => {
    if (session) navigate("/admin", { replace: true });
  }, [session, navigate]);

  // "form" = normal login/signup, "reset" = forgot-password request,
  // "reset-sent" = confirmation screen after the email is sent.
  const [view, setView] = useState("form");

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [businessName, setBusinessName] = useState("");
  const [propertyKind, setPropertyKind] = useState("apartment");
  const [phone, setPhone] = useState("");
  const [loading, setLoading] = useState(false);
  const [resetEmail, setResetEmail] = useState("");

  const submit = async (e) => {
    e.preventDefault();
    setLoading(true);
    try {
      if (isLogin) {
        const { error } = await supabase.auth.signInWithPassword({
          email,
          password,
        });
        if (error) throw error;
      } else {
        const { error } = await supabase.auth.signUp({
          email,
          password,
          options: {
            data: {
              business_name: businessName,
              property_kind: propertyKind,
              phone,
            },
          },
        });
        if (error) throw error;
        toast.success(t("auth.accountCreated"));
      }
      navigate("/admin", { replace: true });
    } catch (err) {
      toast.error(err.message);
    } finally {
      setLoading(false);
    }
  };

  const submitReset = async (e) => {
    e.preventDefault();
    setLoading(true);
    try {
      const { error } = await supabase.auth.resetPasswordForEmail(resetEmail, {
        redirectTo: `${window.location.origin}/admin/reset-password`,
      });
      if (error) throw error;
      setView("reset-sent");
    } catch (err) {
      toast.error(err.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="paywall">
      <div className="paywall-card" style={{ textAlign: "left" }}>
        <div className="row-between" style={{ marginBottom: 18 }}>
          <div className="sidebar-logo" style={{ padding: 0 }}>
            <div className="logo-mark">R</div>
            <div className="logo-text" style={{ color: "var(--text)" }}>
              Rently
            </div>
          </div>
          <LanguageSwitcher compact />
        </div>

        {view === "form" && (
          <>
            <h1 style={{ fontSize: 22 }}>
              {isLogin ? t("auth.welcomeBack") : t("auth.startTrial")}
            </h1>
            <p className="muted small" style={{ margin: "6px 0 20px" }}>
              {isLogin
                ? t("auth.signInSubtitle")
                : t("auth.signupSubtitle")}
            </p>

            <form onSubmit={submit}>
              {!isLogin && (
                <>
                  <Field label={t("auth.businessName")}>
                    <Input
                      required
                      value={businessName}
                      onChange={(e) => setBusinessName(e.target.value)}
                      placeholder={t("auth.businessNamePlaceholder")}
                    />
                  </Field>
                  <Field label={t("auth.manageWhat")}>
                    <Select
                      value={propertyKind}
                      onChange={(e) => setPropertyKind(e.target.value)}
                    >
                      <option value="apartment">{t("auth.apartments")}</option>
                      <option value="cottage">{t("auth.cottages")}</option>
                      <option value="both">{t("auth.both")}</option>
                    </Select>
                  </Field>
                  <Field label={t("auth.phone")}>
                    <Input
                      type="tel"
                      required
                      value={phone}
                      onChange={(e) => setPhone(e.target.value)}
                      placeholder={t("auth.phonePlaceholder")}
                      autoComplete="tel"
                    />
                  </Field>
                </>
              )}
              <Field label={t("auth.email")}>
                <Input
                  type="email"
                  required
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  placeholder="you@example.com"
                  autoComplete="email"
                />
              </Field>
              <Field label={t("auth.password")}>
                <Input
                  type="password"
                  required
                  minLength={6}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="••••••••"
                  autoComplete={isLogin ? "current-password" : "new-password"}
                />
              </Field>

              {isLogin && (
                <div
                  style={{
                    textAlign: "right",
                    marginTop: -8,
                    marginBottom: 16,
                  }}
                >
                  <button
                    type="button"
                    className="auth-link-btn"
                    onClick={() => {
                      setResetEmail(email);
                      setView("reset");
                    }}
                  >
                    {t("auth.forgotPassword")}
                  </button>
                </div>
              )}

              <Button
                type="submit"
                block
                size="lg"
                disabled={loading}
                className="mt-2"
              >
                {loading
                  ? t("auth.pleaseWait")
                  : isLogin
                    ? t("auth.signIn")
                    : t("auth.createAccount")}
              </Button>
            </form>

            <p
              className="small muted text-center mt-3"
              style={{ marginBottom: 0 }}
            >
              {isLogin ? (
                <>
                  {t("auth.newHere")}{" "}
                  <Link
                    to="/admin/signup"
                    style={{ color: "var(--primary)", fontWeight: 600 }}
                  >
                    {t("auth.startFreeTrial")}
                  </Link>
                </>
              ) : (
                <>
                  {t("auth.haveAccount")}{" "}
                  <Link
                    to="/admin/login"
                    style={{ color: "var(--primary)", fontWeight: 600 }}
                  >
                    {t("auth.signIn")}
                  </Link>
                </>
              )}
            </p>
          </>
        )}

        {view === "reset" && (
          <>
            <button
              type="button"
              className="auth-link-btn mb-2"
              onClick={() => setView("form")}
            >
              ← {t("auth.backToSignIn")}
            </button>
            <h1 style={{ fontSize: 22 }}>{t("auth.resetPassword")}</h1>
            <p className="muted small" style={{ margin: "6px 0 20px" }}>
              {t("auth.resetSubtitle")}
            </p>
            <form onSubmit={submitReset}>
              <Field label={t("auth.email")}>
                <Input
                  type="email"
                  required
                  value={resetEmail}
                  onChange={(e) => setResetEmail(e.target.value)}
                  placeholder="you@example.com"
                  autoComplete="email"
                />
              </Field>
              <Button
                type="submit"
                block
                size="lg"
                disabled={loading}
                className="mt-2"
              >
                {loading ? t("auth.sending") : t("auth.sendResetLink")}
              </Button>
            </form>
          </>
        )}

        {view === "reset-sent" && (
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
              {t("auth.checkInbox")}
            </h1>
            <p
              className="muted small text-center"
              style={{ margin: "6px 0 20px" }}
            >
              {t("auth.resetSentBody", { email: resetEmail })}
            </p>
            <Button
              block
              size="lg"
              variant="secondary"
              onClick={() => setView("form")}
            >
              {t("auth.backToSignIn")}
            </Button>
          </>
        )}
      </div>
    </div>
  );
}
