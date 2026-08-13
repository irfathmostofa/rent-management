import { Link, useLocation } from "react-router-dom";
import { useTranslation } from "react-i18next";
import LanguageSwitcher from "../layout/LanguageSwitcher";
import Icon from "../ui/Icon";

export default function PublicShell({ children }) {
  const { t } = useTranslation();
  const { pathname } = useLocation();

  return (
    <div className="min-h-screen bg-slate-50 text-slate-900">
      <header className="sticky top-0 z-40 bg-slate-900 text-white shadow-lg">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-4 px-4 py-3">
          <Link
            to="/"
            className="flex items-center gap-2 text-lg font-extrabold tracking-tight"
          >
            <span className="grid h-9 w-9 place-items-center rounded-lg bg-gradient-to-br from-indigo-500 to-violet-500 text-white">
              R
            </span>
            Rently
          </Link>
          <nav className="flex items-center gap-2 sm:gap-3">
            <Link
              to="/feedback"
              className={`hidden items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-semibold sm:flex ${
                pathname === "/feedback"
                  ? "bg-white/15 text-white"
                  : "text-slate-300 hover:bg-white/10 hover:text-white"
              }`}
            >
              <Icon name="chat" size={16} />
              {t("public.feedback")}
            </Link>
            <LanguageSwitcher />
            <Link
              to="/admin/login"
              className="flex items-center gap-1.5 rounded-lg bg-indigo-500 px-3 py-2 text-sm font-bold text-white transition hover:bg-indigo-400"
            >
              <Icon name="arrowLeft" size={14} className="rotate-180" />
              {t("public.becomeOwner")}
            </Link>
          </nav>
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-4 py-6">{children}</main>

      <footer className="border-t border-slate-200 bg-white py-6 text-center text-xs text-slate-400">
        © {new Date().getFullYear()} Rently · {t("public.footer")}
      </footer>
    </div>
  );
}
