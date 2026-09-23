const API = "";
let lang = "th";
let current = null;
let pollTimer = null;
async function fetchJSON(url, opts) {
  const r = await fetch(API + url, opts);
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, m => ({
    "&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"
  })[m]);
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
    msg.textContent = "เข้าคิวแล้ว: " + meta.id;
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
    }).join("") || "<p class='msg'>รอ OCR / แปล...</p>";
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
