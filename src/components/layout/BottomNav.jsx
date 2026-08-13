import { useState } from "react";
import { NavLink, useLocation } from "react-router-dom";
import { useTranslation } from "react-i18next";
import Icon from "../ui/Icon";
import Modal from "../ui/Modal";
import { navItems } from "./navItems";
import { useAuth } from "../../auth/AuthContext";

const primaryPaths = ["/admin", "/admin/properties", "/admin/tenants", "/admin/invoices"];
const mobileItems = navItems.filter((i) => primaryPaths.includes(i.path));
const extraItems = navItems.filter((i) => !primaryPaths.includes(i.path));

export default function BottomNav() {
  const { t } = useTranslation();
  const { isSuperAdmin } = useAuth();
  const { pathname } = useLocation();
  const [moreOpen, setMoreOpen] = useState(false);

  const items = isSuperAdmin
    ? [...extraItems, { path: "/admin/super", labelKey: "nav.superAdmin", icon: "shield" }]
    : extraItems;

  // "More" should read as active whenever the current route belongs to one
  // of the items tucked inside it — not just while the sheet is open.
  const isInsideMore = items.some((item) =>
    item.path === "/admin" ? pathname === "/admin" : pathname.startsWith(item.path),
  );

  return (
    <nav className="bottom-nav">
      <div className="bottom-nav-inner">
        {mobileItems.map((item) => (
          <NavLink
            key={item.path}
            to={item.path}
            end={item.path === "/admin"}
            className={({ isActive }) =>
              `bottom-item${isActive ? " active" : ""}`
            }
          >
            <span className="ico">
              <Icon name={item.icon} size={19} />
            </span>
            {t(item.labelKey)}
          </NavLink>
        ))}
        <button
          className={`bottom-item${moreOpen || isInsideMore ? " active" : ""}`}
          onClick={() => setMoreOpen(true)}
          aria-label={t("nav.more")}
          aria-haspopup="dialog"
          aria-expanded={moreOpen}
        >
          <span className="ico">
            <Icon name="more" size={19} />
          </span>
          {t("nav.more")}
        </button>
      </div>

      <Modal open={moreOpen} onClose={() => setMoreOpen(false)} title={t("nav.more")}>
        <div className="more-sheet">
          {items.map((item) => {
            const active =
              item.path === "/admin"
                ? pathname === "/admin"
                : pathname.startsWith(item.path);
            return (
              <NavLink
                key={item.path}
                to={item.path}
                end={item.path === "/admin"}
                onClick={() => setMoreOpen(false)}
                className={`more-sheet-item${active ? " active" : ""}`}
              >
                <div className={`avatar alt${active ? " active" : ""}`}>
                  <Icon name={item.icon} size={18} />
                </div>
                <div className="body">
                  <div className="l-title">{t(item.labelKey)}</div>
                </div>
                <Icon name="chevronRight" size={16} className="muted" />
              </NavLink>
            );
          })}
        </div>
      </Modal>
    </nav>
  );
}
