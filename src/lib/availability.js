// Availability helpers for units/seats based on their ACTIVE leases.
// `unit.leases` must be included in the query (seat_id null = whole-unit lease).

export function isUnitAvailable(unit) {
  return !(unit?.leases ?? []).some(
    (l) => l.status === "active" && l.seat_id === null,
  );
}

export function isSeatAvailable(unit, seatId) {
  const leases = unit?.leases ?? [];
  // If the whole unit is leased out, no individual seat is bookable.
  if (leases.some((l) => l.status === "active" && l.seat_id === null))
    return false;
  return !leases.some((l) => l.status === "active" && l.seat_id === seatId);
}

// True if there is nothing left to offer on this unit at all:
// - apartments / whole-unit rentals: the unit itself is taken
// - cottages: every seat is taken (and there's at least one seat)
export function isUnitFullyBooked(unit) {
  if (!isUnitAvailable(unit)) return true;
  const seats = unit?.seats ?? [];
  if (seats.length === 0) return false;
  return seats.every((s) => !isSeatAvailable(unit, s.id));
}

// Available seats for a given unit (empty array if unit/seats missing).
export function availableSeats(unit) {
  return (unit?.seats ?? []).filter((s) => isSeatAvailable(unit, s.id));
}
