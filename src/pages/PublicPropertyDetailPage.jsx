import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import PublicShell from "../components/public/PublicShell";
import Icon from "../components/ui/Icon";
import { money } from "../lib/format";
import { fetchPropertyDetail } from "../lib/publicDirectory";

function facilityNames(list) {
  if (!Array.isArray(list)) return [];
  return list.map((f) => (typeof f === "string" ? f : f?.name)).filter(Boolean);
}

// Normalize a phone number for the wa.me link (BD numbers -> 880...).
function waNumber(phone) {
  if (!phone) return "";
  let n = String(phone).replace(/[^0-9]/g, "");
  if (n.startsWith("00")) n = n.slice(2);
  if (n.startsWith("0")) n = "880" + n.slice(1);
  return n;
}

// Pre-filled tenant enquiry (kept in Bengali as requested).
function interestMessage(unitNumber, propertyName) {
  const prop = propertyName ? ` "${propertyName}" এর` : "";
  return `আসসালামু আলাইকুম, আমি${prop} ইউনিট ${unitNumber} ভাড়া নিতে আগ্রহী। অনুগ্রহ করে আমার সাথে যোগাযোগ করুন।`;
}

function GenderBadge({ value }) {
  const { t } = useTranslation();
  if (!value) return null;
  return (
    <span className={`gender-badge ${value}`}>
      {value === "male"
        ? t("gender.male")
        : value === "female"
          ? t("gender.female")
          : t("gender.both")}
    </span>
  );
}

function Facilities({ items }) {
  const names = facilityNames(items);
  if (names.length === 0) return null;
  return (
    <div className="flex flex-wrap gap-1.5">
      {names.map((f) => (
        <span
          key={f}
          className="rounded-full bg-indigo-50 px-2.5 py-0.5 text-xs font-semibold text-indigo-600"
        >
          {f}
        </span>
      ))}
    </div>
  );
}

