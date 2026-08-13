import { useState } from "react";
import { useTranslation } from "react-i18next";
import { callRpc } from "../lib/supabase";
import { supabase } from "../lib/supabase";
import { useMessages, useMessageTemplates } from "../hooks/useMessaging";
import { useTenants } from "../hooks/useTenants";
import { useOwnerId } from "../auth/AuthContext";
import { usePagination } from "../hooks/usePagination";
import Button from "../components/ui/Button";
import { Field, Input, Textarea, Select } from "../components/ui/Input";
import Modal from "../components/ui/Modal";
import Badge from "../components/ui/Badge";
import Spinner from "../components/ui/Spinner";
import EmptyState from "../components/ui/EmptyState";
import Pagination from "../components/ui/Pagination";
import QuickAction from "../components/layout/QuickAction";
import Icon from "../components/ui/Icon";
import { useToast } from "../components/ui/Toast";
import { formatDateTime, fullName } from "../lib/format";

const TEMPLATE_VARIABLES = [
  ["{name}", "Tenant full name"],
  ["{invoice}", "Invoice number"],
  ["{amount}", "Invoice amount"],
  ["{balance}", "Outstanding balance"],
  ["{days}", "Days overdue"],
  ["{date}", "Effective date"],
  ["{body}", "Raw body"],
];

