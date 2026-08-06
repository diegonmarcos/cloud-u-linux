#!/usr/bin/env node
// claude-superset-tui — launch composer + infra dashboard (TTY-safe).
// No npm deps. ASCII glyphs + ANSI colors only, so it renders identically on a
// bare Linux console, xterm and konsole. Sections (single screen, distinct
// colors): COMPOSER (agents/face/mcps/plugins/flags/restore/actions),
// USAGE (sessions + token/image stats), STACK (mesh/public/container/host/git).
// Data is OFFLINE (instant fs
// reads at startup) or NETWORK/CMD (fired ONLY on Refresh/r) — nothing hits the
// wire on open, so it never blocks. Each probe is independent + hard-timeout'd
// and patches only its own slot, re-rendering as answers arrive.
import readline from "node:readline";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const env = process.env;
const EP = {
  proxy: env.CAS_PROXY || "http://10.0.0.6:8789", api: env.CAS_API || "http://10.0.0.6:3117",
  ollama: env.CAS_OLLAMA || "http://10.0.0.6:11436", compress: env.CAS_COMPRESS || "http://10.0.0.6:8788",
  anthropic: env.CAS_ANTHROPIC || "https://api.anthropic.com",
};
const jp = (s) => { try { return JSON.parse(s || "{}"); } catch { return {}; } };
const MESH = jp(env.CAS_MESH), PUBLIC = jp(env.CAS_PUBLIC);
const IMAGE = env.CAS_IMAGE || "ghcr.io/diegonmarcos/claude-superset-api-binaries";
const BIN = { ping: env.CAS_PING || "ping", df: env.CAS_DF || "df", git: env.CAS_GIT || "git" };
const SELF = env.CAS_SELF || "claude-superset", HOME = os.homedir(), CFG = env.CLAUDE_CONFIG_DIR || path.join(HOME, ".claude");
const GITROOT = path.join(HOME, "git"), REPOS = ["cloud", "unix", "front", "vault", "tools"];
const RESTORE_PRESETS = { count: [1, 3, 5, 10, 20, 50], hours: [1, 4, 8, 24, 72, 168] };
const PONY_LEVELS = ["lite", "full", "ultra"];
const C = { r: "\x1b[0m", b: "\x1b[1m", dim: "\x1b[2m", inv: "\x1b[7m", g: "\x1b[32m", y: "\x1b[33m", red: "\x1b[31m", cy: "\x1b[36m", mag: "\x1b[35m", blu: "\x1b[34m",
  composer: "\x1b[38;5;213m", usage: "\x1b[38;5;220m", stack: "\x1b[38;5;39m" };
