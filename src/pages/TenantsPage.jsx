import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { callRpc } from "../lib/supabase";
import { useTenants } from "../hooks/useTenants";
import { usePropertyOptions } from "../hooks/useProperties";
import { usePagination } from "../hooks/usePagination";
import Button from "../components/ui/Button";
import { Field, Input, Select } from "../components/ui/Input";
import Modal from "../components/ui/Modal";
import Spinner from "../components/ui/Spinner";
import EmptyState from "../components/ui/EmptyState";
import Pagination from "../components/ui/Pagination";
import QuickAction from "../components/layout/QuickAction";
import Icon from "../components/ui/Icon";
import { useToast } from "../components/ui/Toast";
import { formatDate, fullName, initials } from "../lib/format";
import {
  isUnitAvailable,
  isUnitFullyBooked,
  availableSeats,
} from "../lib/availability";

// "Unit 5-A" for a whole-unit lease, "Room 3 · Seat 2" for a seated one.
// A tenant can hold several active leases at once, so this returns the
// full list (used both for the desktop table and mobile card).
function activeLeaseLabels(tenant) {
  return (tenant.leases ?? [])
    .filter((l) => l.status === "active")
    .map((l) =>
      l.seat?.seat_number
        ? `${l.unit?.unit_number ?? "—"} · ${l.seat.seat_number}`
        : (l.unit?.unit_number ?? "—"),
    );
}

