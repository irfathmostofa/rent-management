import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useInvoices } from "../hooks/useInvoices";
import { useTenants } from "../hooks/useTenants";
import { useProperties } from "../hooks/useProperties";
import { useReports } from "../hooks/useReports";
import { useAuth } from "../auth/AuthContext";
import Badge from "../components/ui/Badge";
import Spinner from "../components/ui/Spinner";
import Icon from "../components/ui/Icon";
import { money, formatDateShort, fullName } from "../lib/format";

function StatCard({ _icon, label, value, sub, tone, _color }) {
  return (
    <div className={`stat-card-modern ${tone || ""}`}>
      <div className="stat-content">
        <div className="stat-label-modern">{label}</div>
        <div className="stat-value-modern">{value}</div>
        {sub && <div className="stat-sub-modern">{sub}</div>}
      </div>
    </div>
  );
}

export default function DashboardPage() {
  const { t } = useTranslation();
  const { owner } = useAuth();
  const invoices = useInvoices();
  const tenants = useTenants();
  const properties = useProperties();
  const reports = useReports();

  if (invoices.loading || tenants.loading || properties.loading)
    return <Spinner />;

  const invs = invoices.data ?? [];
  const activeTenants = (tenants.data ?? []).filter(
    (t) => t.status === "active",
  );

  const outstanding = invs
    .filter((i) => !i.is_void && i.balance > 0)
    .reduce((s, i) => s + Number(i.balance), 0);
  const overdue = invs
    .filter((i) => i.status_key === "overdue" && !i.is_void)
    .sort((a, b) => new Date(a.due_date) - new Date(b.due_date));

  const now = new Date();
  const monthStart = new Date(
    now.getFullYear(),
    now.getMonth(),
    1,
  ).toISOString();
  const collectedThisMonth = (invs.flatMap((i) => i.payments ?? []) || [])
    .filter((p) => new Date(p.paid_at) >= new Date(monthStart))
    .reduce((s, p) => s + Number(p.amount), 0);

  const recentPayments = (
    invs.flatMap((i) =>
      (i.payments ?? []).map((p) => ({ ...p, invoice: i })),
    ) || []
  )
    .sort((a, b) => new Date(b.paid_at) - new Date(a.paid_at))
    .slice(0, 5);

  const occupancy = reports.occupancy;
  const occupied = occupancy.reduce((s, o) => s + Number(o.occupied_units), 0);
  const total = occupancy.reduce((s, o) => s + Number(o.total_units), 0);

  return (
    <div className="">
      {/* Header */}
      <div className="dashboard-header">
        <div>
          <h1 className="dashboard-title">
            {t("dashboard.welcome", {
              name: owner ? `, ${owner.business_name}` : "",
            })}
          </h1>
          <p className="dashboard-subtitle">{t("dashboard.subtitle")}</p>
        </div>
      </div>

      {/* Stats Grid - Modern Cards */}
      <div className="stats-grid-modern">
        <StatCard
          icon="dollarSign"
          label={t("dashboard.outstanding")}
          value={money(outstanding)}
          sub={t("dashboard.overdueCount", { count: overdue.length })}
          tone="warning"
          color="#d97706"
        />
        <StatCard
          icon="checkCircle"
          label={t("dashboard.collectedThisMonth")}
          value={money(collectedThisMonth)}
          tone="success"
          color="#16a34a"
        />
        <StatCard
          icon="home"
          label={t("dashboard.occupancy")}
          value={total ? `${Math.round((occupied / total) * 100)}%` : "—"}
          sub={t("dashboard.unitsOccupied", { occupied, total })}
          tone="info"
          color="#0284c7"
        />
        <StatCard
          icon="users"
          label={t("dashboard.activeTenants")}
          value={activeTenants.length}
          tone="primary"
          color="#4f46e5"
        />
      </div>

      {/* Quick Actions */}
      {/* <div className="quick-actions">
        <Link to="/admin/invoices/new" className="quick-action-btn">
          <div
            className="qa-icon"
            style={{ background: "var(--primary-soft)" }}
          >
            <Icon name="plus" size={18} color="var(--primary)" />
          </div>
          <span>{t("dashboard.newInvoice")}</span>
        </Link>
        <Link to="/admin/tenants/new" className="quick-action-btn">
          <div
            className="qa-icon"
            style={{ background: "var(--success-soft)" }}
          >
            <Icon name="userPlus" size={18} color="var(--success)" />
          </div>
          <span>{t("dashboard.addTenant")}</span>
        </Link>
        <Link to="/admin/properties/new" className="quick-action-btn">
          <div className="qa-icon" style={{ background: "var(--info-soft)" }}>
            <Icon name="home" size={18} color="var(--info)" />
          </div>
          <span>{t("dashboard.addProperty")}</span>
        </Link>
      </div> */}

      {/* Overdue Invoices */}
      {/* Overdue Invoices & Recent Payments - Row on Desktop */}
      <div className="dashboard-grid-2">
        {/* Overdue Invoices */}
        {/* Recent Payments */}
        <div className="section-card">
          <div className="section-header">
            <div>
              <h2 className="section-title">{t("dashboard.recentPayments")}</h2>
            </div>
            <Link to="/admin/ledger" className="btn-ghost-sm">
              {t("dashboard.ledger")}
            </Link>
          </div>

          {recentPayments.length === 0 ? (
            <div className="empty-state-modern">
              <div
                className="empty-icon"
                style={{ background: "var(--info-soft)" }}
              >
                <Icon name="receipt" size={24} color="var(--info)" />
              </div>
              <h3>{t("dashboard.noPayments")}</h3>
              <p>{t("dashboard.noPaymentsBody")}</p>
            </div>
          ) : (
            <div className="payment-list">
              {recentPayments.map((p) => (
                <div key={p.id} className="payment-item">
                  <div className="payment-item-left">
                    <div>
                      <div className="payment-tenant">
                        {fullName(p.invoice?.tenant)}
                      </div>
                      <div className="payment-meta">
                        <span className="payment-date">
                          {formatDateShort(p.paid_at)}
                        </span>
                        <span className="dot">·</span>
                        <Badge value={p.method_key} />
                      </div>
                    </div>
                  </div>
                  <div className="payment-item-right">
                    <div className="payment-amount">{money(p.amount)}</div>
                    <span className="badge badge-green">
                      {t("dashboard.paid")}
                    </span>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>{" "}
        <div className="section-card">
          <div className="section-header">
            <div>
              <h2 className="section-title">
                {t("dashboard.overdueInvoices")}
              </h2>
              {overdue.length > 0 && (
                <span className="section-badge badge-red">
                  {overdue.length}
                </span>
              )}
            </div>
            <Link to="/admin/invoices" className="btn-ghost-sm">
              {t("dashboard.viewAll")}
            </Link>
          </div>

          {overdue.length === 0 ? (
            <div className="empty-state-modern">
              <div
                className="empty-icon"
                style={{ background: "var(--success-soft)" }}
              >
                <Icon name="check" size={24} color="var(--success)" />
              </div>
              <h3>{t("dashboard.allClear")}</h3>
              <p>{t("dashboard.noOverdue")}</p>
            </div>
          ) : (
            <div className="invoice-list">
              {overdue.slice(0, 5).map((i) => (
                <Link
                  key={i.id}
                  to={`/admin/tenants/${i.tenant_id}`}
                  state={{ from: "/admin" }}
                  className="invoice-item"
                >
                  <div className="invoice-item-left">
                    <div
                      className="invoice-avatar"
                      style={{ background: "var(--danger-soft)" }}
                    >
                      <Icon
                        name="alertCircle"
                        size={16}
                        color="var(--danger)"
                      />
                    </div>
                    <div>
                      <div className="invoice-tenant">{fullName(i.tenant)}</div>
                      <div className="invoice-meta">
                        <span className="invoice-number">
                          {i.invoice_number}
                        </span>
                        <span className="dot">·</span>
                        <span className="invoice-date">
                          {formatDateShort(i.due_date)}
                        </span>
                      </div>
                    </div>
                  </div>
                  <div className="invoice-item-right">
                    <div className="invoice-amount-overdue">
                      {money(i.balance)}
                    </div>
                    <span className="badge badge-red">
                      {t("dashboard.overdue")}
                    </span>
                  </div>
                </Link>
              ))}
              {overdue.length > 5 && (
                <Link to="/admin/invoices" className="view-more-btn">
                  {t("dashboard.viewMore", { count: overdue.length - 5 })}
                </Link>
              )}
            </div>
          )}
        </div>
      </div>

      {/* Occupancy by Property */}
      <div className="section-card">
        <div className="section-header">
          <h2 className="section-title">
            {t("dashboard.occupancyByProperty")}
          </h2>
          <Link to="/admin/reports" className="btn-ghost-sm">
            {t("dashboard.reports")}
          </Link>
        </div>

        {occupancy.length === 0 ? (
          <div className="empty-state-modern">
            <div
              className="empty-icon"
              style={{ background: "var(--primary-soft)" }}
            >
              <Icon name="building" size={24} color="var(--primary)" />
            </div>
            <h3>{t("dashboard.noProperties")}</h3>
            <p>{t("dashboard.noPropertiesBody")}</p>
          </div>
        ) : (
          <div className="occupancy-list">
            {occupancy.map((o) => (
              <Link
                key={o.property_id}
                to={`/admin/properties/${o.property_id}`}
                className="occupancy-item-modern"
              >
                <div className="occupancy-info">
                  <div className="occupancy-name">{o.property_name}</div>
                  <div className="occupancy-stats">
                    <span className="occupancy-count">
                      {o.occupied_units}/{o.total_units} {t("dashboard.units")}
                    </span>
                  </div>
                </div>
                <div className="occupancy-right">
                  <div className="occupancy-rate">{o.occupancy_rate}%</div>
                  <div className="occupancy-bar">
                    <div
                      className="occupancy-bar-fill"
                      style={{
                        width: `${o.occupancy_rate}%`,
                        background:
                          o.occupancy_rate > 80
                            ? "var(--success)"
                            : o.occupancy_rate > 50
                              ? "var(--warning)"
                              : "var(--danger)",
                      }}
                    />
                  </div>
                </div>
              </Link>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
