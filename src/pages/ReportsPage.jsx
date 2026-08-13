import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useReports } from "../hooks/useReports";
import { usePagination } from "../hooks/usePagination";
import Spinner from "../components/ui/Spinner";
import EmptyState from "../components/ui/EmptyState";
import Button from "../components/ui/Button";
import Pagination from "../components/ui/Pagination";
import Icon from "../components/ui/Icon";
import { money, formatDate } from "../lib/format";

const TABS = [
  "collection",
  "occupancy",
  "overdue",
  "year-end",
  "income",
  "renewals",
];

export default function ReportsPage() {
  const { t } = useTranslation();
  const reports = useReports();
  const [tab, setTab] = useState("collection");

  const overduePagination = usePagination(reports.overdue, 25);

  if (reports.loading) return <Spinner />;

  return (
    <div>
      <div className="page-head">
        <div>
          <h1 className="page-title">{t("reports.title")}</h1>
          <div className="page-sub">{t("reports.subtitle")}</div>
        </div>
        <Button variant="secondary" size="sm" onClick={reports.refreshAll}>
          <Icon name="refresh" size={14} /> {t("reports.refresh")}
        </Button>
      </div>

      <div className="tabs">
        {TABS.map((x) => (
          <button
            key={x}
            className={`tab${tab === x ? " active" : ""}`}
            onClick={() => setTab(x)}
          >
            {t(`reports.tab.${x}`)}
          </button>
        ))}
      </div>

      {tab === "collection" && (
        <DataTable
          rows={reports.monthlyCollection}
          cols={[
            [t("reports.colMonth"), (r) => formatDate(r.month)],
            [t("reports.colInvoiced"), (r) => money(r.invoiced), "right"],
            [t("reports.colCollected"), (r) => money(r.collected), "right green"],
            [t("reports.colOutstanding"), (r) => money(r.outstanding), "right"],
            [t("reports.colCollectionRate"), (r) => `${r.collection_rate}%`, "right"],
          ]}
          empty={t("reports.emptyBilling")}
          emptyTitle={t("reports.nothingToShow")}
        />
      )}

      {tab === "occupancy" && (
        <DataTable
          rows={reports.occupancy}
          cols={[
            [t("reports.colProperty"), (r) => r.property_name],
            [
              t("reports.colOccupied"),
              (r) => `${r.occupied_units}/${r.total_units}`,
              "right",
            ],
            [t("reports.colRate"), (r) => `${r.occupancy_rate}%`, "right"],
          ]}
          empty={t("reports.emptyProperties")}
          emptyTitle={t("reports.nothingToShow")}
        />
      )}

      {tab === "overdue" && (
        <>
          <DataTable
            rows={reports.overdueSummary}
            cols={[
              [t("reports.colBucket"), (r) => `${r.bucket} ${t("reports.days")}`, "bold"],
              [t("reports.colInvoices"), (r) => r.invoices, "right"],
              [t("reports.colTotal"), (r) => money(r.total), "right red"],
            ]}
            empty={t("reports.emptyOverdue")}
            emptyTitle={t("reports.nothingToShow")}
          />
          <div className="card mt-3">
            <div className="card-header">
              <div className="card-title">{t("reports.overdueDetail")}</div>
            </div>
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>{t("reports.colInvoice")}</th>
                    <th>{t("reports.colTenant")}</th>
                    <th>{t("reports.colDue")}</th>
                    <th>{t("reports.colDays")}</th>
                    <th>{t("reports.colBucket")}</th>
                    <th className="text-right">{t("reports.colBalance")}</th>
                  </tr>
                </thead>
                <tbody>
                  {overduePagination.pageItems.map((r) => (
                    <tr key={`${r.invoice_number}-${r.tenant_id}`}>
                      <td className="mono">{r.invoice_number}</td>
                      <td>{r.tenant_name}</td>
                      <td className="small">{formatDate(r.due_date)}</td>
                      <td className="mono">{r.days_overdue}</td>
                      <td>
                        <span className="badge badge-red">{r.bucket}d</span>
                      </td>
                      <td
                        className="text-right mono bold"
                        style={{ color: "var(--danger)" }}
                      >
                        {money(r.balance)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {reports.overdue.length === 0 ? (
              <EmptyState
                icon="chart"
                title={t("reports.nothingToShow")}
                body={t("reports.emptyOverdue")}
              />
            ) : (
              <Pagination
                page={overduePagination.page}
                totalPages={overduePagination.totalPages}
                totalItems={overduePagination.totalItems}
                pageSize={overduePagination.pageSize}
                onChange={overduePagination.setPage}
              />
            )}
          </div>
        </>
      )}

      {tab === "year-end" && (
        <DataTable
          rows={reports.yearEnd}
          cols={[
            [t("reports.colTenant"), (r) => r.tenant_name],
            [t("reports.colYear"), (r) => r.year, "right"],
            [t("reports.colInvoices"), (r) => r.invoices, "right"],
            [t("reports.colBilled"), (r) => money(r.billed), "right"],
            [t("reports.colPaid"), (r) => money(r.paid), "right green"],
            [t("reports.colBalance"), (r) => money(r.balance), "right"],
          ]}
          empty={t("reports.emptyStatements")}
          emptyTitle={t("reports.nothingToShow")}
        />
      )}

      {tab === "income" && (
        <DataTable
          rows={reports.incomeExpense}
          cols={[
            [t("reports.colMonth"), (r) => formatDate(r.month)],
            [t("reports.colIncome"), (r) => money(r.income), "right green"],
            [t("reports.colExpenses"), (r) => money(r.expense), "right red"],
            [t("reports.colNet"), (r) => money(r.net), "right bold"],
          ]}
          empty={t("reports.emptyIncome")}
          emptyTitle={t("reports.nothingToShow")}
        />
      )}

      {tab === "renewals" && (
        <DataTable
          rows={reports.renewals}
          cols={[
            [t("reports.colTenant"), (r) => r.tenant_name],
            [t("reports.colUnit"), (r) => r.unit_number],
            [t("reports.colEndDate"), (r) => formatDate(r.end_date)],
            [t("reports.colRent"), (r) => money(r.rent_amount), "right"],
            [t("reports.colIn"), (r) => `${r.days_until_renewal}d`, "right"],
          ]}
          empty={t("reports.emptyRenewals")}
          emptyTitle={t("reports.nothingToShow")}
        />
      )}
    </div>
  );
}

// Generic paginated table used by every simple-report tab (collection,
// occupancy, year-end, income, renewals). The overdue-detail table has its
// own state above since it sits alongside a second (summary) table.
function DataTable({ rows, cols, empty, emptyTitle }) {
  const { pageItems, page, setPage, totalPages, totalItems, pageSize } =
    usePagination(rows, 25);

  return (
    <div className="card">
      {rows.length === 0 ? (
        <EmptyState icon="chart" title={emptyTitle} body={empty} />
      ) : (
        <>
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  {cols.map(([label]) => (
                    <th key={label}>{label}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {pageItems.map((r, idx) => (
                  <tr key={idx}>
                    {cols.map(([_label, render, align]) => (
                      <td
                        key={_label}
                        className={typeof align === "string" ? align : ""}
                      >
                        {render(r)}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <Pagination
            page={page}
            totalPages={totalPages}
            totalItems={totalItems}
            pageSize={pageSize}
            onChange={setPage}
          />
        </>
      )}
    </div>
  );
}
