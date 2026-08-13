import { useState, useEffect, useCallback, useRef } from "react";
import { Link, useParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { supabase, callRpc } from "../lib/supabase";
import { availableSeats } from "../lib/availability";
import {
  useProperty,
  useUnits,
  useUnitTemplates,
} from "../hooks/useProperties";
import { useLookups } from "../hooks/useLookups";
import Button from "../components/ui/Button";
import { Field, Input, Select } from "../components/ui/Input";
import { GenderSelect, FacilityPicker } from "../components/ui/FacilityPicker";
import Modal from "../components/ui/Modal";
import Spinner from "../components/ui/Spinner";
import EmptyState from "../components/ui/EmptyState";
import Icon from "../components/ui/Icon";
import { useToast } from "../components/ui/Toast";
import { money, formatRooms } from "../lib/format";
import ImageUpload from "../components/ui/ImageUpload";

export default function PropertyDetailPage() {
  const { t } = useTranslation();
  const { id } = useParams();
  const property = useProperty(id);
  const units = useUnits(id);
  const templates = useUnitTemplates();
  const lookups = useLookups();
  const toast = useToast();

  const [bulkOpen, setBulkOpen] = useState(false);
  const [editUnit, setEditUnit] = useState(null);
  const [seatsUnit, setSeatsUnit] = useState(null);
  const [deleteUnit, setDeleteUnit] = useState(null);
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [refreshing, setRefreshing] = useState(false);

  const [meta, setMeta] = useState(null);
  const [savingMeta, setSavingMeta] = useState(false);

  const prop = property.data?.[0];
  const unitRows = units.data ?? [];

  const isCottage = prop?.property_types?.key === "cottage";
  const noun = isCottage ? t("newProperty.room") : t("newProperty.unit");
  const nounPlural = isCottage
    ? t("newProperty.rooms")
    : t("newProperty.units");

  const [bulk, setBulk] = useState({
    count: 6,
    pattern: "Unit ",
    template_id: "",
    dimension: "",
    default_rent: "",
    deposit: "",
    rooms: {},
    seats_per_unit: 0,
    seat_rent: "",
    applicable_for: "both",
    facilities: [],
  });
  const setBulkF = (k) => (e) =>
    setBulk((b) => ({ ...b, [k]: e.target.value }));
  const setBulkRoom = (key) => (e) =>
    setBulk((b) => ({
      ...b,
      rooms: { ...b.rooms, [key]: Number(e.target.value) || 0 },
    }));

  const roomTypes = (lookups.roomTypes ?? []).filter(
    (r) => !r.property_kind || r.property_kind === prop?.property_types?.key,
  );

  function SeatAvailabilityBadge({ unit }) {
    const total = unit.seats?.length ?? 0;
    if (total === 0) return <span className="muted small">—</span>;
    const free = availableSeats(unit).length;
    const tone = free === 0 ? "red" : free === total ? "green" : "amber";
    return (
      <span className={`badge badge-${tone}`}>
        {t("propertyDetail.freeSeats", { free, total })}
      </span>
    );
  }

  // Refetch function with safe checks
  const refetchAll = useCallback(async () => {
    setRefreshing(true);
    try {
      const refetchPromises = [];

      if (property.refresh && typeof property.refresh === "function") {
        refetchPromises.push(property.refresh());
      }
      if (units.refresh && typeof units.refresh === "function") {
        refetchPromises.push(units.refresh());
      }
      if (templates.refresh && typeof templates.refresh === "function") {
        refetchPromises.push(templates.refresh());
      }
      if (lookups.refresh && typeof lookups.refresh === "function") {
        refetchPromises.push(lookups.refresh());
      }

      await Promise.all(refetchPromises);
      toast.success(t("propertyDetail.dataRefreshed"));
    } catch (err) {
      console.error("Refresh error:", err);
      toast.error(t("propertyDetail.refreshFailed"));
    } finally {
      setRefreshing(false);
    }
  }, [property, units, templates, lookups, toast, t]);

  const refetchAllRef = useRef();
  refetchAllRef.current = refetchAll;

  // Auto-refresh on mount and when id changes
  useEffect(() => {
    if (id) {
      const timer = setTimeout(() => {
        refetchAllRef.current();
      }, 100);
      return () => clearTimeout(timer);
    }
  }, [id]);

  // Auto-refresh when property type changes (for room types)
  const lookupsRefresh = lookups.refresh;
  useEffect(() => {
    if (
      prop?.property_types?.key &&
      lookupsRefresh &&
      typeof lookupsRefresh === "function"
    ) {
      lookupsRefresh();
    }
  }, [prop?.property_types?.key, lookupsRefresh]);

  // Update unit count when units change
  const propertyData = property.data;
  const propertySetData = property.setData;
  useEffect(() => {
    if (propertyData && units.data) {
      const updatedProp = {
        ...propertyData[0],
        unit_count: units.data.length,
      };
      if (propertySetData) {
        propertySetData([updatedProp]);
      }
    }
  }, [units.data, propertyData, propertySetData]);

  const runBulk = async (e) => {
    e.preventDefault();
    setSaving(true);
    try {
      await callRpc("create_units_bulk", {
        p_property_id: id,
        p_count: Number(bulk.count),
        p_pattern: bulk.pattern,
        p_template_id: bulk.template_id || null,
        p_dimension: bulk.dimension || null,
        p_default_rent:
          bulk.default_rent === "" ? null : Number(bulk.default_rent),
        p_deposit: bulk.deposit === "" ? null : Number(bulk.deposit),
        p_rooms: Object.keys(bulk.rooms).length ? bulk.rooms : null,
        p_seats_per_unit: isCottage ? Number(bulk.seats_per_unit) || 0 : 0,
        p_seat_rent:
          isCottage && bulk.seat_rent !== "" ? Number(bulk.seat_rent) : null,
        p_applicable_for: bulk.applicable_for,
        p_facilities: bulk.facilities.length
          ? bulk.facilities.map((n) => ({ name: n }))
          : null,
      });
      toast.success(
        t("propertyDetail.unitsCreated", { count: bulk.count, nounPlural }),
      );
      setBulkOpen(false);
      await refetchAll();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSaving(false);
    }
  };

  const saveUnit = async (e) => {
    e.preventDefault();
    setSaving(true);
    try {
      const { error } = await supabase
        .from("units")
        .update({
          rent_amount: Number(editUnit.rent_amount),
          deposit_amount: Number(editUnit.deposit_amount),
          dimension: editUnit.dimension,
          status: editUnit.status,
          floor: editUnit.floor,
          rooms: editUnit.rooms || {},
          applicable_for: editUnit.applicable_for,
          facilities: editUnit.facilities || [],
          images: editUnit.images || [],
        })
        .eq("id", editUnit.id);
      if (error) throw error;
      toast.success(t("propertyDetail.unitUpdated", { noun }));
      setEditUnit(null);
      await refetchAll();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSaving(false);
    }
  };

  const saveMeta = async (e) => {
    e.preventDefault();
    setSavingMeta(true);
    try {
      const { error } = await supabase
        .from("properties")
        .update({
          description: meta.description,
          images: meta.images,
          is_public: meta.is_public,
        })
        .eq("id", prop.id);
      if (error) throw error;
      toast.success(t("propertyDetail.metaSaved"));
      setMeta(null);
      await refetchAll();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSavingMeta(false);
    }
  };

  const resubmitPublication = async () => {
    setSavingMeta(true);
    try {
      await callRpc("resubmit_publication", { p_property_id: prop.id });
      toast.success(t("propertyDetail.resubmitted"));
      setMeta(null);
      await refetchAll();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSavingMeta(false);
    }
  };

  const deleteUnitHandler = async () => {
    if (!deleteUnit) return;

    setDeleting(true);
    try {
      if (isCottage && deleteUnit.seats?.length > 0) {
        const { error: seatsError } = await supabase
          .from("seats")
          .delete()
          .eq("unit_id", deleteUnit.id);

        if (seatsError) throw seatsError;
      }

      const { error } = await supabase
        .from("units")
        .delete()
        .eq("id", deleteUnit.id);

      if (error) throw error;

      toast.success(
        t("propertyDetail.unitDeleted", {
          noun,
          number: deleteUnit.unit_number,
        }),
      );
      setDeleteUnit(null);
      await refetchAll();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setDeleting(false);
    }
  };

  const handleManualRefresh = () => {
    refetchAll();
  };

  if (property.loading || units.loading) return <Spinner />;
  if (!prop)
    return <EmptyState icon="search" title={t("propertyDetail.notFound")} />;

  return (
    <div>
      <div className="page-head">
        <div>
          <Link to="/admin/properties" className="btn btn-ghost btn-sm mb-2">
            <Icon name="arrowLeft" size={15} /> {t("common.back")}
          </Link>
          <h1 className="page-title">{prop.name}</h1>
          <div className="page-sub">
            {prop.property_types?.name} · {unitRows.length} {nounPlural} ·
            {[prop.address_line1, prop.city, prop.country]
              .filter(Boolean)
              .join(", ")}{" "}
            · {t("propertyDetail.grace", { days: prop.grace_days })}
          </div>
        </div>
      </div>

      <div className="card card-pad mb-3">
        <div className="row-between mb-2">
          <div className="bold">{t("propertyDetail.publicListing")}</div>
          <span
            className={`badge ${
              !prop.is_public
                ? "badge-gray"
                : prop.publication_status === "pending"
                  ? "badge-amber"
                  : prop.publication_status === "rejected"
                    ? "badge-red"
                    : "badge-green"
            }`}
          >
            {!prop.is_public
              ? t("propertyDetail.notListed")
              : prop.publication_status === "pending"
                ? t("propertyDetail.pendingApproval")
                : prop.publication_status === "rejected"
                  ? t("propertyDetail.rejected")
                  : t("propertyDetail.listed")}
          </span>
        </div>
        {meta === null ? (
          <div>
            <p className="small muted">
              {t("propertyDetail.publicListingBody")}
            </p>
            {prop.publication_status === "rejected" && (
              <div
                className="mt-2"
                style={{
                  background: "var(--danger-soft)",
                  color: "var(--danger)",
                  borderRadius: 10,
                  padding: "10px 12px",
                  fontSize: 14,
                }}
              >
                {t("propertyDetail.rejectionNote")}
                {prop.review_note && (
                  <div className="mt-1">“{prop.review_note}”</div>
                )}
              </div>
            )}
            {prop.publication_status === "pending" && (
              <p className="small mt-2" style={{ color: "var(--warning)" }}>
                {t("propertyDetail.pendingApprovalBody")}
              </p>
            )}
            <div className="row mt-2">
              <Button
                variant="secondary"
                size="sm"
                onClick={() =>
                  setMeta({
                    description: prop.description ?? "",
                    images: prop.images ?? [],
                    is_public: prop.is_public,
                  })
                }
              >
                <Icon name="edit" size={14} /> {t("common.edit")}
              </Button>
              {prop.is_public && prop.publication_status === "rejected" && (
                <Button
                  variant="secondary"
                  size="sm"
                  disabled={savingMeta}
                  onClick={resubmitPublication}
                >
                  <Icon name="refresh" size={14} />{" "}
                  {t("propertyDetail.resubmit")}
                </Button>
              )}
              <Link to={`/rent/${prop.id}`} className="btn btn-ghost btn-sm">
                <Icon name="external" size={14} />{" "}
                {t("propertyDetail.viewPublic")}
              </Link>
            </div>
          </div>
        ) : (
          <form onSubmit={saveMeta}>
            <label className="row" style={{ gap: 8, marginBottom: 12 }}>
              <input
                type="checkbox"
                checked={meta.is_public}
                onChange={(e) =>
                  setMeta({ ...meta, is_public: e.target.checked })
                }
              />
              <span className="small">{t("propertyDetail.listPublic")}</span>
            </label>
            <Field label={t("propertyDetail.description")}>
              <textarea
                className="textarea"
                value={meta.description}
                onChange={(e) =>
                  setMeta({ ...meta, description: e.target.value })
                }
                placeholder={t("propertyDetail.descriptionPlaceholder")}
              />
            </Field>
            <ImageUpload
              images={meta.images ?? []}
              onChange={(images) => setMeta({ ...meta, images })}
              label={t("propertyDetail.images")}
            />
            <div className="modal-actions">
              <Button
                type="button"
                variant="secondary"
                onClick={() => setMeta(null)}
              >
                {t("common.cancel")}
              </Button>
              <Button type="submit" disabled={savingMeta}>
                {savingMeta ? t("common.saving") : t("common.save")}
              </Button>
            </div>
          </form>
        )}
      </div>

      <div className="row-between mb-2">
        <div className="bold">
          {t("propertyDetail.roomsLabel", { nounPlural })}
        </div>
        <div className="row">
          <span className="muted small">
            {unitRows.length} {nounPlural}
          </span>
          <Button
            variant="secondary"
            size="sm"
            onClick={() => setBulkOpen(true)}
          >
            <Icon name="plus" size={14} />{" "}
            {t("propertyDetail.generateUnits", { nounPlural })}
          </Button>{" "}
          <div className="header-actions">
            <Button
              variant="secondary"
              size="sm"
              onClick={handleManualRefresh}
              disabled={refreshing}
            >
              <Icon
                name="refresh"
                size={16}
                className={refreshing ? "spin" : ""}
              />
              {refreshing ? t("common.refreshing") : t("common.refresh")}
            </Button>
          </div>
        </div>
      </div>

      {/* Desktop Table View */}
      <div className="desktop-table">
        <div className="card table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>{t("propertyDetail.colUnit", { noun })}</th>
                {!isCottage && <th>{t("propertyDetail.colRooms")}</th>}
                <th>{t("propertyDetail.colFloor")}</th>
                <th>{t("propertyDetail.colDimension")}</th>
                <th>{t("propertyDetail.colRent")}</th>
                <th>{t("propertyDetail.colDeposit")}</th>
                {isCottage && <th>{t("propertyDetail.colSeats")}</th>}
                <th>{t("propertyDetail.colStatus")}</th>
                <th>{t("propertyDetail.colActions")}</th>
              </tr>
            </thead>
            <tbody>
              {unitRows.map((u) => (
                <tr key={u.id}>
                  <td>
                    <div className="row" style={{ gap: 8 }}>
                      <span className="bold">{u.unit_number}</span>
                      <GenderBadge value={u.applicable_for} />
                    </div>
                  </td>
                  {!isCottage && (
                    <td className="short-text muted">
                      {formatRooms(u.rooms, roomTypes)}
                    </td>
                  )}
                  <td className="muted">{u.floor || "—"}</td>
                  <td className="muted">{u.dimension || "—"}</td>
                  <td className="mono">{money(u.rent_amount)}</td>
                  <td className="mono muted">{money(u.deposit_amount)}</td>
                  {isCottage && (
                    <td>
                      <SeatAvailabilityBadge unit={u} />
                    </td>
                  )}
                  <td>
                    <span
                      className={`badge badge-${u.status === "available" ? "blue" : u.status === "occupied" ? "green" : u.status === "maintenance" ? "amber" : "gray"}`}
                    >
                      {u.status}
                    </span>
                  </td>
                  <td>
                    <div className="action-group">
                      {isCottage && (
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={() => setSeatsUnit(u)}
                        >
                          {t("propertyDetail.seats")}
                        </Button>
                      )}
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => setEditUnit({ ...u })}
                      >
                        {t("common.edit")}
                      </Button>
                      <Button
                        variant="danger-ghost"
                        size="sm"
                        onClick={() => setDeleteUnit(u)}
                        disabled={u.status === "occupied"}
                        title={
                          u.status === "occupied"
                            ? t("propertyDetail.cannotDeleteOccupied")
                            : t("propertyDetail.deleteUnit")
                        }
                      >
                        <Icon name="trash" size={14} />
                      </Button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {/* Mobile Unit Cards - Compact */}
      <div className="unit-list">
        {unitRows.map((u) => (
          <div key={u.id} className="unit-card-compact">
            <div className="uc-header">
              <span className="uc-title">{u.unit_number}</span>
              <div className="uc-badges">
                <GenderBadge value={u.applicable_for} />
                <span
                  className={`badge badge-${u.status === "available" ? "blue" : u.status === "occupied" ? "green" : u.status === "maintenance" ? "amber" : "gray"}`}
                >
                  {u.status}
                </span>
              </div>
            </div>

            <div className="uc-details">
              {!isCottage && (
                <>
                  <div>
                    <div className="label">{t("propertyDetail.colRooms")}</div>
                    <div>{formatRooms(u.rooms, roomTypes) || "—"}</div>
                  </div>
                  <div>
                    <div className="label">{t("propertyDetail.colFloor")}</div>
                    <div>{u.floor || "—"}</div>
                  </div>
                </>
              )}
              <div>
                <div className="label">{t("propertyDetail.colRent")}</div>
                <div className="mono">{money(u.rent_amount)}</div>
              </div>
              {isCottage && (
                <div>
                  <div className="label">{t("propertyDetail.colSeats")}</div>
                  <div>
                    <SeatAvailabilityBadge unit={u} />
                  </div>
                </div>
              )}
              {!isCottage && (
                <div>
                  <div className="label">{t("propertyDetail.colDeposit")}</div>
                  <div className="mono">{money(u.deposit_amount)}</div>
                </div>
              )}
            </div>

            <div className="uc-actions">
              {isCottage && (
                <Button
                  variant="secondary"
                  size="sm"
                  onClick={() => setSeatsUnit(u)}
                >
                  <Icon name="users" size={12} /> {t("propertyDetail.seats")}
                </Button>
              )}
              <Button
                variant="secondary"
                size="sm"
                onClick={() => setEditUnit({ ...u })}
              >
                <Icon name="edit" size={12} />
              </Button>
              <Button
                variant="danger-ghost"
                size="sm"
                onClick={() => setDeleteUnit(u)}
                disabled={u.status === "occupied"}
                title={
                  u.status === "occupied"
                    ? t("propertyDetail.cannotDeleteOccupied")
                    : ""
                }
              >
                <Icon name="trash" size={12} />
              </Button>
            </div>
          </div>
        ))}
      </div>

      {unitRows.length === 0 && (
        <EmptyState
          icon="building"
          title={t("propertyDetail.noUnits", { nounPlural })}
          body={t("propertyDetail.noUnitsBody", { noun })}
          action={
            <Button onClick={() => setBulkOpen(true)}>
              <Icon name="plus" size={16} />{" "}
              {t("propertyDetail.generateUnits", { nounPlural })}
            </Button>
          }
        />
      )}

      {/* Bulk create Modal */}
      <Modal
        open={bulkOpen}
        onClose={() => setBulkOpen(false)}
        title={t("propertyDetail.generateTitle", { nounPlural })}
      >
        <form onSubmit={runBulk}>
          <div className="form-grid">
            <Field label={t("propertyDetail.numberOfUnits", { nounPlural })}>
              <Input
                type="number"
                min={1}
                max={500}
                required
                value={bulk.count}
                onChange={setBulkF("count")}
              />
            </Field>
            <Field label={t("newProperty.numberingPattern")}>
              <Input
                required
                value={bulk.pattern}
                onChange={setBulkF("pattern")}
                placeholder="Unit / A- / Room {n}"
              />
            </Field>
          </div>
          <Field
            label={t("newProperty.template")}
            hint={t("propertyDetail.templateHint")}
          >
            <Select value={bulk.template_id} onChange={setBulkF("template_id")}>
              <option value="">{t("newProperty.noTemplate")}</option>
              {(templates.data ?? []).map((t) => (
                <option key={t.id} value={t.id}>
                  {t.name} · {money(t.default_rent)}/mo
                </option>
              ))}
            </Select>
          </Field>
          <div className="form-grid-3">
            <Field label={t("newProperty.dimension")}>
              <Input
                value={bulk.dimension}
                onChange={setBulkF("dimension")}
                placeholder="e.g. 45 m²"
              />
            </Field>
            <Field label={t("propertyDetail.rentOverride")}>
              <Input
                type="number"
                min={0}
                step="0.01"
                value={bulk.default_rent}
                onChange={setBulkF("default_rent")}
              />
            </Field>
            <Field label={t("propertyDetail.depositOverride")}>
              <Input
                type="number"
                min={0}
                step="0.01"
                value={bulk.deposit}
                onChange={setBulkF("deposit")}
              />
            </Field>
          </div>
          {isCottage ? (
            <>
              <div className="form-grid">
                <Field label={t("newProperty.seatsPerRoom")}>
                  <Input
                    type="number"
                    min={0}
                    max={100}
                    value={bulk.seats_per_unit}
                    onChange={setBulkF("seats_per_unit")}
                  />
                </Field>
                <Field label={t("propertyDetail.seatRentOverride")}>
                  <Input
                    type="number"
                    min={0}
                    step="0.01"
                    value={bulk.seat_rent}
                    onChange={setBulkF("seat_rent")}
                    placeholder="e.g. 150"
                  />
                </Field>
              </div>
              <p className="hint">{t("propertyDetail.seatsHint")}</p>
            </>
          ) : (
            roomTypes.length > 0 && (
              <div className="mb-2">
                <div className="bold small mb-2">
                  {t("propertyDetail.roomsDescription")}
                </div>
                <div className="grid-2">
                  {roomTypes.map((r) => (
                    <Field
                      key={r.key}
                      label={`${r.name} (${t("newProperty.count")})`}
                    >
                      <Input
                        type="number"
                        min={0}
                        value={bulk.rooms[r.key] ?? 0}
                        onChange={setBulkRoom(r.key)}
                      />
                    </Field>
                  ))}
                </div>
              </div>
            )
          )}

          <div className="form-grid">
            <Field label={t("newProperty.gender")}>
              <GenderSelect
                value={bulk.applicable_for}
                onChange={(v) => setBulk((b) => ({ ...b, applicable_for: v }))}
                t={t}
              />
            </Field>
          </div>
          <Field label={t("newProperty.facilities")}>
            <FacilityPicker
              t={t}
              facilities={lookups.facilities ?? []}
              selected={bulk.facilities}
              onChange={(names) =>
                setBulk((b) => ({ ...b, facilities: names }))
              }
            />
          </Field>

          <div className="modal-actions">
            <Button
              type="button"
              variant="secondary"
              onClick={() => setBulkOpen(false)}
            >
              {t("common.cancel")}
            </Button>
            <Button type="submit" disabled={saving}>
              {saving
                ? t("propertyDetail.generating")
                : t("propertyDetail.generate")}
            </Button>
          </div>
        </form>
      </Modal>

      {/* Edit unit Modal */}
      {editUnit && (
        <Modal
          open
          onClose={() => setEditUnit(null)}
          title={`${titleCase(noun)} ${editUnit.unit_number}`}
        >
          <form onSubmit={saveUnit}>
            <div className="form-grid">
              <Field label={t("propertyDetail.rentPerMonth")}>
                <Input
                  type="number"
                  min={0}
                  step="0.01"
                  value={editUnit.rent_amount}
                  onChange={(e) =>
                    setEditUnit({ ...editUnit, rent_amount: e.target.value })
                  }
                />
              </Field>
              <Field label={t("newProperty.deposit")}>
                <Input
                  type="number"
                  min={0}
                  step="0.01"
                  value={editUnit.deposit_amount}
                  onChange={(e) =>
                    setEditUnit({ ...editUnit, deposit_amount: e.target.value })
                  }
                />
              </Field>
            </div>
            <div className="form-grid">
              <Field label={t("newProperty.dimension")}>
                <Input
                  value={editUnit.dimension}
                  onChange={(e) =>
                    setEditUnit({ ...editUnit, dimension: e.target.value })
                  }
                />
              </Field>
              <Field label={t("propertyDetail.colFloor")}>
                <Input
                  value={editUnit.floor}
                  onChange={(e) =>
                    setEditUnit({ ...editUnit, floor: e.target.value })
                  }
                />
              </Field>
            </div>
            {!isCottage && roomTypes.length > 0 && (
              <div className="mb-2">
                <div className="bold small mb-2">
                  {t("propertyDetail.roomsDescription")}
                </div>
                <div className="grid-2">
                  {roomTypes.map((r) => (
                    <Field
                      key={r.key}
                      label={`${r.name} (${t("newProperty.count")})`}
                    >
                      <Input
                        type="number"
                        min={0}
                        value={editUnit.rooms?.[r.key] ?? 0}
                        onChange={(e) =>
                          setEditUnit({
                            ...editUnit,
                            rooms: {
                              ...(editUnit.rooms || {}),
                              [r.key]: Number(e.target.value) || 0,
                            },
                          })
                        }
                      />
                    </Field>
                  ))}
                </div>
              </div>
            )}
            <div className="form-grid">
              <Field label={t("newProperty.gender")}>
                <GenderSelect
                  value={editUnit.applicable_for ?? "both"}
                  onChange={(v) =>
                    setEditUnit({ ...editUnit, applicable_for: v })
                  }
                  t={t}
                />
              </Field>
            </div>
            <Field label={t("newProperty.facilities")}>
              <FacilityPicker
                t={t}
                facilities={lookups.facilities ?? []}
                selected={(editUnit.facilities ?? []).map((f) => f.name)}
                onChange={(names) =>
                  setEditUnit({
                    ...editUnit,
                    facilities: names.map((n) => ({ name: n })),
                  })
                }
              />
            </Field>
            <Field label={t("propertyDetail.unitImages")}>
              <ImageUpload
                images={editUnit.images ?? []}
                onChange={(images) => setEditUnit({ ...editUnit, images })}
              />
            </Field>
            <Field label={t("propertyDetail.colStatus")}>
              <Select
                value={editUnit.status}
                onChange={(e) =>
                  setEditUnit({ ...editUnit, status: e.target.value })
                }
              >
                <option value="available">
                  {t("propertyDetail.statusAvailable")}
                </option>
                <option value="occupied">
                  {t("propertyDetail.statusOccupied")}
                </option>
                <option value="maintenance">
                  {t("propertyDetail.statusMaintenance")}
                </option>
                <option value="off_market">
                  {t("propertyDetail.statusOffMarket")}
                </option>
              </Select>
            </Field>
            <div className="modal-actions">
              <Button
                type="button"
                variant="secondary"
                onClick={() => setEditUnit(null)}
              >
                {t("common.close")}
              </Button>
              <Button type="submit" disabled={saving}>
                {t("common.save")}
              </Button>
            </div>
          </form>
        </Modal>
      )}

      {/* Delete Unit Confirmation Modal */}
      {deleteUnit && (
        <Modal
          open
          onClose={() => setDeleteUnit(null)}
          title={t("propertyDetail.deleteTitle", { noun })}
          className="delete-modal"
        >
          <div className="delete-confirmation">
            <div className="delete-icon">
              <Icon name="alertTriangle" size={32} color="var(--danger)" />
            </div>
            <h3>{t("propertyDetail.areYouSure")}</h3>
            <p className="muted">
              {t("propertyDetail.deleteBody", { noun })}{" "}
              <strong>{deleteUnit.unit_number}</strong>.
              {isCottage && deleteUnit.seats?.length > 0 && (
                <>
                  {" "}
                  {t("propertyDetail.deleteBodySeats", {
                    count: deleteUnit.seats.length,
                  })}
                </>
              )}
            </p>
            {deleteUnit.status === "occupied" && (
              <div className="warning-box">
                <Icon name="info" size={16} />
                <span>{t("propertyDetail.occupiedWarning")}</span>
              </div>
            )}
            <div className="modal-actions">
              <Button
                type="button"
                variant="secondary"
                onClick={() => setDeleteUnit(null)}
              >
                {t("common.cancel")}
              </Button>
              <Button
                type="button"
                variant="danger"
                onClick={deleteUnitHandler}
                disabled={deleting || deleteUnit.status === "occupied"}
              >
                {deleting ? t("propertyDetail.deleting") : t("common.delete")}
              </Button>
            </div>
          </div>
        </Modal>
      )}

      <SeatManager
        key={seatsUnit?.id ?? "none"}
        unit={seatsUnit}
        onClose={() => setSeatsUnit(null)}
        toast={toast}
        facilities={lookups.facilities ?? []}
        onSeatUpdate={refetchAll}
      />
    </div>
  );
}

function titleCase(value) {
  if (!value) return value;
  return value.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

function GenderBadge({ value }) {
  const { t } = useTranslation();
  const v = value ?? "both";
  return (
    <span className={`gender-badge ${v}`}>
      {v === "male"
        ? t("gender.male")
        : v === "female"
          ? t("gender.female")
          : t("gender.both")}
    </span>
  );
}

function SeatManager({ unit, onClose, toast, facilities, onSeatUpdate }) {
  const { t } = useTranslation();
  const [seats, setSeats] = useState(unit?.seats ?? []);
  const [form, setForm] = useState({
    seat_number: "",
    name: "",
    rent_amount: "",
    applicable_for: "both",
  });
  const [saving, setSaving] = useState(false);
  const [deletingSeat, setDeletingSeat] = useState(null);

  if (!unit) return null;

  const addSeat = async (e) => {
    e.preventDefault();
    setSaving(true);
    try {
      const { data, error } = await supabase
        .from("seats")
        .insert({
          unit_id: unit.id,
          seat_number: form.seat_number,
          name: form.name,
          rent_amount: Number(form.rent_amount || 0),
          applicable_for: form.applicable_for,
        })
        .select()
        .single();
      if (error) throw error;
      setSeats((s) => [...s, data]);
      setForm({
        seat_number: "",
        name: "",
        rent_amount: "",
        applicable_for: "both",
      });
      toast.success(t("seatManager.seatAdded"));
      if (onSeatUpdate) onSeatUpdate();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSaving(false);
    }
  };

  const updateRent = async (seat) => {
    try {
      const { error } = await supabase
        .from("seats")
        .update({ rent_amount: Number(seat.rent_amount) })
        .eq("id", seat.id);
      if (error) throw error;
      toast.success(t("seatManager.seatRentUpdated"));
      if (onSeatUpdate) onSeatUpdate();
    } catch (err) {
      toast.error(err.message);
    }
  };

  const deleteSeat = async (seatId) => {
    if (!confirm(t("seatManager.deleteSeatConfirm"))) return;

    setDeletingSeat(seatId);
    try {
      const { error } = await supabase.from("seats").delete().eq("id", seatId);

      if (error) throw error;

      setSeats((s) => s.filter((x) => x.id !== seatId));
      toast.success(t("seatManager.seatDeleted"));
      if (onSeatUpdate) onSeatUpdate();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setDeletingSeat(null);
    }
  };

  const updateGender = async (seat, value) => {
    setSeats((all) =>
      all.map((x) => (x.id === seat.id ? { ...x, applicable_for: value } : x)),
    );
    try {
      const { error } = await supabase
        .from("seats")
        .update({ applicable_for: value })
        .eq("id", seat.id);
      if (error) throw error;
      if (onSeatUpdate) onSeatUpdate();
    } catch (err) {
      toast.error(err.message);
    }
  };

  const toggleFacility = async (seat, name) => {
    const current = seat.facilities ?? [];
    const next = current.some((f) => f.name === name)
      ? current.filter((f) => f.name !== name)
      : [...current, { name }];
    setSeats((all) =>
      all.map((x) => (x.id === seat.id ? { ...x, facilities: next } : x)),
    );
    try {
      const { error } = await supabase
        .from("seats")
        .update({ facilities: next })
        .eq("id", seat.id);
      if (error) throw error;
      if (onSeatUpdate) onSeatUpdate();
    } catch (err) {
      toast.error(err.message);
    }
  };

  return (
    <Modal
      open
      onClose={onClose}
      title={`${t("seatManager.title")} · ${unit.unit_number}`}
    >
      <p className="small muted">{t("seatManager.subtitle")}</p>

      <div className="seat-list">
        {seats.map((s) => (
          <div key={s.id} className="seat-item">
            <div className="seat-item-header">
              <div className="seat-item-info">
                <div className="seat-item-number">
                  {s.seat_number}
                  {s.name && (
                    <span className="seat-item-name"> · {s.name}</span>
                  )}
                </div>
                <div className="seat-item-actions">
                  <button
                    className="btn btn-danger-ghost btn-sm"
                    onClick={() => deleteSeat(s.id)}
                    disabled={deletingSeat === s.id}
                  >
                    <Icon name="trash" size={12} />
                  </button>
                </div>
              </div>
              <div className="seat-item-rent">
                <Input
                  type="number"
                  min={0}
                  step="0.01"
                  value={s.rent_amount}
                  onChange={(e) =>
                    setSeats((all) =>
                      all.map((x) =>
                        x.id === s.id
                          ? { ...x, rent_amount: e.target.value }
                          : x,
                      ),
                    )
                  }
                  onBlur={() => updateRent(s)}
                  className="seat-rent-input"
                />
              </div>
            </div>
            <div className="seat-item-gender">
              <span className="label">{t("newProperty.gender")}</span>
              <select
                className="select seat-gender-select"
                value={s.applicable_for ?? "both"}
                onChange={(e) => updateGender(s, e.target.value)}
              >
                <option value="both">{t("gender.both")}</option>
                <option value="male">{t("gender.male")}</option>
                <option value="female">{t("gender.female")}</option>
              </select>
            </div>
            {facilities.length > 0 && (
              <div className="seat-item-facilities">
                {facilities.map((f) => {
                  const on = (s.facilities ?? []).some(
                    (x) => x.name === f.name,
                  );
                  return (
                    <label key={f.name} className="seat-facility-label">
                      <input
                        type="checkbox"
                        checked={on}
                        onChange={() => toggleFacility(s, f.name)}
                      />
                      <span className="small muted">{f.name}</span>
                    </label>
                  );
                })}
              </div>
            )}
          </div>
        ))}
        {seats.length === 0 && (
          <p className="muted small seat-empty">{t("seatManager.noSeats")}</p>
        )}
      </div>

      <form onSubmit={addSeat} className="seat-add-form">
        <Input
          placeholder={t("seatManager.seatNo")}
          value={form.seat_number}
          onChange={(e) => setForm({ ...form, seat_number: e.target.value })}
          className="seat-add-input"
          required
        />
        <Input
          placeholder={t("seatManager.nameOptional")}
          value={form.name}
          onChange={(e) => setForm({ ...form, name: e.target.value })}
          className="seat-add-input"
        />
        <Input
          placeholder={t("seatManager.rent")}
          type="number"
          min={0}
          step="0.01"
          value={form.rent_amount}
          onChange={(e) => setForm({ ...form, rent_amount: e.target.value })}
          className="seat-add-input"
        />
        <select
          className="select seat-add-input"
          value={form.applicable_for}
          onChange={(e) => setForm({ ...form, applicable_for: e.target.value })}
        >
          <option value="both">{t("gender.both")}</option>
          <option value="male">{t("gender.male")}</option>
          <option value="female">{t("gender.female")}</option>
        </select>
        <Button type="submit" disabled={saving} className="seat-add-btn">
          {t("seatManager.add")}
        </Button>
      </form>
    </Modal>
  );
}
