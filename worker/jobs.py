import json
import os
import time
from pathlib import Path

import requests
from PIL import Image

DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
LT_URL = os.environ.get("LIBRETRANSLATE_URL", "http://libretranslate:5000").rstrip("/")
OCR_LANGS = os.environ.get("OCR_LANGS", "korean")  # korean|japan|chinese|en

_ocr = None


def get_ocr():
    global _ocr
    if _ocr is None:
        from rapidocr_onnxruntime import RapidOCR
        _ocr = RapidOCR()
    return _ocr


def translate(text: str, source: str, target: str) -> str:
    if not text.strip():
        return text
    # LibreTranslate may need a moment after boot
    for attempt in range(5):
        try:
            r = requests.post(
                f"{LT_URL}/translate",
                json={"q": text, "source": source, "target": target, "format": "text"},
                timeout=120,
            )
            if r.status_code == 200:
                return r.json().get("translatedText", text)
        except requests.RequestException:
            pass
        time.sleep(3 * (attempt + 1))
    return text


def detect_source_lang() -> str:
    # map OCR_LANGS hint to LibreTranslate codes
    m = {"korean": "ko", "japan": "ja", "chinese": "zh", "en": "en"}
    return m.get(OCR_LANGS, "auto")


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

    if out_path.exists():
        update_meta_progress(chapter_id)
        return {"skipped": True}

    # mark processing
    meta_path = chapter_dir / "meta.json"
    if meta_path.exists():
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        meta["status"] = "processing"
        meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")

    img = Image.open(page_path).convert("RGB")
    # downscale very large pages to save RAM
    max_side = 2000
    w, h = img.size
    if max(w, h) > max_side:
        scale = max_side / max(w, h)
        img = img.resize((int(w * scale), int(h * scale)))

    ocr = get_ocr()
    result, _ = ocr(img)
    lines = []
    src = detect_source_lang()

    if result:
        # RapidOCR: list of [box, text, score]
        for item in result:
            text = item[1] if len(item) > 1 else ""
            if not text or not str(text).strip():
                continue
            text = str(text).strip()
            th = translate(text, src if src != "auto" else "auto", "th")
            en = translate(text, src if src != "auto" else "auto", "en")
            lines.append({"src": text, "th": th, "en": en})

    payload = {"status": "done", "page": page_name, "lines": lines}
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    update_meta_progress(chapter_id)
    return {"ok": True, "lines": len(lines)}