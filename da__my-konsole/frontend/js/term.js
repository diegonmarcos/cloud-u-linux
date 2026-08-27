// term.js — terminals, panes, and splits. Each tab holds a binary split TREE:
// leaves are `.pane` (one xterm.js + one Rust PTY each), internal nodes are
// `.split.row` (left/right) or `.split.col` (top/bottom) flex containers.
// Konsole-style. All keybindings are data-driven (config.json → MYK.config).
const MYK = {
  panes: new Map(),   // paneId -> { term, fit, search, host, tabId }
  activePane: null,
  seq: 0,
  config: {},         // theme/font/terminal/keybindings — set by boot.js

  // ── Create a leaf pane (xterm + PTY) inside `container` (not yet split) ──
  async makePane(tabId, container) {
    const id = "p" + ++this.seq;
    const host = document.createElement("div");
    host.className = "pane";
    host.dataset.id = id;
    host.tabIndex = -1;
    container.appendChild(host);

    const c = this.config || {}, font = c.font || {}, t = c.terminal || {};
    const term = new Terminal({
      fontFamily: font.family || "monospace",
      fontSize: font.size || 11,
      scrollback: t.scrollback ?? 5000,
      cursorBlink: t.cursorBlink ?? true,
      theme: c.theme || {},
      allowProposedApi: true,
    });
    const fit = new FitAddon.FitAddon();
    const search = new SearchAddon.SearchAddon();
    term.loadAddon(fit); term.loadAddon(search);
    term.open(host);
    this._bindKeys(term, id);
    host.addEventListener("mousedown", () => this.focusPane(id));
    host.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      this.focusPane(id);
      this.showPaneMenu(e.clientX, e.clientY);
    });

    term.onData((d) => Transport.ptyWrite(id, d));
    term.onResize(({ cols, rows }) => Transport.ptyResize(id, cols, rows));
    term.onTitleChange((title) => Tabs.setTitle(tabId, title));
    const unlisten = await Transport.onPty(id, (data) => term.write(data));
    await Transport.onPtyExit(id, () => this.closeView(id));

    this.panes.set(id, { term, fit, search, host, tabId, unlisten });
    fit.fit();
    await Transport.ptyStart(id, term.cols, term.rows, null);
    return id;
  },

  focusPane(id) {
    const p = this.panes.get(id);
    if (!p) return;
    this.activePane = id;
    for (const [pid, pane] of this.panes) pane.host.classList.toggle("focused", pid === id);
    p.fit.fit(); p.term.focus();
  },

  // ── Split the active pane. dir: "row" = left/right, "col" = top/bottom.
  // before: new pane goes before the current one (left/up) instead of after (right/down).
  async split(dir, before = false) {
    const p = this.panes.get(this.activePane);
    if (!p) return;
    const host = p.host, parent = host.parentNode;
    const wrap = document.createElement("div");
    wrap.className = "split " + dir;
    parent.replaceChild(wrap, host);
    wrap.appendChild(host);
    const nid = await this.makePane(p.tabId, wrap);
    if (before) wrap.insertBefore(this.panes.get(nid).host, host);
    this._fitTab(p.tabId);
    this.focusPane(nid);
  },

  // Open the pane's working directory in the system file manager. No cwd is
  // tracked per-pane (ptyStart's cwd is always null — see makePane) so this
  // always opens $HOME; that's the only "current directory" this app actually
  // knows, and pretending otherwise would be a fabricated feature.
  openFileManager() {
    const home = "$HOME"; // shell-expanded by the target, not resolved here
    if (window.__TAURI__?.shell?.open) window.__TAURI__.shell.open(home).catch(() => {});
    else console.warn("[pane-menu] Open File Manager: no Tauri shell plugin in this environment");
  },

  renameTab(tabId) {
    const t = Tabs.tabs.get(tabId);
    if (!t) return;
    const name = prompt("Tab name:", t.tabEl.querySelector(".tab-title")?.textContent || "");
    if (name !== null && name.trim()) Tabs.setTitle(tabId, name.trim());
  },

  // ── Right-click pane menu: Konsole's terminal context menu, minus the
  // entries this app can't actually do (Adjust Scrollback…, Detach Current
  // Tab — see term.js history / task notes for why those are omitted).
  showPaneMenu(x, y) {
    document.getElementById("pane-menu")?.remove();
    const p = this.panes.get(this.activePane);
    if (!p) return;
    const { term, tabId } = p;
    const id = this.activePane;

    const items = [
      { label: "Copy", disabled: !term.hasSelection(), action: () => navigator.clipboard.writeText(term.getSelection()) },
      { label: "Paste", action: () => navigator.clipboard.readText().then((t) => Transport.ptyWrite(id, t)) },
      { sep: true },
      { label: "Select All", action: () => term.selectAll() },
      { sep: true },
      { label: "Open File Manager", action: () => this.openFileManager() },
      { sep: true },
      { label: "Rename Tab…", action: () => this.renameTab(tabId) },
      { sep: true },
      { label: "Clear Scrollback", action: () => term.clear() },
      { label: "Clear Scrollback and Reset", action: () => term.reset() },
      { sep: true },
      { label: "Split View", sub: [
        { label: "Split View Left/Right", action: () => this.split("row") },
        { label: "Split View Top/Bottom", action: () => this.split("col") },
      ] },
      { sep: true },
      { label: "Show Menu Bar", check: true, checked: window.Layout?.get("topnav"), action: () => window.Layout?.toggle("topnav") },
      { label: "Close Tab", action: () => Tabs.close(tabId) },
    ];

    const menu = document.createElement("div");
    menu.id = "pane-menu";
    this._renderMenuItems(menu, items);
    document.body.appendChild(menu);
    const r = menu.getBoundingClientRect();
    menu.style.left = Math.min(x, window.innerWidth - r.width - 4) + "px";
    menu.style.top = Math.min(y, window.innerHeight - r.height - 4) + "px";
    const closeOnce = (e) => { if (!menu.contains(e.target)) menu.remove(); };
    setTimeout(() => document.addEventListener("mousedown", closeOnce, { once: true }), 0);
  },

  // Shared renderer for the pane menu's flat items / separators / one-level
  // submenu (Split View) / checkbox row (Show Menu Bar) — same DOM shape as
  // the ☰ dropdown (#menu-dropdown in index.html) so the CSS in style.css
  // applies unchanged instead of growing a second menu skin.
  _renderMenuItems(host, items) {
    for (const it of items) {
      if (it.sep) {
        const s = document.createElement("div");
        s.className = "menu-sep";
        host.appendChild(s);
        continue;
      }
      const row = document.createElement("div");
      row.className = "menu-item" + (it.sub ? " has-sub" : "") + (it.check ? " check" : "") + (it.checked ? " checked" : "") + (it.disabled ? " disabled" : "");
      row.append(document.createTextNode(it.label));
      if (it.sub) {
        const sub = document.createElement("div");
        sub.className = "submenu";
        this._renderMenuItems(sub, it.sub);
        row.appendChild(sub);
      } else {
        row.addEventListener("click", (e) => {
          e.stopPropagation();
          document.getElementById("pane-menu")?.remove();
          it.action?.();
        });
      }
      host.appendChild(row);
    }
  },

  // ── Close the active view (pane). Unwraps the split; closes tab if last. ──
  closeView(id) {
    id = id || this.activePane;
    const p = this.panes.get(id);
    if (!p) return;
    const tabId = p.tabId;
    this._disposePane(id);
    const host = p.host, wrap = host.parentNode;
    if (wrap && wrap.classList.contains("split")) {
      const sibling = [...wrap.children].find((c) => c !== host);
      wrap.parentNode.replaceChild(sibling, wrap);
      const firstPane = sibling.classList.contains("pane") ? sibling : sibling.querySelector(".pane");
      this._fitTab(tabId);
      if (firstPane) this.focusPane(firstPane.dataset.id);
    } else {
      Tabs.close(tabId); // was the tab's only pane
    }
  },

  _disposePane(id) {
    const p = this.panes.get(id);
    if (!p) return;
    Transport.ptyKill(id);
    if (p.unlisten) p.unlisten();
    p.term.dispose();
    p.host.remove();
    this.panes.delete(id);
  },

  paneIdsOf(tabId) {
    return [...this.panes.entries()].filter(([, p]) => p.tabId === tabId).map(([id]) => id);
  },
  disposeTab(tabId) { for (const id of this.paneIdsOf(tabId)) this._disposePane(id); },
  _fitTab(tabId) { for (const id of this.paneIdsOf(tabId)) this.panes.get(id)?.fit.fit(); },
  fitActive() { const p = this.panes.get(this.activePane); if (p) p.fit.fit(); },

  focusSibling(delta) {
    const p = this.panes.get(this.activePane); if (!p) return;
    const ids = this.paneIdsOf(p.tabId);
    const i = ids.indexOf(this.activePane);
    if (i < 0) return;
    this.focusPane(ids[(i + delta + ids.length) % ids.length]);
  },

  // ── Data-driven keybinding dispatch ──────────────────────────────────────
  _action(name, term, id) {
    switch (name) {
      case "new-tab":          Tabs.newTab(); return false;
      case "close-tab":        Tabs.close(this.panes.get(this.activePane)?.tabId); return false;
      case "next-tab":         Tabs.next(); return false;
      case "prev-tab":         Tabs.prev(); return false;
      case "move-tab-left":    Tabs.move(-1); return false;
      case "move-tab-right":   Tabs.move(+1); return false;
      case "copy": {
        const sel = term.getSelection();
        if (sel) { navigator.clipboard.writeText(sel); return false; }
        return true; // no selection → let it fall through
      }
      case "paste":            navigator.clipboard.readText().then((t) => Transport.ptyWrite(id, t)); return false;
      case "find":             Find.open(); return false;
      case "split-left-right": this.split("row"); return false;
      case "split-top-bottom": this.split("col"); return false;
      case "close-view":       this.closeView(this.activePane); return false;
      case "focus-next-view":  this.focusSibling(+1); return false;
      case "focus-prev-view":  this.focusSibling(-1); return false;
      case "clear-scrollback": term.clear(); return false;
      default: return true;
    }
  },

  _bindKeys(term, id) {
    term.attachCustomKeyEventHandler((e) => {
      if (e.type !== "keydown") return true;
      for (const b of (this.config.keybindings || [])) {
        if (!!e.ctrlKey === !!b.ctrl && !!e.shiftKey === !!b.shift &&
            !!e.altKey === !!b.alt && e.code === b.key) {
          return this._action(b.action, term, id) === true;
        }
      }
      return true;
    });
  },
};

// Find bar (find action)
const Find = {
  open() { const b = document.getElementById("findbar"); b.hidden = false; document.getElementById("find-input").focus(); },
  close() { document.getElementById("findbar").hidden = true; MYK.panes.get(MYK.activePane)?.term.focus(); },
  _s() { return MYK.panes.get(MYK.activePane)?.search; },
  next() { const q = document.getElementById("find-input").value; if (q) this._s()?.findNext(q); },
  prev() { const q = document.getElementById("find-input").value; if (q) this._s()?.findPrevious(q); },
};
