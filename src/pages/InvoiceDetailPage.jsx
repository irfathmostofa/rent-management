import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { callRpc } from "../lib/supabase";
import { useInvoice } from "../hooks/useInvoices";
import { useLookups } from "../hooks/useLookups";
import Button from "../components/ui/Button";
import { Field, Input, Select } from "../components/ui/Input";
import Modal from "../components/ui/Modal";
import Badge from "../components/ui/Badge";
import Spinner from "../components/ui/Spinner";
import EmptyState from "../components/ui/EmptyState";
import ConfirmDialog from "../components/ui/ConfirmDialog";
import Icon from "../components/ui/Icon";
import { useToast } from "../components/ui/Toast";
import { money, formatDate, formatDateTime, fullName } from "../lib/format";

export default function InvoiceDetailPage() {
  const { t } = useTranslation();
  const { id } = useParams();
  const invoice = useInvoice(id);
  const lookups = useLookups();
  const toast = useToast();

  const [payOpen, setPayOpen] = useState(false);
  const [fineOpen, setFineOpen] = useState(false);
  const [voidOpen, setVoidOpen] = useState(false);
  const [saving, setSaving] = useState(false);

  const [payForm, setPayForm] = useState({
    amount: "",
    method_key: "bank_transfer",
    paid_at: new Date().toISOString().slice(0, 16),
    reference: "",
  });
  const [fineForm, setFineForm] = useState({ amount: "", reason: "" });

  // The component instance persists across navigation between
  // /invoices/:id routes (same route pattern, only the param changes), so
  // any stale form state or open modal from a previous invoice must be
  // cleared explicitly when the id changes — otherwise a leftover payment
  // amount from a bigger invoice can silently exceed the new invoice's
  // balance and blow the `amount_paid <= amount` check constraint.
  useEffect(() => {
    setPayOpen(false);
    setFineOpen(false);
    setVoidOpen(false);
    setPayForm({
      amount: "",
      method_key: "bank_transfer",
      paid_at: new Date().toISOString().slice(0, 16),
      reference: "",
    });
    setFineForm({ amount: "", reason: "" });
  }, [id]);

  const inv = invoice.data?.[0];

  if (invoice.loading) return <Spinner />;
  if (!inv) return <EmptyState icon="search" title={t("invoiceDetail.notFound")} />;

  const recordPayment = async (e) => {
    e.preventDefault();

    const amount = Number(payForm.amount);
    if (amount > Number(inv.balance)) {
      toast.error(
        t("invoiceDetail.amountExceeds", { balance: money(inv.balance) }),
      );
      return;
    }

    setSaving(true);
    try {
      await callRpc("record_payment", {
        p_invoice_id: id,
        p_amount: amount,
        p_method_key: payForm.method_key,
        p_paid_at: new Date(payForm.paid_at).toISOString(),
        p_reference: payForm.reference || null,
      });
      toast.success(t("invoiceDetail.paymentRecorded"));
      setPayOpen(false);
      setPayForm({
        amount: "",
        method_key: "bank_transfer",
        paid_at: new Date().toISOString().slice(0, 16),
        reference: "",
      });
      // Realtime only patches the base `invoices` row — the joined
      // `payments`/`lines` relations on this hook won't update on their
      // own, so refetch explicitly to bring in the new payment + balance.
      await invoice.refresh();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSaving(false);
    }
  };

  const createFine = async (e) => {
    e.preventDefault();
    setSaving(true);
    try {
      const fine = await callRpc("create_fine", {
        p_tenant_id: inv.tenant_id,
        p_amount: Number(fineForm.amount),
        p_reason: fineForm.reason,
        p_rent_invoice_id: inv.invoice_type_key === "rent" ? inv.id : null,
      });
      toast.success(t("invoiceDetail.fineCreated", { number: fine.invoice_number }));
      setFineOpen(false);
      setFineForm({ amount: "", reason: "" });
      await invoice.refresh();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSaving(false);
    }
  };

  const voidIt = async () => {
    try {
      await callRpc("void_invoice", {
        p_invoice_id: id,
        p_reason: t("invoiceDetail.voidedByOwner"),
      });
      toast.success(t("invoiceDetail.invoiceVoided"));
      await invoice.refresh();
    } catch (err) {
      toast.error(err.message);
    }
  };

  const payments = inv.payments ?? [];

  return (
    <div>
      <Link to="/admin/invoices" className="btn btn-ghost btn-sm mb-2">
        <Icon name="arrowLeft" size={15} /> {t("common.back")}
      </Link>

      <div className="page-head">
        <div>
          <h1 className="page-title mono">{inv.invoice_number}</h1>
          <div className="page-sub">
            <Link
              to={`/admin/tenants/${inv.tenant_id}?tab=invoices`}
              state={{ from: `/admin/invoices/${inv.id}` }}
              style={{ color: "var(--primary)", fontWeight: 600 }}
            >
              {fullName(inv.tenant)}
            </Link>
            {" · "}
            {inv.invoice_types?.name || inv.invoice_type_key}
            {" · "}
            {inv.period_start
              ? `${formatDate(inv.period_start)} → ${formatDate(inv.period_end)}`
              : `${t("invoiceDetail.issued")} ${formatDate(inv.issue_date)}`}
          </div>
        </div>
        <div className="row">
          {!inv.is_void && inv.invoice_type_key === "rent" && (
            <Button
              variant="secondary"
              size="sm"
              onClick={() => setFineOpen(true)}
            >
              {t("invoiceDetail.addFine")}
            </Button>
          )}
          {!inv.is_void && inv.balance > 0 && (
            <Button size="sm" onClick={() => setPayOpen(true)}>
              {t("invoiceDetail.recordPayment")}
            </Button>
          )}
        </div>
      </div>

      <div className="stats-grid mb-3">
        <div className="stat">
          <div className="stat-label">{t("invoiceDetail.amount")}</div>
          <div className="stat-value">{money(inv.amount)}</div>
        </div>
        <div className="stat">
          <div className="stat-label">{t("invoiceDetail.paid")}</div>
          <div className="stat-value green">{money(inv.amount_paid)}</div>
        </div>
        <div className="stat">
          <div className="stat-label">{t("invoiceDetail.balance")}</div>
          <div
            className="stat-value"
            style={{
              color: inv.balance > 0 ? "var(--danger)" : "var(--success)",
            }}
          >
            {inv.is_void ? "—" : money(inv.balance)}
          </div>
        </div>
        <div className="stat">
          <div className="stat-label">{t("invoiceDetail.due")}</div>
          <div className="stat-value" style={{ fontSize: 18, paddingTop: 8 }}>
            <Badge value={inv.is_void ? "void" : inv.status_key} />
            {inv.due_date ? (
              <div className="small muted mt-1">{formatDate(inv.due_date)}</div>
            ) : null}
          </div>
        </div>
      </div>

      {inv.fine_reason && (
        <div
          className="card card-pad mb-3"
          style={{ borderLeft: "3px solid var(--danger)" }}
        >
          <div className="bold small">{t("invoiceDetail.fineReason")}</div>
          <div className="small">{inv.fine_reason}</div>
        </div>
      )}
      {inv.is_void && (
        <div
          className="card card-pad mb-3"
          style={{ borderLeft: "3px solid var(--muted)" }}
        >
          <div className="bold small muted">
            {t("invoiceDetail.voided")}
            {inv.voided_at ? ` · ${formatDateTime(inv.voided_at)}` : ""}
          </div>
          <div className="small">{inv.void_reason}</div>
        </div>
      )}

      <div className="grid-2">
        <div className="card">
          <div className="card-header">
            <div className="card-title">{t("invoiceDetail.lineItems")}</div>
          </div>
          <div className="table-wrap desktop-table">
            <table className="table">
              <thead>
                <tr>
                  <th>{t("invoiceDetail.colDescription")}</th>
                  <th className="text-right">{t("invoiceDetail.colAmount")}</th>
                </tr>
              </thead>
              <tbody>
                {(inv.lines ?? []).map((l) => (
                  <tr key={l.id}>
                    <td className="small">
                      {l.description || t("invoiceDetail.seatLabel", { seatId: l.seat_id || "" })}
                    </td>
                    <td className="text-right mono">{money(l.amount)}</td>
                  </tr>
                ))}
                <tr>
                  <td className="bold">{t("invoiceDetail.total")}</td>
                  <td className="text-right mono bold">{money(inv.amount)}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <div className="detail-list">
            {(inv.lines ?? []).map((l) => (
              <div key={l.id} className="detail-row">
                <div className="dr-main">
                  <div className="dr-sub">
                    {l.description ||
                      t("invoiceDetail.seatLabel", { seatId: l.seat_id || "" })}
                  </div>
                </div>
                <div className="dr-right">
                  <div className="dr-value">{money(l.amount)}</div>
                </div>
              </div>
            ))}
            <div className="detail-row">
              <div className="dr-main">
                <div className="dr-title">{t("invoiceDetail.total")}</div>
              </div>
              <div className="dr-right">
                <div className="dr-value">{money(inv.amount)}</div>
              </div>
            </div>
          </div>
        </div>

        <div className="card">
          <div className="card-header">
            <div className="card-title">{t("invoiceDetail.payments")}</div>
          </div>
          {payments.length === 0 ? (
            <EmptyState
              icon="wallet"
              title={t("invoiceDetail.noPayments")}
              body={t("invoiceDetail.noPaymentsBody")}
            />
          ) : (
            <>
              <div className="table-wrap desktop-table">
                <table className="table">
                  <thead>
                    <tr>
                      <th>{t("invoiceDetail.colWhen")}</th>
                      <th>{t("invoiceDetail.colMethod")}</th>
                      <th>{t("invoiceDetail.colRef")}</th>
                      <th className="text-right">{t("invoiceDetail.colAmount")}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {payments.map((p) => (
                      <tr key={p.id}>
                        <td className="small">{formatDateTime(p.paid_at)}</td>
                        <td>
                          <Badge value={p.method_key} />
                        </td>
                        <td className="small muted">{p.reference || "—"}</td>
                        <td
                          className="text-right mono green"
                          style={{ color: "var(--success)" }}
                        >
                          {money(p.amount)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <div className="detail-list">
                {payments.map((p) => (
                  <div key={p.id} className="detail-row">
                    <div className="dr-main">
                      <div className="dr-title">
                        <Badge value={p.method_key} />
                      </div>
                      <div className="dr-sub">
                        {formatDateTime(p.paid_at)}
                        {p.reference ? ` · ${p.reference}` : ""}
                      </div>
                    </div>
                    <div className="dr-right">
                      <div className="dr-value dr-pos">{money(p.amount)}</div>
                    </div>
                  </div>
                ))}
              </div>
            </>
          )}
          {!inv.is_void && inv.balance > 0 && (
            <div className="card-pad" style={{ paddingTop: 8 }}>
              <Button
                variant="secondary"
                block
                onClick={() => setPayOpen(true)}
              >
                {t("invoiceDetail.recordPayment")}
              </Button>
            </div>
          )}
          {!inv.is_void && inv.amount_paid === 0 && (
            <div className="card-pad" style={{ paddingTop: 4 }}>
              <Button
                variant="danger-ghost"
                block
                size="sm"
                onClick={() => setVoidOpen(true)}
              >
                {t("invoiceDetail.voidInvoice")}
              </Button>
            </div>
          )}
        </div>
      </div>

      {/* Record payment modal */}
      <Modal
        open={payOpen}
        onClose={() => setPayOpen(false)}
        title={`${t("invoiceDetail.recordPayment")} · ${inv.invoice_number}`}
      >
        <form onSubmit={recordPayment}>
          <div className="row-between mb-2">
            <span className="muted small">{t("invoiceDetail.outstanding")}</span>
            <span className="bold mono" style={{ color: "var(--danger)" }}>
              {money(inv.balance)}
            </span>
          </div>
          <div className="form-grid">
            <Field label={t("invoiceDetail.amount")}>
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
            <Field label={t("invoiceDetail.method")}>
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
          <Field label={t("invoiceDetail.paidAt")}>
            <Input
              type="datetime-local"
              value={payForm.paid_at}
              onChange={(e) =>
                setPayForm({ ...payForm, paid_at: e.target.value })
              }
            />
          </Field>
          <Field label={t("invoiceDetail.reference")}>
            <Input
              value={payForm.reference}
              onChange={(e) =>
                setPayForm({ ...payForm, reference: e.target.value })
              }
            />
          </Field>
          <div className="modal-actions">
            <Button
              type="button"
              variant="secondary"
              onClick={() => setPayOpen(false)}
            >
              {t("common.cancel")}
            </Button>
            <Button type="submit" disabled={saving}>
              {saving ? t("common.saving") : t("invoiceDetail.record")}
            </Button>
          </div>
        </form>
      </Modal>

      {/* Fine modal */}
      <Modal
        open={fineOpen}
        onClose={() => setFineOpen(false)}
        title={t("invoiceDetail.addFine")}
      >
        <form onSubmit={createFine}>
          <p className="small muted" style={{ marginTop: 0 }}>
            {t("invoiceDetail.fineHint")}
          </p>
          <div className="form-grid">
            <Field label={t("invoiceDetail.amount")}>
              <Input
                type="number"
                min="0.01"
                step="0.01"
                required
                value={fineForm.amount}
                onChange={(e) =>
                  setFineForm({ ...fineForm, amount: e.target.value })
                }
              />
            </Field>
            <Field label={t("invoiceDetail.reason")}>
              <Input
                required
                value={fineForm.reason}
                onChange={(e) =>
                  setFineForm({ ...fineForm, reason: e.target.value })
                }
                placeholder={t("invoiceDetail.reasonPlaceholder")}
              />
            </Field>
          </div>
          <div className="modal-actions">
            <Button
              type="button"
              variant="secondary"
              onClick={() => setFineOpen(false)}
            >
              {t("common.cancel")}
            </Button>
            <Button type="submit" disabled={saving}>
              {saving ? t("invoiceDetail.creating") : t("invoiceDetail.createFine")}
            </Button>
          </div>
        </form>
      </Modal>

      <ConfirmDialog
        open={voidOpen}
        onClose={() => setVoidOpen(false)}
        onConfirm={voidIt}
        danger
        title={t("invoiceDetail.voidTitle")}
        body={t("invoiceDetail.voidBody")}
        confirmLabel={t("invoiceDetail.voidInvoice")}
      />
    </div>
  );
}
