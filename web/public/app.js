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
    el.innerHTML = "<p class='msg'>à¸¢à¸±à¸‡à¹„à¸¡à¹ˆà¸¡à¸µà¸šà¸—</p>";
    return;
  }
  el.innerHTML = list.map(c => 
    <div class="chapter">
      <div>
        <strong></strong>
        <div class="badge"> Â· /</div>
      </div>
      <button type="button" data-id="">à¸­à¹ˆà¸²à¸™</button>
    </div>
  ).join("");
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
  if (!file) { msg.textContent = "à¹€à¸¥à¸·à¸­à¸à¹„à¸Ÿà¸¥à¹Œà¸à¹ˆà¸­à¸™"; return; }
  msg.textContent = "à¸à¸³à¸¥à¸±à¸‡à¸­à¸±à¸›à¹‚à¸«à¸¥à¸”...";
  const fd = new FormData();
  fd.append("file", file);
  try {
    const q = new URLSearchParams({ title });
    const r = await fetch(API + "/api/chapters/upload?" + q, { method: "POST", body: fd });
    if (!r.ok) throw new Error(await r.text());
    const meta = await r.json();
    msg.textContent = "à¸„à¸´à¸§à¹à¸¥à¹‰à¸§: " + meta.id;
    await loadChapters();
    openChapter(meta.id);
  } catch (e) {
    msg.textContent = "à¸œà¸´à¸”à¸žà¸¥à¸²à¸”: " + e.message;
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
      à¸ªà¸–à¸²à¸™à¸°:  (/);
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
    try { tr = await fetchJSON(/api/chapters//pages//translation); } catch {}
    const texts = (tr.lines || []).map(l => {
      const t = lang === "th" ? l.th : lang === "en" ? l.en : l.src;
      return <p></p>;
    }).join("") || "<p class='msg'>à¸£à¸­ OCR/à¹à¸›à¸¥...</p>";
    blocks.push(
      <div class="page-block">
        <img src="/api/chapters//pages/" alt="" loading="lazy" />
        <div class="lines"></div>
      </div>
    );
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
  document.getElementById("chapters").textContent = "API à¸¢à¸±à¸‡à¹„à¸¡à¹ˆà¸žà¸£à¹‰à¸­à¸¡: " + e.message;
});