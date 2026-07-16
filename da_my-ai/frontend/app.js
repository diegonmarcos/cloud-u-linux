// my-ai-gui frontend — renders the `my-ai-dash --snapshot` JSON as a graphical
// dashboard and wires the launch bar to the Rust commands.
const invoke = (cmd, args) => window.__TAURI__.core.invoke(cmd, args);
const $ = (s) => document.querySelector(s);
const el = (html) => { const t = document.createElement("template"); t.innerHTML = html.trim(); return t.content.firstChild; };
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const n = (x) => Number(x || 0).toLocaleString();

function pill(slot) {
  if (!slot) return `<span class="pill na">--</span>`;
  switch (slot.st) {
    case "up": return `<span class="pill up">up ${slot.ms}ms</span>`;
    case "dn": return `<span class="pill dn">dn</span>`;
    case "to": return `<span class="pill to">t/o</span>`;
    case "stdio": return `<span class="pill stdio">stdio</span>`;
    case "pending": return `<span class="pill pending">…</span>`;
    default: return `<span class="pill na">--</span>`;
  }
}
const card = (title, body, wide) => `<section class="card${wide ? " wide" : ""}"><h2>${esc(title)}</h2><div class="body">${body}</div></section>`;
const row = (k, v) => `<div class="row"><span class="k">${esc(k)}</span><span>${v}</span></div>`;

function render(s) {
  const g = $("#grid");
  const parts = [];

  // FACES / services
  const svc = Object.entries(s.services || {}).map(([k, v]) => row(k, pill(v))).join("");
  parts.push(card("FACES", svc));

  // container health
  const c = s.container;
  let cbody = pill(c);
  if (c && c.st === "up" && c.body) {
    const b = c.body, st = b.stats || {};
    cbody = row("conc", `${b.active}/${b.max}`) + row("calls", n(st.calls)) + row("errors", n(st.errors)) +
      row("in / out", `${n(st.prompt_tokens)} / ${n(st.completion_tokens)}`) +
      row("headroom", `<span class="${b.headroom ? "on" : "off"}">${b.headroom ? "on" : "off"}</span>`);
  }
  parts.push(card("CONTAINER", cbody));

  // tokens saved
  const t = s.tokens;
  let tbody = pill(t);
  if (t && t.st === "up" && t.body) {
    const j = t.body;
    tbody = row("saved", `<span class="saved">${n(j.tokens_saved)}</span> (${((j.lifetime_ratio || 0) * 100).toFixed(0)}%)`) +
      row("before → after", `${n(j.tokens_before)} → ${n(j.tokens_after)}`) + row("compressions", n(j.compressions));
  }
  parts.push(card("TOKENS", tbody));

  // image
  const im = s.image;
  let ibody = pill(im);
  if (im && im.st === "image") {
    const arches = im.arches || [], multi = arches.length > 1;
    ibody = `<span class="${multi ? "multi" : "single"}">${esc(arches.join(","))} ${multi ? "(multi-arch)" : "(single-arch!)"}</span>`;
  }
  parts.push(card("GHCR IMAGE", ibody));

  // mesh + public
  const meshRows = Object.entries(s.mesh || {}).map(([k, v]) => row(k, pill(v))).join("");
  parts.push(card("MESH (wg)", meshRows));
  const pubRows = Object.entries(s.public || {}).map(([k, v]) => row(k, pill(v))).join("");
  parts.push(card("PUBLIC edge", pubRows));

  // MCP servers
  const mcpRows = (s.mcps || []).map((m) => row(`<span class="tag">${esc(m.name)}</span>`, m.kind === "http" ? pill(m.slot) : `<span class="stdio">stdio</span>`)).join("");
  parts.push(card(`MCP servers (${(s.mcps || []).length})`, mcpRows || `<span class="na">none</span>`));

  // git repos
  const repoRows = Object.entries(s.repos || {}).map(([k, v]) => {
    if (v.st !== "ok") return row(k, pill(v));
    const flags = `${v.ahead ? `<span class="on">+${v.ahead}</span> ` : ""}${v.behind ? `<span class="dn">-${v.behind}</span> ` : ""}${v.dirty ? `<span class="to">${v.dirty} dirty</span>` : `<span class="on">clean</span>`}`;
    return row(`<span class="tag">${esc(k)}</span>`, `<span class="k">${esc(v.br)}</span> ${flags}`);
  }).join("");
  parts.push(card("GIT REPOS", repoRows));

  // host disks
  const disks = (s.host && s.host.disks) || null;
  const diskBody = Array.isArray(disks)
    ? disks.map((d) => row(d.mount, `<b>${esc(d.pct)}</b> <span class="k">${esc(d.used)}/${esc(d.size)}, ${esc(d.avail)} free</span>`)).join("")
    : pill({ st: "na" });
  parts.push(card("HOST DISK", diskBody));

  // claude config
  const cl = s.claude || {};
  const plugins = (cl.plugins || []).map((p) => `<span class="${p.on ? "on" : "off"}">${esc(p.label)}${p.detail ? ":" + esc(p.detail) : ""}</span>`).join(" ")
    + ` <span class="${cl.statusline ? "on" : "off"}">Statusline:${cl.statusline ? "on" : "off"}</span>`;
  const claudeBody = row("model", esc(cl.model)) + row("mcp", cl.mcp_count) +
    row("plugins", plugins) +
    row("skills", `<span class="k">${(cl.skills || []).slice(0, 14).map(esc).join(" ") || "none"}</span>`) +
    row("hooks", `<span class="k">${(cl.hooks || []).map((h) => `${esc(h.name)}(${h.kb}K)`).join("  ")}</span>`);
  parts.push(card("CLAUDE", claudeBody, true));

  // sessions (wide, table)
  const se = s.sessions || { total: 0, mb: 0, list: [] };
  const rows = se.list.map((x) => `<tr><td>${esc(x.age)}</td><td>${x.msgs}</td><td>${x.kb}K</td><td>${esc(x.title)}</td><td class="cwd">${esc(x.cwd)}</td></tr>`).join("");
  const sessBody = `<div class="overflow"><table><thead><tr><th>age</th><th>msgs</th><th>size</th><th>title</th><th>cwd</th></tr></thead><tbody>${rows}</tbody></table></div>`;
  parts.push(card(`LOCAL sessions (${se.total} total, ${se.mb}MB)`, sessBody, true));

  g.innerHTML = parts.join("");
}

async function refresh() {
  const st = $("#status");
  st.textContent = "probing…";
  try {
    const snap = await invoke("snapshot");
    render(snap);
    st.textContent = "updated";
  } catch (e) {
    st.textContent = "snapshot failed: " + e;
  }
}

function wire() {
  document.querySelectorAll("[data-face]").forEach((b) =>
    b.addEventListener("click", () => invoke("launch", { face: b.dataset.face }))
  );
  $("#restoreBtn").addEventListener("click", () =>
    invoke("launch", { face: "remote", restore: Number($("#restoreN").value) || 5 })
  );
  $("#syncBtn").addEventListener("click", () => { invoke("sync_now"); $("#status").textContent = "sync started"; });
  $("#refreshBtn").addEventListener("click", refresh);
}

window.addEventListener("DOMContentLoaded", () => { wire(); refresh(); });
