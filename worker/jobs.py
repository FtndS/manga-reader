import base64
import io
import json
import os
from pathlib import Path

import requests
from PIL import Image

DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
OCR_LANGS = os.environ.get("OCR_LANGS", "japan")
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "").strip()
ANTHROPIC_MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-4-6").strip()


def source_label(lang: str | None = None) -> str:
    m = {
        "korean": "Korean",
        "japan": "Japanese",
        "chinese": "Chinese",
        "en": "English",
        "thai": "Thai",
    }
    return m.get((lang or OCR_LANGS), "the source language")


def extract_json_array(text: str):
    text = (text or "").strip()
    if not text:
        raise ValueError("empty Claude text")
    if text.startswith("```"):
        lines = text.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        text = "\n".join(lines).strip()
    start, end = text.find("["), text.rfind("]")
    if start < 0 or end <= start:
        raise ValueError(f"no JSON array: {text[:300]!r}")
    return json.loads(text[start:end + 1])


def clamp_box(box: dict) -> dict:
    left = max(0.0, min(98.0, float(box.get("left", 0))))
    top = max(0.0, min(98.0, float(box.get("top", 0))))
    width = max(4.0, min(100.0 - left, float(box.get("width", 12))))
    height = max(3.0, min(100.0 - top, float(box.get("height", 8))))
    # prevent ultra-thin vertical strips
    if height > width * 3:
        height = min(height, max(width * 2.2, 8))
        height = min(height, 100.0 - top)
    if width < 6 and height > 12:
        width = min(18.0, 100.0 - left)
    return {
        "left": round(left, 3),
        "top": round(top, 3),
        "width": round(width, 3),
        "height": round(height, 3),
    }


def image_to_jpeg_b64(path: Path, max_side: int = 1800) -> str:
    img = Image.open(path).convert("RGB")
    w, h = img.size
    if max(w, h) > max_side:
        scale = max_side / max(w, h)
        img = img.resize((int(w * scale), int(h * scale)))
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=88)
    return base64.standard_b64encode(buf.getvalue()).decode("ascii")


def vision_translate_page(page_path: Path) -> list[dict]:
    if not ANTHROPIC_API_KEY:
        raise RuntimeError("ANTHROPIC_API_KEY missing")

    system = (
        "You are a professional manga localizer. "
        "Priority #1: extract and translate EVERY speech bubble and important SFX. Do not skip any. "
        "Thai must be natural spoken comic Thai (ภาษาพูดมังงะ อ่านลื่น), not stiff literal Thai. "
        "Keep emotion and tone. Do not summarize. "
        "Return ONLY a raw JSON array. No markdown."
    )
    user = (
        f"Source language: {source_label(OCR_LANGS)}.\n"
        "Read the whole page carefully.\n"
        "Return JSON array in reading order (Japanese manga: right-to-left, then top-to-bottom):\n"
        '[{"src":"full original","th":"natural Thai","en":"natural English",'
        '"box":{"left":0-100,"top":0-100,"width":0-100,"height":0-100}}]\n\n'
        "Rules:\n"
        "1) Completeness: include ALL bubbles/SFX with readable text. Missing text is failure.\n"
        "2) One bubble = one item with the FULL sentence/phrase.\n"
        "3) box is % of full page, roughly covering that bubble (not huge, not a thin vertical strip).\n"
        "4) Prefer wider short boxes for Thai horizontal text (width >= height when possible).\n"
        "5) Thai: natural, fluent, comic-like.\n"
    )

    r = requests.post(
        "https://api.anthropic.com/v1/messages",
        headers={
            "x-api-key": ANTHROPIC_API_KEY,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        json={
            "model": ANTHROPIC_MODEL,
            "max_tokens": 8192,
            "system": system,
            "messages": [{
                "role": "user",
                "content": [
                    {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": image_to_jpeg_b64(page_path)}},
                    {"type": "text", "text": user},
                ],
            }],
        },
        timeout=240,
    )
    if r.status_code != 200:
        raise RuntimeError(f"Claude HTTP {r.status_code}: {r.text[:800]}")

    content = "".join(b.get("text", "") for b in r.json().get("content", []) if b.get("type") == "text")
    print(f"[vision-full] raw_len={len(content)}", flush=True)
    data = extract_json_array(content)

    lines = []
    for i, item in enumerate(data, 1):
        src = str(item.get("src") or "").strip()
        th = str(item.get("th") or "").strip()
        en = str(item.get("en") or "").strip()
        if not (src or th or en):
            continue
        box = clamp_box(item.get("box") or {})
        lines.append({"id": i, "src": src, "th": th or src, "en": en or src, "box": box})
        print(f"[out] #{i} th_len={len(th)} box={box} th={th[:60]!r}", flush=True)
    return lines


def update_meta_progress(chapter_id: str):
    chapter_dir = DATA_DIR / "chapters" / chapter_id
    meta_path = chapter_dir / "meta.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    done = len(list((chapter_dir / "translations").glob("*.json")))
    meta["done_pages"] = done
    meta["status"] = "done" if done >= meta.get("total_pages", 0) else "processing"
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")


def process_page(chapter_id: str, page_name: str):
    chapter_dir = DATA_DIR / "chapters" / chapter_id
    page_path = chapter_dir / "pages" / page_name
    stem = Path(page_name).stem
    out_path = chapter_dir / "translations" / f"{stem}.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    meta_path = chapter_dir / "meta.json"
    if meta_path.exists():
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        meta["status"] = "processing"
        meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")

    global OCR_LANGS
    src_lang = OCR_LANGS
    if meta_path.exists():
        try:
            _meta = json.loads(meta_path.read_text(encoding="utf-8"))
            if _meta.get("source_lang"):
                src_lang = str(_meta["source_lang"]).strip().lower()
        except Exception:
            pass
    OCR_LANGS = src_lang or OCR_LANGS
    print(f"[page] start {chapter_id}/{page_name} source_lang={OCR_LANGS}", flush=True)
    lines = vision_translate_page(page_path)
    payload = {"status": "done", "page": page_name, "engine": "claude-vision-full", "lines": lines}
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    update_meta_progress(chapter_id)
    print(f"[page] done count={len(lines)}", flush=True)
    return {"ok": True, "lines": len(lines)}
