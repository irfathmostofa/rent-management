import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useProperties } from "../hooks/useProperties";
import { usePagination } from "../hooks/usePagination";
import Spinner from "../components/ui/Spinner";
import EmptyState from "../components/ui/EmptyState";
import Pagination from "../components/ui/Pagination";
import Icon from "../components/ui/Icon";
import { useState, useEffect } from "react";
import { supabase } from "../lib/supabase";
import { useToast } from "../components/ui/Toast";

export default function PropertiesPage() {
  const { t } = useTranslation();
  const { data, loading, mutate } = useProperties();
  const [searchQuery, setSearchQuery] = useState("");
  const [typeFilter, setTypeFilter] = useState("all");
  const [refreshTrigger, setRefreshTrigger] = useState(0);
  const toast = useToast();

  // Refresh data when refreshTrigger changes
  useEffect(() => {
    if (refreshTrigger > 0) {
      mutate();
    }
  }, [refreshTrigger, mutate]);

  if (loading) return <Spinner />;

  const items = data ?? [];

  // Filter items based on search and type
  const filteredItems = items.filter((p) => {
    const matchesSearch =
      p.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
      p.address_line1?.toLowerCase().includes(searchQuery.toLowerCase()) ||
      p.city?.toLowerCase().includes(searchQuery.toLowerCase());

    const matchesType =
      typeFilter === "all" || p.property_types?.name === typeFilter;

    return matchesSearch && matchesType;
  });

  // Get unique property types for filter
  const propertyTypes = [
    "all",
    ...new Set(items.map((p) => p.property_types?.name).filter(Boolean)),
  ];

  const handleDelete = async (propertyId, propertyName) => {
    // First check if property has tenants
    try {
      const { data: tenants, error: tenantError } = await supabase
        .from("tenants")
        .select("id", { count: "exact", head: true })
        .eq("property_id", propertyId);

      if (tenantError) throw tenantError;

      if (tenants && tenants.length > 0) {
        toast.error(
          `Cannot delete "${propertyName}" because it has active tenants. Please remove all tenants first.`,
        );
        return;
      }

      // Also check if property has any units with tenants
      const { data: units, error: unitError } = await supabase
        .from("units")
        .select("id", { count: "exact", head: true })
        .eq("property_id", propertyId);

      if (unitError) throw unitError;

      if (units && units.length > 0) {
        toast.error(
          `Cannot delete "${propertyName}" because it has units. Please remove all units first.`,
        );
        return;
      }
    } catch (err) {
      toast.error(err.message || "Failed to check property dependencies");
      return;
    }

    // If no tenants, proceed with deletion
    if (!window.confirm(`Are you sure you want to delete "${propertyName}"?`)) {
      return;
    }

    try {
      const { error } = await supabase
        .from("properties")
        .delete()
        .eq("id", propertyId);

      if (error) throw error;

      toast.success(`Property "${propertyName}" deleted successfully`);
      setRefreshTrigger((prev) => prev + 1);
    } catch (err) {
      toast.error(err.message || "Failed to delete property");
    }
  };

  return (
    <div>
      {/* Header Section */}
      <div className="page-head">
        <div>
          <h1 className="page-title">{t("properties.title")}</h1>
          <p className="page-sub">{t("properties.subtitle")}</p>
        </div>
        <div className="desktop-actions">
          <Link
            to="/admin/properties/new/apartment"
            className="btn btn-primary"
          >
            <Icon name="building" size={16} /> {t("properties.newApartment")}
          </Link>
          <Link
            to="/admin/properties/new/cottage"
            className="btn btn-secondary"
          >
            <Icon name="home" size={16} /> {t("properties.newCottage")}
          </Link>
        </div>
      </div>

      {/* Filter Bar - Responsive */}
      <div className="filter-section">
        <div className="filter-bar">
          <div className="filter-item">
            <Icon name="search" size={16} className="muted" />
            <input
              type="text"
              placeholder={t("properties.searchPlaceholder")}
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              className="input compact"
            />
          </div>
          <div className="filter-item">
            <select
              value={typeFilter}
              onChange={(e) => setTypeFilter(e.target.value)}
              className="select compact"
            >
              <option value="all">{t("properties.allTypes")}</option>
              {propertyTypes
                .filter((t) => t !== "all")
                .map((type) => (
                  <option key={type} value={type}>
                    {type}
                  </option>
                ))}
            </select>
          </div>
          <span className="filter-count">
            {t("properties.count", { count: filteredItems.length })}
          </span>
        </div>

        {/* Mobile Action Buttons */}
        <div className="mobile-actions">
          <Link
            to="/admin/properties/new/apartment"
            className="btn btn-primary btn-sm"
          >
            <Icon name="building" size={14} /> {t("properties.newShort")}
          </Link>
          <Link
            to="/admin/properties/new/cottage"
            className="btn btn-secondary btn-sm"
          >
            <Icon name="home" size={14} /> {t("properties.cottageShort")}
          </Link>
        </div>
      </div>

      <PagedProperties
        key={`${searchQuery}::${typeFilter}`}
        items={filteredItems}
        onDelete={handleDelete}
      />
    </div>
  );
}

