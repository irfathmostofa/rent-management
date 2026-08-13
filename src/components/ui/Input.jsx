export function Field({ label, hint, children }) {
  return (
    <div className="field">
      {label && <label className="label">{label}</label>}
      {children}
      {hint && <div className="hint">{hint}</div>}
    </div>
  );
}

export function Input({ className = "", ...props }) {
  return <input className={`input ${className}`.trim()} {...props} />;
}

export function Select({ children, className = "", ...props }) {
  return (
    <select className={`select ${className}`.trim()} {...props}>
      {children}
    </select>
  );
}

export function Textarea({ className = "", ...props }) {
  return <textarea className={`textarea ${className}`.trim()} {...props} />;
}