const strip = (s) => s.replace(/\x1b\[[0-9;]*m/g, "");
const padE = (s, n) => { const w = strip(s).length; return w >= n ? s : s + " ".repeat(n - w); };
const padS = (s, n) => { const w = strip(s).length; return w >= n ? s : " ".repeat(n - w) + s; };
const W = 76;
const num = (x) => Number(x || 0).toLocaleString();
const SPIN = ["|", "/", "-", "\\"]; let spin = 0, spinTimer = null;
function secHead(title, right = "", color = C.cy) {
  const label = `[ ${title} ]`, rt = right ? `[ ${right} ]` : "";
  const fill = Math.max(2, W - strip(label).length - strip(rt).length - 6);
  return `  ${color}${C.b}+==${C.r}${C.b}${color}${label}${C.r}${color}${C.b}${"=".repeat(fill)}${right ? `${C.r}${C.y}${rt}${color}${C.b}` : ""}==+${C.r}`;
}
function bigBanner(title, color) {
  const bar = "#".repeat(Math.max(2, W - title.length - 5));
  return `  ${color}${C.b}## ${title} ${bar}${C.r}`;
}

// ── OFFLINE data (instant) ──────────────────────────────────────────────────
const readJSON = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } };
function loadMcps() {
  const j = readJSON(path.join(HOME, ".mcp.json")) || readJSON(path.join(HOME, ".claude.json")) || {};
  return Object.entries(j.mcpServers || {}).map(([name, v]) => {
    const type = v.type || (v.url ? "http" : "stdio"); let host = null;
    try { if (v.url) host = new URL(v.url).host; } catch {}
    return { name, type, url: v.url || null, host, st: undefined };
  });
}
function loadPlugins() {
  // Real source of truth: ~/.claude/settings.json enabledPlugins (name@marketplace
  // strings). The old ~/.claude/claude-plugins.json (5-entry, superset-infra-only)
  // was stale — the 4 superset-infra toggles (headroom/rtk/caveman/ponytail) are
  // separate live-togglable `st` rows, not sourced from here.
  const s = readJSON(path.join(CFG, "settings.json")) || {};
  // enabledPlugins is an OBJECT keyed by "name@marketplace" -> true (not an
  // array) — normalize both shapes defensively, then split each key on '@'.
  const ep = s.enabledPlugins;
  const entries = Array.isArray(ep) ? ep : ep && typeof ep === "object" ? Object.keys(ep).filter((k) => ep[k]) : [];
  return entries.map((entry) => {
    const [name, marketplace] = String(entry).split("@");
    return { id: entry, label: name, icon: "*", on: true, detail: marketplace || "" };
  });
}
function loadDirList(dir) {
  try { return fs.readdirSync(path.join(CFG, dir)).filter((f) => !f.startsWith(".")); } catch { return []; }
}
function hooksDetailed() {
  const d = path.join(CFG, "hooks"); const out = [];
  try { for (const f of fs.readdirSync(d)) { if (f.startsWith(".")) continue; let sz = 0; try { sz = fs.statSync(path.join(d, f)).size; } catch {} out.push({ name: f.replace(/\.(sh|json|md)$/, ""), kb: Math.max(1, Math.round(sz / 1024)) }); } } catch {}
  return out;
}
const ago = (ms) => { const s = Math.max(0, (Date.now() - ms) / 1000); return s < 90 ? `${Math.round(s)}s` : s < 5400 ? `${Math.round(s / 60)}m` : s < 172800 ? `${Math.round(s / 3600)}h` : `${Math.round(s / 86400)}d`; };
function loadLocalSessions() {
  const base = path.join(HOME, ".claude", "projects"); const out = []; let dirs = [];
  try { dirs = fs.readdirSync(base).map((d) => path.join(base, d)); } catch { return { list: [], total: 0, bytes: 0 }; }
  for (const dir of dirs) { let names = []; try { if (!fs.statSync(dir).isDirectory()) continue; names = fs.readdirSync(dir); } catch { continue; }
    for (const n of names) { if (!n.endsWith(".jsonl")) continue; const f = path.join(dir, n); try { const st = fs.statSync(f); out.push({ id: n.slice(0, -6), f, mtime: st.mtimeMs, size: st.size }); } catch {} } }
  const total = out.length, bytes = out.reduce((a, s) => a + s.size, 0);
  out.sort((a, b) => b.mtime - a.mtime);
  const list = out.slice(0, 15).map((s) => {
    let ct = null, slug = null, ai = null, fp = null, cwd = null, msgs = 0;
    try { for (const line of fs.readFileSync(s.f, "utf8").split("\n")) { if (!line) continue; let o; try { o = JSON.parse(line); } catch { continue; }
      if (o.customTitle) ct = String(o.customTitle); if (o.aiTitle) ai = String(o.aiTitle); if (!slug && o.slug) slug = String(o.slug);
      if (!cwd && o.cwd) cwd = o.cwd; if (o.type === "user" || o.type === "assistant") msgs++;
      if (!fp && o.type === "user") { const c = o.message?.content; const t = typeof c === "string" ? c : Array.isArray(c) ? c.find((b) => b?.type === "text")?.text : null; if (t && !t.startsWith("<")) fp = t; } } } catch {}
    const title = (ct || slug || ai || fp || s.id.slice(0, 8)).replace(/[\r\n]+/g, " ").trim().slice(0, 30);
    return { id: s.id, title, age: ago(s.mtime), kb: Math.max(1, Math.round(s.size / 1024)), msgs, cwd: (cwd || "").replace(HOME, "~") };
  });
  return { list, total, bytes };
}
function claudeConfig() {
  const s = readJSON(path.join(CFG, "settings.json")) || {};
  return { model: s.model || "(default)", statusline: !!s.statusLine, skills: loadDirList("skills"), mcpCount: loadMcps().length };
}

