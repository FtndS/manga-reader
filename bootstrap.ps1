# bootstrap.ps1 — scaffold manga-reader MVP (RAM-safe)
$ErrorActionPreference = "Stop"
$Root = "D:\manga-reader"
Set-Location $Root

function Write-Text($Path, $Content) {
  $full = Join-Path $Root $Path
  $dir = Split-Path $full -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  # UTF-8 no BOM
  [System.IO.File]::WriteAllText($full, $Content)
  Write-Host "wrote $Path"
}

Write-Text ".gitignore" @"
data/
.env
.htpasswd*
__pycache__/
*.pyc
.venv/
node_modules/
dist/
web/dist/
.DS_Store
*.log
"@

Write-Text ".env.example" @"
# Copy to .env on VPS / local
SECRET_PATH=r/change-me-to-long-random
BASIC_AUTH_USER=reader
# Create htpasswd separately — do not put password here in git
OCR_LANGS=korean
# korean | japan | chinese | en
"@

Write-Text "docker-compose.yml" @"
services:
  api:
    build: ./api
    container_name: manga-api
    env_file: .env
    environment:
      DATA_DIR: /data
      REDIS_URL: redis://redis:6379/0
      LIBRETRANSLATE_URL: http://libretranslate:5000
      OCR_LANGS: `${OCR_LANGS:-korean}
    volumes:
      - ./data:/data
    depends_on:
      - redis
      - libretranslate
    networks:
      - manga-net
      - portfolio-net
    restart: unless-stopped
    mem_limit: 512m

  worker:
    build: ./worker
    container_name: manga-worker
    env_file: .env
    environment:
      DATA_DIR: /data
      REDIS_URL: redis://redis:6379/0
      LIBRETRANSLATE_URL: http://libretranslate:5000
      OCR_LANGS: `${OCR_LANGS:-korean}
    volumes:
      - ./data:/data
    depends_on:
      - redis
      - libretranslate
    networks:
      - manga-net
    restart: unless-stopped
    # OCR is heavy — one worker, one page at a time
    mem_limit: 2g

  web:
    build: ./web
    container_name: manga-web
    networks:
      - manga-net
      - portfolio-net
    restart: unless-stopped
    mem_limit: 128m

  libretranslate:
    image: libretranslate/libretranslate:latest
    container_name: manga-libretranslate
    environment:
      LT_LOAD_ONLY: en,th,ko,ja,zh
      LT_DISABLE_WEB_UI: "true"
      LT_UPDATE_MODELS: "true"
    networks:
      - manga-net
    restart: unless-stopped
    mem_limit: 1536m

  redis:
    image: redis:7-alpine
    container_name: manga-redis
    networks:
      - manga-net
    restart: unless-stopped
    mem_limit: 64m

networks:
  manga-net:
    driver: bridge
  # Join PortDiary network on VPS (name may differ — check: docker network ls)
  portfolio-net:
    external: true
    name: portfolio-app_portfolio-network
"@

Write-Text "docker-compose.dev.yml" @"
# Local PC: do NOT require PortDiary network
services:
  api:
    ports:
      - "8000:8000"
    networks:
      - manga-net
  worker:
    networks:
      - manga-net
  web:
    ports:
      - "5173:80"
    networks:
      - manga-net
  libretranslate:
    networks:
      - manga-net
  redis:
    networks:
      - manga-net

networks:
  manga-net:
    driver: bridge
  portfolio-net:
    external: false
"@

# ---- API ----
Write-Text "api/Dockerfile" @"
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
ENV DATA_DIR=/data
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
"@

Write-Text "api/requirements.txt" @"
fastapi==0.115.6
uvicorn[standard]==0.34.0
python-multipart==0.0.20
redis==5.2.1
rq==2.1.0
aiofiles==24.1.0
"@

Write-Text "api/app/__init__.py" @"
"@

Write-Text "api/app/main.py" @"
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
"@

# ---- WORKER ----
Write-Text "worker/Dockerfile" @"
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1 libglib2.0-0 libgomp1 curl \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY jobs.py .
ENV DATA_DIR=/data
CMD ["rq", "worker", "ocr", "--url", "redis://redis:6379/0"]
"@

