import { useRealtimeList } from "./useRealtimeList";

export function useProperties() {
  const res = useRealtimeList({
    table: "properties",
    select: "*, property_types(key, name), units(count)",
    order: "name",
  });

  const data = (res.data ?? []).map((p) => ({
    ...p,
    unit_count: p.unit_count ?? p.units?.[0]?.count ?? 0,
  }));

  return { ...res, data };
}

export function useProperty(id) {
  return useRealtimeList({
    table: "properties",
    select: "*, property_types(key, name), units(*)",
    eq: id ? ["id", id] : null,
    realtimeFilter: null,
    enabled: Boolean(id),
  });
}

export function useUnitTemplates() {
  return useRealtimeList({ table: "unit_templates", order: "name" });
}

export function useUnits(propertyId) {
  return useRealtimeList({
    table: "units",
    select: "*, seats(*), leases(seat_id, status)",
    eq: propertyId ? ["property_id", propertyId] : null,
    order: "unit_number",
    realtimeFilter: null,
    enabled: Boolean(propertyId),
  });
}

export function usePropertyOptions() {
  return useRealtimeList({
    table: "properties",
    select:
      "*, property_types(key, name), units(id, unit_number, rent_amount, seats(id, seat_number, rent_amount), leases(seat_id, status))",
    order: "name",
  });
}
