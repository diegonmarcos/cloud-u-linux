// boot.js — wire the shell: profiles top-nav, command sections, search, find.
(async function () {
  let profiles = [];
  let current = null;

  // Load runtime UI config (theme/font/terminal/keybindings) BEFORE any pane.
  // ponytail: Phase 2b — on Tauri, invoke the Rust commands directly; on the
  // WebView/browser path (no __TAURI__) load the static JSON the build emits
  // instead (frozen paths/format: data/config.json, data/profiles.json).
  try {
    MYK.config = window.__TAURI__
      ? await window.__TAURI__.core.invoke("get_config")
      : await fetch("data/config.json").then((r) => (r.ok ? r.json() : {})).catch(() => ({}));
  } catch (e) { console.error("get_config failed", e); MYK.config = {}; }

  try {
    const res = window.__TAURI__
      ? await window.__TAURI__.core.invoke("get_profiles")
      : await fetch("data/profiles.json").then((r) => (r.ok ? r.json() : { profiles: [] })).catch(() => ({ profiles: [] }));
    profiles = res.profiles || [];
  } catch (e) { console.error("get_profiles failed", e); }
  if (profiles.length === 0) profiles = [{ name: "default", display_name: "Shell", sections: [] }];
  console.log("[boot] tauri=" + !!window.__TAURI__ + " config.keys=" + Object.keys(MYK.config || {}).join(","));
  console.log("[boot] profiles(" + profiles.length + "): " + profiles.map((p) => p.name + (p.home ? "*" : "")).join(", "));
  console.log("[boot] home profiles: " + profiles.filter((p) => p.home).map((p) => p.name).join(", "));
  Palette.profiles = profiles;
  Palette.runItem = runItem;

  // Top-nav pills — Row 1 (the CLI tools, each with its own bookmark sections).
  // Profiles flagged `home` are the GUI-demanding tools and live in Row 0.
  //
  // Ordering is data-driven: `order` in each profile.json, not the directory
  // name. Directory prefixes (00-, 01-, ...) are how the files sort on disk,
  // which is not the same question as how the nav should read — Home belongs
  // first in the nav regardless of where its folder sorts. Profiles with no
  // `order` fall to the end, in their existing order, so adding one is not a
  // silent reshuffle.
  //
  // `menu: "<label>"` files a profile into a named dropdown folder ("Cloud",
  // "Unix-Dev", "Others", …); no `menu` leaves it a standalone pill. The strip
  // is a single 32px row: past ~10 pills it overflows into a horizontal scroll
  // nobody discovers, so related profiles live one click behind a folder
  // rather than making every profile harder to reach. Legacy `secondary: true`
  // still reads as the "Others" folder. A folder sits where its first member
  // sits, so `order` alone drives the whole row.
  const nav = document.getElementById("profiles");
  const byOrder = (list) =>
    list.map((p, idx) => ({ p, idx }))
        .sort((a, b) => (a.p.order ?? 999) - (b.p.order ?? 999) || a.idx - b.idx)
        .map((x) => x.p);
  const cli = profiles.filter((p) => !p.home);
  const menuOf = (p) => p.menu || (p.secondary ? "Others" : null);
  const entries = [];               // in render order: {p} pills and {label, items} folders
  const folders = new Map();
  for (const p of byOrder(cli)) {
    const label = menuOf(p);
    if (!label) { entries.push({ p, group: p.group }); continue; }
    let f = folders.get(label);
    if (!f) { f = { label, items: [], group: p.group }; folders.set(label, f); entries.push(f); }
    f.items.push(p);
  }
  // Full names for abbreviated pills — shown as a tooltip so the shortened
  // label ("SSH Man", "Mesh&Net") doesn't lose its meaning at a glance.
  const FULL_NAME = {
    "ssh-manager": "SSH Manager",
    "mesh-network": "Mesh & Network",
    "cloud-infra": "Cloud & Infra",
    docker: "Docker",
  };
  const mkPill = (p, active) => {
    const pill = document.createElement("div");
    pill.className = "profile-pill" + (active ? " active" : "");
    pill.textContent = p.display_name || p.name;
    pill.tabIndex = 0;
    const full = FULL_NAME[p.name];
    if (full && full !== (p.display_name || p.name)) pill.title = full;
    pill.addEventListener("click", () => selectProfile(p, pill));
    pill.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); selectProfile(p, pill); } });
    return pill;
  };
  // A "|" between a standalone pill and the folders, so the strip reads as
  // clusters rather than one long run. Folders separate themselves visually,
  // so this only fires around the pills.
  const mkSep = () => {
    const sep = document.createElement("span");
    sep.className = "nav-pill-sep";
    sep.textContent = "|";
    sep.setAttribute("aria-hidden", "true");
    return sep;
  };
  const mkFolder = (label, items) => {
    const wrap = document.createElement("div");
    wrap.className = "home-dropdown";
    const pill = document.createElement("div");
    pill.className = "profile-pill";
    pill.tabIndex = 0;
    pill.textContent = label + " ▾";
    const menu = document.createElement("div");
    menu.className = "home-menu others-menu";
    menu.hidden = true;
    wrap.append(pill, menu);
    for (const p of items) {
      const it = document.createElement("div");
      it.className = "menu-item";
      it.textContent = p.display_name || p.name;
      // A leading color dot per entry (its profile.theme.accent) — with no
      // pill/icon in this dropdown, it's the only way to tell these apart
      // at a glance, same as a browser bookmarks menu's favicons.
      it.style.setProperty("--dot", (p.theme && p.theme.accent) || "var(--muted)");
      it.addEventListener("click", () => selectProfile(p, pill));
      menu.appendChild(it);
    }
    const closeMenu = () => { menu.hidden = true; };
    const openMenu = () => {
      menu.hidden = false;
      const r = pill.getBoundingClientRect();
      menu.style.top = `${r.bottom + 2}px`;
      menu.style.left = `${Math.min(r.left, window.innerWidth - 220)}px`;
    };
    pill.addEventListener("click", (e) => {
      e.stopPropagation();
      if (menu.hidden) openMenu(); else closeMenu();
    });
    pill.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); pill.click(); } });
    // Capture-phase pointerdown, not a bubbling click: xterm.js and the native
    // child webviews swallow clicks before they ever reach document, so a
    // bubbling listener leaves the dropdown stuck open.
    document.addEventListener("pointerdown", (e) => { if (!wrap.contains(e.target)) closeMenu(); }, true);
    document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeMenu(); });
    return wrap;
  };
  entries.forEach((e, i) => {
    // A "|" wherever profile.group changes — the clusters are data, not a
    // hardcoded boundary: my-AI | Cloud Data | Unix-Infra/Envs/Dev | Others.
    // Never leading.
    if (i && e.group !== entries[i - 1].group) nav.appendChild(mkSep());
    nav.appendChild(e.label ? mkFolder(e.label, e.items) : mkPill(e.p, i === 0));
  });

  const byName = (n) => profiles.find((p) => p.name === n);

  // Every profile switch — pill OR Row-1 home button — goes through here, so the
  // sidebar command sections ALWAYS match the active profile (no stale bleed) and
  // tabs stay grouped per profile. `pill` is null for home buttons; `opener`
  // forces a specific new tab (e.g. Vim) instead of the group's default.
  function selectProfile(p, pill, opener) {
    if (!p) { console.error("[selectProfile] null profile — byName miss? (button wired to a profile that isn't loaded)"); return; }
    console.log(`[selectProfile] ${p.name} pill=${!!pill} opener=${!!opener} sections=${(p.sections || []).length}`);
    current = p;
    for (const el of document.querySelectorAll(".profile-pill")) el.classList.remove("active");
    if (pill) pill.classList.add("active");
    buildSections(p);
    // Only bother rebuilding if the Data view is actually visible — same deal
    // as Tabs.renderTabList(), no reason to do the work for a hidden panel.
    // (The groups themselves are lazyloaded regardless — this just decides
    // whether to draw the skeleton at all.)
    if (!document.getElementById("data-panel").hidden) buildDataPanel(p);
    Tabs.switchProfile(p, opener);
  }

  // Per-profile command sections
  function buildSections(p) {
    const host = document.getElementById("sections");
    host.innerHTML = "";
    for (const sec of p.sections || []) {
      const t = document.createElement("div");
      t.className = "section-title"; t.textContent = sec.title;
      host.appendChild(t);
      for (const item of sec.items || []) {
        const b = document.createElement("button");
        b.className = "cmd-item";
        b.textContent = item.label;
        b.dataset.search = (item.label + " " + (item.cmd || "")).toLowerCase();
        b.addEventListener("click", () => runItem(item));
        host.appendChild(b);
      }
    }
    filterSearch(document.getElementById("search").value);
  }

  // Run a command item in the active pane. Convention: a cmd ending in a
  // space is PREFILLED (no Enter) so the user can add args; otherwise it runs.
  // An item with `url` (no `cmd`) opens a pinned native browser tab instead —
  // same mechanism as a `browser:true` profile (Tabs.openBrowserTab), just
  // triggered from a section item rather than being the profile's home tab.
  function runItem(item) {
    // signature is (url, profile, label, mode) — the label goes in slot 3;
    // undefined keeps the default, this.activeProfile.
    if (item.url && !item.cmd) { Tabs.openBrowserTab(item.url, undefined, item.label); return; }
    const id = MYK.activePane;
    if (!id || !item.cmd) return;
    const run = !/\s$/.test(item.cmd);
    Transport.ptyWrite(id, run ? item.cmd + "\n" : item.cmd);
    MYK.panes.get(id)?.term.focus();
  }

  // Live search filter over command items
  function filterSearch(q) {
    q = (q || "").toLowerCase();
    for (const b of document.querySelectorAll(".cmd-item"))
      b.classList.toggle("hidden", q && !b.dataset.search.includes(q));
    for (const t of document.querySelectorAll(".section-title")) t.style.display = "";
  }
  document.getElementById("search").addEventListener("input", (e) => filterSearch(e.target.value));

  // ── Data panel: glob-expand the active profile's `configs[]` (the
  // CLI/framework it wraps) into real files. Lazyloaded — a group's `paths`
  // aren't resolved until the user expands it, so opening the panel costs
  // nothing; the Rust-side fs_glob cache (60s TTL) makes re-expanding, or
  // switching back to a profile, near-instant without a JS-side cache here.
  // Two "nothing here" cases are deliberately worded differently — no
  // `configs` key means the profile never claimed a config surface; an empty
  // glob result means it did, but the patterns found nothing (a real problem,
  // e.g. a repo that moved).
  const homeRelative = (p) => {
    const m = /^\/home\/[^/]+/.exec(p);
    return m ? "~" + p.slice(m[0].length) : p;
  };
  const shQuote = (s) => "'" + s.replace(/'/g, "'\\''") + "'";
  const DATA_CAP = 500; // must match GLOB_MAX_RESULTS in src-tauri/src/main.rs

  function openConfig(path, profile) {
    if ((localStorage.getItem("myk-editor") || "vim") === "plain") {
      Tabs.openFileEditorTab(path, profile);
      return;
    }
    Tabs.openRunTab(`vim ${shQuote(path)}`, path.split("/").filter(Boolean).pop() || path, profile);
  }

  // First grouping level: file type, derived from the extension rather than
  // hand-declared per profile (a profile's paths mix ad-hoc file kinds and
  // nobody wants to maintain a second list in sync with them). `.md` sorts
  // last (documentation, not configuration) and `.lock` second-to-last
  // (generated) — everything else keeps a stable, arbitrary-but-fixed order.
  const TYPE_ORDER = ["nix", "json", "toml", "yaml", "conf", "sh", "other", "lock", "md"];
  const TYPE_LABEL = {
    nix: ".nix", json: ".json", toml: ".toml", yaml: ".yaml/.yml", conf: ".conf/.cfg/.ini",
    sh: ".sh", other: "other", lock: ".lock", md: ".md",
  };
  const EXT_TYPE = {
    nix: "nix", json: "json", toml: "toml", yaml: "yaml", yml: "yaml",
    md: "md", lock: "lock", conf: "conf", cfg: "conf", ini: "conf", sh: "sh",
  };
  const fileType = (f) => {
    const m = /\.([^./]+)$/.exec(f);
    return (m && EXT_TYPE[m[1].toLowerCase()]) || "other";
  };

  // The group's "walk root" for the second grouping level (directory), derived
  // from the resolved files themselves rather than re-parsing the glob
  // patterns — the longest directory prefix every file in the group shares.
  // Groups with no shared directory (e.g. exact dotfiles scattered across
  // ~/.config) fall back to null, and each file's directory is shown
  // ~/-relative instead.
  function commonDir(paths) {
    if (!paths.length) return null;
    let common = paths[0].split("/").slice(0, -1);
    for (const p of paths.slice(1)) {
      const dir = p.split("/").slice(0, -1);
      let i = 0;
      while (i < common.length && i < dir.length && common[i] === dir[i]) i++;
      common = common.slice(0, i);
    }
    return common.length > 1 ? common.join("/") : null; // require more than a bare "/"
  }
  const dirBucket = (f, root) => {
    const dir = f.split("/").slice(0, -1).join("/");
    if (!root) return homeRelative(dir);
    if (dir === root) return homeRelative(root); // files sitting directly in the root — never an empty label
    if (dir.startsWith(root + "/")) return dir.slice(root.length + 1); // relative to the walk root
    return homeRelative(dir); // shouldn't happen — every file here came from the same commonDir()
  };

  function leafButton(f, profileName) {
    const b = document.createElement("button");
    b.className = "cmd-item data-leaf";
    b.textContent = f.split("/").filter(Boolean).pop() || f;
    b.title = f;
    b.dataset.search = homeRelative(f).toLowerCase();
    b.addEventListener("click", () => openConfig(f, profileName));
    return b;
  }

  // Renders one group's resolved file list into `body`: type buckets (only
  // non-empty ones, TYPE_ORDER), each split further by containing directory —
  // unless every file in that type bucket lives in the same directory, in
  // which case the directory level is pure noise and gets skipped.
  function renderGroupBody(body, files, profileName) {
    body.innerHTML = "";
    if (!files.length) {
      const m = document.createElement("div");
      m.className = "data-muted"; m.textContent = "No files matched these patterns.";
      body.appendChild(m);
      return;
    }
    const root = commonDir(files);
    const byType = new Map();
    for (const f of files) {
      const t = fileType(f);
      if (!byType.has(t)) byType.set(t, []);
      byType.get(t).push(f);
    }
    for (const type of TYPE_ORDER) {
      const group = byType.get(type);
      if (!group || !group.length) continue;
      const typeHeader = document.createElement("div");
      typeHeader.className = "section-title";
      typeHeader.textContent = `${TYPE_LABEL[type]} (${group.length})`;
      body.appendChild(typeHeader);

      const byDir = new Map();
      for (const f of group) {
        const label = dirBucket(f, root);
        if (!byDir.has(label)) byDir.set(label, []);
        byDir.get(label).push(f);
      }
      if (byDir.size <= 1) {
        for (const f of group) body.appendChild(leafButton(f, profileName));
      } else {
        for (const [label, list] of byDir) {
          const dirHeader = document.createElement("div");
          dirHeader.className = "data-dir-title";
          dirHeader.textContent = `${label} (${list.length})`;
          body.appendChild(dirHeader);
          for (const f of list) body.appendChild(leafButton(f, profileName));
        }
      }
    }
  }

  // Groups expanded per profile, kept for the session so switching profiles
  // away and back doesn't re-collapse everything the user had opened.
  const dataExpanded = new Map(); // profile.name -> Set<group.title>
  let dataGen = 0; // bumped per buildDataPanel() call — guards against a
                    // stale in-flight fs_glob response landing after the
                    // user has already switched to a different profile.

  // Root for the Tree-* buttons: the longest literal (non-glob) directory
  // prefix shared by every profile.configs[].paths pattern — same shape as
  // commonDir() above, but over glob strings rather than resolved files, so
  // a scan doesn't wait on fs_glob just to find out where to start. A glob
  // segment (containing * ? [ or a bare **) ends the literal prefix.
  function configsRoot(p) {
    const patterns = (p.configs || []).flatMap((g) => g.paths || []);
    if (!patterns.length) return null;
    const literalDirs = (pattern) => {
      const segs = pattern.split("/");
      const out = [];
      for (const seg of segs) {
        if (/[*?[]/.test(seg)) break;
        out.push(seg);
      }
      return out.slice(0, -1); // drop the trailing literal filename, keep dirs only
    };
    let common = literalDirs(patterns[0]);
    for (const pat of patterns.slice(1)) {
      const dirs = literalDirs(pat);
      let i = 0;
      while (i < common.length && i < dirs.length && common[i] === dirs[i]) i++;
      common = common.slice(0, i);
    }
    return common.length ? common.join("/") : null;
  }

  function renderTreeButtons(p) {
    const host = document.getElementById("data-tree-btns");
    host.innerHTML = "";
    const root = configsRoot(p);
    const rootPath = root || "$HOME";
    for (const kind of Object.keys(TreeCmd.KINDS)) {
      const b = document.createElement("button");
      b.className = "home-btn";
      b.textContent = kind;
      const title = root ? kind : `${kind} (whole home — profile declares no configs)`;
      b.title = root ? rootPath : "no configs[] on this profile — falling back to $HOME";
      b.addEventListener("click", () => {
        Tabs.openRunTab(TreeCmd.command(kind, rootPath), title, p.name);
      });
      host.appendChild(b);
    }
  }

  function buildDataPanel(p) {
    dataGen++;
    const gen = dataGen;
    renderTreeButtons(p);
    const host = document.getElementById("data-list");
    host.innerHTML = "";
    if (!p.configs || !p.configs.length) {
      host.innerHTML = `<div class="data-muted">This profile declares no config files.</div>`;
      return;
    }
    const expanded = dataExpanded.get(p.name) || new Set();
    dataExpanded.set(p.name, expanded);

    for (const group of p.configs) {
      const header = document.createElement("button");
      header.className = "section-title data-group-title";
      const caret = document.createElement("span");
      caret.className = "data-caret"; caret.textContent = "▸";
      const label = document.createElement("span");
      label.textContent = group.title;
      const count = document.createElement("span");
      count.className = "data-count";
      header.append(caret, label, count);

      const body = document.createElement("div");
      body.hidden = true;

      let loaded = false;
      const setOpen = (open) => {
        body.hidden = !open;
        caret.textContent = open ? "▾" : "▸";
        if (open) expanded.add(group.title); else expanded.delete(group.title);
      };
      const load = async () => {
        if (loaded) return;
        loaded = true;
        body.innerHTML = `<div class="data-scanning">scanning…</div>`;
        const files = await Transport.fsGlob(group.paths || []);
        if (gen !== dataGen) return; // a newer profile's panel is on screen now — drop it
        renderGroupBody(body, files, p.name);
        count.textContent = files.length >= DATA_CAP ? ` (${files.length}, capped)` : ` (${files.length})`;
      };
      header.addEventListener("click", () => {
        const open = body.hidden;
        setOpen(open);
        if (open) load();
      });

      host.appendChild(header);
      host.appendChild(body);
      if (expanded.has(group.title)) { setOpen(true); load(); }
    }
    filterData(document.getElementById("data-search").value);
  }

  function filterData(q) {
    q = (q || "").toLowerCase();
    for (const b of document.querySelectorAll("#data-list .cmd-item"))
      b.classList.toggle("hidden", q && !b.dataset.search.includes(q));
  }
  document.getElementById("data-search").addEventListener("input", (e) => filterData(e.target.value));

  // Buttons + find bar
  document.getElementById("btn-newtab").addEventListener("click", () => Tabs.newTab());
  document.getElementById("find-next").addEventListener("click", () => Find.next());
  document.getElementById("find-prev").addEventListener("click", () => Find.prev());
  document.getElementById("find-close").addEventListener("click", () => Find.close());
  document.getElementById("find-input").addEventListener("keydown", (e) => {
    if (e.key === "Enter") Find.next();
    if (e.key === "Escape") Find.close();
  });
  // _fitTab only re-fits xterm panes — it has no idea a browser tab exists.
  // Without an explicit sync here, an active browser tab keeps its
  // pre-resize bounds until the 250ms poll catches up, painting outside its
  // (now different-sized) host for that gap.
  window.addEventListener("resize", () => { if (Tabs.active) MYK._fitTab(Tabs.active); NativeEmbed.sync(true); });
  window.addEventListener("beforeunload", () => Tabs.saveSession());

  // Global ☰ menu. Submenus stay CSS-driven (:hover) for visibility; JS only
  // adds positioning so a submenu near the right/bottom of the window doesn't
  // open off-screen and become unreachable (Konsole flips left / shifts up).
  const menuBtn = document.getElementById("btn-menu");
  const menuDrop = document.getElementById("menu-dropdown");
  menuBtn.addEventListener("click", (e) => { e.stopPropagation(); menuDrop.hidden = !menuDrop.hidden; });
  document.addEventListener("click", () => {
    menuDrop.hidden = true;
    resetSubmenus(); // the root closing must not leave a flipped submenu visibly stuck open
  });

  function resetSubmenus() {
    for (const sub of menuDrop.querySelectorAll(".submenu")) {
      sub.classList.remove("open");
      sub.style.left = ""; sub.style.right = ""; sub.style.top = ""; sub.style.bottom = "";
    }
  }
  for (const row of menuDrop.querySelectorAll(".menu-item.has-sub")) {
    const sub = row.querySelector(".submenu");
    if (!sub) continue;
    row.addEventListener("mouseenter", () => {
      // Reset first so the measurement below reflects the row's own default
      // (right-of-parent) position, not a flip left over from a previous open.
      sub.style.left = ""; sub.style.right = ""; sub.style.top = ""; sub.style.bottom = "";
      sub.classList.add("open"); // force visible so getBoundingClientRect is real, not display:none's 0×0
      const subRect = sub.getBoundingClientRect();
      const rowRect = row.getBoundingClientRect();
      if (subRect.right > window.innerWidth) {
        sub.style.left = "auto";
        sub.style.right = "100%";
      }
      if (subRect.bottom > window.innerHeight) {
        const overflow = subRect.bottom - window.innerHeight;
        sub.style.top = `${-7 - overflow}px`;
      }
    });
    row.addEventListener("mouseleave", () => {
      sub.classList.remove("open");
      sub.style.left = ""; sub.style.right = ""; sub.style.top = ""; sub.style.bottom = "";
    });
  }

  // ── Layout tickers (Konsole's View menu): show/hide the top nav and the left
  // sidebar. Persisted, because a hidden chrome that comes back on every launch
  // is not "hidden", it's a flicker.
  //
  // Hiding the top nav also hides the ☰ that unhides it — Ctrl+Shift+M is the
  // way back, same as Konsole's Ctrl+M. Without it the setting is a one-way
  // door that survives restarts.
  const layout = { topnav: true, sidebar: true };
  try { Object.assign(layout, JSON.parse(localStorage.getItem("myk-layout") || "{}")); } catch {}
  const applyLayout = () => {
    document.getElementById("topnav").classList.toggle("hidden", !layout.topnav);
    document.getElementById("sidebar").classList.toggle("hidden", !layout.sidebar);
    document.getElementById("cfg-topnav").classList.toggle("checked", layout.topnav);
    document.getElementById("cfg-sidebar").classList.toggle("checked", layout.sidebar);
    const sb = document.getElementById("btn-sidebar");
    sb.textContent = layout.sidebar ? "«" : "»";
    sb.title = (layout.sidebar ? "Hide" : "Show") + " Left Side Bar";
    const tn = document.getElementById("btn-topnav");
    tn.textContent = layout.topnav ? "▴" : "▾";
    tn.title = (layout.topnav ? "Hide" : "Show") + " Top Nav Bar";
    localStorage.setItem("myk-layout", JSON.stringify(layout));
    if (Tabs.active) MYK._fitTab(Tabs.active);   // the terminal must re-fit, not clip
    NativeEmbed.sync(true);   // a browser tab's host just moved/resized too
  };
  // `layout` itself is trapped in this IIFE's closure — the pane context menu's
  // "Show Menu Bar" checkbox (term.js) lives outside it and needs to read/flip
  // the SAME state as the ☰ → Layout → Top Nav Bar ticker below, never a copy
  // that can drift out of sync. This accessor is the one door in.
  window.Layout = {
    get: (key) => layout[key],
    toggle: (key) => { layout[key] = !layout[key]; applyLayout(); },
  };
  const ticker = (id, key) =>
    document.getElementById(id).addEventListener("click", (e) => {
      e.stopPropagation();                       // keep the menu open: both are often toggled together
      layout[key] = !layout[key];
      applyLayout();
    });
  ticker("cfg-topnav", "topnav");
  ticker("cfg-sidebar", "sidebar");
  document.getElementById("btn-sidebar").addEventListener("click", () => Layout.toggle("sidebar"));
  document.getElementById("btn-topnav").addEventListener("click", () => Layout.toggle("topnav"));
  window.addEventListener("keydown", (e) => {
    if (e.ctrlKey && e.shiftKey && (e.key === "M" || e.key === "m")) {
      e.preventDefault();
      layout.topnav = !layout.topnav;
      applyLayout();
    }
  });
  applyLayout();

  // ── Editor setting (☰ → Editor): which app opens a file clicked in the
  // Data panel — Vim (real vim in a PTY, default) or Plain (in-app
  // textarea). Unlike the Layout tickers these are mutually exclusive:
  // picking one clears the other. Same "don't close the menu" behavior.
  const applyEditorPref = () => {
    const editor = localStorage.getItem("myk-editor") || "vim";
    document.getElementById("cfg-editor-vim").classList.toggle("checked", editor === "vim");
    document.getElementById("cfg-editor-plain").classList.toggle("checked", editor === "plain");
  };
  const editorTicker = (id, val) =>
    document.getElementById(id).addEventListener("click", (e) => {
      e.stopPropagation();
      localStorage.setItem("myk-editor", val);
      applyEditorPref();
    });
  editorTicker("cfg-editor-vim", "vim");
  editorTicker("cfg-editor-plain", "plain");
  applyEditorPref();

  // ── Browser setting (☰ → Browser): how a browser tab renders a page — GUI
  // (webview: iframe for local UIs, native embed/popout for external sites,
  // default) or Terminal (browsh in a PTY). Same mutually-exclusive shape as
  // the Editor pref above; read by Tabs.openBrowserTab.
  const applyBrowserPref = () => {
    const mode = localStorage.getItem("myk-browser") || "tui";
    document.getElementById("cfg-browser-gui").classList.toggle("checked", mode === "gui");
    document.getElementById("cfg-browser-tui").classList.toggle("checked", mode === "tui");
  };
  const browserTicker = (id, val) =>
    document.getElementById(id).addEventListener("click", (e) => {
      e.stopPropagation();
      localStorage.setItem("myk-browser", val);
      applyBrowserPref();
    });
  browserTicker("cfg-browser-gui", "gui");
  browserTicker("cfg-browser-tui", "tui");
  applyBrowserPref();

  document.getElementById("menu-restore-session").addEventListener("click", () => Tabs.restoreSession());

  // Updater — all params from the engine-derived MYK.config.app (single source:
  // build.json). Commands run in a visible PTY tab so the user sees progress.
  // ponytail: no bespoke updater UI — a terminal tab IS the progress view.
  const app = (MYK.config && MYK.config.app) || {};
  document.getElementById("menu-update").addEventListener("click", () => {
    if (!app.repo) return;
    const s = app.store, b = app.bin, d = app.dash;
    Tabs.openRunTab(
      `gh release download ${app.release_tag} --repo ${app.repo} --pattern ${b} --pattern ${d} --dir ${s} --clobber ` +
      `&& chmod +x ${s}/${b} ${s}/${d} 2>/dev/null; echo '✓ Fetched — restart my-konsole to load the new binary'`,
      "update");
  });
  document.getElementById("menu-clone-build").addEventListener("click", () => {
    if (!app.repo_url) return;
    Tabs.openRunTab(
      `git clone ${app.repo_url} ${app.clone_dir} 2>/dev/null || git -C ${app.clone_dir} pull; ` +
      `cd ${app.clone_dir}/${app.subdir} && ./build.sh build && ./build.sh install ` +
      `&& echo '✓ Built + installed locally (heavy — CI is the normal path)'`,
      "clone+build");
  });

  async function showAbout() {
    let appVersion = "unknown", tauriVersion = "unknown";
    if (window.__TAURI__) {
      try { appVersion = await window.__TAURI__.app.getVersion(); } catch {}
      try { tauriVersion = await window.__TAURI__.app.getTauriVersion(); } catch {}
    }
    document.getElementById("about-body").textContent =
      `Version: ${appVersion}\nTauri: ${tauriVersion}\nProfiles loaded: ${profiles.length}\nTabs open: ${Tabs.tabs.size}`;
    // Repo / location block — from the derived app metadata.
    const url = document.getElementById("about-repo-url");
    url.textContent = app.repo_url || "—"; url.href = app.repo_url || "#";
    document.getElementById("about-repo-path").textContent = app.clone_dir ? `${app.clone_dir}/${app.subdir}` : "—";
    document.getElementById("about-bin-path").textContent = (app.store && app.bin) ? `${app.store}/${app.bin}` : "—";
    document.getElementById("about").hidden = false;
  }
  document.getElementById("about-clone").addEventListener("click", () => {
    if (!app.repo_url) return;
    document.getElementById("about").hidden = true;
    Tabs.openRunTab(
      `git clone ${app.repo_url} ${app.clone_dir} 2>/dev/null || git -C ${app.clone_dir} pull; ` +
      `echo '✓ Repo at ${app.clone_dir}'`,
      "clone");
  });
  // ── Dependency solver ────────────────────────────────────────────────────
  // The hub's dependency list is DERIVED, never hand-written: every bookmark in
  // every profile is a shell command, and the first word of that command is the
  // binary it needs. A hand-kept list would rot the moment someone adds a
  // bookmark — this cannot, because the bookmarks ARE the list.
  //
  // It reports where each one came from, so a missing binary tells you which
  // profile stops working rather than just naming something absent.
  function scanDeps() {
    const SHELL_BUILTINS = new Set([
      "cd", "export", "source", ".", "echo", "exit", "set", "unset", "alias",
      "if", "for", "while", "read", "eval", "exec", "trap", "true", "false",
      "clear", "pushd", "popd", "wait", "kill", "jobs", "fg", "bg", "printf",
      // Control-flow keywords a bookmark's pipeline can start a segment with
      // (e.g. "... ; do ...; done") — these aren't binaries, `command -v`/
      // `which_all` would just report them MISSING forever.
      "do", "done", "end", "then", "fi", "elif", "else", "esac", "in",
      "function", "return", "local", "test",
    ]);
    const deps = new Map(); // binary -> Set(profile display names)
    for (const p of profiles) {
      const label = p.display_name || p.name;
      for (const sec of p.sections || []) {
        for (const it of sec.items || []) {
          if (!it.cmd) continue;
          // Take the first word of each ;/&&/| segment: a bookmark is often a
          // pipeline, and every stage of it is a dependency too.
          for (const seg of it.cmd.split(/\|\||&&|[;|]/)) {
            let w = seg.trim().split(/\s+/)[0] || "";
            w = w.replace(/^\(+/, "");                 // "(cmd ..." subshells
            if (!w || w.startsWith("$") || w.startsWith("-")) continue;
            if (w.includes("/")) w = w.split("/").pop(); // /usr/bin/x -> x
            if (!/^[A-Za-z][\w.+-]*$/.test(w)) continue;
            if (SHELL_BUILTINS.has(w)) continue;
            // "build.sh" etc. is a script NAME (run as ./build.sh or bash
            // build.sh), not a PATH-resolved command — a false positive that
            // would sit in the missing column forever.
            if (w.endsWith(".sh")) continue;
            if (!deps.has(w)) deps.set(w, new Set());
            deps.get(w).add(label);
          }
        }
      }
    }
    return deps;
  }

  // Resolution is pure Rust (which_all — see src-tauri/src/main.rs), never a
  // shell: the old version built a ~4KB `for b in ...; do ...; done` bash
  // one-liner and wrote it into a PTY tab, which fish-shell users' shells
  // rejected outright (bash `x=0` isn't valid fish) — and dumping a generated
  // script into an interactive terminal was bad UX even for bash users.
  let depsResults = []; // [[name, path|null, Set(profile labels)], ...] — current scan, for the filter box
  function renderDepsRows(filter) {
    const body = document.getElementById("deps-body");
    body.innerHTML = "";
    const q = (filter || "").toLowerCase();
    for (const [name, path, who] of depsResults) {
      if (q && !name.toLowerCase().includes(q)) continue;
      const row = document.createElement("div");
      row.className = "deps-row" + (path ? "" : " missing");
      const needers = path ? "" : ` <span class="deps-who">needed by: ${[...who].join(", ")}</span>`;
      row.innerHTML =
        `<span class="deps-mark">${path ? "✓" : "✗"}</span>` +
        `<span class="deps-name">${name}</span>` +
        `<span class="deps-path">${path || ""}</span>${needers}`;
      body.appendChild(row);
    }
  }
  document.getElementById("menu-deps").addEventListener("click", async () => {
    const deps = scanDeps();
    const names = [...deps.keys()].sort();
    console.log(`[deps] ${names.length} binaries referenced by ${profiles.length} profiles`);
    const resolved = await Transport.whichAll(names); // [[name, path|null], ...]
    // Missing first, then installed — each group alphabetical, same order the
    // Rust side returned them in (names was already sorted going in).
    const missing = resolved.filter(([, p]) => !p).map(([n, p]) => [n, p, deps.get(n)]);
    const installed = resolved.filter(([, p]) => p).map(([n, p]) => [n, p, deps.get(n)]);
    depsResults = [...missing, ...installed];
    document.getElementById("deps-summary").textContent =
      `${resolved.length} binaries — ${installed.length} installed, ${missing.length} missing`;
    document.getElementById("deps-search").value = "";
    renderDepsRows("");
    document.getElementById("deps").hidden = false;
  });
  document.getElementById("deps-search").addEventListener("input", (e) => renderDepsRows(e.target.value));
  document.getElementById("deps-close").addEventListener("click", () => { document.getElementById("deps").hidden = true; });
  document.getElementById("deps-copy-missing").addEventListener("click", () => {
    const text = depsResults.filter(([, p]) => !p).map(([n]) => n).join("\n");
    navigator.clipboard.writeText(text).catch(() => {});
  });

  document.getElementById("menu-about").addEventListener("click", showAbout);
  document.getElementById("about-close").addEventListener("click", () => { document.getElementById("about").hidden = true; });

  // Logs (logcat) viewer + export — captures console.* via DevLog. Export writes
  // console buffer + a live state snapshot to DevLog.PATH for offline debugging.
  const logsBody = document.getElementById("logs-body");
  const renderLogs = () => { logsBody.textContent = DevLog.buffer.join("\n") || "(no logs yet)"; logsBody.scrollTop = logsBody.scrollHeight; };
  const doExport = async () => {
    const p = await DevLog.export();
    console.log(p ? `Logs exported → ${p}` : "Log export failed");
    renderLogs();
  };
  document.getElementById("menu-logs").addEventListener("click", () => { renderLogs(); document.getElementById("logs").hidden = false; });
  document.getElementById("menu-export-logs").addEventListener("click", doExport);
  document.getElementById("logs-refresh").addEventListener("click", renderLogs);
  document.getElementById("logs-export").addEventListener("click", doExport);
  document.getElementById("logs-clear").addEventListener("click", () => { DevLog.clear(); renderLogs(); });
  document.getElementById("logs-close").addEventListener("click", () => { document.getElementById("logs").hidden = true; });

  // Row 1 (Home): each button selects its own home profile → its own tab group +
  // its own (empty) command sidebar. Reuses the group's tab instead of spawning.
  // Home is a tauri-app, not a shell profile: its tab is the hub's inventory
  // page. Tabs needs the profile list to render it, and `select` so a card can
  // actually take you there — that is the whole point of the page.
  Tabs.allProfiles = profiles;
  Tabs.selectProfileByName = (n) => {
    const p = byName(n);
    if (!p) return;
    const pill = [...document.querySelectorAll(".profile-pill")].find((e) => e.textContent === (p.display_name || p.name));
    selectProfile(p, pill || null);
  };
  document.getElementById("btn-home-home").addEventListener("click", () => selectProfile(byName("home"), null));
  document.getElementById("btn-home-filebrowser").addEventListener("click", () => selectProfile(byName("file-browser"), null));
  // Web Browser is a mode dropdown, same shape as File Editor: Terminal (browsh
  // in a PTY tab — renders every site, no GTK geometry involved) | GUI (native
  // webview embed, still being fixed). Picking one overrides the ☰ pref for
  // this launch only.
  const browserBtn = document.getElementById("btn-home-browser");
  const browserMenu = document.getElementById("browser-menu");
  browserBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    const show = browserMenu.hidden;
    browserMenu.hidden = !show;
    if (show) {
      const r = browserBtn.getBoundingClientRect();
      browserMenu.style.top = `${r.bottom + 2}px`;
      browserMenu.style.left = `${r.left}px`;
    }
    console.log("[browser] dropdown", browserMenu.hidden ? "closed" : "opened");
  });
  document.addEventListener("click", () => { browserMenu.hidden = true; });
  const openBrowserAs = (m) => () => {
    const p = byName("web-browser");
    console.log(`[browser] ${m} clicked → web-browser profile`);
    selectProfile(p, null, () => Tabs.openBrowserTab(p.url, "web-browser", null, m));
  };
  document.getElementById("browser-tui").addEventListener("click", openBrowserAs("tui"));
  document.getElementById("browser-gui").addEventListener("click", openBrowserAs("gui"));
  document.getElementById("btn-home-agentic").addEventListener("click", () => selectProfile(byName("agentic"), null));
  // Any other `home:true` profile (e.g. goose-desktop, cloud-agentic) gets its
  // button generated here instead of a hardcoded HTML entry — new pinned tabs
  // are then just a new profile.json, no code change. The 4 above are hand-wired
  // because file-editor is a dropdown menu, not a plain profile click, and
  // file-browser/web-browser/agentic predate this loop.
  const fixedHomeBtns = new Set(["home", "file-browser", "file-editor", "web-browser", "agentic"]);
  const homeActions = document.getElementById("home-actions");
  profiles.filter((p) => p.home && !fixedHomeBtns.has(p.name)).forEach((p) => {
    const b = document.createElement("button");
    b.className = "home-btn";
    b.textContent = p.display_name || p.name;
    b.addEventListener("click", () => selectProfile(p, null));
    homeActions.appendChild(b);
  });
  // File Editor is a mode dropdown: Plain (in-app textarea) | Vim (real vim in a
  // PTY). Both open in the file-editor group; Vim uses the opener override.
  const editorBtn = document.getElementById("btn-home-fileeditor");
  const editorMenu = document.getElementById("editor-menu");
  editorBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    const show = editorMenu.hidden;
    editorMenu.hidden = !show;
    if (show) {  // position the fixed menu right under the button
      const r = editorBtn.getBoundingClientRect();
      editorMenu.style.top = `${r.bottom + 2}px`;
      editorMenu.style.left = `${r.left}px`;
    }
    console.log("[editor] dropdown", editorMenu.hidden ? "closed" : "opened");
  });
  document.addEventListener("click", () => { editorMenu.hidden = true; });
  document.getElementById("editor-plain").addEventListener("click", () => {
    console.log("[editor] Plain clicked → file-editor profile");
    selectProfile(byName("file-editor"), null);
  });
  document.getElementById("editor-vim").addEventListener("click", () => {
    console.log("[editor] Vim clicked → file-editor profile + vim");
    selectProfile(byName("file-editor"), null, () => Tabs.openVimTab("file-editor"));
  });
  // About lives in the Configs (⋮ → menu-about) dropdown now — no standalone button.

  // Sidebar view switcher: Commands (search + per-profile items) | Data
  // (per-profile config/data files, lazyloaded) | Tabs (vertical, grouped).
  for (const btn of document.querySelectorAll(".sidebar-toggle-btn")) {
    btn.addEventListener("click", () => {
      for (const b of document.querySelectorAll(".sidebar-toggle-btn")) b.classList.toggle("active", b === btn);
      const view = btn.dataset.view;
      document.getElementById("commands-panel").hidden = view !== "commands";
      document.getElementById("tabs-panel").hidden = view !== "tabs";
      document.getElementById("data-panel").hidden = view !== "data";
      if (view === "tabs") Tabs.renderTabList();
      if (view === "data") buildDataPanel(current);
    });
  }

  // First profile + its first tab (one pane, or a browser tab)
  current = profiles[0];
  buildSections(current);
  Tabs.activeProfile = current.name;
  if (current.browser) Tabs.openBrowserTab(current.url, current.name);
  else if (current.filebrowser) Tabs.openFileBrowserTab(current.start_path || "~", current.name);
  else await Tabs.newTab(current.name);
})();