function Gallery({ images, name }) {
  const { t } = useTranslation();
  const list = Array.isArray(images) ? images.filter(Boolean) : [];
  const [active, setActive] = useState(0);
  const current = list[active] ?? list[0];

  if (!current) {
    return (
      <div className="grid aspect-[16/9] w-full place-items-center rounded-2xl bg-slate-200 text-slate-400">
        <Icon name="image" size={56} />
      </div>
    );
  }

  return (
    <div>
      <img
        src={current}
        alt={`${name} - ${active + 1}`}
        className="aspect-[16/9] w-full rounded-2xl object-cover shadow"
      />
      {list.length > 1 && (
        <div className="mt-3 grid grid-cols-5 gap-2">
          {list.map((img, i) => (
            <button
              key={img + i}
              type="button"
              onClick={() => setActive(i)}
              className={`overflow-hidden rounded-lg border-2 transition ${
                i === active
                  ? "border-indigo-500"
                  : "border-transparent opacity-70 hover:opacity-100"
              }`}
              aria-label={`${t("public.image")} ${i + 1}`}
            >
              <img
                src={img}
                alt=""
                className="aspect-video w-full object-cover"
              />
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

function UnitCard({ unit, t, ownerPhone, propertyName }) {
  const [open, setOpen] = useState(false);
  const seats = Array.isArray(unit.seats) ? unit.seats : [];
  const availableSeats = seats.filter((s) => s.available);
  const hasSeats = seats.length > 0;
  const waLink = ownerPhone
    ? `https://wa.me/${waNumber(ownerPhone)}?text=${encodeURIComponent(
        interestMessage(unit.unit_number, propertyName),
      )}`
    : null;

  return (
    <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
      <button
        type="button"
        onClick={() => setOpen(!open)}
        className="flex w-full flex-wrap items-center gap-3 p-4 text-left transition hover:bg-slate-50"
      >
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <span className="font-extrabold text-slate-900">
              {t("public.unit")} {unit.unit_number}
            </span>
            <GenderBadge value={unit.applicable_for} />
            {!unit.available && (
              <span className="rounded-full bg-red-50 px-2.5 py-0.5 text-xs font-bold text-red-600">
                {t("public.booked")}
              </span>
            )}
          </div>
          <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-sm text-slate-500">
            {unit.floor != null && (
              <span>
                {t("public.floor")} {unit.floor}
              </span>
            )}
            {unit.dimension && <span>{unit.dimension}</span>}
            {hasSeats && (
              <span>
                {t("public.seatCount", {
                  count: availableSeats.length,
                  total: seats.length,
                })}
              </span>
            )}
          </div>
        </div>
        <div className="text-right">
          <div className="text-lg font-extrabold text-indigo-600">
            {unit.rent_amount != null ? money(unit.rent_amount) : "—"}
          </div>
          {unit.deposit_amount > 0 && (
            <div className="text-xs text-slate-400">
              {t("public.deposit")} {money(unit.deposit_amount)}
            </div>
          )}
        </div>
        <Icon
          name="chevronDown"
          size={18}
          className={`text-slate-400 transition ${open ? "rotate-180" : ""}`}
        />
      </button>

      {open && (
        <div className="border-t border-slate-100 p-4">
          {unit.description
            ? unit.description && (
                <p className="mb-3 text-sm text-slate-600">
                  {unit.description}
                </p>
              )
            : null}
          {facilityNames(unit.facilities).length > 0 && (
            <div className="mb-3">
              <div className="mb-1.5 text-xs font-bold uppercase tracking-wide text-slate-400">
                {t("public.facilities")}
              </div>
              <Facilities items={unit.facilities} />
            </div>
          )}

          {hasSeats && (
            <div>
              <div className="mb-1.5 text-xs font-bold uppercase tracking-wide text-slate-400">
                {t("public.seatsInUnit")}
              </div>
              <div className="space-y-2">
                {seats.map((s) => (
                  <div
                    key={s.id}
                    className="flex flex-wrap items-center gap-2 rounded-xl bg-slate-50 px-3 py-2"
                  >
                    <span className="text-sm font-bold text-slate-700">
                      {s.name || s.seat_number}
                    </span>
                    <GenderBadge value={s.applicable_for} />
                    <span className="ml-auto text-sm font-extrabold text-indigo-600">
                      {s.rent_amount != null ? money(s.rent_amount) : "—"}
                    </span>
                    {!s.available && (
                      <span className="rounded-full bg-red-50 px-2 py-0.5 text-xs font-bold text-red-600">
                        {t("public.booked")}
                      </span>
                    )}
                  </div>
                ))}
              </div>
            </div>
          )}

          {facilityNames(unit.facilities).length === 0 &&
            !hasSeats &&
            !unit.description && (
              <p className="text-sm text-slate-400">
                {t("public.noUnitDetails")}
              </p>
            )}
        </div>
      )}

      {waLink && (
        <div className="border-t border-slate-100 p-4">
          <a
            href={waLink}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-2 rounded-xl bg-green-500 px-4 py-2.5 text-sm font-bold text-white transition hover:bg-green-600"
          >
            <Icon name="chat" size={16} />
            {t("public.sendMessage")}
          </a>
        </div>
      )}
    </div>
  );
}

export default function PublicPropertyDetailPage() {
  const { id } = useParams();
  const { t } = useTranslation();
  const [detail, setDetail] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    let mounted = true;
    setLoading(true);
    fetchPropertyDetail(id)
      .then((d) => {
        if (!mounted) return;
        setDetail(d);
        setError(null);
      })
      .catch((e) => mounted && setError(e.message))
      .finally(() => mounted && setLoading(false));
    return () => {
      mounted = false;
    };
  }, [id]);

  if (loading) {
    return (
      <PublicShell>
        <div className="grid place-items-center py-24">
          <div className="h-8 w-8 animate-spin rounded-full border-2 border-slate-300 border-t-indigo-600" />
        </div>
      </PublicShell>
    );
  }

  if (error || !detail) {
    return (
      <PublicShell>
        <div className="grid place-items-center py-24 text-center">
          <div className="text-3xl font-extrabold text-slate-800">
            {t("public.notFound")}
          </div>
          <p className="mt-2 text-sm text-slate-500">
            {error || t("public.notFoundBody")}
          </p>
          <Link
            to="/"
            className="mt-4 inline-flex items-center gap-2 rounded-xl bg-indigo-600 px-5 py-2.5 text-sm font-bold text-white transition hover:bg-indigo-500"
          >
            <Icon name="arrowLeft" size={16} />
            {t("public.backToDirectory")}
          </Link>
        </div>
      </PublicShell>
    );
  }

  const units = Array.isArray(detail.units) ? detail.units : [];
  const location = [
    detail.address_line1,
    detail.address_line2,
    detail.city,
    detail.state,
    detail.postal_code,
    detail.country,
  ]
    .filter(Boolean)
    .join(", ");

  return (
    <PublicShell>
      <Link
        to="/"
        className="mb-4 inline-flex items-center gap-2 text-sm font-semibold text-indigo-600 hover:text-indigo-500"
      >
        <Icon name="arrowLeft" size={16} />
        {t("public.backToDirectory")}
      </Link>

      <div className="grid gap-6 lg:grid-cols-[1fr_340px]">
        <div>
          <Gallery images={detail.images} name={detail.name} />
        </div>

        <div className="space-y-4">
          <div>
            <div className="flex items-center gap-2">
              <span className="rounded-full bg-slate-900 px-3 py-1 text-xs font-bold text-white">
                {detail.property_type_name}
              </span>
              {detail.unit_count != null && (
                <span className="rounded-full bg-indigo-50 px-3 py-1 text-xs font-bold text-indigo-600">
                  {t("public.unitCount", { count: detail.unit_count })}
                </span>
              )}
            </div>
            <h1 className="mt-2 text-2xl font-extrabold text-slate-900 sm:text-3xl">
              {detail.name}
            </h1>
          </div>

          {location && (
            <p className="flex items-start gap-2 text-sm text-slate-600">
              <Icon
                name="mapPin"
                size={18}
                className="mt-0.5 shrink-0 text-slate-400"
              />
              {location}
            </p>
          )}

          {detail.description && (
            <p className="text-sm leading-relaxed text-slate-600">
              {detail.description}
            </p>
          )}

          {facilityNames(detail.facilities).length > 0 && (
            <div>
              <div className="mb-1.5 text-xs font-bold uppercase tracking-wide text-slate-400">
                {t("public.propertyFacilities")}
              </div>
              <Facilities items={detail.facilities} />
            </div>
          )}

          <div className="rounded-2xl border border-indigo-100 bg-indigo-50 p-4">
            <p className="text-sm font-semibold text-indigo-700">
              {t("public.interested")}
            </p>
            {detail.owner_name && (
              <p className="mt-2 text-sm font-bold text-slate-800">
                {detail.owner_name}
              </p>
            )}
            {detail.owner_phone && (
              <a
                href={`tel:${detail.owner_phone}`}
                className="mt-1 inline-flex items-center gap-2 text-sm font-bold text-indigo-700 hover:text-indigo-500"
              >
                <Icon name="phone" size={16} />
                {detail.owner_phone}
              </a>
            )}
            {/* <Link
              to="/feedback"
              className="mt-3 inline-flex items-center gap-2 rounded-xl bg-indigo-600 px-4 py-2.5 text-sm font-bold text-white transition hover:bg-indigo-500"
            >
              <Icon name="chat" size={16} />
              {t("public.contactOwner")}
            </Link> */}
          </div>
        </div>
      </div>

      <section className="mt-10">
        <h2 className="mb-4 text-lg font-extrabold text-slate-900">
          {t("public.unitsTitle")}
          <span className="ml-2 text-sm font-semibold text-slate-400">
            {units.length} {t("public.unitsTotal")}
          </span>
        </h2>
        {units.length === 0 ? (
          <p className="rounded-2xl border border-dashed border-slate-300 bg-white p-8 text-center text-sm text-slate-500">
            {t("public.noUnits")}
          </p>
        ) : (
          <div className="space-y-3">
            {units.map((u) => (
              <UnitCard
                key={u.id}
                unit={u}
                t={t}
                ownerPhone={detail.owner_phone}
                propertyName={detail.name}
              />
            ))}
          </div>
        )}
      </section>
    </PublicShell>
  );
}
