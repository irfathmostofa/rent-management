export default function Spinner() {
  return (
    <div className="loading-block">
      <div className="spinner" />
    </div>
  )
}

export function Loading({ loading, children }) {
  if (!loading) return children
  return (
    <div className="loading-block">
      <div className="spinner" />
    </div>
  )
}
