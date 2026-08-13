import { useTranslation } from "react-i18next";
import Icon from "./Icon";

// Compact pager: prev/next + up to 5 page numbers with ellipses, plus a
// "showing X–Y of Z" summary. Renders nothing when there's only one page.
export default function Pagination({
  page,
  totalPages,
  totalItems,
  pageSize,
  onChange,
}) {
  const { t } = useTranslation();
  if (totalPages <= 1) return null;

  const start = totalItems === 0 ? 0 : (page - 1) * pageSize + 1;
  const end = Math.min(page * pageSize, totalItems);

  const pages = pageNumbers(page, totalPages);

  return (
    <div className="pagination">
      <div className="pagination-summary">
        {t("pagination.showing", { start, end, total: totalItems })}
      </div>
      <div className="pagination-controls">
        <button
          className="btn btn-ghost btn-sm btn-icon"
          onClick={() => onChange(page - 1)}
          disabled={page <= 1}
          aria-label={t("pagination.previous")}
        >
          <Icon
            name="chevronRight"
            size={15}
            style={{ transform: "rotate(180deg)" }}
          />
        </button>
        {pages.map((p, i) =>
          p === "…" ? (
            <span key={`gap-${i}`} className="pagination-ellipsis">
              …
            </span>
          ) : (
            <button
              key={p}
              className={`pagination-page${p === page ? " active" : ""}`}
              onClick={() => onChange(p)}
              aria-current={p === page ? "page" : undefined}
            >
              {p}
            </button>
          ),
        )}
        <button
          className="btn btn-ghost btn-sm btn-icon"
          onClick={() => onChange(page + 1)}
          disabled={page >= totalPages}
          aria-label={t("pagination.next")}
        >
          <Icon name="chevronRight" size={15} />
        </button>
      </div>
    </div>
  );
}

// Builds a compact page list like [1, '…', 4, 5, 6, '…', 12] around the
// current page, always keeping first/last visible.
function pageNumbers(current, total) {
  const delta = 1;
  const range = [];
  for (
    let i = Math.max(2, current - delta);
    i <= Math.min(total - 1, current + delta);
    i++
  ) {
    range.push(i);
  }
  const pages = [1];
  if (range[0] > 2) pages.push("…");
  pages.push(...range);
  if (range[range.length - 1] < total - 1) pages.push("…");
  if (total > 1) pages.push(total);
  return pages;
}