Write-Text "worker/requirements.txt" @"
redis==5.2.1
rq==2.1.0
requests==2.32.3
rapidocr-onnxruntime==1.4.4
Pillow==11.1.0
numpy==2.2.2
"@

Write-Text "worker/jobs.py" @"
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
"@

# ---- WEB (static nginx + simple SPA without node build complexity: plain HTML) ----
Write-Text "web/Dockerfile" @"
FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY public /usr/share/nginx/html
"@

Write-Text "web/nginx.conf" @"
server {
  listen 80;
  root /usr/share/nginx/html;
  index index.html;

  location /api/ {
    proxy_pass http://api:8000/api/;
    client_max_body_size 200m;
    proxy_read_timeout 300s;
  }

  location / {
    try_files `$uri `$uri/ /index.html;
  }
}
"@

Write-Text "web/public/index.html" @"
<!DOCTYPE html>
<html lang="th">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Manga Reader (private)</title>
  <link rel="stylesheet" href="styles.css" />
</head>
<body>
  <header>
    <h1>Manga Reader</h1>
    <p class="sub">ส่วนตัว · แปลไทย / อังกฤษ</p>
  </header>

  <section class="upload card">
    <h2>อัปโหลดบท</h2>
    <label>ชื่อบท <input id="title" type="text" placeholder="chapter 1" /></label>
    <label>ZIP รูป หรือรูปเดียว <input id="file" type="file" accept=".zip,image/*" /></label>
    <button id="uploadBtn" type="button">อัปโหลด + เริ่มแปล</button>
    <p id="uploadMsg" class="msg"></p>
  </section>

  <section class="list card">
    <h2>บททั้งหมด</h2>
    <div id="chapters"></div>
  </section>

  <section id="reader" class="reader card hidden">
    <div class="reader-top">
      <button id="backBtn" type="button">← กลับ</button>
      <h2 id="readerTitle"></h2>
      <div class="lang">
        <button type="button" data-lang="th" class="lang-btn active">ไทย</button>
        <button type="button" data-lang="en" class="lang-btn">EN</button>
        <button type="button" data-lang="src" class="lang-btn">ต้นฉบับ</button>
      </div>
    </div>
    <p id="statusLine" class="msg"></p>
    <div id="pages"></div>
  </section>

  <script src="app.js"></script>
</body>
</html>
"@

