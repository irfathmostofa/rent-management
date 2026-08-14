import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import PublicShell from "../components/public/PublicShell";
import GateModal from "../components/public/GateModal";
import Icon from "../components/ui/Icon";
import { money } from "../lib/format";
import {
  fetchPublicSettings,
  fetchListings,
  getGateApproval,
  setGateApproval,
} from "../lib/publicDirectory";

function GenderBadges({ values }) {
  const { t } = useTranslation();
  const list = Array.isArray(values) ? values : [];
  return (
    <div className="flex flex-wrap gap-1.5">
      {list.map((v) => (
        <span key={v} className={`gender-badge ${v}`}>
          {v === "male"
            ? t("gender.male")
            : v === "female"
              ? t("gender.female")
              : t("gender.both")}
        </span>
      ))}
    </div>
  );
}

function PropertyCard({ p }) {
  const { t } = useTranslation();
  const img = p.images?.[0];
  const facilities = p.facilities ?? [];
  const shownFacilities = facilities.slice(0, 4);

  return (
    <Link
      to={`/rent/${p.id}`}
      className="group flex flex-col overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm transition hover:-translate-y-0.5 hover:shadow-lg"
    >
      <div className="relative aspect-[4/3] w-full overflow-hidden bg-slate-100">
        {img ? (
          <img
            src={img}
            alt={p.name}
            className="h-full w-full object-cover transition group-hover:scale-105"
          />
        ) : (
          <div className="grid h-full w-full place-items-center text-slate-300">
            <Icon name="building" size={48} />
          </div>
        )}
        <span className="absolute left-3 top-3 rounded-full bg-slate-900/80 px-3 py-1 text-xs font-bold text-white backdrop-blur">
          {p.property_type_name}
        </span>
      </div>

      <div className="flex flex-1 flex-col gap-2 p-4">
        <div className="flex items-start justify-between gap-2">
          <h3 className="text-base font-extrabold text-slate-900">{p.name}</h3>
        </div>
        <p className="flex items-center gap-1.5 text-sm text-slate-500">
          <Icon name="mapPin" size={15} />
          {[p.address_line1, p.city, p.country].filter(Boolean).join(", ") ||
            t("public.locationUnknown")}
        </p>

        <GenderBadges values={p.applicable_for} />

        {shownFacilities.length > 0 && (
          <div className="flex flex-wrap gap-1.5">
            {shownFacilities.map((f) => (
              <span
                key={f}
                className="rounded-full bg-indigo-50 px-2.5 py-0.5 text-xs font-semibold text-indigo-600"
              >
                {f}
              </span>
            ))}
            {facilities.length > shownFacilities.length && (
              <span className="rounded-full bg-slate-100 px-2.5 py-0.5 text-xs font-semibold text-slate-500">
                +{facilities.length - shownFacilities.length}
              </span>
            )}
          </div>
        )}

        <div className="mt-auto flex items-center justify-between border-t border-slate-100 pt-3">
          <div>
            <div className="text-[11px] font-semibold uppercase tracking-wide text-slate-400">
              {t("public.from")}
            </div>
            <div className="text-lg font-extrabold text-indigo-600">
              {p.min_rent != null ? money(p.min_rent) : "—"}
            </div>
          </div>
          <div className="flex gap-4 text-sm">
            {p.available_rooms > 0 && (
              <div className="text-center">
                <div className="font-extrabold text-slate-800">
                  {p.available_rooms}
                </div>
                <div className="text-[11px] text-slate-400">
                  {t("public.rooms")}
                </div>
              </div>
            )}
            {p.available_seats > 0 && (
              <div className="text-center">
                <div className="font-extrabold text-slate-800">
                  {p.available_seats}
                </div>
                <div className="text-[11px] text-slate-400">
                  {t("public.seats")}
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </Link>
  );
}

export default function PublicDirectoryPage() {
  const { t } = useTranslation();
  const [settings, setSettings] = useState(null);
  const [approved, setApproved] = useState(() => getGateApproval());
  const [listings, setListings] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [filters, setFilters] = useState({
    minPrice: "",
    maxPrice: "",
    gender: "all",
  });
  const [isFilterOpen, setIsFilterOpen] = useState(false);

  useEffect(() => {
    let mounted = true;
    fetchPublicSettings()
      .then((s) => mounted && setSettings(s))
      .catch((e) => mounted && setError(e.message));
    return () => {
      mounted = false;
    };
  }, []);

  const needsGate =
    settings?.enabled &&
    settings?.gateEnabled &&
    (settings?.nameRequired || settings?.phoneRequired) &&
    !approved;

  const allowFetch = settings?.enabled && !needsGate;

  useEffect(() => {
    if (!allowFetch) return;
    let mounted = true;
    setLoading(true);
    fetchListings(filters)
      .then((rows) => mounted && setListings(rows))
      .catch((e) => mounted && setError(e.message))
      .finally(() => mounted && setLoading(false));
    return () => {
      mounted = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [allowFetch, filters.minPrice, filters.maxPrice, filters.gender]);

  const resultCount = useMemo(() => listings?.length ?? 0, [listings]);

  const handleClearFilters = () => {
    setFilters({
      minPrice: "",
      maxPrice: "",
      gender: "all",
    });
  };

  const hasActiveFilters =
    filters.minPrice || filters.maxPrice || filters.gender !== "all";

  if (error) {
    return (
      <PublicShell>
        <div className="grid place-items-center py-24 text-center">
          <div className="text-3xl font-extrabold text-slate-800">
            {t("public.unavailable")}
          </div>
          <p className="mt-2 text-sm text-slate-500">{error}</p>
        </div>
      </PublicShell>
    );
  }

  if (settings === null) {
    return (
      <PublicShell>
        <div className="grid place-items-center py-24">
          <div className="h-8 w-8 animate-spin rounded-full border-2 border-slate-300 border-t-indigo-600" />
        </div>
      </PublicShell>
    );
  }

  if (!settings.enabled) {
    return (
      <PublicShell>
        <div className="grid place-items-center py-24 text-center">
          <div className="text-3xl font-extrabold text-slate-800">
            {t("public.directoryClosed")}
          </div>
          <p className="mt-2 text-sm text-slate-500">
            {t("public.directoryClosedBody")}
          </p>
        </div>
      </PublicShell>
    );
  }

  return (
    <PublicShell>
      {needsGate && (
        <GateModal
          nameRequired={settings.nameRequired}
          phoneRequired={settings.phoneRequired}
          onApproved={(info) => {
            setGateApproval(info);
            setApproved(info);
          }}
        />
      )}

      <section className="public-dir-hero">
        <h1 className="text-2xl font-extrabold sm:text-3xl">
          {t("public.heroTitle")}
        </h1>
        <p className="mt-2 max-w-2xl text-sm text-indigo-100 sm:text-base">
          {t("public.heroSubtitle")}
        </p>
        <Link
          to="/admin/login"
          className="mt-5 inline-flex items-center gap-2 rounded-xl bg-white px-5 py-2.5 text-sm font-bold text-indigo-700 shadow transition hover:bg-indigo-50"
        >
          <Icon
            name="arrowLeft"
            size={16}
            className="rotate-180  text-indigo-700"
          />
          <p className=" text-indigo-700">{t("public.becomeOwner")}</p>
        </Link>
      </section>

      {/* Professional Filter Section */}
      <section className="mb-6">
        {/* Filter Header */}
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-center gap-3">
            <button
              onClick={() => setIsFilterOpen(!isFilterOpen)}
              className="inline-flex items-center gap-2 rounded-xl bg-white px-4 py-2.5 text-sm font-semibold text-slate-700 shadow-sm transition hover:bg-slate-50 hover:shadow-md border border-slate-200"
            >
              <Icon name="filter" size={16} />
              {t("public.filters")}
              {hasActiveFilters && (
                <span className="ml-1 flex h-5 w-5 items-center justify-center rounded-full bg-indigo-600 text-[10px] font-bold text-white">
                  {
                    Object.values(filters).filter((v) => v && v !== "all")
                      .length
                  }
                </span>
              )}
            </button>
            {hasActiveFilters && (
              <button
                onClick={handleClearFilters}
                className="text-sm font-medium text-slate-500 transition hover:text-slate-700 hover:underline"
              >
                {t("public.clearFilters")}
              </button>
            )}
          </div>
          <div className="text-sm font-semibold text-slate-500">
            {loading ? (
              <span className="inline-flex items-center gap-2">
                <span className="h-4 w-4 animate-spin rounded-full border-2 border-slate-300 border-t-indigo-600" />
                {t("public.loading")}
              </span>
            ) : (
              t("public.results", { count: resultCount })
            )}
          </div>
        </div>

        {/* Filter Body */}
        {isFilterOpen && (
          <div className="mt-3 rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
              {/* Min Price */}
              <div>
                <label className="mb-1.5 block text-xs font-semibold uppercase tracking-wider text-slate-500">
                  <Icon name="dollar" size={12} className="inline mr-1" />
                  {t("public.minPrice")}
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-sm text-slate-400">
                    ৳
                  </span>
                  <input
                    type="number"
                    min={0}
                    value={filters.minPrice}
                    onChange={(e) =>
                      setFilters({ ...filters, minPrice: e.target.value })
                    }
                    placeholder="0"
                    className="w-full rounded-xl border border-slate-300 pl-8 pr-3 py-2.5 text-sm outline-none transition placeholder:text-slate-400 focus:border-indigo-500 focus:ring-2 focus:ring-indigo-200"
                  />
                </div>
              </div>

              {/* Max Price */}
              <div>
                <label className="mb-1.5 block text-xs font-semibold uppercase tracking-wider text-slate-500">
                  <Icon name="dollar" size={12} className="inline mr-1" />
                  {t("public.maxPrice")}
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-sm text-slate-400">
                    ৳
                  </span>
                  <input
                    type="number"
                    min={0}
                    value={filters.maxPrice}
                    onChange={(e) =>
                      setFilters({ ...filters, maxPrice: e.target.value })
                    }
                    placeholder={t("public.noLimit")}
                    className="w-full rounded-xl border border-slate-300 pl-8 pr-3 py-2.5 text-sm outline-none transition placeholder:text-slate-400 focus:border-indigo-500 focus:ring-2 focus:ring-indigo-200"
                  />
                </div>
              </div>

              {/* Gender */}
              <div>
                <label className="mb-1.5 block text-xs font-semibold uppercase tracking-wider text-slate-500">
                  <Icon name="user" size={12} className="inline mr-1" />
                  {t("public.gender")}
                </label>
                <select
                  value={filters.gender}
                  onChange={(e) =>
                    setFilters({ ...filters, gender: e.target.value })
                  }
                  className="w-full rounded-xl border border-slate-300 bg-white px-3 py-2.5 text-sm outline-none transition focus:border-indigo-500 focus:ring-2 focus:ring-indigo-200"
                >
                  <option value="all">{t("public.allGenders")}</option>
                  <option value="male">{t("gender.male")}</option>
                  <option value="female">{t("gender.female")}</option>
                  <option value="both">{t("gender.both")}</option>
                </select>
              </div>

              {/* Quick Actions */}
              <div className="flex items-end gap-2">
                <button
                  onClick={handleClearFilters}
                  className="w-full rounded-xl border border-slate-300 bg-white px-4 py-2.5 text-sm font-medium text-slate-600 transition hover:bg-slate-50 hover:border-slate-400"
                >
                  {t("public.clear")}
                </button>
                <button
                  onClick={() => setIsFilterOpen(false)}
                  className="w-full rounded-xl bg-indigo-600 px-4 py-2.5 text-sm font-bold text-white transition hover:bg-indigo-500"
                >
                  {t("public.apply")}
                </button>
              </div>
            </div>
          </div>
        )}

        {/* Active Filters Tags */}
        {hasActiveFilters && (
          <div className="mt-3 flex flex-wrap items-center gap-2">
            {filters.minPrice && (
              <span className="inline-flex items-center gap-1.5 rounded-full bg-indigo-50 px-3 py-1 text-xs font-medium text-indigo-700">
                {t("public.minPrice")}: ৳{filters.minPrice}
                <button
                  onClick={() => setFilters({ ...filters, minPrice: "" })}
                  className="ml-1 text-indigo-400 transition hover:text-indigo-600"
                >
                  ×
                </button>
              </span>
            )}
            {filters.maxPrice && (
              <span className="inline-flex items-center gap-1.5 rounded-full bg-indigo-50 px-3 py-1 text-xs font-medium text-indigo-700">
                {t("public.maxPrice")}: ৳{filters.maxPrice}
                <button
                  onClick={() => setFilters({ ...filters, maxPrice: "" })}
                  className="ml-1 text-indigo-400 transition hover:text-indigo-600"
                >
                  ×
                </button>
              </span>
            )}
            {filters.gender !== "all" && (
              <span className="inline-flex items-center gap-1.5 rounded-full bg-indigo-50 px-3 py-1 text-xs font-medium text-indigo-700">
                {t("public.gender")}: {t(`gender.${filters.gender}`)}
                <button
                  onClick={() => setFilters({ ...filters, gender: "all" })}
                  className="ml-1 text-indigo-400 transition hover:text-indigo-600"
                >
                  ×
                </button>
              </span>
            )}
          </div>
        )}
      </section>

      {/* Listings */}
      {loading ? (
        <div className="grid place-items-center py-20">
          <div className="h-8 w-8 animate-spin rounded-full border-2 border-slate-300 border-t-indigo-600" />
        </div>
      ) : resultCount === 0 ? (
        <div className="grid place-items-center rounded-2xl border border-dashed border-slate-300 bg-white py-20 text-center">
          <Icon name="building" size={40} className="text-slate-300" />
          <div className="mt-3 text-lg font-bold text-slate-700">
            {t("public.noListings")}
          </div>
          <p className="mt-1 text-sm text-slate-500">
            {t("public.noListingsBody")}
          </p>
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-3">
          {(listings ?? []).map((p) => (
            <PropertyCard key={p.id} p={p} />
          ))}
        </div>
      )}

      <div className="mt-10 text-center">
        <Link
          to="/feedback"
          className="inline-flex items-center gap-2 rounded-xl bg-slate-900 px-5 py-3 text-sm font-bold text-white transition hover:bg-slate-700"
        >
          <Icon name="chat" size={16} className="text-white" />
          <p className="text-white">{t("public.sendFeedback")}</p>
        </Link>
      </div>
    </PublicShell>
  );
}