// Keyed by the active filters in the parent (see `key={...}` at the call
// site) so changing the search or type filter remounts this component and
// resets pagination back to page 1, instead of staying on a page that no
// longer makes sense for the new result set.
function PagedProperties({ items, onDelete }) {
  const { t } = useTranslation();
  const { pageItems, page, setPage, totalPages, totalItems, pageSize } =
    usePagination(items, 20);

  return (
    <>
      {/* Desktop Table View */}
      <div className="hidden md:block">
        <div className="card table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>{t("properties.colName")}</th>
                <th>{t("properties.colType")}</th>
                <th>{t("properties.colAddress")}</th>
                <th>{t("properties.colUnits")}</th>
                <th>{t("properties.colGrace")}</th>
                <th className="text-right">{t("properties.colAction")}</th>
              </tr>
            </thead>
            <tbody>
              {items.length === 0 ? (
                <tr>
                  <td colSpan={6} className="empty-state-cell">
                    <EmptyState
                      title={t("properties.noFound")}
                      body={t("properties.noFoundBody")}
                      icon="building"
                    />
                  </td>
                </tr>
              ) : (
                pageItems.map((p) => (
                  <tr key={p.id} className="row-link">
                    <td>
                      <Link
                        to={`/admin/properties/${p.id}`}
                        className="font-bold"
                      >
                        {p.name}
                      </Link>{" "}
                      {p.is_public && (
                        <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800">
                          {t("properties.public")}
                        </span>
                      )}
                      {p.tenant_count > 0 && (
                        <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-yellow-100 text-yellow-800 ml-1">
                          {p.tenant_count} {t("properties.tenants")}
                        </span>
                      )}
                    </td>
                    <td>
                      <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-indigo-100 text-indigo-800">
                        {p.property_types?.name || "—"}
                      </span>
                    </td>
                    <td className="text-gray-500 text-sm">
                      {[p.address_line1, p.city].filter(Boolean).join(", ") ||
                        "—"}
                    </td>
                    <td className="font-mono">{p.unit_count}</td>
                    <td>
                      <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-800">
                        {p.grace_days}d
                      </span>
                    </td>
                    <td className="text-right">
                      <div className="flex items-center justify-end gap-1">
                        <Link
                          to={`/admin/properties/${p.id}`}
                          className="inline-flex items-center px-3 py-1 text-sm font-medium rounded-md text-gray-700 bg-gray-100 hover:bg-gray-200 transition-colors"
                        >
                          {t("common.view")}
                        </Link>
                        <button
                          onClick={(e) => {
                            e.preventDefault();
                            onDelete(p.id, p.name);
                          }}
                          disabled={p.tenant_count > 0}
                          className={`inline-flex items-center px-3 py-1 text-sm font-medium rounded-md transition-colors ${
                            p.tenant_count > 0
                              ? "bg-gray-100 text-gray-400 cursor-not-allowed"
                              : "bg-red-100 text-red-700 hover:bg-red-200"
                          }`}
                          title={
                            p.tenant_count > 0
                              ? "Cannot delete: Property has tenants"
                              : "Delete property"
                          }
                        >
                          <Icon name="trash" size={14} className="mr-1" />
                          {t("common.delete")}
                        </button>
                      </div>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
          {items.length > 0 && (
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
      <div className="block md:hidden">
        {items.length === 0 ? (
          <div className="py-5">
            <EmptyState
              title={t("properties.noFound")}
              body={t("properties.noFoundBody")}
              icon="building"
            />
          </div>
        ) : (
          <>
            {pageItems.map((p) => (
              <div
                key={p.id}
                className="bg-white rounded-xl shadow-sm mb-3 overflow-hidden border border-gray-200 transition-shadow hover:shadow-md"
              >
                <Link
                  to={`/admin/properties/${p.id}`}
                  className="block no-underline text-inherit px-4 py-3"
                >
                  <div className="flex flex-col gap-2">
                    <div className="flex justify-between items-start">
                      <div className="font-semibold text-gray-900 text-sm flex items-center flex-wrap gap-1">
                        {p.name}
                        {p.is_public && (
                          <span className="inline-flex items-center px-2 py-0.5 rounded-full text-[10px] font-medium bg-green-100 text-green-800 ml-1">
                            {t("properties.public")}
                          </span>
                        )}
                        {p.tenant_count > 0 && (
                          <span className="inline-flex items-center px-2 py-0.5 rounded-full text-[10px] font-medium bg-yellow-100 text-yellow-800 ml-1">
                            {p.tenant_count} {t("properties.tenants")}
                          </span>
                        )}
                      </div>
                      <Icon
                        name="chevronRight"
                        size={18}
                        className="text-gray-400"
                      />
                    </div>

                    <div className="flex flex-wrap items-center gap-2">
                      <span className="inline-flex items-center px-2 py-0.5 rounded-full text-[11px] font-medium bg-indigo-100 text-indigo-800">
                        {p.property_types?.name || "—"}
                      </span>
                      <span className="text-gray-500 text-xs flex items-center gap-1">
                        <Icon name="mapPin" size={12} />
                        {[p.address_line1, p.city].filter(Boolean).join(", ") ||
                          "—"}
                      </span>
                    </div>

                    <div className="flex gap-4 pt-2 border-t border-gray-100 flex-wrap">
                      <div className="flex items-center gap-1">
                        <span className="text-xs text-gray-500">
                          {t("properties.unitsShort", { count: p.unit_count })}
                        </span>
                        <span className="font-semibold text-sm text-gray-900">
                          {p.unit_count}
                        </span>
                      </div>
                      <div className="flex items-center gap-1">
                        <span className="text-xs text-gray-500">
                          {t("properties.grace")}
                        </span>
                        <span className="font-semibold text-sm text-gray-900">
                          {p.grace_days}d
                        </span>
                      </div>
                      {p.tenant_count > 0 && (
                        <div className="flex items-center gap-1">
                          <span className="text-xs text-gray-500">
                            {t("properties.tenants")}
                          </span>
                          <span className="font-semibold text-sm text-gray-900">
                            {p.tenant_count}
                          </span>
                        </div>
                      )}
                    </div>
                  </div>
                </Link>

                <button
                  onClick={() => onDelete(p.id, p.name)}
                  disabled={p.tenant_count > 0}
                  className={`w-full py-2.5 px-4 text-sm font-semibold border-t transition-colors flex items-center justify-center gap-2 ${
                    p.tenant_count > 0
                      ? "bg-gray-50 text-gray-400 cursor-not-allowed border-gray-100"
                      : "bg-red-50 text-red-600 hover:bg-red-100 border-red-100"
                  }`}
                  title={
                    p.tenant_count > 0
                      ? "Cannot delete: Property has tenants"
                      : "Delete property"
                  }
                >
                  <Icon name="trash" size={14} />
                  {p.tenant_count > 0 ? "Has tenants" : t("common.delete")}
                </button>
              </div>
            ))}
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

      <div className="h-3.5" />
    </>
  );
}
