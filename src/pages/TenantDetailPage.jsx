import { useMemo, useState } from "react";
import {
  Link,
  useLocation,
  useParams,
  useSearchParams,
} from "react-router-dom";
import { useTranslation } from "react-i18next";
import { callRpc } from "../lib/supabase";
import { useTenant, useRentHistory } from "../hooks/useTenants";
import { usePropertyOptions } from "../hooks/useProperties";
import { useInvoices, useLedger } from "../hooks/useInvoices";
import { useLookups } from "../hooks/useLookups";
import { useMessageTemplates } from "../hooks/useMessaging";
import Button from "../components/ui/Button";
import { Field, Input, Select, Textarea } from "../components/ui/Input";
import Modal from "../components/ui/Modal";
import Badge from "../components/ui/Badge";
import Spinner from "../components/ui/Spinner";
import EmptyState from "../components/ui/EmptyState";
import Icon from "../components/ui/Icon";
import { useToast } from "../components/ui/Toast";
import { money, formatDate, fullName, initials } from "../lib/format";
import {
  isUnitAvailable,
  isUnitFullyBooked,
  availableSeats,
} from "../lib/availability";

const TABS = ["overview", "ledger", "invoices", "history"];

export default function TenantDetailPage() {
  const { t } = useTranslation();
  const { id } = useParams();
  const [searchParams, setSearchParams] = useSearchParams();
  const location = useLocation();
  const tenant = useTenant(id);
  const history = useRentHistory(id);
  const properties = usePropertyOptions();
  const invoices = useInvoices();
  const ledger = useLedger(id);
  const lookups = useLookups();
  const templates = useMessageTemplates();
  const toast = useToast();

  const refreshAll = () => {
    tenant.refresh();
    invoices.refresh();
    ledger.refresh();
    history.refresh();
  };

  const tab = TABS.includes(searchParams.get("tab"))
    ? searchParams.get("tab")
    : "overview";

  const setTab = (next) =>
    setSearchParams((prev) => {
      const params = new URLSearchParams(prev);
      params.set("tab", next);
      return params;
    });
  const backTo = location.state?.from || "/admin/tenants";
  const [leaseOpen, setLeaseOpen] = useState(false);
  const [payInvoice, setPayInvoice] = useState(null);
  const [increaseOpen, setIncreaseOpen] = useState(false);
  const [msgOpen, setMsgOpen] = useState(false);
  const [msgForm, setMsgForm] = useState({
    template_key: "",
    subject: "",
    body: "",
  });
  const [saving, setSaving] = useState(false);
  const [queuing, setQueuing] = useState(false);

  const [leaseForm, setLeaseForm] = useState({
    property_id: "",
    unit_id: "",
    seat_id: "",
    start_date: "",
    end_date: "",
    grace_days: 3,
  });
  const [payForm, setPayForm] = useState({
    amount: "",
    method_key: "bank_transfer",
    paid_at: new Date().toISOString().slice(0, 16),
    reference: "",
  });
  const [incForm, setIncForm] = useState({
    enabled: false,
    amount: "",
    percent: "",
  });

  const tenantRow = tenant.data?.[0];
  const tenantInvoices = useMemo(
    () => (invoices.data ?? []).filter((i) => i.tenant_id === id),
    [invoices.data, id],
  );
  const activeLeases = (tenantRow?.leases ?? []).filter(
    (l) => l.status === "active",
  );
  const selectedProperty = (properties.data ?? []).find(
    (p) => p.id === leaseForm.property_id,
  );
  const selectedKind = selectedProperty?.property_types?.key;

  // Only units/rooms with something available.
  const availableUnits = useMemo(
    () => (selectedProperty?.units ?? []).filter((u) => !isUnitFullyBooked(u)),
    [selectedProperty],
  );
  const selectedUnit = useMemo(
    () => availableUnits.find((u) => u.id === leaseForm.unit_id),
    [availableUnits, leaseForm.unit_id],
  );
  const seats = useMemo(() => availableSeats(selectedUnit), [selectedUnit]);
  const wholeUnitAvailable = selectedUnit
    ? isUnitAvailable(selectedUnit)
    : true;

  if (tenant.loading) return <Spinner />;
  if (!tenantRow)
    return <EmptyState icon="search" title={t("tenantDetail.notFound")} />;

  const addLease = async (e) => {
    e.preventDefault();
    setSaving(true);
    try {
      await callRpc("create_lease", {
        p_tenant_id: id,
        p_unit_id: leaseForm.unit_id,
        p_seat_id: leaseForm.seat_id || null,
        p_start_date:
          leaseForm.start_date || new Date().toISOString().slice(0, 10),
        p_end_date: leaseForm.end_date || null,
        p_grace_days: Number(leaseForm.grace_days),
      });
      toast.success(t("tenantDetail.leaseCreated"));
      setLeaseOpen(false);
      refreshAll();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSaving(false);
    }
  };

  const endLease = async (lease) => {
    try {
      await callRpc("end_lease", { p_lease_id: lease.id });
      toast.success(t("tenantDetail.leaseEnded"));
      refreshAll();
    } catch (err) {
      toast.error(err.message);
    }
  };

  const recordPayment = async (e) => {
    e.preventDefault();
    setSaving(true);
    try {
      await callRpc("record_payment", {
        p_invoice_id: payInvoice.id,
        p_amount: Number(payForm.amount),
        p_method_key: payForm.method_key,
        p_paid_at: new Date(payForm.paid_at).toISOString(),
        p_reference: payForm.reference || null,
      });
      toast.success(t("tenantDetail.paymentRecorded"));
      setPayInvoice(null);
      refreshAll();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSaving(false);
    }
  };

  const saveIncrease = async (e) => {
    e.preventDefault();
    setSaving(true);
    try {
      await callRpc("set_tenant_rent_increase", {
        p_tenant_id: id,
        p_enabled: incForm.enabled,
        p_amount: incForm.amount === "" ? null : Number(incForm.amount),
        p_percent: incForm.percent === "" ? null : Number(incForm.percent),
      });
      toast.success(t("tenantDetail.increaseSaved"));
      setIncreaseOpen(false);
      refreshAll();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSaving(false);
    }
  };

  const sendMessage = () => {
    setMsgForm({ template_key: "", subject: "", body: "" });
    setMsgOpen(true);
  };

  const tenantTemplates = (templates.data ?? []).filter(
    (t) => t.channel_group === "tenant_facing" && t.is_active,
  );

  const CUSTOM_KEY = "__custom__";

  const fillTemplate = (tpl) => {
    const inv = [...tenantInvoices]
      .filter((i) => !i.is_void)
      .sort(
        (a, b) =>
          new Date(b.period_end ?? b.created_at) -
          new Date(a.period_end ?? a.created_at),
      )[0];
    const vars = {
      name: fullName(tenantRow),
      invoice: inv?.invoice_number ?? "",
      amount: inv ? money(inv.amount) : "",
      balance: inv ? money(inv.balance) : "",
      days: inv?.due_date
        ? Math.max(
            0,
            Math.floor(
              (Date.now() - new Date(inv.due_date).getTime()) / 86400000,
            ),
          )
        : "",
      date: formatDate(new Date().toISOString().slice(0, 10)),
    };
    const body = (tpl?.body ?? "").replace(
      /\{(\w+)\}/g,
      (m, k) => vars[k] ?? "",
    );
    return {
      template_key: tpl ? tpl.key : CUSTOM_KEY,
      subject: tpl?.subject ?? "",
      body,
    };
  };

  const pickTemplate = (tpl) => {
    setMsgForm(fillTemplate(tpl));
  };

  const backToTypes = () => {
    setMsgForm({ template_key: "", subject: "", body: "" });
  };

  const queueMessage = async (e) => {
    e.preventDefault();
    setQueuing(true);
    try {
      await callRpc("create_announcement", {
        p_subject: msgForm.subject,
        p_body: msgForm.body,
        p_tenant_ids: [id],
      });
      toast.success(t("tenantDetail.messageQueued"));
      setMsgOpen(false);
      setMsgForm({ template_key: "", subject: "", body: "" });
    } catch (err) {
      toast.error(err.message);
    } finally {
      setQueuing(false);
    }
  };

  return (
    <div>
      <Link to={backTo} className="btn btn-ghost btn-sm mb-2">
        <Icon name="arrowLeft" size={15} /> {t("common.back")}
      </Link>

      <div className="page-head">
        <div className="row" style={{ gap: 14 }}>
          <div
            className="avatar"
            style={{ width: 52, height: 52, fontSize: 18 }}
          >
            {initials(tenantRow.first_name, tenantRow.last_name)}
          </div>
          <div>
            <h1 className="page-title">{fullName(tenantRow)}</h1>
            <div className="page-sub">
              {tenantRow.email} · {tenantRow.phone} · {t("tenantDetail.joined")}{" "}
              {formatDate(tenantRow.join_date)}
            </div>
          </div>
        </div>
        <div className="row">
          <Button variant="secondary" size="sm" onClick={sendMessage}>
            <Icon name="message" size={14} /> {t("common.message")}
          </Button>
          <Button size="sm" onClick={() => setLeaseOpen(true)}>
            <Icon name="plus" size={14} /> {t("tenantDetail.addLease")}
          </Button>
        </div>
      </div>

      <div className="tabs">
        {TABS.map((x) => (
          <button
            key={x}
            className={`tab${tab === x ? " active" : ""}`}
            onClick={() => setTab(x)}
          >
            {t(`tenantDetail.tab_${x}`)}
          </button>
        ))}
      </div>

      {tab === "overview" && (
        <>
          {(tenantRow.tenant_type || tenantRow.occupation_type) && (
            <div className="card mb-3">
              <div className="card-header">
                <div className="card-title">
                  {t("tenantDetail.tenantProfile")}
                </div>
              </div>
              <div className="card-pad" style={{ paddingTop: 12 }}>
                <div className="small">
                  {t("tenantDetail.type")}:{" "}
                  <Badge
                    value={tenantRow.tenant_type || "single"}
                    tone={
                      tenantRow.tenant_type === "family" ? "indigo" : "gray"
                    }
                  >
                    {tenantRow.tenant_type || "single"}
                  </Badge>
                  {tenantRow.occupation_type && (
                    <>
                      {" · "}
                      {t("tenantDetail.occupation")}:{" "}
                      <Badge
                        value={tenantRow.occupation_type}
                        tone={
                          tenantRow.occupation_type === "student"
                            ? "blue"
                            : tenantRow.occupation_type === "job_holder"
                              ? "green"
                              : "amber"
                        }
                      >
                        {tenantRow.occupation_type}
                      </Badge>
                    </>
                  )}
                </div>
                {tenantRow.occupation_type === "student" &&
                  (tenantRow.occupation_details?.university ||
                    tenantRow.occupation_details?.course ||
                    tenantRow.occupation_details?.student_id) && (
                    <p className="small muted" style={{ marginBottom: 0 }}>
                      {[
                        tenantRow.occupation_details?.university,
                        tenantRow.occupation_details?.course,
                        tenantRow.occupation_details?.student_id &&
                          `ID ${tenantRow.occupation_details.student_id}`,
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                    </p>
                  )}
                {tenantRow.occupation_type === "job_holder" &&
                  (tenantRow.occupation_details?.employer ||
                    tenantRow.occupation_details?.job_title) && (
                    <p className="small muted" style={{ marginBottom: 0 }}>
                      {[
                        tenantRow.occupation_details?.employer,
                        tenantRow.occupation_details?.job_title,
                        tenantRow.occupation_details?.income &&
                          `${money(tenantRow.occupation_details.income)}/mo`,
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                    </p>
                  )}
              </div>
            </div>
          )}

          <div className="card mb-3">
            <div className="card-header">
              <div className="card-title">
                {t("tenantDetail.leasesAndSeats")}
              </div>
            </div>
            {activeLeases.length === 0 && (
              <EmptyState
                icon="fileText"
                title={t("tenantDetail.noActiveLease")}
                body={t("tenantDetail.noActiveLeaseBody")}
              />
            )}
            {activeLeases.map((l) => (
              <div
                key={l.id}
                className="row-between"
                style={{
                  padding: "12px 20px",
                  borderBottom: "1px solid var(--border)",
                }}
              >
                <div>
                  <div className="bold">
                    {l.unit?.unit_number}
                    {l.seat ? ` · ${l.seat.seat_number}` : ""}
                  </div>
                  <div className="small muted">
                    {t("tenantDetail.rent")} {money(l.rent_amount)}/
                    {t("tenantDetail.cycle")} · {t("tenantDetail.since")}{" "}
                    {formatDate(l.start_date)}
                    {l.end_date
                      ? ` · ${t("tenantDetail.ends")} ${formatDate(l.end_date)}`
                      : ""}
                  </div>
                </div>
                <Button variant="ghost" size="sm" onClick={() => endLease(l)}>
                  {t("common.end")}
                </Button>
              </div>
            ))}
          </div>

          <div className="card">
            <div className="card-header">
              <div className="card-title">
                {t("tenantDetail.annualIncrease")}
              </div>
              <Button
                variant="secondary"
                size="sm"
                onClick={() => {
                  setIncForm({
                    enabled: Boolean(tenantRow.rent_increase_enabled),
                    amount: tenantRow.rent_increase_amount ?? "",
                    percent: tenantRow.rent_increase_percent ?? "",
                  });
                  setIncreaseOpen(true);
                }}
              >
                {t("common.configure")}
              </Button>
            </div>
            <div className="card-pad" style={{ paddingTop: 12 }}>
              <div className="small muted">
                {t("tenantDetail.status")}:{" "}
                <Badge
                  value={tenantRow.rent_increase_enabled ?? null}
                  tone={
                    tenantRow.rent_increase_enabled === true
                      ? "green"
                      : tenantRow.rent_increase_enabled === false
                        ? "amber"
                        : "gray"
                  }
                >
                  {tenantRow.rent_increase_enabled === true
                    ? t("tenantDetail.enabledPerTenant")
                    : tenantRow.rent_increase_enabled === false
                      ? t("tenantDetail.disabledPerTenant")
                      : t("tenantDetail.inheritGlobal")}
                </Badge>
                {tenantRow.rent_increase_amount
                  ? ` · +${money(tenantRow.rent_increase_amount)}`
                  : ""}
                {tenantRow.rent_increase_percent
                  ? ` · +${tenantRow.rent_increase_percent}%`
                  : ""}
              </div>
            </div>
          </div>
        </>
      )}

      {tab === "ledger" && (
        <div className="card">
          <div className="card-header">
            <div className="card-title">{t("tenantDetail.runningLedger")}</div>
          </div>
          <div className="table-wrap desktop-table">
            <table className="table">
              <thead>
                <tr>
                  <th>{t("tenantDetail.colWhen")}</th>
                  <th>{t("tenantDetail.colType")}</th>
                  <th>{t("tenantDetail.colDescription")}</th>
                  <th className="text-right">{t("tenantDetail.colAmount")}</th>
                  <th className="text-right">{t("tenantDetail.colBalance")}</th>
                </tr>
              </thead>
              <tbody>
                {(ledger.data ?? []).map((e) => (
                  <tr key={`${e.entry_type}-${e.entry_id}`}>
                    <td className="small muted">
                      {formatDate(e.effective_at)}
                    </td>
                    <td>
                      <Badge
                        value={e.entry_type}
                        tone={
                          e.entry_type === "payment"
                            ? "green"
                            : e.kind === "rent"
                              ? "indigo"
                              : "amber"
                        }
                      >
                        {e.entry_type === "payment"
                          ? t("tenantDetail.payment")
                          : e.kind}
                      </Badge>
                    </td>
                    <td className="small">{e.description || e.kind}</td>
                    <td
                      className="text-right mono"
                      style={{
                        color: e.delta < 0 ? "var(--success)" : "inherit",
                      }}
                    >
                      {e.delta < 0 ? money(Math.abs(e.delta)) : money(e.delta)}
                    </td>
                    <td className="text-right mono bold">
                      {money(e.running_balance)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="detail-list">
            {(ledger.data ?? []).map((e) => (
              <div key={`${e.entry_type}-${e.entry_id}`} className="detail-row">
                <div className="dr-main">
                  <div className="dr-title">
                    <Badge
                      value={e.entry_type}
                      tone={
                        e.entry_type === "payment"
                          ? "green"
                          : e.kind === "rent"
                            ? "indigo"
                            : "amber"
                      }
                    >
                      {e.entry_type === "payment"
                        ? t("tenantDetail.payment")
                        : e.kind}
                    </Badge>
                    <span className="muted small">
                      {" "}
                      · {formatDate(e.effective_at)}
                    </span>
                  </div>
                  <div className="dr-sub">{e.description || e.kind}</div>
                </div>
                <div className="dr-right">
                  <div className={`dr-value${e.delta < 0 ? " dr-pos" : ""}`}>
                    {e.delta < 0 ? money(Math.abs(e.delta)) : money(e.delta)}
                  </div>
                  <div className="small muted">
                    {t("tenantDetail.colBalance")}: {money(e.running_balance)}
                  </div>
                </div>
              </div>
            ))}
          </div>
          {(ledger.data ?? []).length === 0 && (
            <EmptyState
              icon="wallet"
              title={t("tenantDetail.noLedgerEntries")}
            />
          )}
        </div>
      )}

      {tab === "invoices" && (
        <div className="card">
          <div className="card-header">
            <div className="card-title">{t("tenantDetail.invoices")}</div>
            <Link to="/admin/invoices" className="btn btn-ghost btn-sm">
              {t("tenantDetail.allInvoices")}
            </Link>
          </div>

          {/* Desktop Table View */}
          <div className="table-wrap desktop-table">
            <table className="table">
              <thead>
                <tr>
                  <th>{t("tenantDetail.colInvoice")}</th>
                  <th>{t("tenantDetail.colPeriod")}</th>
                  <th>{t("tenantDetail.colType")}</th>
                  <th>{t("tenantDetail.colAmount")}</th>
                  <th className="text-right">{t("tenantDetail.colBalance")}</th>
                  <th>{t("tenantDetail.colStatus")}</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {tenantInvoices.map((i) => (
                  <tr key={i.id}>
                    <td className="mono">
                      <Link to={`/admin/invoices/${i.id}`}>{i.invoice_number}</Link>
                    </td>
                    <td className="small muted">
                      {i.period_start
                        ? `${formatDate(i.period_start)} → ${formatDate(i.period_end)}`
                        : "—"}
                    </td>
                    <td>{i.invoice_types?.name}</td>
                    <td className="mono">{money(i.amount)}</td>
                    <td
                      className="text-right mono bold"
                      style={{
                        color:
                          i.balance > 0 ? "var(--danger)" : "var(--success)",
                      }}
                    >
                      {money(i.balance)}
                    </td>
                    <td>
                      <Badge value={i.status_key} />
                    </td>
                    <td>
                      <Button
                        variant="ghost"
                        size="sm"
                        disabled={i.is_void || i.balance <= 0}
                        onClick={() => setPayInvoice({ ...i })}
                      >
                        {t("tenantDetail.recordPayment")}
                      </Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {/* Mobile Card View */}
          <div className="detail-list">
            {tenantInvoices.map((i) => (
              <div key={i.id} className="detail-row">
                <Link
                  to={`/admin/invoices/${i.id}`}
                  className="dr-main"
                  style={{ textDecoration: "none", color: "inherit", flex: 1 }}
                >
                  <div className="dr-title dr-link">{i.invoice_number}</div>
                  <div className="dr-sub">
                    {i.invoice_types?.name}
                    {i.period_start
                      ? ` · ${formatDate(i.period_start)} → ${formatDate(i.period_end)}`
                      : ""}
                  </div>
                  <div className="dr-badges" style={{ marginTop: 4 }}>
                    <Badge value={i.status_key} />
                  </div>
                </Link>
                <div className="dr-right">
                  <div className={`dr-value${i.balance > 0 ? " dr-neg" : ""}`}>
                    {money(i.balance)}
                  </div>
                  <div className="small muted">
                    {t("invoiceDetail.balance")}
                  </div>
                  {i.balance > 0 && (
                    <Button
                      variant="ghost"
                      size="sm"
                      disabled={i.is_void || i.balance <= 0}
                      onClick={(e) => {
                        e.preventDefault();
                        setPayInvoice({ ...i });
                      }}
                      style={{ marginTop: 4 }}
                    >
                      {t("tenantDetail.recordPayment")}
                    </Button>
                  )}
                </div>
              </div>
            ))}

            {tenantInvoices.length === 0 && (
              <EmptyState
                icon="receipt"
                title={t("tenantDetail.noInvoices")}
                body={t("tenantDetail.noInvoicesBody")}
              />
            )}
          </div>
        </div>
      )}
      {tab === "history" && (
        <div className="card">
          <div className="card-header">
            <div className="card-title">{t("tenantDetail.rentHistory")}</div>
          </div>
          <div className="table-wrap desktop-table">
            <table className="table">
              <thead>
                <tr>
                  <th>{t("tenantDetail.colEffective")}</th>
                  <th>{t("tenantDetail.colFrom")}</th>
                  <th>{t("tenantDetail.colTo")}</th>
                  <th>{t("tenantDetail.colType")}</th>
                  <th>{t("tenantDetail.colBy")}</th>
                  <th>{t("tenantDetail.colNote")}</th>
                </tr>
              </thead>
              <tbody>
                {(history.data ?? []).map((h) => (
                  <tr key={h.id}>
                    <td>{formatDate(h.effective_date)}</td>
                    <td className="mono">{money(h.old_amount)}</td>
                    <td className="mono bold">{money(h.new_amount)}</td>
                    <td>
                      <Badge
                        value={h.change_type}
                        tone={
                          h.change_type === "manual"
                            ? "blue"
                            : h.change_type === "override"
                              ? "purple"
                              : "indigo"
                        }
                      >
                        {h.change_type}
                      </Badge>
                    </td>
                    <td className="small muted">{h.applied_by}</td>
                    <td className="small muted">{h.note || "—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="detail-list">
            {(history.data ?? []).map((h) => (
              <div key={h.id} className="detail-row">
                <div className="dr-main">
                  <div className="dr-title">
                    <Badge
                      value={h.change_type}
                      tone={
                        h.change_type === "manual"
                          ? "blue"
                          : h.change_type === "override"
                            ? "purple"
                            : "indigo"
                      }
                    >
                      {h.change_type}
                    </Badge>
                    <span className="muted small">
                      {" "}
                      · {formatDate(h.effective_date)}
                    </span>
                  </div>
                  <div className="dr-sub">
                    {money(h.old_amount)} → {money(h.new_amount)}
                    {h.note ? ` · ${h.note}` : ""}
                  </div>
                </div>
                <div className="dr-right">
                  <div className="dr-value">{money(h.new_amount)}</div>
                  <div className="small muted">{h.applied_by || "—"}</div>
                </div>
              </div>
            ))}
          </div>
          {(history.data ?? []).length === 0 && (
            <EmptyState
              icon="fileText"
              title={t("tenantDetail.noRentChanges")}
            />
          )}
        </div>
      )}

      {/* Add lease */}
      <Modal
        open={leaseOpen}
        onClose={() => setLeaseOpen(false)}
        title={t("tenantDetail.addLease")}
      >
        <form onSubmit={addLease}>
          <Field label={t("tenants.property")}>
            <Select
              value={leaseForm.property_id}
              onChange={(e) =>
                setLeaseForm({
                  ...leaseForm,
                  property_id: e.target.value,
                  unit_id: "",
                  seat_id: "",
                })
              }
            >
              <option value="">{t("tenantDetail.selectProperty")}</option>
              {(properties.data ?? []).map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name} ({p.property_types?.name})
                </option>
              ))}
            </Select>
          </Field>
          <Field
            label={
              selectedKind === "cottage" ? t("tenants.room") : t("tenants.unit")
            }
          >
            <Select
              required
              value={leaseForm.unit_id}
              onChange={(e) =>
                setLeaseForm({
                  ...leaseForm,
                  unit_id: e.target.value,
                  seat_id: "",
                })
              }
            >
              <option value="">{t("common.select")}…</option>
              {availableUnits.map((u) => (
                <option key={u.id} value={u.id}>
                  {u.unit_number} · {money(u.rent_amount)}
                </option>
              ))}
            </Select>
            {leaseForm.property_id && availableUnits.length === 0 && (
              <div className="hint">
                {t("tenants.noAvailableUnits", {
                  units:
                    selectedKind === "cottage"
                      ? t("tenants.rooms")
                      : t("tenants.unitsPlural"),
                })}
              </div>
            )}
          </Field>
          {leaseForm.unit_id &&
            selectedKind === "cottage" &&
            seats.length > 0 && (
              <Field label={t("tenants.seat")} hint={t("tenants.seatHint")}>
                <Select
                  value={leaseForm.seat_id}
                  onChange={(e) =>
                    setLeaseForm({ ...leaseForm, seat_id: e.target.value })
                  }
                >
                  {wholeUnitAvailable && (
                    <option value="">{t("tenants.wholeRoom")}</option>
                  )}
                  {seats.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.seat_number} · {money(s.rent_amount)}
                    </option>
                  ))}
                </Select>
              </Field>
            )}
          <div className="form-grid">
            <Field label={t("tenantDetail.startDate")}>
              <Input
                type="date"
                value={leaseForm.start_date}
                onChange={(e) =>
                  setLeaseForm({ ...leaseForm, start_date: e.target.value })
                }
              />
            </Field>
            <Field label={t("tenantDetail.endDateOptional")}>
              <Input
                type="date"
                value={leaseForm.end_date}
                onChange={(e) =>
                  setLeaseForm({ ...leaseForm, end_date: e.target.value })
                }
              />
            </Field>
          </div>
          <Field label={t("tenants.graceDays")}>
            <Input
              type="number"
              min={0}
              value={leaseForm.grace_days}
              onChange={(e) =>
                setLeaseForm({ ...leaseForm, grace_days: e.target.value })
              }
            />
          </Field>
          <div className="modal-actions">
            <Button
              type="button"
              variant="secondary"
              onClick={() => setLeaseOpen(false)}
            >
              {t("common.cancel")}
            </Button>
            <Button type="submit" disabled={saving}>
              {saving
                ? t("tenantDetail.creating")
                : t("tenantDetail.createLease")}
            </Button>
          </div>
        </form>
      </Modal>

      {/* Record payment */}
      {payInvoice && (
        <Modal
          open
          onClose={() => setPayInvoice(null)}
          title={`${t("tenantDetail.recordPayment")} · ${payInvoice.invoice_number}`}
        >
          <form onSubmit={recordPayment}>
            <div className="row-between mb-2">
              <span className="muted small">
                {t("tenantDetail.outstandingBalance")}
              </span>
              <span className="bold mono" style={{ color: "var(--danger)" }}>
                {money(payInvoice.balance)}
              </span>
            </div>
            <div className="form-grid">
              <Field label={t("tenantDetail.amount")}>
                <Input
                  type="number"
                  min="0.01"
                  step="0.01"
                  required
                  value={payForm.amount}
                  onChange={(e) =>
                    setPayForm({ ...payForm, amount: e.target.value })
                  }
                />
              </Field>
              <Field label={t("tenantDetail.method")}>
                <Select
                  value={payForm.method_key}
                  onChange={(e) =>
                    setPayForm({ ...payForm, method_key: e.target.value })
                  }
                >
                  {(lookups.paymentMethods ?? []).map((m) => (
                    <option key={m.key} value={m.key}>
                      {m.name}
                    </option>
                  ))}
                </Select>
              </Field>
            </div>
            <Field label={t("tenantDetail.paidAt")}>
              <Input
                type="datetime-local"
                value={payForm.paid_at}
                onChange={(e) =>
                  setPayForm({ ...payForm, paid_at: e.target.value })
                }
              />
            </Field>
            <Field label={t("tenantDetail.referenceOptional")}>
              <Input
                value={payForm.reference}
                onChange={(e) =>
                  setPayForm({ ...payForm, reference: e.target.value })
                }
                placeholder="e.g. bank ref"
              />
            </Field>
            <div className="modal-actions">
              <Button
                type="button"
                variant="secondary"
                onClick={() => setPayInvoice(null)}
              >
                {t("common.cancel")}
              </Button>
              <Button type="submit" disabled={saving}>
                {saving ? t("common.saving") : t("tenantDetail.recordPayment")}
              </Button>
            </div>
          </form>
        </Modal>
      )}

      {/* Rent increase config */}
      <Modal
        open={increaseOpen}
        onClose={() => setIncreaseOpen(false)}
        title={t("tenantDetail.annualIncrease")}
      >
        <form onSubmit={saveIncrease}>
          <p className="small muted" style={{ marginTop: 0 }}>
            {t("tenantDetail.increaseHint")}
          </p>
          <div className="row mb-2" style={{ gap: 10 }}>
            <label className="row" style={{ gap: 8 }}>
              <input
                type="checkbox"
                checked={incForm.enabled}
                onChange={(e) =>
                  setIncForm({ ...incForm, enabled: e.target.checked })
                }
              />
              <span className="small bold">
                {t("tenantDetail.enabledForTenant")}
              </span>
            </label>
          </div>
          <div className="form-grid">
            <Field label={t("tenantDetail.fixedAmount")}>
              <Input
                type="number"
                min={0}
                step="0.01"
                value={incForm.amount}
                onChange={(e) =>
                  setIncForm({ ...incForm, amount: e.target.value })
                }
              />
            </Field>
            <Field label={t("tenantDetail.percent")}>
              <Input
                type="number"
                min={0}
                step="0.1"
                value={incForm.percent}
                onChange={(e) =>
                  setIncForm({ ...incForm, percent: e.target.value })
                }
              />
            </Field>
          </div>
          <div className="modal-actions">
            <Button
              type="button"
              variant="secondary"
              onClick={() => setIncreaseOpen(false)}
            >
              {t("common.cancel")}
            </Button>
            <Button type="submit" disabled={saving}>
              {saving ? t("common.saving") : t("common.save")}
            </Button>
          </div>
        </form>
      </Modal>

      {/* Send a message to this tenant */}
      <Modal
        open={msgOpen}
        onClose={() => setMsgOpen(false)}
        title={t("tenantDetail.sendMessage")}
      >
        <form onSubmit={queueMessage}>
          {msgForm.template_key === "" && (
            <>
              <p className="small muted" style={{ marginTop: 0 }}>
                {t("tenantDetail.chooseMessageType")}
              </p>
              {templates.loading ? (
                <div className="hint" style={{ padding: "10px 0" }}>
                  {t("common.loading")}
                </div>
              ) : (
                <div className="list" style={{ marginBottom: 14 }}>
                  {tenantTemplates.map((tpl) => (
                    <button
                      key={tpl.id}
                      type="button"
                      className="btn btn-ghost"
                      style={{
                        display: "block",
                        width: "100%",
                        textAlign: "left",
                        padding: "10px 12px",
                        marginBottom: 8,
                      }}
                      onClick={() => pickTemplate(tpl)}
                    >
                      <span className="bold small">{tpl.subject}</span>
                      <div className="tiny muted">{tpl.body}</div>
                    </button>
                  ))}
                <button
                  type="button"
                  className="btn btn-ghost"
                  style={{
                    display: "block",
                    width: "100%",
                    textAlign: "left",
                    padding: "10px 12px",
                  }}
                  onClick={() => pickTemplate(null)}
                >
                  <span className="bold small">
                    {t("tenantDetail.customMessage")}
                  </span>
                  <div className="tiny muted">
                    {t("tenantDetail.customMessageHint")}
                  </div>
                </button>
              </div>
              )}
            </>
          )}

          {msgForm.template_key !== "" && (
            <>
              <div className="row-between mb-2">
                <span className="small bold">
                  {t("tenantDetail.messageType")}:{" "}
                  {msgForm.template_key === CUSTOM_KEY
                    ? t("tenantDetail.customMessage")
                    : msgForm.template_key}
                </span>
                <button
                  type="button"
                  className="auth-link-btn"
                  onClick={backToTypes}
                >
                  {t("tenantDetail.changeType")}
                </button>
              </div>
              <Field label={t("tenantDetail.subject")}>
                <Input
                  required
                  value={msgForm.subject}
                  onChange={(e) =>
                    setMsgForm({ ...msgForm, subject: e.target.value })
                  }
                />
              </Field>
              <Field label={t("tenantDetail.messageBody")}>
                <Textarea
                  required
                  value={msgForm.body}
                  onChange={(e) =>
                    setMsgForm({ ...msgForm, body: e.target.value })
                  }
                />
              </Field>
              <div className="modal-actions">
                <Button
                  type="button"
                  variant="secondary"
                  onClick={() => setMsgOpen(false)}
                >
                  {t("common.cancel")}
                </Button>
                <Button type="submit" disabled={queuing}>
                  {queuing
                    ? t("tenantDetail.queueing")
                    : t("tenantDetail.queueMessage")}
                </Button>
              </div>
            </>
          )}
        </form>
      </Modal>
    </div>
  );
}
