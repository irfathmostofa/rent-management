import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useInvoices } from "../hooks/useInvoices";
import { usePagination } from "../hooks/usePagination";
import Badge from "../components/ui/Badge";
import Spinner from "../components/ui/Spinner";
import EmptyState from "../components/ui/EmptyState";
import Button from "../components/ui/Button";
import Pagination from "../components/ui/Pagination";
import { Select, Input } from "../components/ui/Input";
import Icon from "../components/ui/Icon";
import { money, formatDate, fullName } from "../lib/format";

const STATUSES = ["", "open", "partially_paid", "paid", "overdue", "void"];
const TYPES = ["", "rent", "fine", "deposit", "utility", "other"];

export default function InvoicesPage() {
  const { t } = useTranslation();
  const { data, loading } = useInvoices();
  const [status, setStatus] = useState("");
  const [type, setType] = useState("");
  const [q, setQ] = useState("");
  const [fromDate, setFromDate] = useState("");
  const [toDate, setToDate] = useState("");

  const filtered = useMemo(() => {
    let rows = data ?? [];
    if (status) rows = rows.filter((i) => i.status_key === status);
    if (type) rows = rows.filter((i) => i.invoice_type_key === type);
    if (fromDate) {
      rows = rows.filter((i) => i.issue_date && i.issue_date >= fromDate);
    }
    if (toDate) {
      rows = rows.filter((i) => i.issue_date && i.issue_date <= toDate);
    }
    if (q) {
      const needle = q.toLowerCase();
      rows = rows.filter(
        (i) =>
          i.invoice_number?.toLowerCase().includes(needle) ||
          fullName(i.tenant).toLowerCase().includes(needle),
      );
    }
    return rows;
  }, [data, status, type, q, fromDate, toDate]);

  const { pageItems, page, setPage, totalPages, totalItems, pageSize } =
    usePagination(filtered, 20);

  if (loading) return <Spinner />;

  const totals = filtered.reduce(
    (acc, i) => {
      acc.amount += Number(i.amount);
      acc.balance += Number(i.balance);
      return acc;
    },
    { amount: 0, balance: 0 },
  );

  return (
    <div>
      <div className="page-head">
        <div>
          <h1 className="page-title">{t("invoices.title")}</h1>
          <div className="page-sub">{t("invoices.subtitle")}</div>
        </div>
      </div>

      <div className="card card-pad mb-3">
        <div className="filter-bar">
          <div className="filter-item grow">
            <Input
              placeholder={t("invoices.searchPlaceholder")}
              value={q}
              onChange={(e) => {
                setQ(e.target.value);
                setPage(1);
              }}
            />
          </div>
          <div className="filter-item">
            <Select
              value={status}
              onChange={(e) => {
                setStatus(e.target.value);
                setPage(1);
              }}
            >
              {STATUSES.map((s) => (
                <option key={s || "all"} value={s}>
                  {s ? t(`invoices.status_${s}`) : t("invoices.allStatuses")}
                </option>
              ))}
            </Select>
          </div>
          <div className="filter-item">
            <Select
              value={type}
              onChange={(e) => {
                setType(e.target.value);
                setPage(1);
              }}
            >
              {TYPES.map((ty) => (
                <option key={ty || "all"} value={ty}>
                  {ty ? t(`invoices.type_${ty}`) : t("invoices.allTypes")}
                </option>
              ))}
            </Select>
          </div>
          <div className="filter-item">
            <span className="label-sm">{t("invoices.from")}</span>
            <Input
              className="compact input-border-none"
              type="date"
              value={fromDate}
              onChange={(e) => {
                setFromDate(e.target.value);
                setPage(1);
              }}
            />
          </div>
          <div className="filter-item ">
            <span className="label-sm">{t("invoices.to")}</span>
            <Input
              className="compact input-border-none"
              type="date"
              value={toDate}
              onChange={(e) => {
                setToDate(e.target.value);
                setPage(1);
              }}
            />
          </div>
          <div className="filter-item">
            <Button
              variant="ghost"
              size="sm"
              onClick={() => {
                setFromDate("");
                setToDate("");
                setQ("");
                setStatus("");
                setType("");
                setPage(1);
              }}
            >
              <Icon name="refresh" size={14} /> {t("common.clear")}
            </Button>
          </div>
        </div>
        <div className="row small muted" style={{ marginTop: 8 }}>
          <span>{t("invoices.count", { count: filtered.length })}</span>
          <span>· {t("invoices.billed", { amount: money(totals.amount) })}</span>
          <span>· {t("invoices.outstanding", { amount: money(totals.balance) })}</span>
        </div>
      </div>

      <div className="desktop-table">
        <div className="card table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>{t("invoices.colInvoice")}</th>
                <th>{t("invoices.colTenant")}</th>
                <th>{t("invoices.colPeriod")}</th>
                <th>{t("invoices.colType")}</th>
                <th>{t("invoices.colAmount")}</th>
                <th className="text-right">{t("invoices.colBalance")}</th>
                <th>{t("invoices.colStatus")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {pageItems.map((i) => (
                <tr key={i.id}>
                  <td className="mono">
                    <Link to={`/admin/invoices/${i.id}`}>{i.invoice_number}</Link>
                  </td>
                  <td>{fullName(i.tenant)}</td>
                  <td className="small muted">
                    {i.period_start
                      ? `${formatDate(i.period_start)} → ${formatDate(i.period_end)}`
                      : "—"}
                  </td>
                  <td>{i.invoice_types?.name || i.invoice_type_key}</td>
                  <td className="mono">{money(i.amount)}</td>
                  <td
                    className="text-right mono bold"
                    style={{
                      color: i.balance > 0 ? "var(--danger)" : "var(--success)",
                    }}
                  >
                    {i.is_void ? "—" : money(i.balance)}
                  </td>
                  <td>
                    <Badge value={i.is_void ? "void" : i.status_key} />
                  </td>
                  <td>
                    <Link
                      to={`/admin/invoices/${i.id}`}
                      className="btn btn-ghost btn-sm"
                    >
                      {t("common.open")}
                    </Link>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <Pagination
            page={page}
            totalPages={totalPages}
            totalItems={totalItems}
            pageSize={pageSize}
            onChange={setPage}
          />
        </div>
      </div>

      <div className="list">
        {pageItems.map((i) => (
          <Link key={i.id} to={`/admin/invoices/${i.id}`} className="list-card">
            <div
              className="avatar alt"
              style={{
                background:
                  i.invoice_type_key === "fine"
                    ? "var(--danger)"
                    : "var(--primary)",
              }}
            >
              <Icon name="receipt" size={17} />
            </div>
            <div className="body">
              <div className="l-title">{i.invoice_number}</div>
              <div className="l-sub">
                {fullName(i.tenant)} ·{" "}
                {i.invoice_types?.name || i.invoice_type_key} ·{" "}
                {i.period_start ? formatDate(i.period_start) : ""}
              </div>
            </div>
            <div className="right">
              <div className="bold mono">{money(i.balance)}</div>
              <Badge value={i.is_void ? "void" : i.status_key} />
            </div>
          </Link>
        ))}
        <Pagination
          page={page}
          totalPages={totalPages}
          totalItems={totalItems}
          pageSize={pageSize}
          onChange={setPage}
        />
      </div>

      {filtered.length === 0 && (
        <EmptyState
          icon="receipt"
          title={t("invoices.noInvoices")}
          body={t("invoices.noInvoicesBody")}
        />
      )}
    </div>
  );
}
