#!/usr/bin/env node
// claude-superset-restore.mjs — session engine for claude-superset. One file,
// shared verbatim by the desktop and termux flakes (universal: KDE, TTY, Termux).
//
//   node claude-superset-restore.mjs sync   [device] [keep]
//       Push the last <keep> local sessions to the hub under <device>.
//   node claude-superset-restore.mjs launch <face> <devsel> <count|hours> <value>
//       Reopen sessions, one per terminal tab/window:
//         devsel = local        → this device's own sessions (files already here)
//         devsel = all|<device> → pull from the hub, re-home into $HOME's project
//                                 dir so `claude --resume` works even when the
//                                 origin cwd doesn't exist on this device.
//       Terminal multiplexer is auto-detected: konsole (if $DISPLAY + CAS_KONSOLE)
//       → tmux (CAS_TMUX) → plain sequential fallback.
//
// Env (injected by the nix wrapper, all optional):
//   CAS_API      hub base url (e.g. http://10.0.0.6:3117)
//   CAS_DEVICE   this device's id (default: hostname)
//   CAS_SELF     launcher command for tabs (default: claude-superset)
//   CAS_FACE     default face for tabs (remote|local)
//   CAS_KONSOLE  path to konsole binary (desktop only)
//   CAS_TMUX     path to tmux binary
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { spawn, spawnSync } from "node:child_process";

// `list | head` closes stdout early — swallow the resulting EPIPE, don't crash.
process.stdout.on("error", (e) => { if (e.code === "EPIPE") process.exit(0); });

const HOME = os.homedir();
const PROJECTS = path.join(HOME, ".claude", "projects");
const API = (process.env.CAS_API || "").replace(/\/$/, "");
const DEVICE = process.env.CAS_DEVICE || os.hostname();
const SELF = process.env.CAS_SELF || "claude-superset";
const KONSOLE = process.env.CAS_KONSOLE || "";
const TMUX = process.env.CAS_TMUX || "";

