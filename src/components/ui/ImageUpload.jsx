import { useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { Input } from "./Input";
import Button from "./Button";
import Icon from "./Icon";
import { useToast } from "./Toast";

const MAX_DIM = 1600;
const QUALITY = 0.82;

function fmtBytes(bytes) {
  if (bytes < 1024) return `${Math.round(bytes)} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function dataUrlBytes(dataUrl) {
  try {
    const base64 = dataUrl.split(",")[1] || "";
    return Math.round((base64.length * 3) / 4);
  } catch {
    return 0;
  }
}

function loadImage(src) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error("image load failed"));
    img.src = src;
  });
}

export async function optimizeImageFile(file, { maxDim = MAX_DIM, quality = QUALITY } = {}) {
  const rawUrl = await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });

  const img = await loadImage(rawUrl);
  const scale = Math.min(1, maxDim / Math.max(img.width, img.height));
  const w = Math.max(1, Math.round(img.width * scale));
  const h = Math.max(1, Math.round(img.height * scale));

  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext("2d");
  ctx.drawImage(img, 0, 0, w, h);

  const mime = "image/webp";
  const dataUrl = canvas.toDataURL(mime, quality);
  return {
    dataUrl,
    width: w,
    height: h,
    originalBytes: file.size,
    optimizedBytes: dataUrlBytes(dataUrl),
  };
}

export default function ImageUpload({
  images = [],
  onChange,
  maxImages = 8,
  maxDim = MAX_DIM,
  quality = QUALITY,
  allowUrl = true,
  label,
  hint,
}) {
  const { t } = useTranslation();
  const toast = useToast();
  const inputRef = useRef(null);
  const [busy, setBusy] = useState(false);
  const [lastSave, setLastSave] = useState(null);
  const [url, setUrl] = useState("");

  const handleFiles = async (e) => {
    const files = Array.from(e.target.files || []);
    e.target.value = "";
    if (!files.length) return;

    const room = maxImages - images.length;
    const take = files.slice(0, Math.max(0, room));
    if (files.length > room) {
      toast.error(t("imageUpload.maxReached", { max: maxImages }));
    }
    if (!take.length) return;

    setBusy(true);
    const next = [...images];
    let original = 0;
    let optimized = 0;
    try {
      for (const file of take) {
        try {
          const res = await optimizeImageFile(file, { maxDim, quality });
          next.push(res.dataUrl);
          original += res.originalBytes;
          optimized += res.optimizedBytes;
        } catch {
          toast.error(t("imageUpload.readFailed"));
        }
      }
    } finally {
      setBusy(false);
    }
    onChange(next);
    if (original > 0) {
      setLastSave({ original, optimized });
      setTimeout(() => setLastSave(null), 6000);
    }
  };

  const addUrl = () => {
    const value = url.trim();
    if (!value) return;
    if (images.length + 1 > maxImages) {
      toast.error(t("imageUpload.maxReached", { max: maxImages }));
      return;
    }
    onChange([...images, value]);
    setUrl("");
  };

  const remove = (i) => onChange(images.filter((_, j) => j !== i));

  return (
    <div className="image-upload">
      {label && <label className="label">{label}</label>}
      <div className="row" style={{ gap: 8 }}>
        <input
          ref={inputRef}
          type="file"
          accept="image/*"
          multiple
          hidden
          onChange={handleFiles}
        />
        <Button
          type="button"
          variant="secondary"
          size="sm"
          disabled={busy}
          onClick={() => inputRef.current?.click()}
        >
          <Icon name="image" size={15} />
          <span>{busy ? t("imageUpload.optimizing") : t("imageUpload.upload")}</span>
        </Button>
        {allowUrl && (
          <>
            <Input
              value={url}
              onChange={(e) => setUrl(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && addUrl()}
              placeholder="https://…"
            />
            <Button type="button" variant="secondary" size="sm" onClick={addUrl}>
              {t("imageUpload.addUrl")}
            </Button>
          </>
        )}
      </div>
      {lastSave && (
        <div className="hint mt-2">
          {t("imageUpload.saved", {
            before: fmtBytes(lastSave.original),
            after: fmtBytes(lastSave.optimized),
          })}
        </div>
      )}
      {hint && <div className="hint mt-2">{hint}</div>}
      {(images ?? []).length > 0 && (
        <div className="image-grid mt-2">
          {images.map((img, i) => (
            <div className="image-tile" key={i}>
              <img src={img} alt="" />
              <button
                type="button"
                className="image-remove"
                onClick={() => remove(i)}
              >
                <Icon name="close" size={14} />
              </button>
            </div>
          ))}
        </div>
      )}
      {(images ?? []).length === 0 && !busy && (
        <div className="hint" style={{ marginTop: 6 }}>
          {t("imageUpload.noImagesYet")}
        </div>
      )}
    </div>
  );
}