// ── probes ──────────────────────────────────────────────────────────────────
async function httpTimed(url, sub = "", { anyStatus = false, headers, timeout = 1800, wantBody = false } = {}) {
  const t0 = Date.now();
  try {
    const c = new AbortController(); const t = setTimeout(() => c.abort(), timeout);
    const r = await fetch(`${url.replace(/\/$/, "")}${sub}`, { signal: c.signal, redirect: "manual", headers }).finally(() => clearTimeout(t));
    const v = { up: anyStatus ? true : r.ok, ms: Date.now() - t0, status: r.status };
    if (wantBody) { try { v.body = await r.json(); } catch {} }
    return v;
  } catch { return "t/o"; }
}
function sh(cmd, args, timeout = 2500) {
  return new Promise((resolve) => {
    let done = false; const fin = (v) => { if (!done) { done = true; resolve(v); } };
    let ch; try { ch = spawn(cmd, args); } catch { return fin("t/o"); }
    const k = setTimeout(() => { try { ch.kill("SIGKILL"); } catch {} fin("t/o"); }, timeout);
    let out = ""; ch.stdout.on("data", (d) => (out += d)); ch.stderr.on("data", () => {});
    ch.on("error", () => { clearTimeout(k); fin("t/o"); });
    ch.on("close", () => { clearTimeout(k); fin({ out }); });
  });
}
async function ping(ip) { const r = await sh(BIN.ping, ["-c", "1", "-W", "1", ip], 2000); if (r === "t/o") return "t/o"; const m = r.out.match(/time[=<]([\d.]+)\s*ms/); return m ? { up: true, ms: Math.round(Number(m[1])) } : "t/o"; }
async function imageArches() {
  try {
    const repo = IMAGE.replace(/^ghcr\.io\//, "");
    const tk = await httpTimed(`https://ghcr.io/token?scope=repository:${repo}:pull`, "", { wantBody: true, timeout: 2000 });
    if (tk === "t/o" || !tk.body?.token) return "t/o";
    const acc = "application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json";
    const m = await httpTimed(`https://ghcr.io/v2/${repo}/manifests/latest`, "", { headers: { Authorization: `Bearer ${tk.body.token}`, Accept: acc }, wantBody: true, timeout: 2200 });
    if (m === "t/o" || !m.body) return "t/o";
    return m.body.manifests ? { arches: m.body.manifests.map((x) => x.platform?.architecture).filter(Boolean) } : { arches: [m.body.architecture || "single"] };
  } catch { return "t/o"; }
}

// ── state ───────────────────────────────────────────────────────────────────
const AGENTS = ["goose", "claude-cli", "claude-cli-ghost", "hermes", "claude-superset"];
const st = { agent: "claude-superset", face: "remote", headroom: true, ponytail: true, ponyLevel: "full", rtk: true, caveman: true, statusLine: !!(readJSON(path.join(CFG, "settings.json")) || {}).statusLine, restore: "off", restoreN: 5, flagResume: false, flagContinue: false };
let numBuf = "", page = 1, focus = 0, refreshing = false, tearing = false;
const OFF = { mcps: loadMcps(), plugins: loadPlugins(), hooks: hooksDetailed(), sessions: loadLocalSessions(), cfg: claudeConfig() };
const D = {}; // net/cmd slots by id: undefined|null|value|"t/o"

function collectors() {
  const cs = [
    ["proxy", () => httpTimed(EP.proxy, "/readyz")],
    ["api", () => httpTimed(EP.api, "/health", { wantBody: true })],
    ["ollama", () => httpTimed(EP.ollama, "/api/version")],
    ["compress", () => httpTimed(EP.compress, "/readyz")],
    ["direct", () => httpTimed(EP.anthropic, "/v1/models", { anyStatus: true })],
    ["health", () => httpTimed(EP.api, "/health", { wantBody: true })],
    ["tokens", () => httpTimed(EP.compress, "/stats", { wantBody: true })],
    ["server", () => httpTimed(EP.api, "/sessions", { wantBody: true })],
    ["image", () => imageArches()],
    ["hostdisk", () => sh(BIN.df, ["-h", HOME, "/mnt/shared-lib"], 2500)],
  ];
  for (const [n, ip] of Object.entries(MESH)) cs.push([`mesh:${n}`, () => ping(ip)]);
  for (const [n, ip] of Object.entries(PUBLIC)) cs.push([`pub:${n}`, () => ping(ip)]);
  for (const m of OFF.mcps) if (m.type === "http" && m.url) cs.push([`mcp:${m.name}`, () => httpTimed(m.url, "", { anyStatus: true })]);
  for (const rp of REPOS) cs.push([`repo:${rp}`, () => sh(BIN.git, ["-C", path.join(GITROOT, rp), "status", "--porcelain=v1", "-b"], 2500)]);
  return cs;
}
const COLS = collectors();
function refresh() {
  if (refreshing) return; refreshing = true;
  for (const [id] of COLS) D[id] = null;
  OFF.mcps.forEach((m) => (m.st = m.type === "http" ? null : "stdio"));
  if (spinTimer) clearInterval(spinTimer);
  spinTimer = setInterval(() => { spin = (spin + 1) % SPIN.length; if (!tearing) render(); }, 110);
  render();
  for (const [id, run] of COLS) run().then((v) => { D[id] = v; if (id.startsWith("mcp:")) { const m = OFF.mcps.find((x) => x.name === id.slice(4)); if (m) m.st = v; } if (!tearing) render(); }).catch(() => { D[id] = "t/o"; });
  setTimeout(() => { refreshing = false; if (spinTimer) { clearInterval(spinTimer); spinTimer = null; } if (!tearing) render(); }, 3400);
}
const progress = () => { const s = COLS.map(([id]) => D[id]); return { total: s.length, done: s.filter((x) => x !== null && x !== undefined).length }; };

function dm(v) {
  if (v === undefined) return `${C.dim}--${C.r}     `;
  if (v === null) return `${C.dim}${SPIN[spin]} ${C.r}    `;
  if (v === "t/o") return `${C.y}t/o${C.r}    `;
  if (v === "stdio") return `${C.blu}stdio${C.r}  `;
  const col = !v.up ? C.red : v.ms < 60 ? C.g : v.ms < 200 ? C.y : C.red;
  return `${v.up ? C.g + "up" : C.red + "dn"}${C.r} ${col}${padS(`${v.ms}ms`, 5)}${C.r}`;
}
const parseDf = (v) => { if (!v || v === "t/o" || v.out === undefined) return null; return v.out.trim().split("\n").slice(1).map((l) => { const p = l.split(/\s+/); return { fs: p[0], size: p[1], used: p[2], avail: p[3], pct: p[4], mount: p[5] }; }); };
const parseRepo = (v) => { if (!v || v === "t/o" || v.out === undefined) return "t/o"; const lines = v.out.split("\n"); const head = lines[0] || ""; const br = (head.match(/## ([^.\s]+)/) || [])[1] || "?"; const ah = (head.match(/ahead (\d+)/) || [])[1] || 0; const be = (head.match(/behind (\d+)/) || [])[1] || 0; const dirty = lines.slice(1).filter(Boolean).length; return { br, ahead: +ah, behind: +be, dirty }; };

// ── PAGES ────────────────────────────────────────────────────────────────────
let rows = [], fl = [];
function buildRows() {
  const r = [];
  r.push({ t: "sec", text: "AGENTS" });
  for (const a of AGENTS) r.push({ t: "radio", grp: "agent", val: a, label: a, note: a === "claude-superset" ? "compression + plugin tools (default)" : "" });
  r.push({ t: "sec", text: "FACE" });
  r.push({ t: "radio", grp: "face", val: "remote", label: "remote", note: "WG compression proxy" });
  r.push({ t: "radio", grp: "face", val: "local", label: "local", note: "container on THIS host" });
  r.push({ t: "radio", grp: "face", val: "claude", label: "claude", note: "plain claude (restore still works)" });
  if (st.face !== "claude") { r.push({ t: "sec", text: "PLUGINS (superset infra)" }); r.push({ t: "check", key: "headroom", label: "Headroom", note: "compression proxy" }); r.push({ t: "checklevel", key: "ponytail", label: "Ponytail", note: "Left/Right level" }); r.push({ t: "check", key: "rtk", label: "RTK", note: "strip CLI/test noise pre-Headroom" }); r.push({ t: "check", key: "caveman", label: "Caveman", note: "linguistic compression" }); r.push({ t: "check", key: "statusLine", label: "Status Line", note: "Claude Code statusline" }); }
  else { r.push({ t: "sec", text: "CLAUDE-FLAGS" }); r.push({ t: "check", key: "flagResume", label: "--resume", note: "restore most recent session" }); r.push({ t: "check", key: "flagContinue", label: "--continue", note: "continue conversation" }); }
  r.push({ t: "sec", text: "RESTORE" });
  r.push({ t: "radio", grp: "restore", val: "off", label: "off", note: "fresh session" });
  r.push({ t: "radio", grp: "restore", val: "count", label: "count", note: "last N sessions" });
  r.push({ t: "radio", grp: "restore", val: "hours", label: "hours", note: "sessions from last N hours" });
  if (st.restore !== "off") r.push({ t: "number", key: "restoreN", label: "N", note: "type digits or Left/Right" });
  r.push({ t: "sec", text: "ACTION" });
  r.push({ t: "action", key: "refresh" }); r.push({ t: "action", key: "launch" }); r.push({ t: "action", key: "quit" });
  return r;
}
const FOCT = ["radio", "check", "checklevel", "number", "action"];
function pageCompose(L) {
  rows = buildRows(); fl = rows.map((r, i) => (FOCT.includes(r.t) ? i : -1)).filter((i) => i >= 0);
  if (focus >= fl.length) focus = fl.length - 1; if (focus < 0) focus = 0;
  const focIdx = fl[focus];
  L.push(""); L.push(secHead("COMPOSER", `${st.agent} / ${st.face}`, C.composer));
  rows.forEach((row, i) => {
    const foc = i === focIdx, cur = foc ? `${C.cy}${C.b}>${C.r} ` : "  ", hl = (s) => (foc ? `${C.inv}${s}${C.r}` : s);
    if (row.t === "sec") return L.push(`   ${C.dim}${row.text}${C.r}`);
    let b = "";
    if (row.t === "radio") b = `${st[row.grp] === row.val ? `${C.g}(*)${C.r}` : `${C.dim}( )${C.r}`} ${hl(padE(row.label, 18))} ${C.dim}${row.note}${C.r}`;
    else if (row.t === "check") b = `${st[row.key] ? `${C.g}[x]${C.r}` : `${C.dim}[ ]${C.r}`} ${hl(padE(row.label, 12))} ${C.dim}${row.note}${C.r}`;
    else if (row.t === "checklevel") { const lv = st[row.key] ? `${C.mag}< ${st.ponyLevel} >${C.r}` : `${C.dim}(off)${C.r}`; b = `${st[row.key] ? `${C.g}[x]${C.r}` : `${C.dim}[ ]${C.r}`} ${hl(padE(row.label, 12))} ${lv}  ${C.dim}${row.note}${C.r}`; }
    else if (row.t === "number") { const sv = foc && numBuf !== "" ? numBuf : String(st.restoreN); b = `    ${hl(row.label)} ${foc ? `${C.inv} ${sv}_ ${C.r}` : `${C.mag}< ${sv} >${C.r}`}  ${C.dim}${row.note}${C.r}`; }
    else if (row.t === "action") { const A = { refresh: [" (r) Refresh ", C.blu], launch: [" (l) LAUNCH ", C.g], quit: [" (q) Quit ", C.dim] }[row.key]; b = foc ? `${C.inv}${A[1]}${A[0]}${C.r}` : `${A[1]}[${A[0].trim()}]${C.r}`; }
    L.push(`${cur}${b}`);
  });
  L.push(""); L.push(secHead(`MCP SERVERS (${OFF.mcps.length})`, "", C.composer));
  if (!OFF.mcps.length) L.push(`    ${C.dim}none${C.r}`);
  for (let i = 0; i < OFF.mcps.length; i += 3)
    L.push("   " + OFF.mcps.slice(i, i + 3).map((m) => padE(`${C.mag}${padE(m.name, 15)}${C.r} ${m.type === "http" ? dm(D[`mcp:${m.name}`]) : dm("stdio")}`, 26)).join(""));
  L.push(""); L.push(secHead(`PLUGINS enabled (${OFF.plugins.length})`, "", C.composer));
  L.push(`    ${OFF.plugins.map((p) => `${C.g}${p.label}${p.detail ? "@" + p.detail : ""}${C.r}`).join("  ") || `${C.dim}none${C.r}`}`);
}
function pageUsage(L) {
  L.push(""); L.push(secHead(`SESSIONS local (${OFF.sessions.total} total, ${Math.round(OFF.sessions.bytes / 1048576)}MB)`, "", C.usage));
  L.push(`    ${C.dim}${padE("age", 9)}${padE("msgs", 6)}${padE("size", 7)}${padE("title", 32)}cwd${C.r}`);
  OFF.sessions.list.forEach((s) => L.push(`    ${padE(s.age + " ago", 9)}${C.dim}${padE(String(s.msgs), 6)}${padE(s.kb + "K", 7)}${C.r}${padE(s.title, 32)}${C.dim}${s.cwd}${C.r}`));
  const sv = D.server;
  L.push(""); L.push(secHead("SESSIONS server (hub)", refreshing ? "probing" : "", C.usage));
  if (sv === undefined) L.push(`    ${C.dim}-- press Refresh / r${C.r}`);
  else if (sv === null) L.push(`    ${C.dim}${SPIN[spin]} loading${C.r}`);
  else if (sv === "t/o" || !sv.body) L.push(`    ${C.y}t/o (hub unreachable)${C.r}`);
  else if (Array.isArray(sv.body)) {
    const arr = sv.body.slice().sort((a, b) => (b.mtime || 0) - (a.mtime || 0));
    const byDev = {}; arr.forEach((s) => { (byDev[s.device || "?"] ||= []).push(s); });
    L.push(`    ${C.dim}${arr.length} sessions across ${Object.keys(byDev).length} device(s)${C.r}`);
    for (const [dev, list] of Object.entries(byDev)) {
      L.push(`    ${C.cy}${dev}${C.r} ${C.dim}(${list.length})${C.r}`);
      list.slice(0, 15).forEach((s) => L.push(`      ${C.dim}${padS(s.mtime ? ago(s.mtime) + " ago" : "", 9)}  ${padE((s.id || "").slice(0, 8), 10)}${padE(Math.round((s.size || 0) / 1024) + "K", 6)}${C.r}`));
    }
  }
  const tk = D.tokens; let tl = `${C.dim}--${C.r}`;
  if (tk === null) tl = `${C.dim}${SPIN[spin]}${C.r}`; else if (tk === "t/o") tl = `${C.y}t/o${C.r}`;
  else if (tk && tk.body) { const j = tk.body; tl = `${C.y}${num(j.tokens_saved)}${C.r} saved ${C.dim}(${((j.lifetime_ratio || 0) * 100).toFixed(0)}%)${C.r}  ${C.dim}before${C.r} ${num(j.tokens_before)}  ${C.dim}after${C.r} ${num(j.tokens_after)}  ${C.dim}compress${C.r} ${num(j.compressions)}`; }
  const im = D.image; let il = `${C.dim}--${C.r}`;
  if (im === null) il = `${C.dim}${SPIN[spin]}${C.r}`; else if (im === "t/o") il = `${C.y}t/o${C.r}`;
  else if (im && im.arches) { const multi = im.arches.length > 1; il = `${multi ? C.g : C.red}${im.arches.join(",")}${C.r} ${C.dim}${multi ? "(multi-arch)" : "(single-arch!)"}${C.r}`; }
  L.push(""); L.push(secHead("USAGE stats", "", C.usage));
  L.push(`    ${C.dim}tokens${C.r}  ${tl}`);
  L.push(`    ${C.dim}image${C.r}   ${il}`);
}
function pageStack(L) {
  const kv = (k, s) => `    ${C.dim}${padE(k, 11)}${C.r}${s}`;
  L.push(""); L.push(secHead("FACES (mesh-status)", "", C.stack));
  L.push(kv("services", ["proxy", "api", "ollama", "compress", "direct"].map((k, i) => `${C.dim}${["proxy", "api", "ollama", "compr", "direct"][i]}${C.r} ${dm(D[k])}`).join(" ")));
  const h = D.health; let hl = `${C.dim}--${C.r}`;
  if (h === null) hl = `${C.dim}${SPIN[spin]}${C.r}`; else if (h === "t/o") hl = `${C.y}t/o${C.r}`;
  else if (h && h.body) { const s = h.body.stats || {}; hl = `${C.dim}conc${C.r} ${h.body.active}/${h.body.max}  ${C.dim}calls${C.r} ${num(s.calls)}  ${C.dim}err${C.r} ${num(s.errors)}  ${C.dim}in${C.r} ${num(s.prompt_tokens)}  ${C.dim}out${C.r} ${num(s.completion_tokens)}  ${C.dim}hr${C.r} ${h.body.headroom ? C.g + "on" : C.dim + "off"}${C.r}`; }
  L.push(kv("container", hl));
  L.push(""); L.push(secHead("MESH (wg)", "", C.stack));
  L.push("    " + Object.keys(MESH).map((n) => `${C.dim}${padE(n, 13)}${C.r}${dm(D[`mesh:${n}`])}`).join("  "));
  L.push(""); L.push(secHead("PUBLIC edge", "", C.stack));
  L.push("    " + Object.keys(PUBLIC).map((n) => `${C.dim}${padE(n, 13)}${C.r}${dm(D[`pub:${n}`])}`).join("  "));
  L.push(""); L.push(secHead("HOST", "", C.stack));
  const disks = parseDf(D.hostdisk);
  if (D.hostdisk === undefined) L.push(`    ${C.dim}disk    -- press Refresh${C.r}`);
  else if (D.hostdisk === null) L.push(`    ${C.dim}disk    ${SPIN[spin]}${C.r}`);
  else if (!disks) L.push(`    ${C.y}disk    t/o${C.r}`);
  else disks.forEach((d) => { const pct = parseInt(d.pct) || 0; const col = pct > 90 ? C.red : pct > 75 ? C.y : C.g; L.push(`    ${C.dim}disk${C.r}  ${padE(d.mount || "", 18)} ${col}${padS(d.pct || "", 4)}${C.r} ${C.dim}${d.used}/${d.size} used, ${d.avail} free${C.r}`); });
  try { const mi = fs.readFileSync("/proc/meminfo", "utf8"); const g = (k) => +((mi.match(new RegExp(k + ":\\s+(\\d+)")) || [])[1] || 0); const tot = g("MemTotal"), av = g("MemAvailable"); L.push(`    ${C.dim}mem${C.r}   ${padE("", 18)} ${((1 - av / tot) * 100).toFixed(0)}% ${C.dim}${(av / 1048576).toFixed(1)}G free / ${(tot / 1048576).toFixed(1)}G${C.r}`); } catch {}
  try { const la = fs.readFileSync("/proc/loadavg", "utf8").split(" ").slice(0, 3).join(" "); L.push(`    ${C.dim}load${C.r}  ${padE("", 18)} ${la}`); } catch {}
  L.push(""); L.push(secHead("GIT REPOS", "", C.stack));
  REPOS.forEach((rp) => { const v = parseRepo(D[`repo:${rp}`]); let s;
    if (D[`repo:${rp}`] === undefined) s = `${C.dim}-- Refresh${C.r}`; else if (D[`repo:${rp}`] === null) s = `${C.dim}${SPIN[spin]}${C.r}`; else if (v === "t/o") s = `${C.y}t/o${C.r}`;
    else s = `${C.cy}${padE(v.br, 8)}${C.r} ${v.ahead ? C.g + "+" + v.ahead + " " : ""}${v.behind ? C.red + "-" + v.behind + " " : ""}${C.r}${v.dirty ? C.y + v.dirty + " dirty" : C.g + "clean"}${C.r}`;
    L.push(`    ${C.mag}${padE(rp, 8)}${C.r} ${s}`); });
  L.push(""); L.push(secHead("CLAUDE", "", C.stack));
  L.push(`    ${C.dim}model${C.r}     ${OFF.cfg.model}   ${C.dim}mcp${C.r} ${OFF.cfg.mcpCount}`);
  L.push(`    ${C.dim}skills${C.r}    ${OFF.cfg.skills.slice(0, 12).map((s) => `${C.dim}${s}${C.r}`).join(" ") || C.dim + "none" + C.r}`);
  L.push(`    ${C.dim}hooks${C.r}     ${OFF.hooks.map((h) => `${C.dim}${h.name}(${h.kb}K)${C.r}`).join("  ")}`);
}

// ── render — EVERYTHING on one screen (no pages) ────────────────────────────
function selArgs() {
  const n = String(Math.max(1, st.restoreN || 1)), a = [st.face];
  if (st.face !== "claude") { if (!st.headroom) a.push("headroom", "off"); a.push("ponytail", st.ponytail ? st.ponyLevel : "off"); if (!st.rtk) a.push("rtk", "off"); if (!st.caveman) a.push("caveman", "off"); }
  else { if (st.flagResume) a.push("--resume"); if (st.flagContinue) a.push("--continue"); }
  if (st.restore === "count") a.push("restore", n); if (st.restore === "hours") a.push("restore-hours", n);
  return a;
}
function render() {
  if (tearing) return;
  const L = [], bar = `+${"-".repeat(W)}+`;
  const pr = progress();
  L.push(`  ${C.b}${C.cy}${bar}${C.r}`);
  L.push(`  ${C.b}${C.cy}|${C.r} ${C.b}${C.mag}C L A U D E - S U P E R S E T${C.r}  ${C.dim}launch + infra dashboard${C.r}${padE("", W - 55)}${C.b}${C.cy}|${C.r}`);
  L.push(`  ${C.b}${C.cy}${bar}${C.r}`);
  L.push(`   ${C.g}>${C.r} ${C.cy}${SELF} ${selArgs().join(" ")}${C.r}   ${refreshing ? `${C.y}${SPIN[spin]} probing ${pr.done}/${pr.total}${C.r}` : `${C.dim}r=Refresh${C.r}`}`);
  if (lastLaunch) L.push(`   ${C.g}[launched in new window: ${lastLaunch}]${C.r}  ${C.dim}TUI stays open${C.r}`);
  L.push(""); L.push(bigBanner("COMPOSER", C.composer));
  pageCompose(L);
  L.push(""); L.push(bigBanner("USAGE", C.usage));
  pageUsage(L);
  L.push(""); L.push(bigBanner("STACK", C.stack));
  pageStack(L);
  L.push(""); L.push(secHead("KEYS + LEGEND"));
  L.push(`   ${C.b}(l)${C.r}aunch  ${C.b}(r)${C.r}efresh  ${C.b}(q)${C.r}uit   ${C.dim}Up/Down move . Space select . Left/Right change . 0-9 type N . Enter activate${C.r}`);
  L.push(`   ${C.g}up${C.r}${C.dim}=reachable(+latency)${C.r}  ${C.red}dn${C.r}${C.dim}=down${C.r}  ${C.y}t/o${C.r}${C.dim}=timeout(no reply<2s)${C.r}  ${C.dim}..${C.r}${C.dim}=probing  --=not probed yet (press r)${C.r}  ${C.blu}stdio${C.r}${C.dim}=local-process MCP (no ping)${C.r}`);
  process.stdout.write("\x1b[H" + L.map((l) => l + "\x1b[K").join("\n") + "\x1b[0J");
}

// ── input ────────────────────────────────────────────────────────────────────
function setStatusLine(on) {
  const p = path.join(CFG, "settings.json"), s = readJSON(p) || {};
  if (on) { if (s._statusLineDisabledCommand) { s.statusLine = s._statusLineDisabledCommand; delete s._statusLineDisabledCommand; } }
  else if (s.statusLine) { s._statusLineDisabledCommand = s.statusLine; delete s.statusLine; }
  try { fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n"); } catch {}
}
function activate(row) { if (row.t === "radio") st[row.grp] = row.val; else if (row.t === "check" || row.t === "checklevel") { st[row.key] = !st[row.key]; if (row.key === "statusLine") setStatusLine(st.statusLine); } }
function adjust(row, dir) {
  if (row.t === "checklevel" && st.ponytail) { const i = PONY_LEVELS.indexOf(st.ponyLevel); st.ponyLevel = PONY_LEVELS[(i + dir + 3) % 3]; }
  else if (row.t === "number") { numBuf = ""; const p = RESTORE_PRESETS[st.restore] || []; const i = Math.max(0, p.indexOf(st.restoreN)); st.restoreN = p[Math.min(p.length - 1, Math.max(0, i + dir))]; }
  else if (row.t === "radio") { const o = rows.filter((r) => r.t === "radio" && r.grp === row.grp).map((r) => r.val); const i = o.indexOf(st[row.grp]); st[row.grp] = o[(i + dir + o.length) % o.length]; }
}
function teardown() { tearing = true; if (process.stdin.isTTY) process.stdin.setRawMode(false); process.stdout.write("\x1b[?25h"); }
function quit() { teardown(); process.exit(0); }
let lastLaunch = "";
function launch() {
  const args = selArgs();
  const isRestore = args.includes("restore") || args.includes("restore-hours");
  // GUI: open the composed command in a NEW konsole window and KEEP the TUI
  // open as a launcher dashboard. Restore already opens its own tab window, so
  // run the wrapper directly; a fresh launch is wrapped in `konsole -e` to give
  // it a terminal.
  if (env.CAS_KONSOLE && env.DISPLAY) {
    const argv = isRestore ? [SELF, ...args] : [env.CAS_KONSOLE, "-e", SELF, ...args];
    try { spawn(argv[0], argv.slice(1), { detached: true, stdio: "ignore" }).unref(); lastLaunch = args.join(" "); }
    catch { lastLaunch = "FAILED"; }
    return render();
  }
  // Bare TTY / termux (no GUI): hand the terminal over — the TUI exits.
  teardown(); process.stdout.write("\x1b[2J\x1b[H");
  const ch = spawn(SELF, args, { stdio: "inherit" });
  ch.on("exit", (c) => process.exit(c ?? 0));
  ch.on("error", () => { console.log(`${SELF} not found on PATH`); process.exit(1); });
}
function main() {
  if (!process.stdin.isTTY) { console.log(`claude-superset TUI needs a terminal. Would launch: ${SELF} ${selArgs().join(" ")}`); process.exit(0); }
  process.stdout.write("\x1b[2J\x1b[H\x1b[?25l"); render();
  readline.emitKeypressEvents(process.stdin); process.stdin.setRawMode(true);
  process.stdin.on("keypress", (str, key) => {
    const name = key?.name;
    if (name === "q" || (key?.ctrl && name === "c")) return quit();
    if (name === "r") return refresh();
    if (name === "l") return launch();
    const row = rows[fl[focus]];
    const editingN = row?.t === "number";
    if (name === "up" || name === "k") { numBuf = ""; focus = (focus - 1 + fl.length) % fl.length; }
    else if (name === "down" || name === "j" || name === "tab") { numBuf = ""; focus = (focus + 1) % fl.length; }
    else if (name === "left") adjust(row, -1);
    else if (name === "right") adjust(row, 1);
    else if (editingN && str && /^[0-9]$/.test(str)) { numBuf = (numBuf + str).slice(0, 4).replace(/^0+/, "") || "0"; st.restoreN = Number(numBuf); }
    else if (editingN && name === "backspace") { numBuf = numBuf.slice(0, -1); st.restoreN = Number(numBuf) || 0; }
    else if (name === "space" || name === "return") { row.t === "action" ? (row.key === "refresh" ? refresh() : row.key === "launch" ? launch() : quit()) : activate(row); }
    else return;
    render();
  });
}
main();
