import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { supabase } from "../../lib/supabase";
import { usePagination } from "../../hooks/usePagination";
import Button from "../ui/Button";
import Badge from "../ui/Badge";
import Spinner from "../ui/Spinner";
import EmptyState from "../ui/EmptyState";
import Pagination from "../ui/Pagination";
import Icon from "../ui/Icon";
import { useToast } from "../ui/Toast";
import { formatDateTime } from "../../lib/format";

const STATUS_TONE = {
  new: "indigo",
  reviewed: "gray",
  archived: "gray",
};

const CATEGORY_ICON = {
  general: "chat",
  suggestion: "info",
  issue: "alert",
  praise: "star",
};

export default function FeedbackManager() {
  const { t } = useTranslation();
  const toast = useToast();
  const [items, setItems] = useState(null);
  const [filter, setFilter] = useState("new");
  const [openId, setOpenId] = useState(null);

  const load = useCallback(async () => {
    let query = supabase
      .from("feedback")
      .select("*")
      .order("created_at", { ascending: false })
      .limit(200);
    if (filter !== "all") query = query.eq("status", filter);
    const { data, error } = await query;
    if (error) {
      toast.error(error.message);
      return;
    }
    setItems(data ?? []);
  }, [filter, toast]);

  useEffect(() => {
    load();
  }, [load]);

  const pagination = usePagination(items ?? [], 20);

  const setStatus = async (id, status) => {
    const { error } = await supabase
      .from("feedback")
      .update({ status })
      .eq("id", id);
    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success(t("admin.feedbackUpdated"));
    if (status === "archived") setOpenId(null);
    load();
  };

  return (
    <div>
      <div className="mb-4 flex flex-wrap gap-2">
        {["new", "reviewed", "archived", "all"].map((s) => (
          <Button
            key={s}
            size="sm"
            variant={filter === s ? "primary" : "secondary"}
            onClick={() => setFilter(s)}
          >
            {t(`admin.feedbackFilter${s.charAt(0).toUpperCase() + s.slice(1)}`)}
            {s === "new" && items && items.some((i) => i.status === "new") ? (
              <span className="ml-1 rounded-full bg-red-500 px-1.5 text-[10px] font-bold text-white">
                {items.filter((i) => i.status === "new").length}
              </span>
            ) : null}
          </Button>
        ))}
      </div>

      {!items ? (
        <Spinner />
      ) : items.length === 0 ? (
        <EmptyState
          icon="chat"
          title={t("admin.noFeedback")}
          body={t("admin.noFeedbackBody")}
        />
      ) : (
        <div className="card table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>{t("admin.feedbackColWhen")}</th>
                <th>{t("admin.feedbackColFrom")}</th>
                <th>{t("admin.feedbackColRating")}</th>
                <th>{t("admin.feedbackColCategory")}</th>
                <th>{t("admin.feedbackColMessage")}</th>
                <th>{t("admin.feedbackColStatus")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {pagination.pageItems.map((f) => (
                <tr key={f.id}>
                  <td className="small muted whitespace-nowrap">
                    {formatDateTime(f.created_at)}
                  </td>
                  <td>
                    <div className="bold">{f.name}</div>
                    {f.phone && <div className="small muted">{f.phone}</div>}
                    {f.email && <div className="small muted">{f.email}</div>}
                  </td>
                  <td>
                    {f.rating ? (
                      <span className="flex items-center gap-0.5 text-amber-500">
                        {Array.from({ length: f.rating }).map((_, i) => (
                          <Icon key={i} name="star" size={14} />
                        ))}
                      </span>
                    ) : (
                      <span className="muted small">—</span>
                    )}
                  </td>
                  <td>
                    {f.category ? (
                      <span className="flex items-center gap-1 text-sm capitalize">
                        <Icon name={CATEGORY_ICON[f.category] || "chat"} size={14} />
                        {f.category}
                      </span>
                    ) : (
                      <span className="muted small">—</span>
                    )}
                  </td>
                  <td>
                    <button
                      type="button"
                      className="max-w-[280px] truncate text-left text-sm text-slate-700 underline decoration-slate-300 underline-offset-2 hover:text-indigo-600"
                      onClick={() => setOpenId(openId === f.id ? null : f.id)}
                    >
                      {f.message}
                    </button>
                    {openId === f.id && (
                      <div className="mt-2 whitespace-pre-wrap rounded-lg bg-slate-50 p-3 text-sm text-slate-700">
                        {f.message}
                      </div>
                    )}
                  </td>
                  <td>
                    <Badge value={f.status} tone={STATUS_TONE[f.status]}>
                      {t(`admin.feedbackStatus${f.status}`)}
                    </Badge>
                  </td>
                  <td className="text-right whitespace-nowrap">
                    {f.status !== "reviewed" && (
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => setStatus(f.id, "reviewed")}
                      >
                        {t("admin.feedbackMarkReviewed")}
                      </Button>
                    )}
                    {f.status !== "archived" && (
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => setStatus(f.id, "archived")}
                      >
                        {t("admin.feedbackArchive")}
                      </Button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <Pagination
            page={pagination.page}
            totalPages={pagination.totalPages}
            totalItems={pagination.totalItems}
            pageSize={pagination.pageSize}
            onChange={pagination.setPage}
          />
        </div>
      )}
    </div>
  );
}
