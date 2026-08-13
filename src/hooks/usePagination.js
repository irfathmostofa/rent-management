import { useEffect, useMemo, useState } from "react";

// Client-side pagination for an already-loaded array. Data hooks in this
// app (useRealtimeList) fetch the full table, so this slices in memory —
// good enough for per-owner data volumes and avoids restructuring every
// query into limit/offset + count.
//
// Usage:
//   const { pageItems, page, setPage, totalPages, pageSize, setPageSize, totalItems } =
//     usePagination(filteredRows, 20)
export function usePagination(items, initialPageSize = 20) {
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(initialPageSize);

  const rows = useMemo(() => items ?? [], [items]);
  const totalItems = rows.length;
  const totalPages = Math.max(1, Math.ceil(totalItems / pageSize));

  // Clamp the current page whenever the underlying data shrinks (filters
  // changed, rows deleted, page size changed) so we never render an
  // out-of-range slice.
  useEffect(() => {
    if (page > totalPages) setPage(totalPages);
  }, [page, totalPages]);

  const pageItems = useMemo(() => {
    const start = (page - 1) * pageSize;
    return rows.slice(start, start + pageSize);
  }, [rows, page, pageSize]);

  return {
    pageItems,
    page,
    setPage,
    pageSize,
    setPageSize,
    totalPages,
    totalItems,
  };
}
