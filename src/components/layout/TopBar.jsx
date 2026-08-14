import Icon from "../ui/Icon";
import { useAuth } from "../../auth/AuthContext";
import { useNotifications } from "../../hooks/useMessaging";
import { useNavigate } from "react-router-dom";
import { useState, useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import { supabase } from "../../lib/supabase";
import LanguageSwitcher from "./LanguageSwitcher";

export default function TopBar({ title }) {
  const { t } = useTranslation();

  const { user, owner, access, signOut } = useAuth();
  const { data: notifications } = useNotifications();
  const [open, setOpen] = useState(false);
  const [avatarOpen, setAvatarOpen] = useState(false);
  const navigate = useNavigate();

  const notificationRef = useRef(null);
  const avatarRef = useRef(null);

  const unread = (notifications ?? []).filter((n) => !n.read_at).length;

  const markRead = async (n) => {
    await supabase
      .from("notifications")
      .update({ read_at: new Date().toISOString() })
      .eq("id", n.id);
    if (n.link) navigate(n.link);
  };

  // Toggle notification dropdown and close avatar dropdown
  const toggleNotifications = () => {
    setOpen((o) => !o);
    if (!open) setAvatarOpen(false);
  };

  // Toggle avatar dropdown and close notification dropdown
  const toggleAvatar = () => {
    setAvatarOpen((o) => !o);
    if (!avatarOpen) setOpen(false);
  };

  // Close dropdowns when clicking outside
  useEffect(() => {
    const handleClickOutside = (event) => {
      // Close notification dropdown if clicked outside
      if (
        notificationRef.current &&
        !notificationRef.current.contains(event.target)
      ) {
        setOpen(false);
      }

      // Close avatar dropdown if clicked outside
      if (avatarRef.current && !avatarRef.current.contains(event.target)) {
        setAvatarOpen(false);
      }
    };

    // Add event listener when component mounts
    document.addEventListener("mousedown", handleClickOutside);

    // Cleanup event listener when component unmounts
    return () => {
      document.removeEventListener("mousedown", handleClickOutside);
    };
  }, []);

  return (
    <header className="topbar">
      <div className="title">{title}</div>
      <div className="row">
        <LanguageSwitcher compact />
        <div
          className="notif-wrap"
          style={{ position: "relative" }}
          ref={notificationRef}
        >
          <button
            className="btn btn-secondary btn-icon"
            onClick={toggleNotifications}
          >
            <Icon name="bell" size={17} />
            {unread > 0 && (
              <span
                style={{
                  position: "absolute",
                  top: 2,
                  right: 2,
                  background: "var(--danger)",
                  color: "#fff",
                  borderRadius: 999,
                  fontSize: 10,
                  minWidth: 15,
                  height: 15,
                  display: "grid",
                  placeItems: "center",
                  padding: "0 3px",
                }}
              >
                {unread}
              </span>
            )}
          </button>
          {open && (
            <div
              className="card"
              style={{
                position: "absolute",
                right: 0,
                top: 46,
                width: 320,
                maxHeight: 360,
                overflowY: "auto",
                zIndex: 50,
                boxShadow: "var(--shadow-lg)",
              }}
            >
              {(notifications ?? []).length === 0 ? (
                <div className="empty">
                  <div className="small">{t("topbar.noNotifications")}</div>
                </div>
              ) : (
                (notifications ?? []).slice(0, 30).map((n) => (
                  <button
                    key={n.id}
                    onClick={() => markRead(n)}
                    style={{
                      display: "block",
                      width: "100%",
                      textAlign: "left",
                      padding: "10px 14px",
                      border: "none",
                      borderBottom: "1px solid var(--border)",
                      background: n.read_at
                        ? "transparent"
                        : "var(--primary-soft)",
                      cursor: "pointer",
                    }}
                  >
                    <div style={{ fontWeight: 600, fontSize: 14 }}>
                      {n.title}
                    </div>
                    <div className="small muted" style={{ fontSize: 13 }}>
                      {n.body}
                    </div>
                  </button>
                ))
              )}
            </div>
          )}
        </div>

        {/* Avatar with dropdown */}
        <div style={{ position: "relative" }} ref={avatarRef}>
          <div
            className="avatar"
            style={{
              width: 34,
              height: 34,
              fontSize: 13,
              cursor: "pointer",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              background: "var(--primary)",
              color: "#fff",
              borderRadius: "50%",
              fontWeight: 600,
            }}
            onClick={toggleAvatar}
          >
            {user?.email?.[0]?.toUpperCase() || "U"}
          </div>

          {avatarOpen && (
            <div
              className="card"
              style={{
                position: "absolute",
                right: 0,
                top: 46,
                width: 200,
                zIndex: 50,
                boxShadow: "var(--shadow-lg)",
                padding: "8px 0",
                minWidth: "180px",
              }}
            >
              <div
                style={{
                  padding: "8px 16px",
                  borderBottom: "1px solid var(--border)",
                }}
              >
                <div
                  style={{ fontWeight: 600, fontSize: 14 }}
                  className="truncate"
                >
                  {user?.email || "User"}
                </div>
                <div
                  style={{ fontSize: 12, color: "var(--muted)", marginTop: 2 }}
                >
                  {user?.role || t("topbar.user")}
                </div>
              </div>

              <button
                onClick={() => {
                  setAvatarOpen(false);
                  signOut();
                }}
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: "10px",
                  width: "100%",
                  padding: "10px 16px",
                  border: "none",
                  background: "transparent",
                  cursor: "pointer",
                  fontSize: 14,
                  color: "var(--danger)",
                  marginTop: "4px",
                }}
                onMouseEnter={(e) =>
                  (e.target.style.background = "var(--danger-soft)")
                }
                onMouseLeave={(e) =>
                  (e.target.style.background = "transparent")
                }
              >
                <Icon name="logout" size={16} />
                {t("sidebar.signOut")}
              </button>
            </div>
          )}
        </div>
      </div>
    </header>
  );
}
