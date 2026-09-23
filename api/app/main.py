import json
import os
import re
import shutil
import uuid
import zipfile
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from redis import Redis
from rq import Queue

DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
CHAPTERS_DIR = DATA_DIR / "chapters"
REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379/0")

CHAPTERS_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="Manga Reader API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

redis_conn = Redis.from_url(REDIS_URL)
q = Queue("ocr", connection=redis_conn)


def slugify(name: str) -> str:
    s = re.sub(r"[^\w\-]+", "-", name.strip(), flags=re.UNICODE)
    s = re.sub(r"-+", "-", s).strip("-").lower()
    return s or uuid.uuid4().hex[:8]


def chapter_meta(chapter_id: str) -> dict:
    meta_path = CHAPTERS_DIR / chapter_id / "meta.json"
    if not meta_path.exists():
        raise HTTPException(404, "chapter not found")
    return json.loads(meta_path.read_text(encoding="utf-8"))


@app.get("/api/health")
def health():
    return {"ok": True}


@app.get("/api/chapters")
def list_chapters():
    items = []
    if not CHAPTERS_DIR.exists():
        return items
    for p in sorted(CHAPTERS_DIR.iterdir()):
        meta = p / "meta.json"
        if meta.exists():
            items.append(json.loads(meta.read_text(encoding="utf-8")))
    items.sort(key=lambda x: x.get("created_at", ""), reverse=True)
    return items


@app.get("/api/chapters/{chapter_id}")
def get_chapter(chapter_id: str):
    return chapter_meta(chapter_id)


@app.get("/api/chapters/{chapter_id}/pages/{page_name}")
def get_page_image(chapter_id: str, page_name: str):
    path = CHAPTERS_DIR / chapter_id / "pages" / page_name
    if not path.exists() or ".." in page_name:
        raise HTTPException(404, "page not found")
    return FileResponse(path)


@app.get("/api/chapters/{chapter_id}/pages/{page_stem}/translation")
def get_translation(chapter_id: str, page_stem: str):
    path = CHAPTERS_DIR / chapter_id / "translations" / f"{page_stem}.json"
    if not path.exists():
        return {"status": "pending", "lines": []}
    return json.loads(path.read_text(encoding="utf-8"))


@app.post("/api/chapters/upload")
async def upload_chapter(title: str = "untitled", file: UploadFile = File(...)):
    chapter_id = f"{slugify(title)}-{uuid.uuid4().hex[:6]}"
    chapter_dir = CHAPTERS_DIR / chapter_id
    pages_dir = chapter_dir / "pages"
    translations_dir = chapter_dir / "translations"
    pages_dir.mkdir(parents=True)
    translations_dir.mkdir(parents=True)

    tmp = chapter_dir / "upload.bin"
    with tmp.open("wb") as f:
        shutil.copyfileobj(file.file, f)

    image_exts = {".jpg", ".jpeg", ".png", ".webp", ".gif"}
    pages = []

    if zipfile.is_zipfile(tmp):
        with zipfile.ZipFile(tmp, "r") as zf:
            names = sorted(
                n for n in zf.namelist()
                if not n.endswith("/") and Path(n).suffix.lower() in image_exts
            )
            for i, name in enumerate(names, start=1):
                ext = Path(name).suffix.lower()
                out_name = f"{i:03d}{ext}"
                with zf.open(name) as src, (pages_dir / out_name).open("wb") as dst:
                    shutil.copyfileobj(src, dst)
                pages.append(out_name)
        tmp.unlink(missing_ok=True)
    else:
        ext = Path(file.filename or "page.jpg").suffix.lower() or ".jpg"
        if ext not in image_exts:
            shutil.rmtree(chapter_dir, ignore_errors=True)
            raise HTTPException(400, "upload a zip of images, or a single image")
        out_name = f"001{ext}"
        tmp.rename(pages_dir / out_name)
        pages.append(out_name)

    if not pages:
        shutil.rmtree(chapter_dir, ignore_errors=True)
        raise HTTPException(400, "no images found")

    from datetime import datetime, timezone

    meta = {
        "id": chapter_id,
        "title": title,
        "pages": pages,
        "status": "queued",
        "done_pages": 0,
        "total_pages": len(pages),
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    (chapter_dir / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")

    # enqueue one job per page (worker processes sequentially via single worker)
    for page in pages:
        q.enqueue("jobs.process_page", chapter_id, page, job_timeout="20m")

    return meta