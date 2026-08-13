import { useState } from "react";
import { useTranslation } from "react-i18next";
import { supabase, callRpc } from "../lib/supabase";
import { useAuditLog } from "../hooks/useSettings";
import { usePagination } from "../hooks/usePagination";
import Button from "../components/ui/Button";
import Modal from "../components/ui/Modal";
import Badge from "../components/ui/Badge";
import Spinner from "../components/ui/Spinner";
import EmptyState from "../components/ui/EmptyState";
import Pagination from "../components/ui/Pagination";
import { Field, Input, Select } from "../components/ui/Input";
import Icon from "../components/ui/Icon";
import { useToast } from "../components/ui/Toast";
import { money, formatDate, formatDateTime } from "../lib/format";
import PublicDirectorySettings from "../components/admin/PublicDirectorySettings";
import FeedbackManager from "../components/admin/FeedbackManager";
import DirectoryApprovals from "../components/admin/DirectoryApprovals";

export default function AdminPage() {
  const { t } = useTranslation();
  const toast = useToast();
  const audit = useAuditLog();

  const [owners, setOwners] = useState(null);
  const [loadingOwners, setLoadingOwners] = useState(false);
  const [selected, setSelected] = useState(null);
  const [snapshot, setSnapshot] = useState(null);
  const [saving, setSaving] = useState(false);
  const [grantOpen, setGrantOpen] = useState(false);
  const [grantUserId, setGrantUserId] = useState("");

  const ownersPagination = usePagination(owners ?? [], 25);
  const auditPagination = usePagination(audit.logs ?? [], 25);

  const loadOwners = async () => {
    setLoadingOwners(true);
    try {
      const data = await callRpc("admin_list_owners");
      setOwners(data ?? []);
    } catch (err) {
      toast.error(err.message);
    } finally {
      setLoadingOwners(false);
    }
  };

  const openOwner = async (ownerId) => {
    setSelected(ownerId);
    setSnapshot(null);
    const data = await callRpc("admin_owner_snapshot", { p_owner_id: ownerId });
    setSnapshot(data);
  };

  const action = async (fn, args, success) => {
    setSaving(true);
    try {
      await callRpc(fn, args);
      toast.success(success);
      await loadOwners();
      if (selected) await openOwner(selected);
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSaving(false);
    }
  };

  const grantSuperAdmin = async (e) => {
    e.preventDefault();
    setSaving(true);
    try {
      const { error } = await supabase
        .from("super_admins")
        .insert({ user_id: grantUserId });
      if (error) throw error;
      toast.success(t("admin.granted"));
      setGrantOpen(false);
      setGrantUserId("");
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSaving(false);
    }
  };

  const [tab, setTab] = useState("owners");

  if (loadingOwners && !owners) return <Spinner />;

  return (
    <div>
      <div className="page-head">
        <div>
          <h1 className="page-title">{t("admin.title")}</h1>
          <div className="page-sub">
            {t("admin.subtitle")}
          </div>
        </div>
        <div className="row">
          <Button variant="secondary" size="sm" onClick={loadOwners}>
            <Icon name="refresh" size={14} /> {t("admin.reload")}
          </Button>
          <Button size="sm" onClick={() => setGrantOpen(true)}>
            <Icon name="shield" size={14} /> {t("admin.grantSuperAdmin")}
          </Button>
        </div>
      </div>

      <div className="tabs">
        <button
          className={`tab${tab === "owners" ? " active" : ""}`}
          onClick={() => setTab("owners")}
        >
          {t("admin.tabOwners")}
        </button>
        <button
          className={`tab${tab === "audit" ? " active" : ""}`}
          onClick={() => setTab("audit")}
        >
          {t("admin.tabAudit")}
        </button>
        <button
          className={`tab${tab === "public" ? " active" : ""}`}
          onClick={() => setTab("public")}
        >
          {t("admin.tabPublic")}
        </button>
        <button
          className={`tab${tab === "feedback" ? " active" : ""}`}
          onClick={() => setTab("feedback")}
        >
          {t("admin.tabFeedback")}
        </button>
      </div>

      {tab === "owners" && (
        <>
          {!owners && (
            <EmptyState
              icon="shield"
              title={t("admin.loadOwners")}
              body={t("admin.loadOwnersBody")}
              action={<Button onClick={loadOwners}>{t("admin.loadOwners")}</Button>}
            />
          )}

          {owners && (
            <div className="card table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>{t("admin.colBusiness")}</th>
                    <th>{t("admin.colKind")}</th>
                    <th>{t("admin.colPlan")}</th>
                    <th>{t("admin.colTrialEnds")}</th>
                    <th>{t("admin.colProps")}</th>
                    <th>{t("admin.colTenants")}</th>
                    <th className="text-right">{t("admin.colOutstanding")}</th>
                    <th>{t("admin.colAccess")}</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {ownersPagination.pageItems.map((o) => (
                    <tr key={o.owner_id}>
                      <td className="bold">{o.business_name}</td>
                      <td className="small">{o.property_kind}</td>
                      <td>
                        <Badge
                          value={o.subscription_status}
                          tone={
                            o.subscription_status === "active"
                              ? "green"
                              : o.subscription_status === "trial"
                                ? "indigo"
                                : "red"
                          }
                        >
                          {o.plan} · {o.subscription_status}
                        </Badge>
                      </td>
                      <td className="small">{formatDate(o.trial_ends_at)}</td>
                      <td className="mono">{o.properties_count}</td>
                      <td className="mono">{o.tenants_count}</td>
                      <td className="text-right mono">
                        {money(o.outstanding)}
                      </td>
                      <td>
                        <Badge
                          value={o.has_access ? "active" : "expired"}
                          tone={o.has_access ? "green" : "red"}
                        >
                          {o.has_access ? t("admin.granted") : t("admin.blocked")}
                        </Badge>
                      </td>
                      <td>
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={() => openOwner(o.owner_id)}
                        >
                          {t("admin.inspect")}
                        </Button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {owners.length === 0 ? (
                <EmptyState
                  icon="shield"
                  title={t("admin.noOwners")}
                  body={t("admin.noOwnersBody")}
                />
              ) : (
                <Pagination
                  page={ownersPagination.page}
                  totalPages={ownersPagination.totalPages}
                  totalItems={ownersPagination.totalItems}
                  pageSize={ownersPagination.pageSize}
                  onChange={ownersPagination.setPage}
                />
              )}
            </div>
          )}
        </>
      )}

      {tab === "audit" && (
        <div className="card">
          <div className="card-header">
            <div className="card-title">{t("admin.auditTitle")}</div>
            <span className="tiny muted">{t("admin.autoPurged")}</span>
          </div>
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>{t("admin.colWhen")}</th>
                  <th>{t("admin.colActor")}</th>
                  <th>{t("admin.colAction")}</th>
                  <th>{t("admin.colEntity")}</th>
                  <th>{t("admin.colMetadata")}</th>
                </tr>
              </thead>
              <tbody>
                {auditPagination.pageItems.map((a) => (
                  <tr key={a.id}>
                    <td className="small muted">
                      {formatDateTime(a.created_at)}
                    </td>
                    <td>
                      <Badge
                        value={a.actor_type}
                        tone={
                          a.actor_type === "super_admin"
                            ? "purple"
                            : a.actor_type === "owner"
                              ? "indigo"
                              : "gray"
                        }
                      >
                        {a.actor_type}
                      </Badge>
                    </td>
                    <td className="small bold">{a.action}</td>
                    <td className="small">
                      {a.entity_type}
                      {a.entity_id ? (
                        <span className="mono muted">
                          {" "}
                          · {a.entity_id.slice(0, 8)}
                        </span>
                      ) : null}
                    </td>
                    <td
                      className="small muted"
                      style={{
                        maxWidth: 260,
                        overflow: "hidden",
                        textOverflow: "ellipsis",
                      }}
                    >
                      {JSON.stringify(a.metadata)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {(audit.logs ?? []).length === 0 ? (
            <EmptyState
              icon="fileText"
              title={t("admin.noActivity")}
              body={t("admin.noActivityBody")}
            />
          ) : (
            <Pagination
              page={auditPagination.page}
              totalPages={auditPagination.totalPages}
              totalItems={auditPagination.totalItems}
              pageSize={auditPagination.pageSize}
              onChange={auditPagination.setPage}
            />
          )}
        </div>
      )}

      {tab === "public" && (
        <>
          <div className="card" style={{ maxWidth: 720 }}>
            <div className="card-header">
              <div className="card-title">{t("admin.publicationApprovalsTitle")}</div>
              <span className="tiny muted">{t("admin.publicationApprovalsSub")}</span>
            </div>
            <DirectoryApprovals />
          </div>
          <div className="card" style={{ maxWidth: 560 }}>
            <div className="card-header">
              <div className="card-title">{t("admin.publicSettingsTitle")}</div>
              <span className="tiny muted">{t("admin.publicSettingsSub")}</span>
            </div>
            <PublicDirectorySettings />
          </div>
        </>
      )}

      {tab === "feedback" && (
        <div className="card">
          <div className="card-header">
            <div className="card-title">{t("admin.feedbackTitle")}</div>
            <span className="tiny muted">{t("admin.feedbackSub")}</span>
          </div>
          <FeedbackManager />
        </div>
      )}

      {/* Owner inspect modal */}
      {selected && (
        <Modal
          open
          onClose={() => setSelected(null)}
          title={snapshot?.owner?.business_name || t("admin.owner")}
        >
          {!snapshot ? (
            <Spinner />
          ) : (
            <div>
              <div
                className="stats-grid"
                style={{
                  gridTemplateColumns: "repeat(auto-fit,minmax(110px,1fr))",
                  gap: 8,
                  marginBottom: 14,
                }}
              >
                <MiniStat label={t("admin.props")} value={snapshot.counts?.properties} />
                <MiniStat label={t("admin.units")} value={snapshot.counts?.units} />
                <MiniStat label={t("admin.tenants")} value={snapshot.counts?.tenants} />
                <MiniStat label={t("admin.invoices")} value={snapshot.counts?.invoices} />
                <MiniStat label={t("admin.payments")} value={snapshot.counts?.payments} />
              </div>

              <div className="row-between mb-2">
                <span className="muted small">{t("admin.subscription")}</span>
                <Badge value={snapshot.subscription?.status} />
              </div>
              <div className="row-between mb-2">
                <span className="muted small">{t("admin.outstanding")}</span>
                <span className="bold mono">{money(snapshot.outstanding)}</span>
              </div>
              <div className="row-between mb-2">
                <span className="muted small">{t("admin.trialEnds")}</span>
                <span className="small">
                  {formatDate(snapshot.subscription?.trial_ends_at)}
                </span>
              </div>

              <div className="form-grid" style={{ gridTemplateColumns: "1fr" }}>
                <Field label={t("admin.monthlyAmount")}>
                  <Input
                    type="number"
                    min={0}
                    step="0.01"
                    defaultValue={snapshot.subscription?.monthly_amount ?? 19}
                    id="admin-amount"
                  />
                </Field>
              </div>

              <div className="modal-actions" style={{ flexWrap: "wrap" }}>
                <Button
                  variant="secondary"
                  size="sm"
                  disabled={saving}
                  onClick={() =>
                    action(
                      "admin_activate_plan",
                      {
                        p_owner_id: selected,
                        p_monthly_amount:
                          Number(
                            document.getElementById("admin-amount").value,
                          ) || 19,
                      },
                      "Plan activated",
                    )
                  }
                >
                  {t("admin.activatePlan")}
                </Button>
                <Button
                  variant="secondary"
                  size="sm"
                  disabled={saving}
                  onClick={() =>
                    action(
                      "admin_record_subscription_payment",
                      {
                        p_owner_id: selected,
                        p_amount:
                          Number(
                            document.getElementById("admin-amount").value,
                          ) || 19,
                      },
                      "Payment recorded — period renewed",
                    )
                  }
                >
                  {t("admin.recordPayment")}
                </Button>
                <Select
                  defaultValue=""
                  style={{ flex: 1 }}
                  onChange={(e) =>
                    e.target.value &&
                    action(
                      "admin_set_subscription_status",
                      { p_owner_id: selected, p_status: e.target.value },
                      "Status updated",
                    ).then(() => (e.target.value = ""))
                  }
                >
                  <option value="">{t("admin.setStatus")}</option>
                  <option value="active">{t("admin.active")}</option>
                  <option value="past_due">{t("admin.pastDue")}</option>
                  <option value="cancelled">{t("admin.cancelled")}</option>
                  <option value="expired">{t("admin.expired")}</option>
                  <option value="trial">{t("admin.trial")}</option>
                </Select>
              </div>

              {snapshot.recent_audit && snapshot.recent_audit.length > 0 && (
                <>
                  <div className="bold small mt-3 mb-2">{t("admin.recentActivity")}</div>
                  {snapshot.recent_audit.map((a, i) => (
                    <div
                      key={i}
                      className="row-between"
                      style={{
                        padding: "6px 0",
                        borderBottom: "1px solid var(--border)",
                      }}
                    >
                      <span className="small">{a.action}</span>
                      <span className="tiny muted">
                        {formatDateTime(a.created_at)}
                      </span>
                    </div>
                  ))}
                </>
              )}
            </div>
          )}
        </Modal>
      )}

      {/* Grant super admin */}
      <Modal
        open={grantOpen}
        onClose={() => setGrantOpen(false)}
        title={t("admin.grantSuperAdmin")}
      >
        <form onSubmit={grantSuperAdmin}>
          <Field
            label={t("admin.userId")}
            hint={t("admin.userIdHint")}
          >
            <Input
              required
              value={grantUserId}
              onChange={(e) => setGrantUserId(e.target.value)}
              placeholder="00000000-…"
            />
          </Field>
          <div className="modal-actions">
            <Button
              type="button"
              variant="secondary"
              onClick={() => setGrantOpen(false)}
            >
              {t("common.cancel")}
            </Button>
            <Button type="submit" disabled={saving}>
              {saving ? t("admin.granting") : t("admin.grantAccess")}
            </Button>
          </div>
        </form>
      </Modal>
    </div>
  );
}

function MiniStat({ label, value }) {
  return (
    <div className="stat" style={{ padding: "10px 12px" }}>
      <div className="stat-label" style={{ fontSize: 11 }}>
        {label}
      </div>
      <div className="stat-value" style={{ fontSize: 18 }}>
        {value ?? 0}
      </div>
    </div>
  );
}
