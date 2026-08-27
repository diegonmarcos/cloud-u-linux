// devlog.js — in-app console capture for remote debugging. Wraps console.* and
// window error hooks into a ring buffer, exports it (+ a state snapshot) to a
// fixed file the maintainer can read back. No deps. MUST load FIRST so it
// catches logs from every other module.
const DevLog = (function () {
  const MAX = 2000;
  const buf = [];

  function push(level, args) {
    let msg;
    try {
      msg = args.map((a) => (typeof a === "string" ? a : a instanceof Error ? (a.stack || a.message) : JSON.stringify(a))).join(" ");
    } catch { msg = args.map(String).join(" "); }
    buf.push(`${new Date().toISOString()} [${level}] ${msg}`);
    if (buf.length > MAX) buf.shift();
  }

  for (const level of ["log", "info", "warn", "error", "debug"]) {
    const orig = console[level] ? console[level].bind(console) : function () {};
    console[level] = function (...a) { push(level, a); orig(...a); };
  }
  window.addEventListener("error", (e) =>
    push("error", [`window.onerror: ${e.message} @ ${e.filename}:${e.lineno}:${e.colno}`, e.error && e.error.stack]));
  window.addEventListener("unhandledrejection", (e) =>
    push("error", ["unhandledrejection:", (e.reason && (e.reason.stack || e.reason.message)) || String(e.reason)]));

  // Live app state — profiles/tabs/panes — for diagnosing grouping + wiring bugs.
  function snapshot() {
    const t = (typeof Tabs !== "undefined") ? Tabs : {};
    const tabs = t.tabs ? [...t.tabs.values()].map((x) => ({
      profile: x.profile,
      kind: x.isBrowser ? "browser" : x.isFileBrowser ? "filebrowser" : x.isFileEditor ? "fileeditor" : "shell",
    })) : [];
    return {
      when: new Date().toISOString(),
      config_app: (typeof MYK !== "undefined" && MYK.config && MYK.config.app) || null,
      activeProfile: t.activeProfile || null,
      activePane: (typeof MYK !== "undefined") ? MYK.activePane : null,
      tabCount: tabs.length,
      tabs,
      logCount: buf.length,
    };
  }

  const PATH = "~/.local/share/my-konsole/logs/debug.log";
  async function exportLog() {
    const body =
      "=== SNAPSHOT ===\n" + JSON.stringify(snapshot(), null, 2) +
      "\n\n=== CONSOLE (" + buf.length + " lines) ===\n" + buf.join("\n") + "\n";
    try { await Transport.writeFile(PATH, body); return PATH; }
    catch (e) { console.error("DevLog export failed", e); return null; }
  }

  const api = { buffer: buf, snapshot, export: exportLog, clear: () => (buf.length = 0), PATH };
  console.log("[devlog] console capture active (log/info/warn/error/debug + window errors)");
  return api;
})();
window.DevLog = DevLog;
