import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useInvoices } from "../hooks/useInvoices";
import { useTenants } from "../hooks/useTenants";
import { usePagination } from "../hooks/usePagination";
import Spinner from "../components/ui/Spinner";
import EmptyState from "../components/ui/EmptyState";
import Pagination from "../components/ui/Pagination";
import Icon from "../components/ui/Icon";
import { money, fullName, initials } from "../lib/format";

export default function LedgerPage() {
  const { t } = useTranslation();
  const invoices = useInvoices();
  const tenants = useTenants();
  const [filter, setFilter] = useState("all"); // all, owes, paid

  const rows = useMemo(() => {
    const invs = (invoices.data ?? []).filter((i) => !i.is_void);
    const byTenant = new Map();
    for (const i of invs) {
      const cur = byTenant.get(i.tenant_id) || {
        billed: 0,
        paid: 0,
        balance: 0,
        count: 0,
      };
      cur.billed += Number(i.amount);
      cur.paid += Number(i.amount_paid);
      cur.balance += Number(i.balance);
      cur.count += 1;
      byTenant.set(i.tenant_id, cur);
    }
    return (tenants.data ?? [])
      .map((t) => ({
        tenant: t,
        ...(byTenant.get(t.id) || { billed: 0, paid: 0, balance: 0, count: 0 }),
      }))
      .sort((a, b) => b.balance - a.balance);
  }, [invoices.data, tenants.data]);

  const filteredRows = useMemo(() => {
    if (filter === "owes") return rows.filter((r) => r.balance > 0);
    if (filter === "paid")
      return rows.filter((r) => r.balance === 0 && r.billed > 0);
    return rows;
  }, [rows, filter]);

  const { pageItems, page, setPage, totalPages, totalItems, pageSize } =
    usePagination(filteredRows, 25);

  if (invoices.loading || tenants.loading) return <Spinner />;

  const totalBalance = rows.reduce((s, r) => s + r.balance, 0);
  const totalBilled = rows.reduce((s, r) => s + r.billed, 0);
  const totalPaid = rows.reduce((s, r) => s + r.paid, 0);
  const collectionRate = totalBilled > 0 ? (totalPaid / totalBilled) * 100 : 0;

  return (
    <div className="ledger-page">
      <div className="page-head">
        <div>
          <h1 className="page-title">{t("ledger.title")}</h1>
          <div className="page-sub">{t("ledger.subtitle")}</div>
        </div>
      </div>

      {/* Stats Grid - Enhanced */}
      <div className="stats-grid ledger-stats">
        <div className="stat stat-card">
          <div className="stat-icon" style={{ color: "var(--primary)" }}>
            <Icon name="receipt" size={20} />
          </div>
          <div>
            <div className="stat-label">{t("ledger.totalBilled")}</div>
            <div className="stat-value">{money(totalBilled)}</div>
          </div>
        </div>
        <div className="stat stat-card stat-success">
          <div className="stat-icon" style={{ color: "var(--success)" }}>
            <Icon name="checkCircle" size={20} />
          </div>
          <div>
            <div className="stat-label">{t("ledger.totalCollected")}</div>
            <div className="stat-value">{money(totalPaid)}</div>
            <div className="stat-sub">
              {collectionRate.toFixed(1)}% {t("ledger.collectionRate")}
            </div>
          </div>
        </div>
        <div className="stat stat-card stat-warning">
          <div className="stat-icon" style={{ color: "var(--warning)" }}>
            <Icon name="clock" size={20} />
          </div>
          <div>
            <div className="stat-label">{t("ledger.outstanding")}</div>
            <div
              className="stat-value"
              style={{
                color: totalBalance > 0 ? "var(--danger)" : "var(--success)",
              }}
            >
              {money(totalBalance)}
            </div>
            <div className="stat-sub">
              {totalBalance > 0
                ? `${rows.filter((r) => r.balance > 0).length} ${t("ledger.tenantsOwe")}`
                : t("ledger.allPaid")}
            </div>
          </div>
        </div>
      </div>

      {/* Filter Bar */}
      <div className="ledger-filter-bar">
        <div className="filter-tabs">
          <button
            className={`filter-tab ${filter === "all" ? "active" : ""}`}
            onClick={() => setFilter("all")}
          >
            <Icon name="users" size={14} />
            {t("ledger.allTenants")}
            <span className="filter-count">{rows.length}</span>
          </button>
          <button
            className={`filter-tab ${filter === "owes" ? "active" : ""}`}
            onClick={() => setFilter("owes")}
          >
            <Icon name="alertTriangle" size={14} />
            {t("ledger.owes")}
            <span className="filter-count filter-count-danger">
              {rows.filter((r) => r.balance > 0).length}
            </span>
          </button>
          <button
            className={`filter-tab ${filter === "paid" ? "active" : ""}`}
            onClick={() => setFilter("paid")}
          >
            <Icon name="check" size={14} />
            {t("ledger.paidUp")}
            <span className="filter-count filter-count-success">
              {rows.filter((r) => r.balance === 0 && r.billed > 0).length}
            </span>
          </button>
        </div>
      </div>

      {/* Desktop Table View */}
      <div className="desktop-table">
        <div className="card table-wrap">
          <table className="table ledger-table">
            <thead>
              <tr>
                <th>{t("ledger.colTenant")}</th>
                <th className="text-right">{t("ledger.colInvoices")}</th>
                <th className="text-right">{t("ledger.colBilled")}</th>
                <th className="text-right">{t("ledger.colPaid")}</th>
                <th className="text-right">{t("ledger.colBalance")}</th>
                <th className="text-center">{t("ledger.colStatus")}</th>
                <th>{t("ledger.colAction")}</th>
              </tr>
            </thead>
            <tbody>
              {pageItems.map((r) => (
                <tr
                  key={r.tenant.id}
                  className={r.balance > 0 ? "row-highlight" : ""}
                >
                  <td>
                    <div className="row tenant-cell">
                      <div
                        className="avatar"
                        style={{ width: 34, height: 34, fontSize: 12 }}
                      >
                        {initials(r.tenant.first_name, r.tenant.last_name)}
                      </div>
                      <Link
                        to={`/admin/tenants/${r.tenant.id}?tab=ledger`}
                        state={{ from: "/admin/ledger" }}
                        className="bold tenant-link"
                      >
                        {fullName(r.tenant)}
                      </Link>
                    </div>
                  </td>
                  <td className="text-center">{r.count || 0}</td>
                  <td className="text-right mono">{money(r.billed)}</td>
                  <td
                    className="text-right mono"
                    style={{ color: "var(--success)" }}
                  >
                    {money(r.paid)}
                  </td>
                  <td className="text-right mono bold">
                    <span
                      className={r.balance > 0 ? "text-danger" : "text-success"}
                    >
                      {money(r.balance)}
                    </span>
                  </td>
                  <td className="text-center">
                    {r.balance > 0 ? (
                      <span className="badge badge-red">
                        <Icon name="alertCircle" size={12} /> {t("ledger.owes")}
                      </span>
                    ) : r.billed > 0 ? (
                      <span className="badge badge-green">
                        <Icon name="check" size={12} /> {t("ledger.paid")}
                      </span>
                    ) : (
                      <span className="badge badge-gray">
                        {t("ledger.noActivity")}
                      </span>
                    )}
                  </td>
                  <td>
                    <Link
                      to={`/admin/tenants/${r.tenant.id}?tab=ledger`}
                      state={{ from: "/admin/ledger" }}
                      className="btn btn-ghost btn-sm"
                    >
                      <Icon name="externalLink" size={14} />
                      {t("common.view")}
                    </Link>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {totalItems > pageSize && (
            <Pagination
              page={page}
              totalPages={totalPages}
              totalItems={totalItems}
              pageSize={pageSize}
              onChange={setPage}
            />
          )}
        </div>
      </div>

      {/* Mobile List View */}
      <div className="list ledger-list">
        {pageItems.map((r) => (
          <Link
            key={r.tenant.id}
            to={`/admin/tenants/${r.tenant.id}?tab=ledger`}
            state={{ from: "/admin/ledger" }}
            className="list-card ledger-list-card"
          >
            <div className="list-card-left">
              <div
                className="avatar"
                style={{ width: 44, height: 44, fontSize: 15 }}
              >
                {initials(r.tenant.first_name, r.tenant.last_name)}
              </div>
              <div className="body">
                <div className="l-title">{fullName(r.tenant)}</div>
                {/* <div className="l-sub">
                  <span className="badge badge-gray">
                    {r.count || 0} {t("ledger.invoices")}
                  </span>
                  {r.balance > 0 ? (
                    <span className="badge badge-red">
                      <Icon name="alertCircle" size={10} /> {t("ledger.owes")}
                    </span>
                  ) : r.billed > 0 ? (
                    <span className="badge badge-green">
                      <Icon name="check" size={10} /> {t("ledger.paid")}
                    </span>
                  ) : (
                    <span className="badge badge-gray">
                      {t("ledger.noActivity")}
                    </span>
                  )}
                </div> */}
              </div>
            </div>
            <div className="list-card-right">
              <div className="ledger-amounts">
                <div className="amount-row">
                  <span className="label">{t("ledger.colBilled")}</span>
                  <span className="value">{money(r.billed)}</span>
                </div>
                <div className="amount-row">
                  <span className="label">{t("ledger.colPaid")}</span>
                  <span className="value paid">{money(r.paid)}</span>
                </div>
                <div className="amount-row balance">
                  <span className="label">{t("ledger.colBalance")}</span>
                  <span
                    className={`value bold ${r.balance > 0 ? "text-danger" : "text-success"}`}
                  >
                    {money(r.balance)}
                  </span>
                </div>
              </div>
              <Icon name="chevronRight" size={18} className="chevron" />
            </div>
          </Link>
        ))}
        {totalItems > pageSize && (
          <Pagination
            page={page}
            totalPages={totalPages}
            totalItems={totalItems}
            pageSize={pageSize}
            onChange={setPage}
          />
        )}
      </div>

      {rows.length === 0 && (
        <EmptyState
          icon="wallet"
          title={t("ledger.noTenants")}
          body={t("ledger.noTenantsBody")}
        />
      )}
    </div>
  );
}
