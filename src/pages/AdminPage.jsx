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
  const [visitors, setVisitors] = useState([]);
  const [loadingVisitors, setLoadingVisitors] = useState(false);

  const ownersPagination = usePagination(owners ?? [], 25);
  const auditPagination = usePagination(audit.logs ?? [], 25);
  const visitorsPagination = usePagination(visitors ?? [], 25);

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

  const loadVisitors = async () => {
    setLoadingVisitors(true);
    try {
      console.log("Loading visitors from Supabase...");

      const { data, error } = await supabase
        .from("visitors")
        .select("*")
        .order("visited_at", { ascending: false });

      if (error) {
        console.error("Error fetching visitors:", error);
        throw error;
      }

      console.log("Visitors data:", data);
      setVisitors(data ?? []);

      if (data && data.length > 0) {
        toast.success(`${data.length} visitors loaded`);
      }
    } catch (err) {
      console.error("Error in loadVisitors:", err);
      toast.error(err.message || "Failed to load visitors");
      setVisitors([]);
    } finally {
      setLoadingVisitors(false);
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
      toast.success("Super admin granted");
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
          <div className="page-sub">{t("admin.subtitle")}</div>
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
        <button
          className={`tab${tab === "visitors" ? " active" : ""}`}
          onClick={() => {
            setTab("visitors");
            loadVisitors();
          }}
        >
          Visitors
        </button>
      </div>

      {tab === "owners" && (
        <>
          {!owners && (
            <EmptyState
              icon="shield"
              title={t("admin.loadOwners")}
              body={t("admin.loadOwnersBody")}
              action={
                <Button onClick={loadOwners}>{t("admin.loadOwners")}</Button>
              }
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
                          {o.has_access ? "Active" : "Blocked"}
                        </Badge>
                      </td>
                      <td>
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={() => openOwner(o.owner_id)}
                        >
                          Inspect
                        </Button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {owners.length === 0 ? (
                <EmptyState
                  icon="shield"
                  title="No owners found"
                  body="There are no owners in the system yet."
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
              title="No activity"
              body="No audit logs available yet."
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
              <div className="card-title">
                {t("admin.publicationApprovalsTitle")}
              </div>
              <span className="tiny muted">
                {t("admin.publicationApprovalsSub")}
              </span>
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

      {tab === "visitors" && (
        <div className="card">
          <div className="card-header">
            <div className="card-title">Public Directory Visitors</div>
            <span className="tiny muted">
              People who accessed the public directory
            </span>
            <div style={{ marginLeft: "auto", display: "flex", gap: "8px" }}>
              <Button variant="secondary" size="sm" onClick={loadVisitors}>
                <Icon name="refresh" size={14} /> Refresh
              </Button>
            </div>
          </div>
          {loadingVisitors ? (
            <div style={{ padding: "40px", textAlign: "center" }}>
              <Spinner />
            </div>
          ) : (
            <>
              <div className="table-wrap">
                <table className="table">
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>Phone</th>
                      <th>Visited At</th>
                    </tr>
                  </thead>
                  <tbody>
                    {visitorsPagination.pageItems.length > 0 ? (
                      visitorsPagination.pageItems.map((visitor) => (
                        <tr key={visitor.id}>
                          <td className="bold">{visitor.name || "—"}</td>
                          <td className="mono">{visitor.phone || "—"}</td>
                          <td className="small muted">
                            {formatDateTime(visitor.visited_at)}
                          </td>
                        </tr>
                      ))
                    ) : (
                      <tr>
                        <td
                          colSpan="4"
                          style={{ textAlign: "center", padding: "40px" }}
                        >
                          <EmptyState
                            icon="users"
                            title="No visitors yet"
                            body="Visitors will appear here when they access the public directory"
                          />
                        </td>
                      </tr>
                    )}
                  </tbody>
                </table>
              </div>
              {visitors.length > 0 && (
                <Pagination
                  page={visitorsPagination.page}
                  totalPages={visitorsPagination.totalPages}
                  totalItems={visitorsPagination.totalItems}
                  pageSize={visitorsPagination.pageSize}
                  onChange={visitorsPagination.setPage}
                />
              )}
            </>
          )}
        </div>
      )}

      {/* Owner inspect modal */}
      {selected && (
        <Modal
          open
          onClose={() => setSelected(null)}
          title={snapshot?.owner?.business_name || "Owner"}
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
                <MiniStat
                  label="Properties"
                  value={snapshot.counts?.properties}
                />
                <MiniStat label="Units" value={snapshot.counts?.units} />
                <MiniStat label="Tenants" value={snapshot.counts?.tenants} />
                <MiniStat label="Invoices" value={snapshot.counts?.invoices} />
                <MiniStat label="Payments" value={snapshot.counts?.payments} />
              </div>

              <div className="row-between mb-2">
                <span className="muted small">Subscription</span>
                <Badge value={snapshot.subscription?.status} />
              </div>
              <div className="row-between mb-2">
                <span className="muted small">Outstanding</span>
                <span className="bold mono">{money(snapshot.outstanding)}</span>
              </div>
              <div className="row-between mb-2">
                <span className="muted small">Trial Ends</span>
                <span className="small">
                  {formatDate(snapshot.subscription?.trial_ends_at)}
                </span>
              </div>

              <div className="form-grid" style={{ gridTemplateColumns: "1fr" }}>
                <Field label="Monthly Amount">
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
                  Activate Plan
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
                  Record Payment
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
                  <option value="">Set Status</option>
                  <option value="active">Active</option>
                  <option value="past_due">Past Due</option>
                  <option value="cancelled">Cancelled</option>
                  <option value="expired">Expired</option>
                  <option value="trial">Trial</option>
                </Select>
              </div>

              {snapshot.recent_audit && snapshot.recent_audit.length > 0 && (
                <>
                  <div className="bold small mt-3 mb-2">Recent Activity</div>
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
        title="Grant Super Admin"
      >
        <form onSubmit={grantSuperAdmin}>
          <Field
            label="User ID"
            hint="Enter the UUID of the user to grant super admin access"
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
              Cancel
            </Button>
            <Button type="submit" disabled={saving}>
              {saving ? "Granting..." : "Grant Access"}
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