export default function TenantsPage() {
  const { t } = useTranslation();
  const { data, loading, refresh } = useTenants();
  const properties = usePropertyOptions();
  const toast = useToast();
  const [open, setOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [form, setForm] = useState({
    first_name: "",
    last_name: "",
    email: "",
    phone: "",
    whatsapp: "",
    join_date: new Date().toISOString().slice(0, 10),
    tenant_type: "single",
    occupation_type: "student",
    occupation_details: {},
    property_id: "",
    unit_id: "",
    seat_id: "",
    start_date: new Date().toISOString().slice(0, 10),
    grace_days: 3,
  });
  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }));

  // Only units/rooms that still have something available to rent.
  const units = useMemo(
    () =>
      (
        (properties.data ?? []).find((p) => p.id === form.property_id)?.units ??
        []
      ).filter((u) => !isUnitFullyBooked(u)),
    [properties.data, form.property_id],
  );
  const selectedUnit = useMemo(
    () => units.find((u) => u.id === form.unit_id),
    [units, form.unit_id],
  );
  // Only seats not currently occupied by an active lease.
  const seats = useMemo(() => availableSeats(selectedUnit), [selectedUnit]);
  // "Whole room" is only offerable if the unit itself isn't leased out.
  const wholeUnitAvailable = selectedUnit
    ? isUnitAvailable(selectedUnit)
    : true;

  const selectedKind = (properties.data ?? []).find(
    (p) => p.id === form.property_id,
  )?.property_types?.key;

  const setOccupationField = (key) => (e) =>
    setForm((f) => ({
      ...f,
      occupation_details: { ...f.occupation_details, [key]: e.target.value },
    }));

  const create = async (e) => {
    e.preventDefault();
    setSaving(true);
    try {
      await callRpc("create_tenant_with_lease", {
        p_first_name: form.first_name,
        p_last_name: form.last_name,
        p_email: form.email || null,
        p_phone: form.phone || null,
        p_whatsapp: form.whatsapp || null,
        p_join_date: form.join_date,
        p_tenant_type: form.tenant_type,
        p_occupation_type: form.occupation_type || null,
        p_occupation_details: Object.keys(form.occupation_details).length
          ? form.occupation_details
          : {},
        p_unit_id: form.unit_id || null,
        p_seat_id: form.seat_id || null,
        p_start_date: form.start_date || null,
        p_grace_days: Number(form.grace_days),
      });
      toast.success(
        form.unit_id
          ? t("tenants.createdWithLease")
          : t("tenants.created"),
      );
      setOpen(false);
      refresh();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSaving(false);
    }
  };

  const items = data ?? [];
  const { pageItems, page, setPage, totalPages, totalItems, pageSize } =
    usePagination(items, 20);

  if (loading) return <Spinner />;

  return (
    <div>
      <div className="page-head">
        <div>
          <h1 className="page-title">{t("tenants.title")}</h1>
          <div className="page-sub">{t("tenants.subtitle")}</div>
        </div>
        <Button onClick={() => setOpen(true)} className="">
          <Icon name="plus" size={16} /> {t("tenants.newTenant")}
        </Button>
      </div>

      <div className="desktop-table">
        <div className="card table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>{t("tenants.colTenant")}</th>
                <th>{t("tenants.colContact")}</th>
                <th>{t("tenants.colType")}</th>
                <th>{t("tenants.colOccupation")}</th>
                <th>{t("tenants.colJoined")}</th>
                <th>{t("tenants.colRoomUnit")}</th>
                <th>{t("tenants.colStatus")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {pageItems.map((row) => {
                const leaseLabels = activeLeaseLabels(row);
                return (
                  <tr key={row.id}>
                    <td>
                      <div className="row">
                        <div className="avatar">
                          {initials(row.first_name, row.last_name)}
                        </div>
                        <Link
                          to={`/admin/tenants/${row.id}`}
                          state={{ from: "/admin/tenants" }}
                          className="bold"
                        >
                          {fullName(row)}
                        </Link>
                      </div>
                    </td>
                    <td className="small muted">
                      {row.email || "—"}
                      <br />
                      {row.phone || ""}
                    </td>
                    <td className="small">{row.tenant_type || "single"}</td>
                    <td className="small muted">{row.occupation_type || "—"}</td>
                    <td>{formatDate(row.join_date)}</td>
                    <td>
                      {leaseLabels.length === 0 ? (
                        <span className="muted small">—</span>
                      ) : (
                        <div
                          className="row"
                          style={{ flexWrap: "wrap", gap: 4 }}
                        >
                          {leaseLabels.map((label, i) => (
                            <span key={i} className="badge badge-indigo mono">
                              {label}
                            </span>
                          ))}
                        </div>
                      )}
                    </td>
                    <td>
                      <span
                        className={`badge badge-${row.status === "active" ? "green" : "gray"}`}
                      >
                        {row.status}
                      </span>
                    </td>
                    <td>
                      <Link
                        to={`/admin/tenants/${row.id}`}
                        state={{ from: "/admin/tenants" }}
                        className="btn btn-ghost btn-sm"
                      >
                        {t("common.open")}
                      </Link>
                    </td>
                  </tr>
                );
              })}
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
        {pageItems.map((row) => {
          const leaseLabels = activeLeaseLabels(row);
          return (
            <Link
              key={row.id}
              to={`/admin/tenants/${row.id}`}
              state={{ from: "/admin/tenants" }}
              className="list-card"
            >
              <div className="avatar">
                {initials(row.first_name, row.last_name)}
              </div>
              <div className="body">
                <div className="l-title">{fullName(row)}</div>
                <div className="l-sub">
                  {row.email || t("tenants.noEmail")} · {row.tenant_type || "single"}
                  {row.occupation_type ? ` · ${row.occupation_type}` : ""}
                </div>
                <div className="l-meta">
                  {leaseLabels.length === 0 ? (
                    <span className="badge badge-gray">{t("tenants.noActiveLease")}</span>
                  ) : (
                    leaseLabels.map((label, i) => (
                      <span key={i} className="badge badge-indigo mono">
                        {label}
                      </span>
                    ))
                  )}
                </div>
              </div>
              <div className="right">
                <span
                  className={`badge badge-${row.status === "active" ? "green" : "gray"}`}
                >
                  {row.status}
                </span>
              </div>
            </Link>
          );
        })}
        <Pagination
          page={page}
          totalPages={totalPages}
          totalItems={totalItems}
          pageSize={pageSize}
          onChange={setPage}
        />
      </div>

      {items.length === 0 && (
        <EmptyState
          icon="users"
          title={t("tenants.noTenants")}
          body={t("tenants.noTenantsBody")}
          action={
            <Button onClick={() => setOpen(true)}>
              <Icon name="plus" size={16} /> {t("tenants.newTenant")}
            </Button>
          }
        />
      )}

      <QuickAction onClick={() => setOpen(true)} label={t("tenants.newTenant")} />

      <Modal open={open} onClose={() => setOpen(false)} title={t("tenants.newTenant")}>
        <form onSubmit={create}>
          <div className="form-grid">
            <Field label={t("tenants.firstName")}>
              <Input
                required
                value={form.first_name}
                onChange={set("first_name")}
              />
            </Field>
            <Field label={t("tenants.lastName")}>
              <Input
                required
                value={form.last_name}
                onChange={set("last_name")}
              />
            </Field>
          </div>
          <Field label={t("tenants.email")}>
            <Input type="email" value={form.email} onChange={set("email")} />
          </Field>
          <div className="form-grid">
            <Field label={t("tenants.phoneSms")}>
              <Input
                value={form.phone}
                onChange={set("phone")}
                placeholder="+49…"
              />
            </Field>
            <Field label={t("tenants.whatsapp")}>
              <Input
                value={form.whatsapp}
                onChange={set("whatsapp")}
                placeholder="+49…"
              />
            </Field>
          </div>

          <div className="form-grid">
            <Field label={t("tenants.tenantType")}>
              <Select value={form.tenant_type} onChange={set("tenant_type")}>
                <option value="single">{t("tenants.single")}</option>
                <option value="family">{t("tenants.family")}</option>
              </Select>
            </Field>
            <Field label={t("tenants.occupation")}>
              <Select
                value={form.occupation_type}
                onChange={set("occupation_type")}
              >
                <option value="student">{t("tenants.student")}</option>
                <option value="job_holder">{t("tenants.jobHolder")}</option>
                <option value="other">{t("tenants.other")}</option>
              </Select>
            </Field>
          </div>

          {form.occupation_type === "student" && (
            <div
              className="card card-pad mb-2"
              style={{ background: "var(--surface-2)" }}
            >
              <div className="bold small mb-2">{t("tenants.studentDetails")}</div>
              <div className="form-grid">
                <Field label={t("tenants.university")}>
                  <Input
                    value={form.occupation_details.university || ""}
                    onChange={setOccupationField("university")}
                  />
                </Field>
                <Field label={t("tenants.course")}>
                  <Input
                    value={form.occupation_details.course || ""}
                    onChange={setOccupationField("course")}
                  />
                </Field>
              </div>
              <Field label={t("tenants.studentId")}>
                <Input
                  value={form.occupation_details.student_id || ""}
                  onChange={setOccupationField("student_id")}
                />
              </Field>
            </div>
          )}

          {form.occupation_type === "job_holder" && (
            <div
              className="card card-pad mb-2"
              style={{ background: "var(--surface-2)" }}
            >
              <div className="bold small mb-2">{t("tenants.jobDetails")}</div>
              <div className="form-grid">
                <Field label={t("tenants.employer")}>
                  <Input
                    value={form.occupation_details.employer || ""}
                    onChange={setOccupationField("employer")}
                  />
                </Field>
                <Field label={t("tenants.jobTitle")}>
                  <Input
                    value={form.occupation_details.job_title || ""}
                    onChange={setOccupationField("job_title")}
                  />
                </Field>
              </div>
              <Field label={t("tenants.monthlyIncome")}>
                <Input
                  type="number"
                  min={0}
                  step="0.01"
                  value={form.occupation_details.income ?? ""}
                  onChange={setOccupationField("income")}
                />
              </Field>
            </div>
          )}

          {form.occupation_type === "other" && (
            <Field label={t("tenants.notes")}>
              <Input
                value={form.occupation_details.note || ""}
                onChange={setOccupationField("note")}
              />
            </Field>
          )}

          <hr className="divider" />
          <div className="bold small mb-2">{t("tenants.assignment")}</div>

          <Field label={t("tenants.property")}>
            <Select
              value={form.property_id}
              onChange={(e) =>
                setForm((f) => ({
                  ...f,
                  property_id: e.target.value,
                  unit_id: "",
                  seat_id: "",
                }))
              }
            >
              <option value="">{t("tenants.noProperty")}</option>
              {(properties.data ?? []).map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </Select>
          </Field>

          {form.property_id && (
            <>
              <Field label={selectedKind === "cottage" ? t("tenants.room") : t("tenants.unit")}>
                <Select
                  value={form.unit_id}
                  onChange={(e) =>
                    setForm((f) => ({
                      ...f,
                      unit_id: e.target.value,
                      seat_id: "",
                    }))
                  }
                  required
                >
                  <option value="">
                    {t("tenants.selectUnit", {
                      unit: selectedKind === "cottage" ? t("tenants.room") : t("tenants.unit"),
                    })}
                  </option>
                  {units.map((u) => (
                    <option key={u.id} value={u.id}>
                      {u.unit_number}
                    </option>
                  ))}
                </Select>
                {units.length === 0 && (
                  <div className="hint">
                    {t("tenants.noAvailableUnits", {
                      units: selectedKind === "cottage" ? t("tenants.rooms") : t("tenants.unitsPlural"),
                    })}
                  </div>
                )}
              </Field>
              {seats.length > 0 && (
                <Field
                  label={t("tenants.seatCottage")}
                  hint={t("tenants.seatHint")}
                >
                  <Select value={form.seat_id} onChange={set("seat_id")}>
                    {wholeUnitAvailable && <option value="">{t("tenants.wholeRoom")}</option>}
                    {seats.map((s) => (
                      <option key={s.id} value={s.id}>
                        {s.seat_number}
                      </option>
                    ))}
                  </Select>
                </Field>
              )}
            </>
          )}

          <div className="form-grid">
            <Field
              label={t("tenants.moveInDate")}
              hint={t("tenants.moveInDateHint")}
            >
              <Input
                type="date"
                required
                value={form.join_date}
                onChange={set("join_date")}
              />
            </Field>
            <Field label={t("tenants.leaseStart")}>
              <Input
                type="date"
                value={form.start_date}
                onChange={set("start_date")}
              />
            </Field>
          </div>
          <Field label={t("tenants.graceDays")}>
            <Input
              type="number"
              min={0}
              value={form.grace_days}
              onChange={set("grace_days")}
            />
          </Field>

          <div className="modal-actions">
            <Button
              type="button"
              variant="secondary"
              onClick={() => setOpen(false)}
            >
              {t("common.cancel")}
            </Button>
            <Button type="submit" disabled={saving}>
              {saving ? t("tenants.creating") : t("tenants.createTenant")}
            </Button>
          </div>
        </form>
      </Modal>
    </div>
  );
}
