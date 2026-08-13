import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { callRpc } from "../../lib/supabase";
import Button from "../ui/Button";
import Spinner from "../ui/Spinner";
import EmptyState from "../ui/EmptyState";
import Icon from "../ui/Icon";
import { useToast } from "../ui/Toast";
import { formatDate } from "../../lib/format";

export default function DirectoryApprovals() {
  const { t } = useTranslation();
  const toast = useToast();
  const [items, setItems] = useState(null);
  const [busyId, setBusyId] = useState(null);
  const [rejectId, setRejectId] = useState(null);
  const [note, setNote] = useState("");

  const load = useCallback(async () => {
    try {
      const data = await callRpc("public_directory_pending");
      setItems(data ?? []);
    } catch (err) {
      toast.error(err.message);
    }
  }, [toast]);

  useEffect(() => {
    load();
  }, [load]);

  const review = async (id, approve, reviewNote = null) => {
    setBusyId(id);
    try {
      await callRpc("public_review_property", {
        p_property_id: id,
        p_approve: approve,
        p_note: reviewNote,
      });
      toast.success(
        approve
          ? t("admin.publicationApproved")
          : t("admin.publicationRejected"),
      );
      setRejectId(null);
      setNote("");
      await load();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setBusyId(null);
    }
  };

  return (
    <div>
      {!items ? (
        <Spinner />
      ) : items.length === 0 ? (
        <EmptyState
          icon="check"
          title={t("admin.noPendingPublications")}
          body={t("admin.noPendingPublicationsBody")}
        />
      ) : (
        <div className="space-y-3">
          {items.map((p) => (
            <div
              key={p.id}
              className="rounded-xl border border-slate-200 bg-white p-4"
            >
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <div className="flex items-center gap-2">
                    <span className="font-semibold text-slate-800">
                      {p.name}
                    </span>
                    <span className="rounded-full bg-amber-100 px-2 py-0.5 text-[11px] font-semibold text-amber-700">
                      {t("admin.publicationPending")}
                    </span>
                  </div>
                  <div className="mt-1 text-sm text-slate-500">
                    {p.business_name && (
                      <span>{p.business_name} · </span>
                    )}
                    {p.property_type_name}
                    {p.unit_count ? ` · ${p.unit_count}` : ""}
                    {[p.city, p.country].filter(Boolean).length > 0 && (
                      <>
                        {" · "}
                        {[p.city, p.country].filter(Boolean).join(", ")}
                      </>
                    )}
                  </div>
                  <div className="mt-0.5 text-xs text-slate-400">
                    {t("admin.publicationRequested")} {formatDate(p.created_at)}
                  </div>
                </div>
                <div className="flex items-center gap-2">
                  <Button
                    size="sm"
                    disabled={busyId === p.id}
                    onClick={() => review(p.id, true)}
                  >
                    <Icon name="check" size={14} /> {t("admin.publicationApprove")}
                  </Button>
                  <Button
                    variant="secondary"
                    size="sm"
                    disabled={busyId === p.id}
                    onClick={() => {
                      setRejectId(rejectId === p.id ? null : p.id);
                      setNote("");
                    }}
                  >
                    {t("admin.publicationReject")}
                  </Button>
                </div>
              </div>

              {rejectId === p.id && (
                <div className="mt-3 rounded-lg bg-slate-50 p-3">
                  <label className="block text-xs font-medium text-slate-600">
                    {t("admin.publicationRejectNote")}
                  </label>
                  <textarea
                    className="mt-1 w-full rounded-md border border-slate-300 bg-white p-2 text-sm"
                    rows={2}
                    value={note}
                    onChange={(e) => setNote(e.target.value)}
                    placeholder={t("admin.publicationRejectPlaceholder")}
                  />
                  <div className="mt-2 flex gap-2">
                    <Button
                      size="sm"
                      variant="danger"
                      disabled={busyId === p.id}
                      onClick={() => review(p.id, false, note || null)}
                    >
                      {t("admin.publicationConfirmReject")}
                    </Button>
                    <Button
                      size="sm"
                      variant="ghost"
                      onClick={() => {
                        setRejectId(null);
                        setNote("");
                      }}
                    >
                      {t("common.cancel")}
                    </Button>
                  </div>
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
