import { supabase, callRpc } from "./supabase";

const GATE_KEY = "rently.publicGate";

// Read-only public directory config (super admin controlled).
export async function fetchPublicSettings() {
  const data = await callRpc("public_directory_settings");
  return {
    enabled: data?.enabled !== false,
    gateEnabled: data?.gate_enabled !== false,
    nameRequired: data?.name_required !== false,
    phoneRequired: data?.phone_required !== false,
  };
}

// The gate approval is stored on the visitor's browser (public page, no auth).
export function getGateApproval() {
  try {
    return JSON.parse(localStorage.getItem(GATE_KEY) || "null");
  } catch {
    return null;
  }
}

export function setGateApproval(info) {
  try {
    localStorage.setItem(GATE_KEY, JSON.stringify(info));
  } catch {
    // ignore
  }
}

export function clearGateApproval() {
  try {
    localStorage.removeItem(GATE_KEY);
  } catch {
    // ignore
  }
}

// Validate the gate fields per the super-admin's required flags.
export function validateGate(info, { nameRequired, phoneRequired }) {
  const errors = {};
  if (nameRequired) {
    const name = (info?.name || "").trim();
    if (name.length < 2) errors.name = "nameTooShort";
  }
  if (phoneRequired) {
    const phone = (info?.phone || "").trim();
    if (!/^\+?[\d\s\-()]{7,}$/.test(phone)) errors.phone = "phoneInvalid";
  }
  return errors;
}

export async function fetchListings({ minPrice, maxPrice, gender } = {}) {
  return (
    (await callRpc("public_listings", {
      p_min_price:
        minPrice !== undefined && minPrice !== "" ? Number(minPrice) : null,
      p_max_price:
        maxPrice !== undefined && maxPrice !== "" ? Number(maxPrice) : null,
      p_gender: gender && gender !== "all" ? gender : null,
    })) ?? []
  );
}

export async function fetchPropertyDetail(id) {
  return callRpc("public_property_detail", { p_property_id: id });
}

export async function submitFeedback(payload) {
  const { error } = await supabase.from("feedback").insert(payload);
  if (error) throw error;
}
