import { useTranslation } from "react-i18next";
import Icon from "./Icon";

export default function EmptyState({ icon = "search", title, body, action }) {
  const { t } = useTranslation();
  return (
    <div className="empty">
      <div className="mx-auto mb-2 w-20 h-20 grid place-items-center rounded-full bg-slate-100 text-slate-400">
        <Icon name={icon} size={34} />
      </div>
      <div className="title">{title || t("common.nothingHereYet")}</div>
      {body && <div className="small muted">{body}</div>}
      {action && <div className="mt-2">{action}</div>}
    </div>
  );
}