// Claude encodes a session's project dir as its cwd with every "/" → "-".
// ponytail: only "/" is remapped; exotic cwd chars are rare here — revisit if a
// resume ever lands in the wrong project dir.
const encodeCwd = (cwd) => cwd.replace(/\//g, "-");

// POSIX single-quote a string for safe embedding inside a generated /bin/sh script.
const shq = (s) => `'${String(s).replace(/'/g, "'\\''")}'`;

// Pull {cwd, title} out of a session jsonl body. Title matches what the
// `/resume` picker shows: customTitle (set by `/rename`) → slug (the dashed
// auto-name) → aiTitle → first user prompt → short id. customTitle/aiTitle take
// the last occurrence (a rename late in the session wins).
function inspect(text, id) {
  let cwd = null, customTitle = null, slug = null, aiTitle = null, firstPrompt = null;
  for (const line of text.split("\n")) {
    if (!line) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (!cwd && typeof o.cwd === "string") cwd = o.cwd;
    if (o.customTitle) customTitle = String(o.customTitle);
    if (o.aiTitle) aiTitle = String(o.aiTitle);
    if (!slug && o.slug) slug = String(o.slug);
    if (!firstPrompt && o.type === "user") {
      const c = o.message?.content;
      const t = typeof c === "string" ? c
        : Array.isArray(c) ? c.find((b) => b?.type === "text")?.text : null;
      if (t && !t.startsWith("<")) firstPrompt = t;
    }
  }
  const raw = customTitle || slug || aiTitle || firstPrompt || id.slice(0, 8);
  const title = raw.replace(/[\r\n;]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 40) || id.slice(0, 8);
  return { cwd, title };
}

// All local sessions, newest first: {id, file, mtime}.
function localSessions() {
  const out = [];
  let dirs = [];
  try { dirs = fs.readdirSync(PROJECTS).map((p) => path.join(PROJECTS, p)); } catch { return out; }
  for (const dir of dirs) {
    let names = [];
    try { if (!fs.statSync(dir).isDirectory()) continue; names = fs.readdirSync(dir); } catch { continue; }
    for (const name of names) {
      if (!name.endsWith(".jsonl")) continue;
      const file = path.join(dir, name);
      try { out.push({ id: name.slice(0, -6), file, mtime: fs.statSync(file).mtimeMs }); } catch {}
    }
  }
  return out.sort((a, b) => b.mtime - a.mtime);
}

const bySelector = (list, selector, value) =>
  selector === "hours"
    ? list.filter((s) => s.mtime >= Date.now() - value * 3600_000)
    : list.slice(0, value);

// ── sync: push last <keep> local sessions to the hub ─────────────────────────
async function doSync(device, keep) {
  if (!API) { process.stderr.write("[restore] no CAS_API; cannot sync\n"); process.exit(0); }
  const picks = localSessions().slice(0, keep);
  let ok = 0;
  for (const s of picks) {
    try {
      const body = fs.readFileSync(s.file);
      const r = await fetch(`${API}/sessions/${encodeURIComponent(device)}/${encodeURIComponent(s.id)}`, {
        method: "PUT", headers: { "content-type": "application/x-ndjson" }, body,
      });
      if (r.ok) ok++;
    } catch {}
  }
  process.stderr.write(`[restore] synced ${ok}/${picks.length} sessions as device '${device}'\n`);
}

// ── remote selection: pull from hub, re-home into local $HOME project dir ─────
async function remoteEntries(devsel, selector, value) {
  if (!API) { process.stderr.write("[restore] no CAS_API; cannot restore remote\n"); return []; }
  let list;
  try {
    const r = await fetch(`${API}/sessions`);
    if (!r.ok) throw new Error(`list ${r.status}`);
    list = await r.json();
  } catch (e) { process.stderr.write(`[restore] hub unreachable: ${e.message}\n`); return []; }
  if (!Array.isArray(list)) return [];
  if (devsel !== "all") list = list.filter((s) => s.device === devsel);
  list.sort((a, b) => (b.mtime || 0) - (a.mtime || 0));
  const picks = bySelector(list.map((s) => ({ ...s, mtime: s.mtime || 0 })), selector, value);

  const homeDir = path.join(PROJECTS, encodeCwd(HOME));
  fs.mkdirSync(homeDir, { recursive: true });
  const entries = [];
  for (const s of picks) {
    try {
      const r = await fetch(`${API}/sessions/${encodeURIComponent(s.device)}/${encodeURIComponent(s.id)}`);
      if (!r.ok) continue;
      const text = await r.text();
      // Re-home under $HOME so `claude --resume` finds it on this device.
      fs.writeFileSync(path.join(homeDir, `${s.id}.jsonl`), text);
      const { title } = inspect(text, s.id);
      entries.push({ id: s.id, title: `${s.device}:${title}`.slice(0, 40), workdir: HOME });
    } catch {}
  }
  return entries;
}

function localEntries(selector, value) {
  return bySelector(localSessions(), selector, value).map((s) => {
    const { cwd, title } = inspect(fs.readFileSync(s.file, "utf8"), s.id);
    return { id: s.id, title, workdir: cwd || HOME };
  });
}

// ── launch entries as tabs/windows via the best available multiplexer ────────
function launch(entries, face) {
  if (!entries.length) { process.stderr.write("[restore] no matching sessions\n"); process.exit(1); }
  const SH = process.env.SHELL || "/bin/bash";
  const bare = (id) => `${SELF} ${face} --resume ${id}`;
  // Each tab runs an interactive shell that STAYS after claude exits: Ctrl+C
  // soft-kills claude (which prints its `claude --resume <id>` hint) and drops
  // you back to a shell prompt in the same tab — the tab is NOT killed.
  // Emitted as a per-session launcher SCRIPT (see the konsole branch for why):
  //   cd <workdir> ; <resume> ; exec <shell> -i
  const tabScript = (e) =>
    `#!/bin/sh\ncd ${shq(e.workdir)} 2>/dev/null || cd ${shq(HOME)}\n${bare(e.id)}\nexec ${SH} -i\n`;
  process.stderr.write(`[restore] restoring ${entries.length} session(s)\n`);

  if (KONSOLE && process.env.DISPLAY) {
    // konsole's --tabs-from-file tokenizes the `command:` field on whitespace
    // and does NOT honor shell quoting — a quoted `sh -c "…; exec sh -i"` gets
    // split apart, the shell dies on the broken fragment, and the tab closes
    // instantly with nothing restored (the exec keep-alive never runs). So write
    // each session's real command to a launcher script and reference it as bare
    // `sh <path>` tokens — no quotes, no `;`, nothing for konsole to mangle.
    const dir = process.env.XDG_RUNTIME_DIR || os.tmpdir();
    const lines = entries.map((e) => {
      const scr = path.join(dir, `claude-superset-tab-${e.id}.sh`);
      fs.writeFileSync(scr, tabScript(e), { mode: 0o755 });
      return `title: ${e.title} ;; command: ${SH} ${scr}`;
    });
    const tabs = path.join(dir, "claude-superset-tabs");
    fs.writeFileSync(tabs, lines.join("\n") + "\n");
    spawn(KONSOLE, ["--tabs-from-file", tabs], { detached: true, stdio: "ignore" }).unref();
    return;
  }
  if (TMUX) {
    const S = "claude-superset";
    // tmux receives the command as a single argv element (quoting preserved) and
    // runs it via `sh -c`, so the inline keep-alive form is safe here.
    const cmd = (id) => `${SH} -c ${shq(`${bare(id)}; exec ${SH} -i`)}`;
    // Fresh detached session; first entry seeds window 0, the rest are new windows.
    spawnSync(TMUX, ["kill-session", "-t", S], { stdio: "ignore" });
    spawnSync(TMUX, ["new-session", "-d", "-s", S, "-n", entries[0].title, "-c", entries[0].workdir, cmd(entries[0].id)]);
    for (const e of entries.slice(1))
      spawnSync(TMUX, ["new-window", "-t", S, "-n", e.title, "-c", e.workdir, cmd(e.id)]);
    // Attach in the foreground (works in TTY + Termux). If already inside tmux, switch.
    if (process.env.TMUX) { spawnSync(TMUX, ["switch-client", "-t", S], { stdio: "inherit" }); return; }
    spawnSync(TMUX, ["attach", "-t", S], { stdio: "inherit" });
    return;
  }
  // No multiplexer: print the (bare) commands so the user can run them by hand.
  process.stderr.write("[restore] no konsole/tmux — run these yourself:\n");
  for (const e of entries) process.stdout.write(`(cd ${e.workdir} && ${bare(e.id)})   # ${e.title}\n`);
}

// ── entry point ──────────────────────────────────────────────────────────────
// ── list: print recent sessions (no launch), newest first ────────────────────
async function doList(devsel, selector, value) {
  const entries = devsel === "local" ? localEntries(selector, value) : await remoteEntries(devsel, selector, value);
  if (!entries.length) { process.stderr.write("[restore] no matching sessions\n"); return; }
  for (const e of entries) process.stdout.write(`${e.id}  ${e.title}\n`);
}

const [, , cmd, ...rest] = process.argv;
if (cmd === "sync") {
  const device = rest[0] || DEVICE;
  const keep = Number(rest[1]) > 0 ? Number(rest[1]) : 20;
  await doSync(device, keep);
} else if (cmd === "launch") {
  const [face = "remote", devsel = "local", selector = "count", rawValue = "0"] = rest;
  const value = Number(rawValue);
  if (!Number.isFinite(value) || value <= 0) { process.stderr.write(`[restore] bad value: ${rawValue}\n`); process.exit(2); }
  const entries = devsel === "local" ? localEntries(selector, value) : await remoteEntries(devsel, selector, value);
  launch(entries, face);
} else if (cmd === "list") {
  const [devsel = "local", selector = "count", rawValue = "0"] = rest;
  const value = Number(rawValue);
  if (!Number.isFinite(value) || value <= 0) { process.stderr.write(`[restore] bad value: ${rawValue}\n`); process.exit(2); }
  await doList(devsel, selector, value);
} else {
  process.stderr.write("usage: restore.mjs sync [device] [keep] | launch <face> <local|all|device> <count|hours> <value> | list <local|all|device> <count|hours> <value>\n");
  process.exit(2);
}