Write-Text "web/public/styles.css" @"
:root {
  --bg: #12141a;
  --card: #1c2030;
  --text: #e8eaef;
  --muted: #9aa3b5;
  --accent: #3d8bfd;
  --ok: #3dd68c;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: "Segoe UI", "Sarabun", system-ui, sans-serif;
  background: radial-gradient(1200px 600px at 20% -10%, #243056, var(--bg));
  color: var(--text);
  min-height: 100vh;
  padding: 1.25rem;
}
header h1 { margin: 0; font-size: 1.6rem; letter-spacing: 0.02em; }
.sub { color: var(--muted); margin: 0.25rem 0 1.25rem; }
.card {
  background: color-mix(in srgb, var(--card) 92%, transparent);
  border: 1px solid #2a3145;
  border-radius: 12px;
  padding: 1rem 1.1rem;
  margin-bottom: 1rem;
}
label { display: block; margin: 0.5rem 0; color: var(--muted); }
input[type="text"], input[type="file"] { display: block; margin-top: 0.35rem; width: 100%; max-width: 420px; }
button {
  background: var(--accent);
  color: white;
  border: 0;
  border-radius: 8px;
  padding: 0.55rem 0.9rem;
  cursor: pointer;
  font-weight: 600;
}
button:hover { filter: brightness(1.08); }
.msg { color: var(--muted); min-height: 1.2em; }
.chapter {
  display: flex; justify-content: space-between; gap: 1rem; align-items: center;
  padding: 0.7rem 0; border-bottom: 1px solid #2a3145;
}
.chapter button { background: #2d364d; }
.badge { color: var(--ok); font-size: 0.85rem; }
.hidden { display: none; }
.reader-top { display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: center; }
.reader-top h2 { flex: 1; margin: 0; font-size: 1.1rem; }
.lang-btn { background: #2d364d; }
.lang-btn.active { background: var(--accent); }
.page-block { margin: 1.25rem 0 2rem; }
.page-block img { width: 100%; max-width: 820px; height: auto; border-radius: 8px; display: block; }
.lines {
  margin-top: 0.75rem; max-width: 820px;
  background: #151925; border-radius: 8px; padding: 0.75rem 1rem;
  border: 1px solid #2a3145;
}
.lines p { margin: 0.35rem 0; line-height: 1.45; }
"@

Write-Text "web/public/app.js" @"
const API = "";
let lang = "th";
let current = null;
let pollTimer = null;

async function fetchJSON(url, opts) {
  const r = await fetch(API + url, opts);
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

async function loadChapters() {
  const list = await fetchJSON("/api/chapters");
  const el = document.getElementById("chapters");
  if (!list.length) {
    el.innerHTML = "<p class='msg'>ยังไม่มีบท</p>";
    return;
  }
  el.innerHTML = list.map(c => `
    <div class="chapter">
      <div>
        <strong>${escapeHtml(c.title)}</strong>
        <div class="badge">${c.status} · ${c.done_pages || 0}/${c.total_pages}</div>
      </div>
      <button type="button" data-id="${c.id}">อ่าน</button>
    </div>
  `).join("");
  el.querySelectorAll("button[data-id]").forEach(btn => {
    btn.onclick = () => openChapter(btn.dataset.id);
  });
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, m => ({
    "&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"
  })[m]);
}

document.getElementById("uploadBtn").onclick = async () => {
  const title = document.getElementById("title").value || "untitled";
  const file = document.getElementById("file").files[0];
  const msg = document.getElementById("uploadMsg");
  if (!file) { msg.textContent = "เลือกไฟล์ก่อน"; return; }
  msg.textContent = "กำลังอัปโหลด...";
  const fd = new FormData();
  fd.append("file", file);
  try {
    const q = new URLSearchParams({ title });
    const r = await fetch(API + "/api/chapters/upload?" + q, { method: "POST", body: fd });
    if (!r.ok) throw new Error(await r.text());
    const meta = await r.json();
    msg.textContent = "คิวแล้ว: " + meta.id;
    await loadChapters();
    openChapter(meta.id);
  } catch (e) {
    msg.textContent = "ผิดพลาด: " + e.message;
  }
};

async function openChapter(id) {
  current = await fetchJSON("/api/chapters/" + id);
  document.getElementById("reader").classList.remove("hidden");
  document.getElementById("readerTitle").textContent = current.title;
  renderPages();
  if (pollTimer) clearInterval(pollTimer);
  pollTimer = setInterval(async () => {
    current = await fetchJSON("/api/chapters/" + id);
    document.getElementById("statusLine").textContent =
      `สถานะ: ${current.status} (${current.done_pages}/${current.total_pages})`;
    renderPages();
    if (current.status === "done") clearInterval(pollTimer);
  }, 4000);
}

async function renderPages() {
  const root = document.getElementById("pages");
  const blocks = [];
  for (const page of current.pages) {
    const stem = page.replace(/\.[^.]+$/, "");
    let tr = { lines: [], status: "pending" };
    try { tr = await fetchJSON(`/api/chapters/${current.id}/pages/${stem}/translation`); } catch {}
    const texts = (tr.lines || []).map(l => {
      const t = lang === "th" ? l.th : lang === "en" ? l.en : l.src;
      return `<p>${escapeHtml(t || "")}</p>`;
    }).join("") || "<p class='msg'>รอ OCR/แปล...</p>";
    blocks.push(`
      <div class="page-block">
        <img src="/api/chapters/${current.id}/pages/${encodeURIComponent(page)}" alt="${page}" loading="lazy" />
        <div class="lines">${texts}</div>
      </div>
    `);
  }
  root.innerHTML = blocks.join("");
}

document.getElementById("backBtn").onclick = () => {
  document.getElementById("reader").classList.add("hidden");
  if (pollTimer) clearInterval(pollTimer);
  loadChapters();
};

document.querySelectorAll(".lang-btn").forEach(btn => {
  btn.onclick = () => {
    lang = btn.dataset.lang;
    document.querySelectorAll(".lang-btn").forEach(b => b.classList.toggle("active", b === btn));
    if (current) renderPages();
  };
});

loadChapters().catch(e => {
  document.getElementById("chapters").textContent = "API ยังไม่พร้อม: " + e.message;
});
"@

Write-Text "README.md" @"
# manga-reader (private)

อ่านมังงะ/มังฮวาส่วนตัว: อัปโหลดรูป → OCR → แปลไทย + อังกฤษ

- รันบน VPS ร่วม PortDiary (path ลับ + Basic Auth)
- ออกแบบประหยัด RAM (OCR ทีละหน้า, mem_limit, LibreTranslate โหลดเฉพาะภาษาที่ใช้)

## ความต้องการเครื่อง

- RAM ~3.8GB + **Swap 4GB** (จำเป็น)
- Docker + Docker Compose

## ทดสอบบน PC (local)

\`\`\`powershell
cd D:\manga-reader
copy .env.example .env
docker compose -f docker-compose.yml -f docker-compose.dev.yml up --build
\`\`\`

เปิด http://localhost:5173

อัปโหลด ZIP รูป หรือรูปเดียว รอสถานะ processing → done

> ครั้งแรก LibreTranslate / OCR จะดาวน์โหลดโมเดล ช้าและกิน RAM/Swap

ตั้งภาษาต้นทางใน \`.env\`:

\`\`\`
OCR_LANGS=korean
\`\`\`

ค่าที่ใช้ได้: \`korean\` | \`japan\` | \`chinese\` | \`en\`

## Push GitHub

\`\`\`powershell
cd D:\manga-reader
git add .
git status
git commit -m "feat: initial manga reader MVP"
git push -u origin main
\`\`\`

## ขึ้น VPS

\`\`\`bash
# swap ควรมีแล้ว
free -h

cd ~
git clone https://github.com/FtndS/manga-reader.git
cd ~/manga-reader
cp .env.example .env
# แก้ OCR_LANGS ตามภาษาที่อ่าน

# ตรวจชื่อ network ของ PortDiary
docker network ls | grep portfolio

# ถ้าชื่อไม่ใช่ portfolio-app_portfolio-network ให้แก้ใน docker-compose.yml

docker compose up -d --build
docker compose ps
\`\`\`

### Basic Auth + path ลับ (ผูก nginx PortDiary)

\`\`\`bash
apt-get install -y apache2-utils
htpasswd -c /root/manga-reader/.htpasswd-reader YOUR_USER
chmod 600 /root/manga-reader/.htpasswd-reader
\`\`\`

ใน \`~/portfolio-app/nginx.conf\` เพิ่ม (เปลี่ยน SECRET):

\`\`\`nginx
location /r/YOUR_LONG_SECRET/ {
  auth_basic "private";
  auth_basic_user_file /etc/nginx/.htpasswd-reader;
  proxy_pass http://manga-web:80/;
  client_max_body_size 200m;
}
\`\`\`

ใน \`docker-compose.yml\` ของ PortDiary ฝั่ง nginx volumes เพิ่ม:

\`\`\`yaml
- /root/manga-reader/.htpasswd-reader:/etc/nginx/.htpasswd-reader:ro
\`\`\`

แล้ว:

\`\`\`bash
cd ~/portfolio-app
docker compose up -d nginx
docker compose exec nginx nginx -t
docker compose exec nginx nginx -s reload
\`\`\`

เปิด: \`https://portdiary.com/r/YOUR_LONG_SECRET/\`

## หมายเหตุ

- ใช้ไฟล์ที่คุณมีสิทธิ์อ่านส่วนตัวเท่านั้น
- อย่า commit โฟลเดอร์ \`data/\` หรือ \`.htpasswd*\`
- เมื่อเสร็จแล้วควรตั้ง GitHub repo กลับเป็น **private**
"@

Write-Text "docs/nginx-snippet.conf" @"
# Paste into portfolio-app nginx.conf (HTTPS server block)
# Replace YOUR_LONG_SECRET

location /r/YOUR_LONG_SECRET/ {
  auth_basic "private";
  auth_basic_user_file /etc/nginx/.htpasswd-reader;
  proxy_pass http://manga-web:80/;
  client_max_body_size 200m;
  proxy_read_timeout 300s;
}
"@

Write-Host ""
Write-Host "DONE. Next:"
Write-Host "  copy .env.example .env"
Write-Host "  docker compose -f docker-compose.yml -f docker-compose.dev.yml up --build"
Write-Host "  git add . ; git commit ; git push"