export default function MessagingPage() {
  const { t } = useTranslation();
  const { data, loading, refresh } = useMessages();
  const templates = useMessageTemplates();
  const tenants = useTenants();
  const ownerId = useOwnerId();
  const toast = useToast();

  const [tab, setTab] = useState("outbox");
  const [open, setOpen] = useState(false);
  const [tplOpen, setTplOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [form, setForm] = useState({
    subject: "Announcement",
    body: "",
    scope: "all",
    tenant_ids: [],
    template_key: "",
  });
  const [tplForm, setTplForm] = useState({
    key: "",
    channel_group: "tenant_facing",
    subject: "",
    body: "",
    is_active: true,
  });

  const messages = data ?? [];
  const queued = messages.filter((m) => m.status === "queued").length;
  const sent = messages.filter((m) => m.status === "sent").length;
  const failed = messages.filter((m) => m.status === "failed").length;

  const {
    pageItems: pageMessages,
    page,
    setPage,
    totalPages,
    totalItems,
    pageSize,
  } = usePagination(messages, 25);

  const send = async (e) => {
    e.preventDefault();
    setSaving(true);
    try {
      const args = {
        p_subject: form.subject,
        p_body: form.body,
        p_tenant_ids: form.scope === "all" ? null : form.tenant_ids,
      };
      await callRpc("create_announcement", args);
      toast.success(t("messaging.toastQueued"));
      setOpen(false);
      refresh();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSaving(false);
    }
  };

  const applyTemplate = (t) => {
    setForm({
      subject: t.subject,
      body: t.body,
      scope: "all",
      tenant_ids: [],
      template_key: t.key,
    });
    setOpen(true);
  };

  const insertVariable = (v) =>
    setForm((f) => ({ ...f, body: `${f.body}${f.body ? " " : ""}${v}` }));

  const saveTemplate = async (e) => {
    e.preventDefault();
    setSaving(true);
    try {
      const { error } = await supabase
        .from("message_templates")
        .insert({ ...tplForm, owner_id: ownerId });
      if (error) throw error;
      toast.success(t("messaging.toastTemplateSaved"));
      setTplOpen(false);
      setTplForm({
        key: "",
        channel_group: "tenant_facing",
        subject: "",
        body: "",
        is_active: true,
      });
      templates.refresh();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSaving(false);
    }
  };

  const manualDispatch = async () => {
    try {
      const res = await fetch("/api/dispatch-sms", { method: "POST" });
      const contentType = res.headers.get("content-type") || "";
      if (!res.ok || !contentType.includes("application/json")) {
        throw new Error(`dispatch api unavailable (${res.status})`);
      }
      const data = await res.json();
      toast.success(`${t("messaging.toastDispatched")} · ${data.dispatched}`);
    } catch {
      // Local dev has no serverless function yet: fall back to the simulated RPC.
      await callRpc("dispatch_queued_messages");
      toast.success(t("messaging.toastDispatched"));
    }
    refresh();
  };

  if (loading) return <Spinner />;

  const activeTenants = (tenants.data ?? []).filter(
    (t) => t.status === "active",
  );

  const toggleTenant = (id) =>
    setForm((f) => ({
      ...f,
      tenant_ids: f.tenant_ids.includes(id)
        ? f.tenant_ids.filter((x) => x !== id)
        : [...f.tenant_ids, id],
    }));

  return (
    <div>
      <div className="page-head">
        <div>
          <h1 className="page-title">{t("messaging.title")}</h1>
          <div className="page-sub">{t("messaging.subtitle")}</div>
        </div>
        <div className="header-actions">
          <Button onClick={() => setOpen(true)}>
            <Icon name="message" size={16} /> {t("messaging.newAnnouncement")}
          </Button>
        </div>
      </div>

      <div className="tabs">
        <button
          className={`tab${tab === "outbox" ? " active" : ""}`}
          onClick={() => setTab("outbox")}
        >
          {t("messaging.tabOutbox")}
        </button>
        <button
          className={`tab${tab === "templates" ? " active" : ""}`}
          onClick={() => setTab("templates")}
        >
          {t("messaging.tabTemplates")}
        </button>
      </div>

      {tab === "outbox" && (
        <>
          <div className="stats-grid mb-3">
            <div className="stat">
              <div className="stat-label">{t("messaging.queued")}</div>
              <div
                className="stat-value"
                style={{ fontSize: 20, paddingTop: 6 }}
              >
                {queued}
              </div>
            </div>
            <div className="stat">
              <div className="stat-label">{t("messaging.sent")}</div>
              <div
                className="stat-value green"
                style={{ fontSize: 20, paddingTop: 6 }}
              >
                {sent}
              </div>
            </div>
            <div className="stat">
              <div className="stat-label">{t("messaging.failed")}</div>
              <div
                className="stat-value"
                style={{
                  fontSize: 20,
                  paddingTop: 6,
                  color: failed > 0 ? "var(--danger)" : undefined,
                }}
              >
                {failed}
              </div>
            </div>
          </div>

          <div className="row-between mb-2">
            <div className="bold">{t("messaging.outbox")}</div>
            <Button variant="secondary" size="sm" onClick={manualDispatch}>
              <Icon name="refresh" size={14} /> {t("messaging.dispatchNow")}
            </Button>
          </div>

          <div className="desktop-table">
            <div className="card table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>{t("messaging.colWhen")}</th>
                    <th>{t("messaging.colRecipient")}</th>
                    <th>{t("messaging.colChannel")}</th>
                    <th>{t("messaging.colTemplate")}</th>
                    <th>{t("messaging.colStatus")}</th>
                    <th>{t("messaging.colBody")}</th>
                  </tr>
                </thead>
                <tbody>
                  {pageMessages.map((m) => (
                    <tr key={m.id}>
                      <td className="small muted">
                        {formatDateTime(m.scheduled_at)}
                      </td>
                      <td className="small">{m.recipient_ref || t("messaging.owner")}</td>
                      <td>
                        <Badge
                          value={m.channel}
                          tone={
                            m.channel === "email"
                              ? "indigo"
                              : m.channel === "in_app"
                                ? "purple"
                                : "blue"
                          }
                        >
                          {m.channel}
                        </Badge>
                      </td>
                      <td className="small">{m.template_key || "—"}</td>
                      <td>
                        <Badge value={m.status} />
                      </td>
                      <td className="small muted" style={{ maxWidth: 280 }}>
                        {m.body}
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
            {pageMessages.map((m) => (
              <div
                key={m.id}
                className="list-card"
                style={{ alignItems: "flex-start" }}
              >
                <div
                  className="avatar alt"
                  style={{ width: 36, height: 36, fontSize: 13 }}
                >
                  <Icon name="message" size={15} />
                </div>
                <div className="body">
                  <div className="l-title small">
                    {m.channel} · {m.recipient_ref || t("messaging.owner")}
                  </div>
                  <div className="l-sub" style={{ whiteSpace: "normal" }}>
                    {m.body}
                  </div>
                </div>
                <div className="right">
                  <Badge value={m.status} />
                </div>
              </div>
            ))}
            <Pagination
              page={page}
              totalPages={totalPages}
              totalItems={totalItems}
              pageSize={pageSize}
              onChange={setPage}
            />
          </div>

          {messages.length === 0 && (
            <EmptyState
              icon="message"
              title={t("messaging.emptyTitle")}
              body={t("messaging.emptyBody")}
              action={
                <Button onClick={() => setOpen(true)}>
                  <Icon name="message" size={16} /> {t("messaging.newAnnouncement")}
                </Button>
              }
            />
          )}
        </>
      )}

      {tab === "templates" && (
        <div className="card">
          <div className="card-header">
            <div className="card-title">{t("messaging.templatesTitle")}</div>
            <Button
              variant="secondary"
              size="sm"
              onClick={() => setTplOpen(true)}
            >
              <Icon name="plus" size={14} /> {t("messaging.newTemplate")}
            </Button>
          </div>
          {(templates.data ?? []).length === 0 ? (
            <EmptyState
              icon="fileText"
              title={t("messaging.noTemplatesTitle")}
              body={t("messaging.noTemplatesBody")}
            />
          ) : (
            (templates.data ?? []).map((tpl) => (
              <div key={tpl.id} className="detail-row">
                <div className="dr-main">
                  <div className="dr-title">{tpl.subject}</div>
                  <div className="dr-sub">{tpl.body}</div>
                  <div className="tiny muted">
                    {tpl.key} · {tpl.channel_group}
                  </div>
                </div>
                <div className="dr-right">
                  <Button
                    variant="secondary"
                    size="sm"
                    onClick={() => applyTemplate(tpl)}
                  >
                    <Icon name="message" size={14} /> {t("messaging.send")}
                  </Button>
                </div>
              </div>
            ))
          )}
        </div>
      )}

      <QuickAction onClick={() => setOpen(true)} label={t("messaging.newAnnouncement")} />

      {/* Compose / send */}
      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title={t("messaging.newAnnouncement")}
      >
        <form onSubmit={send}>
          <Field label={t("messaging.subject")}>
            <Input
              required
              value={form.subject}
              onChange={(e) => setForm({ ...form, subject: e.target.value })}
            />
          </Field>
          <Field label={t("messaging.message")}>
            <Textarea
              required
              value={form.body}
              onChange={(e) => setForm({ ...form, body: e.target.value })}
            />
          </Field>
          <div className="mb-2">
            <div className="bold small mb-1">{t("messaging.insertVariable")}</div>
            <div className="row" style={{ flexWrap: "wrap", gap: 6 }}>
              {TEMPLATE_VARIABLES.map(([v]) => (
                <button
                  key={v}
                  type="button"
                  className="btn btn-ghost btn-sm"
                  onClick={() => insertVariable(v)}
                  title={t(`messaging.var.${v.replace(/[{}]/g, "")}`)}
                >
                  {v}
                </button>
              ))}
            </div>
          </div>
          <Field label={t("messaging.sendTo")}>
            <select
              className="select"
              value={form.scope}
              onChange={(e) => setForm({ ...form, scope: e.target.value })}
            >
              <option value="all">{t("messaging.allActiveTenants")}</option>
              <option value="selected">{t("messaging.selectedTenants")}</option>
            </select>
          </Field>
          {form.scope === "selected" && (
            <div className="card" style={{ maxHeight: 220, overflowY: "auto" }}>
              {activeTenants.map((t) => (
                <label
                  key={t.id}
                  className="row"
                  style={{
                    padding: "8px 12px",
                    gap: 10,
                    borderBottom: "1px solid var(--border)",
                  }}
                >
                  <input
                    type="checkbox"
                    checked={form.tenant_ids.includes(t.id)}
                    onChange={() => toggleTenant(t.id)}
                  />
                  <span className="small">{fullName(t)}</span>
                </label>
              ))}
            </div>
          )}
          <div className="modal-actions">
            <Button
              type="button"
              variant="secondary"
              onClick={() => setOpen(false)}
            >
              {t("common.cancel")}
            </Button>
            <Button type="submit" disabled={saving}>
              {saving ? t("messaging.queueing") : t("messaging.sendAnnouncement")}
            </Button>
          </div>
        </form>
      </Modal>

      {/* New template */}
      <Modal
        open={tplOpen}
        onClose={() => setTplOpen(false)}
        title={t("messaging.newTemplateTitle")}
      >
        <form onSubmit={saveTemplate}>
          <div className="form-grid">
            <Field label={t("messaging.key")} hint={t("messaging.keyHint")}>
              <Input
                required
                value={tplForm.key}
                onChange={(e) =>
                  setTplForm({ ...tplForm, key: e.target.value })
                }
                placeholder="welcome_message"
              />
            </Field>
            <Field label={t("messaging.channelGroup")}>
              <Select
                value={tplForm.channel_group}
                onChange={(e) =>
                  setTplForm({ ...tplForm, channel_group: e.target.value })
                }
              >
                <option value="tenant_facing">{t("messaging.tenantFacing")}</option>
                <option value="owner_facing">{t("messaging.ownerFacing")}</option>
              </Select>
            </Field>
          </div>
          <Field label={t("messaging.subject")}>
            <Input
              required
              value={tplForm.subject}
              onChange={(e) =>
                setTplForm({ ...tplForm, subject: e.target.value })
              }
            />
          </Field>
          <Field
            label={t("messaging.body")}
            hint={t("messaging.bodyHint")}
          >
            <Textarea
              required
              value={tplForm.body}
              onChange={(e) => setTplForm({ ...tplForm, body: e.target.value })}
            />
          </Field>
          <label className="row" style={{ gap: 8, marginBottom: 12 }}>
            <input
              type="checkbox"
              checked={tplForm.is_active}
              onChange={(e) =>
                setTplForm({ ...tplForm, is_active: e.target.checked })
              }
            />
            <span className="small">{t("messaging.active")}</span>
          </label>
          <div className="modal-actions">
            <Button
              type="button"
              variant="secondary"
              onClick={() => setTplOpen(false)}
            >
              {t("common.cancel")}
            </Button>
            <Button type="submit" disabled={saving}>
              {saving ? t("messaging.saving") : t("messaging.saveTemplate")}
            </Button>
          </div>
        </form>
      </Modal>
    </div>
  );
}
