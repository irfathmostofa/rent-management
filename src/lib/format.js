import { useSyncExternalStore } from "react";
import i18n from "../i18n";

// Active currency for the owner account. Defaults to BDT until the access
// payload (which carries owner_settings.currency) is loaded.
let activeCurrency = "BDT";
const currencyListeners = new Set();

export function setActiveCurrency(code) {
  const next = (code || "BDT").toUpperCase();
  if (next === activeCurrency) return;
  activeCurrency = next;
  currencyListeners.forEach((l) => l());
}

export function getActiveCurrency() {
  return activeCurrency;
}

export function subscribeCurrency(fn) {
  currencyListeners.add(fn);
  return () => currencyListeners.delete(fn);
}

// Subscribe to currency changes from React (Settings selector, previews).
export function useActiveCurrency() {
  return useSyncExternalStore(subscribeCurrency, getActiveCurrency);
}

function formatter() {
  return new Intl.NumberFormat(i18n.language === "bn" ? "bn-BD" : "en-IE", {
    style: "currency",
    currency: activeCurrency,
    minimumFractionDigits: 0,
  });
}

function dateLocale() {
  return i18n.language === "bn" ? "bn-BD" : "en-IE";
}

export function money(value) {
  if (value === null || value === undefined) return "—";
  return formatter().format(Number(value));
}

export function moneyCompact(value) {
  if (value === null || value === undefined) return "—";
  return formatter().format(Number(value));
}

export function formatDate(value) {
  if (!value) return "—";
  return new Date(value).toLocaleDateString(dateLocale(), {
    day: "numeric",
    month: "short",
    year: "numeric",
  });
}

export function formatDateShort(value) {
  if (!value) return "—";
  return new Date(value).toLocaleDateString(dateLocale(), {
    day: "numeric",
    month: "short",
  });
}

export function formatDateTime(value) {
  if (!value) return "—";
  return new Date(value).toLocaleString(dateLocale(), {
    day: "numeric",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function relativeTime(value) {
  if (!value) return "—";
  const diff = Date.now() - new Date(value).getTime();
  const mins = Math.round(diff / 60000);
  const t = i18n.t.bind(i18n);
  if (mins < 1) return t("time.justNow");
  if (mins < 60) return t("time.minutesAgo", { count: mins });
  const hours = Math.round(mins / 60);
  if (hours < 24) return t("time.hoursAgo", { count: hours });
  const days = Math.round(hours / 24);
  if (days < 30) return t("time.daysAgo", { count: days });
  return formatDate(value);
}

export function initials(firstName, lastName) {
  return (
    `${(firstName || "")[0] || ""}${(lastName || "")[0] || ""}`.toUpperCase() ||
    "?"
  );
}

export function fullName(tenant) {
  if (!tenant) return "—";
  return `${tenant.first_name || ""} ${tenant.last_name || ""}`.trim();
}

export function titleCase(value) {
  if (!value) return value;
  return value.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

// Render a rooms map {"bedroom":2,"bathroom":1,"balcony":1} as a short label
// like "2 bed · 1 bath · 1 balcony". Names come from the roomTypes lookup.
export function formatRooms(rooms, roomTypes = []) {
  if (!rooms || typeof rooms !== "object") return "—";
  const labels = [];
  for (const t of roomTypes) {
    const count = Number(rooms[t.key]);
    if (count > 0) labels.push(`${count} ${t.name.toLowerCase()}`);
  }
  if (labels.length === 0) return "—";
  return labels.join(" · ");
}
