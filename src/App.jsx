import { Routes, Route, Navigate } from "react-router-dom";
import { useAuth } from "./auth/AuthContext";
import { isConfigured } from "./lib/supabase";
import Spinner from "./components/ui/Spinner";
import AppShell from "./components/layout/AppShell";
import AuthPage from "./pages/AuthPage";
import DashboardPage from "./pages/DashboardPage";
import PropertiesPage from "./pages/PropertiesPage";
import NewPropertyPage from "./pages/NewPropertyPage";
import PropertyDetailPage from "./pages/PropertyDetailPage";
import TenantsPage from "./pages/TenantsPage";
import TenantDetailPage from "./pages/TenantDetailPage";
import InvoicesPage from "./pages/InvoicesPage";
import InvoiceDetailPage from "./pages/InvoiceDetailPage";
import LedgerPage from "./pages/LedgerPage";
import MessagingPage from "./pages/MessagingPage";
import ReportsPage from "./pages/ReportsPage";
import SettingsPage from "./pages/SettingsPage";
import CurrencySettingsPage from "./pages/CurrencySettingsPage";
import BillingPage from "./pages/BillingPage";
import AdminPage from "./pages/AdminPage";
import ResetPasswordPage from "./pages/ResetPasswordPage";
import PublicDirectoryPage from "./pages/PublicDirectoryPage";
import PublicPropertyDetailPage from "./pages/PublicPropertyDetailPage";
import FeedbackPage from "./pages/FeedbackPage";

function SetupScreen() {
  return (
    <div className="paywall">
      <div className="paywall-card">
        <h1>Supabase not configured</h1>
        <p className="muted small">
          Copy <span className="mono">.env.example</span> to{" "}
          <span className="mono">.env.local</span>, fill in your{" "}
          <span className="mono">VITE_SUPABASE_URL</span> and{" "}
          <span className="mono">VITE_SUPABASE_ANON_KEY</span>, then run the
          migrations in <span className="mono">supabase/migrations</span> and{" "}
          <span className="mono">supabase/seed.sql</span>.
        </p>
      </div>
    </div>
  );
}

function RequireAuth({ children }) {
  const { user, loading } = useAuth();
  if (loading) return <Spinner />;
  if (!user) return <Navigate to="/admin/login" replace />;
  return children;
}

function RequireAccess({ children }) {
  const { access, user, loading } = useAuth();
  if (loading) return <Spinner />;
  if (!user) return <Navigate to="/admin/login" replace />;
  if (!access) return <Spinner />;
  if (access.has_access) return children;
  return <BillingPage />;
}

function RequireAdmin({ children }) {
  const { access, loading } = useAuth();
  if (loading) return <Spinner />;
  if (!access?.has_access) return <Navigate to="/admin" replace />;
  if (access.access_state !== "super_admin") return <Navigate to="/admin" replace />;
  return children;
}

export default function App() {
  if (!isConfigured) return <SetupScreen />;

  return (
    <Routes>
      <Route path="/" element={<PublicDirectoryPage />} />
      <Route path="/rent" element={<Navigate to="/" replace />} />
      <Route path="/rent/:id" element={<PublicPropertyDetailPage />} />
      <Route path="/feedback" element={<FeedbackPage />} />

      <Route path="/admin/login" element={<AuthPage mode="login" />} />
      <Route path="/admin/signup" element={<AuthPage mode="signup" />} />
      <Route path="/admin/reset-password" element={<ResetPasswordPage />} />

      <Route
        element={
          <RequireAuth>
            <AppShell />
          </RequireAuth>
        }
      >
        <Route path="/admin/billing" element={<BillingPage />} />
      </Route>

      <Route
        element={
          <RequireAuth>
            <RequireAccess>
              <AppShell />
            </RequireAccess>
          </RequireAuth>
        }
      >
        <Route path="/admin" element={<DashboardPage />} />
        <Route path="/admin/properties" element={<PropertiesPage />} />
        <Route path="/admin/properties/new/:kind" element={<NewPropertyPage />} />
        <Route path="/admin/properties/:id" element={<PropertyDetailPage />} />
        <Route path="/admin/tenants" element={<TenantsPage />} />
        <Route path="/admin/tenants/:id" element={<TenantDetailPage />} />
        <Route path="/admin/invoices" element={<InvoicesPage />} />
        <Route path="/admin/invoices/:id" element={<InvoiceDetailPage />} />
        <Route path="/admin/ledger" element={<LedgerPage />} />
        <Route path="/admin/messaging" element={<MessagingPage />} />
        <Route path="/admin/reports" element={<ReportsPage />} />
        <Route path="/admin/settings" element={<SettingsPage />} />
        <Route path="/admin/settings/currencies" element={<CurrencySettingsPage />} />
      </Route>

      <Route
        path="/admin/super"
        element={
          <RequireAuth>
            <RequireAdmin>
              <AppShell />
            </RequireAdmin>
          </RequireAuth>
        }
      >
        <Route index element={<AdminPage />} />
      </Route>

      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
