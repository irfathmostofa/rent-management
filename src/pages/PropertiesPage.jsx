import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useProperties } from "../hooks/useProperties";
import { usePagination } from "../hooks/usePagination";
import Spinner from "../components/ui/Spinner";
import EmptyState from "../components/ui/EmptyState";
import Pagination from "../components/ui/Pagination";
import Icon from "../components/ui/Icon";
import { useState } from "react";

export default function PropertiesPage() {
  const { t } = useTranslation();
  const { data, loading } = useProperties();
  const [searchQuery, setSearchQuery] = useState("");
  const [typeFilter, setTypeFilter] = useState("all");

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

  return (
    <div>
      {/* Header Section */}
      <div className="page-head">
        <div>
          <h1 className="page-title">{t("properties.title")}</h1>
          <p className="page-sub">{t("properties.subtitle")}</p>
        </div>
        <div className="desktop-actions">
          <Link to="/admin/properties/new/apartment" className="btn btn-primary">
            <Icon name="building" size={16} /> {t("properties.newApartment")}
          </Link>
          <Link to="/admin/properties/new/cottage" className="btn btn-secondary">
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
      />
    </div>
  );
}

// Keyed by the active filters in the parent (see `key={...}` at the call
// site) so changing the search or type filter remounts this component and
// resets pagination back to page 1, instead of staying on a page that no
// longer makes sense for the new result set.
function PagedProperties({ items }) {
  const { t } = useTranslation();
  const { pageItems, page, setPage, totalPages, totalItems, pageSize } =
    usePagination(items, 20);

  return (
    <>
      {/* Desktop Table View */}
      <div className="desktop-table">
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
                      <Link to={`/admin/properties/${p.id}`} className="bold">
                        {p.name}
                      </Link>{" "}
                      {p.is_public && (
                        <span className="badge badge-green">
                          {t("properties.public")}
                        </span>
                      )}
                    </td>
                    <td>
                      <span className="badge badge-indigo">
                        {p.property_types?.name || "—"}
                      </span>
                    </td>
                    <td className="muted small">
                      {[p.address_line1, p.city].filter(Boolean).join(", ") ||
                        "—"}
                    </td>
                    <td className="mono">{p.unit_count}</td>
                    <td>
                      <span className="badge badge-gray">{p.grace_days}d</span>
                    </td>
                    <td className="text-right">
                      <Link
                        to={`/admin/properties/${p.id}`}
                        className="btn btn-ghost btn-sm"
                      >
                        {t("common.view")}
                      </Link>
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

      {/* Mobile List View - Improved */}
      <div className="list">
        {items.length === 0 ? (
          <div className="empty-state-mobile">
            <EmptyState
              title={t("properties.noFound")}
              body={t("properties.noFoundBody")}
              icon="building"
            />
          </div>
        ) : (
          <>
            {pageItems.map((p) => (
              <Link
                key={p.id}
                to={`/admin/properties/${p.id}`}
                className="property-card"
              >
                <div className="property-card-header">
                  <div className="property-card-icon">
                    <Icon name="building" size={20} />
                  </div>
                  <div className="property-card-title-group">
                    <div className="property-card-title">{p.name}</div>
                    <div className="property-card-type">
                      <span className="badge badge-indigo">
                        {p.property_types?.name || "—"}
                      </span>{" "}
                      {p.is_public && (
                        <span className="badge badge-green">
                          {t("properties.public")}
                        </span>
                      )}
                    </div>
                  </div>
                  <Icon
                    name="chevronRight"
                    size={20}
                    className="property-card-arrow"
                  />
                </div>

                <div className="property-card-body">
                  <div className="property-card-address">
                    <Icon name="mapPin" size={14} className="muted" />
                    <span className="muted small">
                      {[p.address_line1, p.city].filter(Boolean).join(", ") ||
                        "—"}
                    </span>
                  </div>

                  <div className="property-card-stats">
                    <div className="property-card-stat">
                      <span className="property-card-stat-label">
                        {t("properties.unitsShort", { count: p.unit_count })}
                      </span>
                      <span className="property-card-stat-value">
                        {p.unit_count}
                      </span>
                    </div>
                    <div className="property-card-stat">
                      <span className="property-card-stat-label">
                        {t("properties.grace", { days: p.grace_days })}
                      </span>
                      <span className="property-card-stat-value">
                        {p.grace_days}d
                      </span>
                    </div>
                  </div>
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
          </>
        )}
      </div>

      <div style={{ height: 14 }} />
    </>
  );
}
