// Reusable gender (applicable_for) selector and facility picker for the
// property / unit creation and editing forms.

export function GenderSelect({ value, onChange, t, className = "" }) {
  return (
    <select
      className={`select ${className}`.trim()}
      value={value}
      onChange={(e) => onChange(e.target.value)}
    >
      <option value="both">{t("gender.both")}</option>
      <option value="male">{t("gender.male")}</option>
      <option value="female">{t("gender.female")}</option>
    </select>
  );
}

// `facilities` are lookup rows ({ name }); `selected` is an array of names.
export function FacilityPicker({ facilities, selected, onChange, t }) {
  const toggle = (name) => {
    if (selected.includes(name)) onChange(selected.filter((x) => x !== name));
    else onChange([...selected, name]);
  };

  if (facilities.length === 0) {
    return <div className="hint">{t("settings.noOptionsYet")}</div>;
  }

  return (
    <div className="facility-picker">
      {facilities.map((f) => {
        const on = selected.includes(f.name);
        return (
          <label
            key={f.name}
            className={`facility-chip${on ? " active" : ""}`}
          >
            <input
              type="checkbox"
              checked={on}
              onChange={() => toggle(f.name)}
            />
            <span>{f.name}</span>
          </label>
        );
      })}
    </div>
  );
}
