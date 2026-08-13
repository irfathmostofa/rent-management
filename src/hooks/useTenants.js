import { useRealtimeList } from "./useRealtimeList";

export function useTenants() {
  return useRealtimeList({
    table: "tenants",
    // unit + seat numbers are pulled in here (not just the count) so list
    // views can show exactly which room/seat each active lease occupies.
    select:
      "*, leases(*, unit:units(unit_number, property_id), seat:seats(seat_number))",
    order: "created_at",
    orderAsc: false,
  });
}

export function useTenant(id) {
  return useRealtimeList({
    table: "tenants",
    select: "*, leases(*, unit:units(*), seat:seats(*))",
    eq: id ? ["id", id] : null,
    realtimeFilter: null,
    enabled: Boolean(id),
  });
}

export function useLeases() {
  return useRealtimeList({
    table: "leases",
    select: "*, tenant:tenants(*), unit:units(*), seat:seats(*)",
    order: "created_at",
    orderAsc: false,
  });
}

export function useRentHistory(tenantId) {
  return useRealtimeList({
    table: "rent_history",
    select: "*",
    eq: tenantId ? ["tenant_id", tenantId] : null,
    order: "effective_date",
    orderAsc: false,
    realtimeFilter: null,
    enabled: Boolean(tenantId),
  });
}
