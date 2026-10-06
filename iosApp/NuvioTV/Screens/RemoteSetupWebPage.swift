import Foundation

/// The single-page config UI served at `/` by `RemoteSetupServer`. Plain HTML+JS, no external
/// resources (works offline on the LAN). Edits are staged client-side; "Send to TV" POSTs the
/// whole desired state to `/api/apply`, then polls `/api/status/{id}` until the user confirms
/// or rejects the change on the TV.
enum RemoteSetupWebPage {
    static let html = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Nuvio Remote Setup</title>
<style>
  :root {
    --bg: #0b0d12; --card: #161a22; --card2: #1d2330; --text: #f2f4f8; --dim: #8b93a5;
    --accent: #4f6bf0; --grad: linear-gradient(90deg, #2bd9e5, #4f6bf0, #a238f0);
    --danger: #e5484d; --ok: #30a46c;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--text);
    font: 16px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    padding-bottom: 96px;
  }
  header { padding: 20px 16px 4px; max-width: 720px; margin: 0 auto; }
  header h1 {
    margin: 0; font-size: 26px; font-weight: 800;
    background: var(--grad); -webkit-background-clip: text; background-clip: text; color: transparent;
  }
  header p { margin: 6px 0 0; color: var(--dim); font-size: 14px; }
  main { max-width: 720px; margin: 0 auto; padding: 8px 16px; }
  section { background: var(--card); border-radius: 14px; padding: 16px; margin-top: 16px; }
  h2 { margin: 0 0 4px; font-size: 18px; }
  .hint { color: var(--dim); font-size: 13px; margin: 0 0 12px; }
  .row {
    display: flex; align-items: center; gap: 10px; background: var(--card2);
    border-radius: 10px; padding: 10px 12px; margin-top: 8px;
  }
  .row .info { flex: 1; min-width: 0; }
  .row .name { font-weight: 600; font-size: 15px; }
  .row .sub {
    color: var(--dim); font-size: 12px; overflow: hidden;
    text-overflow: ellipsis; white-space: nowrap;
  }
  .row.disabled .name, .row.disabled .sub { opacity: 0.45; }
  button {
    border: 0; border-radius: 8px; background: #2a3245; color: var(--text);
    font-size: 14px; padding: 8px 10px; cursor: pointer; flex-shrink: 0;
  }
  button:active { opacity: 0.7; }
  button.icon { width: 36px; height: 36px; padding: 0; font-size: 16px; }
  button.danger { background: rgba(229, 72, 77, 0.18); color: var(--danger); }
  .addbar { display: flex; gap: 8px; margin-top: 12px; }
  input[type=text], input[type=password] {
    flex: 1; min-width: 0; background: var(--card2); border: 1px solid #2a3245;
    border-radius: 8px; color: var(--text); font-size: 15px; padding: 10px 12px;
  }
  input::placeholder { color: #5a6376; }
  .keyrow { display: flex; gap: 8px; align-items: center; margin-top: 8px; }
  .keyrow label { width: 88px; flex-shrink: 0; font-size: 14px; }
  .footer {
    position: fixed; left: 0; right: 0; bottom: 0; padding: 12px 16px;
    background: rgba(11, 13, 18, 0.92); backdrop-filter: blur(10px);
    border-top: 1px solid #232a3a;
  }
  .footer .inner { max-width: 720px; margin: 0 auto; display: flex; gap: 10px; align-items: center; }
  .apply {
    flex: 1; background: var(--grad); font-weight: 700; font-size: 16px; padding: 13px;
    border-radius: 10px; color: #fff;
  }
  .apply:disabled { filter: grayscale(0.7); opacity: 0.6; }
  #status { font-size: 13px; color: var(--dim); flex: 1; }
  #status.ok { color: var(--ok); }
  #status.err { color: var(--danger); }
  .toggle { position: relative; width: 44px; height: 26px; flex-shrink: 0; }
  .toggle input { display: none; }
  .toggle span {
    position: absolute; inset: 0; border-radius: 13px; background: #2a3245; transition: 0.15s;
  }
  .toggle span::after {
    content: ""; position: absolute; top: 3px; left: 3px; width: 20px; height: 20px;
    border-radius: 50%; background: #fff; transition: 0.15s;
  }
  .toggle input:checked + span { background: var(--accent); }
  .toggle input:checked + span::after { left: 21px; }
  .empty { color: var(--dim); font-size: 14px; padding: 8px 2px; }
</style>
</head>
<body>
<header>
  <h1>Nuvio Remote Setup</h1>
  <p>Changes are staged here, then confirmed on your Apple&nbsp;TV.</p>
</header>
<main>
  <section>
    <h2>Add-ons</h2>
    <p class="hint">Paste a manifest URL to install. Reorder with the arrows; the first add-on's rows appear first on Home.</p>
    <div id="addons"></div>
    <div class="addbar">
      <input type="text" id="addon-url" placeholder="https://example.com/manifest.json" autocapitalize="off" autocorrect="off">
      <button onclick="addAddon()">Add</button>
    </div>
  </section>

  <section>
    <h2>Home Rows</h2>
    <p class="hint">Toggle rows on or off and reorder how they appear on the Home screen.</p>
    <div id="rows"></div>
  </section>

  <section>
    <h2>Stream Badge Packs</h2>
    <p class="hint">Badge packs add quality / HDR / audio chips to stream results. Paste a pack's JSON URL to import it on the TV. Remove packs on the TV under Settings &rarr; Appearance &rarr; Stream Badges.</p>
    <div id="badges"></div>
    <div class="addbar">
      <input type="text" id="badge-url" placeholder="https://example.com/badges.json" autocapitalize="off" autocorrect="off">
      <button onclick="addBadgeUrl()">Add</button>
    </div>
  </section>

  <section>
    <h2>API Keys</h2>
    <p class="hint">Optional. TMDB enriches titles (cast, studios, collections); MDBList adds IMDb/RT/Metacritic ratings. Keys are only sent when you enter one.</p>
    <div class="keyrow">
      <label>TMDB</label>
      <input type="password" id="tmdb-key" autocapitalize="off" autocorrect="off">
    </div>
    <div class="keyrow">
      <label>MDBList</label>
      <input type="password" id="mdblist-key" autocapitalize="off" autocorrect="off">
    </div>
  </section>
</main>
<div class="footer">
  <div class="inner">
    <div id="status">Loading&hellip;</div>
    <button class="apply" id="apply" onclick="apply()" disabled>Send to TV</button>
  </div>
</div>

<script>
let addons = [];   // {url, name, description, enabled, isNew}
let badgePacks = [];      // source URLs already imported on the TV (read-only here)
let stagedBadgeUrls = []; // pack URLs staged for import on Send
let rows = [];     // {key, title, enabled, isCollection}

const el = id => document.getElementById(id);
const esc = s => (s || "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

// Per-session pairing token from the QR/typed URL; the server requires it on every route.
const TOKEN = new URLSearchParams(location.search).get("t") || "";
const AUTH = { "X-Setup-Token": TOKEN };

function setStatus(text, cls) {
  const s = el("status");
  s.textContent = text;
  s.className = cls || "";
}

async function load() {
  try {
    const res = await fetch("/api/state", { headers: AUTH });
    const state = await res.json();
    addons = (state.addons || []).map(a => ({ ...a, isNew: false }));
    rows = state.rows || [];
    badgePacks = state.badgePacks || [];
    if (state.tmdbKeySet) el("tmdb-key").placeholder = "Saved on TV — enter to replace";
    if (state.mdblistKeySet) el("mdblist-key").placeholder = "Saved on TV — enter to replace";
    render();
    setStatus("Connected to " + (state.deviceName || "Apple TV"), "ok");
    el("apply").disabled = false;
  } catch (e) {
    setStatus("Couldn't reach the TV. Is Remote Setup still open?", "err");
  }
}

function move(list, i, delta) {
  const j = i + delta;
  if (j < 0 || j >= list.length) return;
  [list[i], list[j]] = [list[j], list[i]];
  render();
}

function render() {
  el("addons").innerHTML = addons.length ? addons.map((a, i) => `
    <div class="row ${a.enabled ? "" : "disabled"}">
      <label class="toggle"><input type="checkbox" ${a.enabled ? "checked" : ""}
        onchange="addons[${i}].enabled = this.checked; render()"><span></span></label>
      <div class="info">
        <div class="name">${esc(a.name || "New add-on")}${a.isNew ? " (new)" : ""}</div>
        <div class="sub">${esc(a.url)}</div>
      </div>
      <button class="icon" onclick="move(addons, ${i}, -1)">&#8593;</button>
      <button class="icon" onclick="move(addons, ${i}, 1)">&#8595;</button>
      <button class="icon danger" onclick="addons.splice(${i}, 1); render()">&#10005;</button>
    </div>`).join("") : `<div class="empty">No add-ons installed.</div>`;

  const badgeRows = badgePacks.map(u => `
    <div class="row">
      <div class="info">
        <div class="name">Imported</div>
        <div class="sub">${esc(u)}</div>
      </div>
    </div>`).concat(stagedBadgeUrls.map((u, i) => `
    <div class="row">
      <div class="info">
        <div class="name">New pack (on Send)</div>
        <div class="sub">${esc(u)}</div>
      </div>
      <button class="icon danger" onclick="stagedBadgeUrls.splice(${i}, 1); render()">&#10005;</button>
    </div>`));
  el("badges").innerHTML = badgeRows.length ? badgeRows.join("") : `<div class="empty">No badge packs imported.</div>`;

  el("rows").innerHTML = rows.length ? rows.map((r, i) => `
    <div class="row ${r.enabled ? "" : "disabled"}">
      <label class="toggle"><input type="checkbox" ${r.enabled ? "checked" : ""}
        onchange="rows[${i}].enabled = this.checked; render()"><span></span></label>
      <div class="info">
        <div class="name">${esc(r.title)}</div>
        <div class="sub">${r.isCollection ? "Collection" : "Catalog row"}</div>
      </div>
      <button class="icon" onclick="move(rows, ${i}, -1)">&#8593;</button>
      <button class="icon" onclick="move(rows, ${i}, 1)">&#8595;</button>
    </div>`).join("") : `<div class="empty">Rows appear after add-ons load.</div>`;
}

function addBadgeUrl() {
  const input = el("badge-url");
  const url = input.value.trim();
  if (!url) return;
  if (stagedBadgeUrls.includes(url) || badgePacks.includes(url)) {
    setStatus("That badge pack is already in the list.", "err");
    return;
  }
  stagedBadgeUrls.push(url);
  input.value = "";
  render();
}

function addAddon() {
  const input = el("addon-url");
  const url = input.value.trim();
  if (!url) return;
  if (addons.some(a => a.url === url)) { setStatus("That add-on is already in the list.", "err"); return; }
  addons.push({ url, name: "", description: "", enabled: true, isNew: true });
  input.value = "";
  render();
}

async function apply() {
  const btn = el("apply");
  btn.disabled = true;
  setStatus("Waiting for confirmation on the TV…");
  const payload = {
    addons: addons.map(a => ({ url: a.url, enabled: a.enabled })),
    rowOrder: rows.map(r => r.key),
    disabledRowKeys: rows.filter(r => !r.enabled).map(r => r.key)
  };
  const tmdb = el("tmdb-key").value.trim();
  const mdbl = el("mdblist-key").value.trim();
  if (tmdb) payload.tmdbKey = tmdb;
  if (mdbl) payload.mdblistKey = mdbl;
  if (stagedBadgeUrls.length) payload.badgeUrls = stagedBadgeUrls.slice();

  try {
    const res = await fetch("/api/apply", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify(payload)
    });
    const { id, error } = await res.json();
    if (error || !id) throw new Error(error || "bad response");
    poll(id, 0);
  } catch (e) {
    setStatus("Couldn't send changes to the TV.", "err");
    btn.disabled = false;
  }
}

async function poll(id, tries) {
  if (tries > 120) { setStatus("Timed out waiting for the TV.", "err"); el("apply").disabled = false; return; }
  try {
    const res = await fetch("/api/status/" + id, { headers: AUTH });
    const { status } = await res.json();
    if (status === "confirmed") {
      setStatus("Applied on the TV ✓", "ok");
      el("tmdb-key").value = ""; el("mdblist-key").value = "";
      stagedBadgeUrls = [];
      setTimeout(load, 1500);
      el("apply").disabled = false;
      return;
    }
    if (status === "rejected" || status === "not_found") {
      setStatus("Declined on the TV.", "err");
      el("apply").disabled = false;
      return;
    }
  } catch (e) { /* transient; keep polling */ }
  setTimeout(() => poll(id, tries + 1), 1000);
}

load();
</script>
</body>
</html>
"""#
}
