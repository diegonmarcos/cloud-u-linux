// shell.js — browser-chrome behavior for the CEF shell window.
//
// This file IS the browser chrome. It runs inside the shell HTML page, which
// is itself displayed by a CEF (Chromium Embedded Framework) native window.
// Page content the user navigates to is now its OWN CEF browser, composited
// by Rust underneath the chrome rows — it is NOT the <iframe id="view"> any
// more (that element is inert legacy markup from index.html; this file never
// writes to it). Everything this shell needs from Rust goes through the
// single sendToRust() function below; nothing else in this file should know
// or care about the wire format, because a parallel change is defining it.
// Matches the qutebrowser behavior documented in:
//   - db_my-browser-qute/src/2_configs/qute-keybindings.json (normal-mode keys)
//   - db_my-browser-rust-chromium/UI-SPEC.md (row order, statusbar, colors)
//
// Plain ES2020. No build step, no dependencies. Runs straight from file://.

(function () {
  'use strict';

  // ---------------------------------------------------------------------
  // DOM handles (defensive: the HTML is authored by another agent; every id
  // in the DOM CONTRACT may or may not exist yet at script-load time).
  // ---------------------------------------------------------------------
  const $ = (id) => document.getElementById(id);

  const dom = {
    mybar: $('mybar'),
    pinbar: $('pinbar'),
    tabbar: $('tabbar'),
    content: $('content'),
    view: $('view'),
    statusbar: $('statusbar'),
    statusUrl: $('status-url'),
    statusMode: $('status-mode'),
    statusScroll: $('status-scroll'),
    statusTabs: $('status-tabs'),
    statusProgress: $('status-progress'),
    cmdline: $('cmdline'),
    pages: $('pages'),
    pagesBody: $('pages-body'),
  };

  const DATA = window.MYDATA || {};
  const KEYBINDINGS = (DATA.keybindings && DATA.keybindings.normal) || {};

  // ---------------------------------------------------------------------
  // The one place the shell talks to Rust. A parallel change defines the wire
  // format; everything else in this file goes through here so that when the
  // format is settled only this function changes.
  // ---------------------------------------------------------------------
  // The one place the shell talks to Rust. Wire format is PLAIN TEXT, not JSON:
  // "__CMD__<verb> <args...>", parsed by input::parse_command on the Rust side.
  // No JSON, because parsing it in Rust would mean a new dependency.
  // Rust clears document.title after draining, so sending the same command twice
  // in a row still fires -- CEF does not re-emit on_title_change for an unchanged
  // string.
  const RUST_VERB = {
    navigate: (c) => 'navigate ' + c.url,
    back: () => 'back',
    forward: () => 'forward',
    reload: () => 'reload',
    stop: () => 'stop',
    find: (c) => 'find ' + c.text,
    'find-next': () => 'find-next',
    'find-prev': () => 'find-prev',
    'find-cancel': () => 'find-cancel',
    // parse_command demands exactly two integers and rejects trailing garbage,
    // so round: a fractional delta from a trackpad would fail to parse.
    scroll: (c) => 'scroll ' + Math.round(c.dx || 0) + ' ' + Math.round(c.dy || 0),
    js: (c) => 'js ' + c.script,
    focus: (c) => 'focus ' + c.target,
    quit: () => 'quit',
  };

  function sendToRust(cmd) {
    const build = cmd && RUST_VERB[cmd.op];
    if (!build) { setStatus('internal: no wire form for ' + (cmd && cmd.op)); return; }
    // A newline would truncate the command inside a window title.
    document.title = '__CMD__' + build(cmd).replace(/[\r\n]+/g, ' ');
  }

  // ---------------------------------------------------------------------
  // Tiny event bus for window.SHELL.on('navigate' | 'tabchange', cb)
  // ---------------------------------------------------------------------
  const listeners = { navigate: [], tabchange: [] };
  function emit(event, payload) {
    (listeners[event] || []).forEach((cb) => {
      try { cb(payload); } catch (e) { console.error('[shell] listener error', event, e); }
    });
  }
  function on(event, cb) {
    if (!listeners[event]) listeners[event] = [];
    listeners[event].push(cb);
    return () => {
      listeners[event] = listeners[event].filter((c) => c !== cb);
    };
  }

  // ---------------------------------------------------------------------
  // TAB MODEL
  // Each tab: { id, url, title, pinned, muted, history: [urls], histIndex }
  // Only the selected tab's URL is ever loaded into #view — switching tabs
  // swaps the iframe's src to the tab's current history entry.
  // ---------------------------------------------------------------------
  let nextId = 1;
  let tabs = [];
  let selectedId = null;
  let closedStack = []; // for `undo`

  function makeTab(url, opts) {
    // label = the permanent name from config; title = whatever the page reports.
    opts = opts || {};
    const t = {
      id: nextId++,
      url: url || 'about:blank',
      title: opts.title || url || 'New Tab',
      // Only pinned tabs get a permanent label: their name comes from mybar.json and
      // must never be replaced by the page's own <title>. Regular tabs stay dynamic.
      label: opts.label || (opts.pinned ? (opts.title || '') : ''),
      pinned: !!opts.pinned,
      muted: false,
      history: [url || 'about:blank'],
      histIndex: 0,
      loadTimer: null,
    };
    return t;
  }

  function orderedTabs() {
    // regular tabs render into #tabbar; pinned into #pinbar. Order preserved
    // from the tabs[] array, filtered by pinned flag.
    return {
      pinned: tabs.filter((t) => t.pinned),
      regular: tabs.filter((t) => !t.pinned),
    };
  }

  function getTab(id) {
    return tabs.find((t) => t.id === id) || null;
  }

  function currentTab() {
    return getTab(selectedId);
  }

  function openTab(url, opts) {
    opts = opts || {};
    // `open -t qute://history` must land on the internal page, not spawn a tab
    // pointing at a scheme the iframe cannot resolve.
    const page = internalPage(url);
    if (page) { showPage(page); return; }
    const t = makeTab(url, opts);
    tabs.push(t);
    render();
    if (!opts.background) {
      selectTab(t.id);
    } else {
      renderTabbars();
    }
    return t.id;
  }

  function closeTab(id) {
    const idx = tabs.findIndex((t) => t.id === id);
    if (idx === -1) return;
    const [removed] = tabs.splice(idx, 1);
    closedStack.push(removed);
    if (selectedId === id) {
      // select a sensible neighbor among non-pinned tabs, falling back to any
      const regular = tabs.filter((t) => !t.pinned);
      const next = regular[idx] || regular[idx - 1] || tabs[tabs.length - 1] || null;
      selectedId = next ? next.id : null;
    }
    render();
    loadSelected();
  }

  function closeOtherTabs() {
    if (!selectedId) return;
    const keep = currentTab();
    closedStack.push(...tabs.filter((t) => t.id !== keep.id));
    tabs = [keep];
    render();
  }

  function undoClose() {
    const t = closedStack.pop();
    if (!t) { setStatus('No tabs to reopen'); return; }
    tabs.push(t);
    render();
    selectTab(t.id);
  }

  function selectTab(id) {
    const t = getTab(id);
    if (!t) return;
    selectedId = id;
    render();
    loadSelected();
    emit('tabchange', { id, tab: t });
  }

  function focusTabByIndex(delta) {
    const regular = tabs.filter((t) => !t.pinned);
    if (regular.length === 0) return;
    const curIdx = regular.findIndex((t) => t.id === selectedId);
    let idx = curIdx === -1 ? 0 : (curIdx + delta + regular.length) % regular.length;
    selectTab(regular[idx].id);
  }

  function moveTab(dir) {
    const idx = tabs.findIndex((t) => t.id === selectedId);
    if (idx === -1) return;
    const swapWith = idx + dir;
    if (swapWith < 0 || swapWith >= tabs.length) return;
    const tmp = tabs[idx];
    tabs[idx] = tabs[swapWith];
    tabs[swapWith] = tmp;
    render();
  }

  function togglePin(id) {
    const t = getTab(id || selectedId);
    if (!t) return;
    t.pinned = !t.pinned;
    render();
  }

  function toggleMute(id) {
    const t = getTab(id || selectedId);
    if (!t) return;
    t.muted = !t.muted;
    render();
    setStatus((t.muted ? 'Muted: ' : 'Unmuted: ') + t.title);
  }

  // -- per-tab history (own stacks; cross-origin iframes cannot be read) --
  // qute:// URLs are internal pages, not network resources. qute's own keybindings
  // use them (gD -> qute://downloads, gI -> qute://history, gS -> qute://settings),
  // so keep the scheme verbatim rather than renaming it and breaking muscle memory.
  const INTERNAL_SCHEME = /^(?:qute|mybrowser):\/\/([a-z-]+)/i;
  function internalPage(url) {
    const m = INTERNAL_SCHEME.exec(String(url || '').trim());
    return m ? m[1].toLowerCase() : null;
  }

  function navigate(url, opts) {
    opts = opts || {};
    const page = internalPage(url);
    if (page) { showPage(page); return; }
    const t = currentTab();
    if (!t) { openTab(url, opts); return; }
    url = normalizeUrl(url);
    if (!opts.silent) {
      // truncate forward history on new navigation
      t.history = t.history.slice(0, t.histIndex + 1);
      t.history.push(url);
      t.histIndex = t.history.length - 1;
    }
    t.url = url;
    // A pinned/bookmarked tab carries an explicit label from mybar.json. Navigating
    // must not overwrite it with the raw URL -- that is what made the PinBar show
    // "file:///home/..." instead of "Bookmarks" for whichever pin was selected.
    t.title = t.label || prettyTitle(url);
    loadUrlIntoBrowser(t, url);
    render();
    emit('navigate', { id: t.id, url, tab: t });
  }

  function goBack() {
    const t = currentTab();
    if (!t || t.histIndex <= 0) { setStatus('No back history'); return; }
    t.histIndex -= 1;
    t.url = t.history[t.histIndex];
    sendToRust({ op: 'back' });
    render();
    emit('navigate', { id: t.id, url: t.url, tab: t });
  }

  function goForward() {
    const t = currentTab();
    if (!t || t.histIndex >= t.history.length - 1) { setStatus('No forward history'); return; }
    t.histIndex += 1;
    t.url = t.history[t.histIndex];
    sendToRust({ op: 'forward' });
    render();
    emit('navigate', { id: t.id, url: t.url, tab: t });
  }

  function normalizeUrl(input) {
    input = (input || '').trim();
    if (!input) return 'about:blank';
    if (/^[a-z][a-z0-9+.-]*:/i.test(input)) return input; // already has a scheme
    if (/^(localhost|[\w-]+\.[\w.-]+)(:\d+)?(\/.*)?$/i.test(input) && !/\s/.test(input)) {
      return 'https://' + input;
    }
    // fall back to configured default search engine, else a generic one
    const engines = DATA.searchEngines || {};
    const engine = engines.DEFAULT || engines.default || 'https://duckduckgo.com/?q={}';
    return engine.replace('{}', encodeURIComponent(input));
  }

  function loadSelected() {
    const t = currentTab();
    if (!t) {
      sendToRust({ op: 'navigate', url: 'about:blank' });
      return;
    }
    loadUrlIntoBrowser(t, t.url);
  }

  // ---------------------------------------------------------------------
  // NAVIGATION -> content browser
  //
  // Content is its own CEF browser now, composited by Rust below the chrome
  // rows — not the <iframe id=view> in index.html (dead markup, left alone).
  // There is no iframe to fail to load, so the old X-Frame-Options / CSP
  // frame-ancestors "refused to load" heuristic no longer applies and has
  // been removed rather than left inert. Real page title/load-progress, once
  // Rust publishes them, arrive via the window.__NAV STATE channel handled
  // in applyNavState() below; until then title/progress are best-effort from
  // the URL alone.
  // ---------------------------------------------------------------------
  function loadUrlIntoBrowser(tab, url) {
    if (url === 'about:blank') {
      sendToRust({ op: 'navigate', url: 'about:blank' });
      updateStatusUrl();
      return;
    }
    sendToRust({ op: 'navigate', url });
    updateStatusUrl();
  }

  // window.__NAV (published by Rust via the STATE channel in state.js, see
  // boot()) may report { url, title, loading, can_back, can_forward }. It
  // may never arrive — every field access here is guarded.
  function applyNavState(nav) {
    if (!nav || typeof nav !== 'object') return;
    const t = currentTab();
    if (!t) return;
    if (nav.url) { t.url = nav.url; }
    if (nav.title && !t.label) { t.title = nav.title; }
    renderTabbars();
    updateStatusUrl();
    setProgress(nav.loading ? 50 : 0);
  }

  function setProgress(pct) {
    if (dom.statusProgress) dom.statusProgress.textContent = pct > 0 && pct < 100 ? pct + '%' : '';
  }

  // ---------------------------------------------------------------------
  // RENDER
  // ---------------------------------------------------------------------
  function render() {
    renderMybar();
    renderPinbar();
    renderTabbars();
    updateStatusUrl();
    updateStatusTabs();
  }

  function renderMybar() {
    if (!dom.mybar) return;
    dom.mybar.innerHTML = '';
    const bookmarks = DATA.bookmarks || [];
    bookmarks.forEach((b) => dom.mybar.appendChild(bookmarkEl(b)));
    const plugins = DATA.plugins || [];
    plugins.forEach((p) => dom.mybar.appendChild(pluginEl(p)));
  }

  function bookmarkEl(b) {
    if (b.links) {
      const wrap = document.createElement('div');
      wrap.className = 'dropdown';
      const btn = document.createElement('button');
      btn.className = 'bookmark-btn';
      btn.textContent = (b.icon ? b.icon + ' ' : '') + b.name;
      const menu = document.createElement('div');
      menu.className = 'dropdown-menu hidden';
      Object.keys(b.links).forEach((label) => {
        const item = document.createElement('button');
        item.textContent = label;
        item.addEventListener('click', () => {
          navigate(b.links[label]);
          menu.classList.add('hidden');
        });
        menu.appendChild(item);
      });
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        menu.classList.toggle('hidden');
      });
      wrap.appendChild(btn);
      wrap.appendChild(menu);
      return wrap;
    }
    const btn = document.createElement('button');
    btn.className = 'bookmark-btn';
    btn.textContent = (b.icon ? b.icon + ' ' : '') + b.name;
    btn.addEventListener('click', () => navigate(b.url));
    return btn;
  }

  function pluginEl(p) {
    const btn = document.createElement('button');
    btn.className = 'plugin-btn';
    btn.textContent = (p.icon ? p.icon + ' ' : '') + p.name;
    btn.dataset.pluginId = p.id;
    btn.addEventListener('click', () => {
      if (p.command) {
        runCommand(p.command);
      } else if (p.option) {
        // config-cycle style toggle plugin: flip between on_value/off_value
        const isOn = btn.classList.toggle('active');
        setStatus(p.name + ': ' + (isOn ? (p.on_value || 'on') : (p.off_value || 'off')));
      } else {
        setStatus('Plugin ' + p.name + ' has no command');
      }
    });
    return btn;
  }

  function renderPinbar() {
    if (!dom.pinbar) return;
    dom.pinbar.innerHTML = '';
    orderedTabs().pinned.forEach((t, i) => dom.pinbar.appendChild(tabEl(t, i)));
  }

  function renderTabbars() {
    if (!dom.tabbar) return;
    dom.tabbar.innerHTML = '';
    orderedTabs().regular.forEach((t, i) => dom.tabbar.appendChild(tabEl(t, i)));
    // pinbar also needs refresh since pin state may have flipped
    renderPinbar();
  }

  function tabEl(t, index) {
    const el = document.createElement('div');
    el.className = 'tab' + (index % 2 === 0 ? ' even' : ' odd') +
      (t.id === selectedId ? ' selected' : '') +
      (t.pinned ? ' pin' : '');
    el.dataset.tabId = t.id;
    el.textContent = t.title || t.url;
    el.title = t.url;
    el.addEventListener('click', () => selectTab(t.id));
    return el;
  }

  function updateStatusUrl() {
    if (!dom.statusUrl) return;
    const t = currentTab();
    const url = t ? t.url : '';
    dom.statusUrl.textContent = url;
    dom.statusUrl.style.color = /^https:/i.test(url) ? '#27ae60' : '';
  }

  function updateStatusTabs() {
    if (!dom.statusTabs) return;
    // qute's [i/N] counts pinned tabs as tabs; only their rendering row differs.
    const all = tabs;
    const idx = all.findIndex((t) => t.id === selectedId);
    dom.statusTabs.textContent = all.length ? (idx + 1) + '/' + all.length : '0/0';
  }

  function setStatus(msg) {
    if (!dom.statusMode) return;
    // transient status text goes into status-mode's title/area briefly via
    // a small side channel so we don't clobber the persistent mode label.
    if (dom.statusbar) {
      let msgEl = dom.statusbar.querySelector('.status-msg');
      if (!msgEl) {
        msgEl = document.createElement('span');
        msgEl.className = 'status-msg';
        dom.statusbar.appendChild(msgEl);
      }
      msgEl.textContent = msg;
      clearTimeout(setStatus._t);
      setStatus._t = setTimeout(() => { msgEl.textContent = ''; }, 4000);
    }
  }

  // ---------------------------------------------------------------------
  // PAGES (qute://downloads, qute://history, qute://settings equivalents)
  // ---------------------------------------------------------------------
  // pages.js owns the renderers and registers them on window.PAGES. It is loaded
  // after this file, so resolve it at call time, never at load time.
  // The start page ships in the bundle one level up from shell/. Overridable from
  // config via MYDATA.homepage without touching this file.
  const HOMEPAGE = '../my-browser-chromium-homepage.html';

  // Chromium refuses contentDocument access on file:// iframes (they are treated as
  // opaque origins), and cross-origin http pages are unreadable by design, so the
  // page's real <title> is usually unavailable. Derive something legible from the
  // URL instead of showing the raw path in the tab strip.
  // Decodes the launcher's #open=<base64> hand-off. Anything malformed is
  // ignored rather than thrown: a bad fragment must not stop the browser booting.
  function requestedUrl() {
    const m = /[#&]open=([^&]+)/.exec(location.hash || '');
    if (!m) return null;
    try {
      const u = decodeURIComponent(escape(atob(m[1])));
      return /^(https?|file|about):/i.test(u) ? u : null;
    } catch (e) {
      return null;
    }
  }

  function prettyTitle(url) {
    const u = String(url || '');
    try {
      const p = new URL(u, location.href);
      const last = p.pathname.split('/').filter(Boolean).pop() || '';
      const base = last.replace(/\.[a-z0-9]+$/i, '').replace(/[-_]+/g, ' ').trim();
      return base || p.hostname || u;
    } catch (e) {
      return u;
    }
  }

  const PAGE_ALIASES = { settings: 'config', 'qute-settings': 'config' };

  function showPage(name) {
    if (!dom.pages) { setStatus('No page overlay in DOM'); return; }
    const page = PAGE_ALIASES[name] || name;
    dom.pages.classList.remove('hidden');
    if (dom.pagesBody) {
      dom.pagesBody.dataset.page = page;
      if (window.PAGES && typeof window.PAGES.render === 'function') {
        window.PAGES.render(page, dom.pagesBody);
      } else {
        dom.pagesBody.textContent = 'pages.js not loaded — no renderer for: ' + page;
      }
    }
    emit('navigate', { page: page });
  }

  function hidePage() {
    if (!dom.pages) return;
    dom.pages.classList.add('hidden');
  }

  // ---------------------------------------------------------------------
  // MODES: normal / insert / command
  // ---------------------------------------------------------------------
  let mode = 'normal';

  function setMode(next) {
    mode = next;
    if (dom.statusMode) dom.statusMode.textContent = next;
    if (dom.statusbar) {
      dom.statusbar.classList.toggle('mode-insert', next === 'insert');
      dom.statusbar.classList.toggle('mode-command', next === 'command' || next === 'find');
    }
    if (next === 'command' || next === 'find') {
      if (dom.cmdline) {
        dom.cmdline.classList.remove('hidden');
        dom.cmdline.focus();
      }
    } else {
      if (dom.cmdline) dom.cmdline.classList.add('hidden');
    }
  }

  function enterCommandMode(prefill) {
    setMode('command');
    if (dom.cmdline) {
      dom.cmdline.value = prefill != null ? prefill : ':';
      // put cursor at end
      dom.cmdline.selectionStart = dom.cmdline.selectionEnd = dom.cmdline.value.length;
    }
  }

  function isEditableTarget(el) {
    if (!el) return false;
    if (el === dom.cmdline) return true;
    const tag = (el.tagName || '').toLowerCase();
    if (tag === 'input' || tag === 'textarea') return true;
    if (el.isContentEditable) return true;
    return false;
  }

  if (dom.cmdline) {
    dom.cmdline.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        dom.cmdline.value = '';
        setMode('normal');
        return;
      }
      if (e.key === 'Enter') {
        e.preventDefault();
        if (mode === 'find') {
          const raw = dom.cmdline.value;
          const text = raw.slice(1); // drop the leading '/' or '?'
          dom.cmdline.value = '';
          setMode('normal');
          if (text) {
            findActive = true;
            findTerm = text;
            sendToRust({ op: 'find', text });
            updateFindStatus();
          }
          return;
        }
        const text = dom.cmdline.value.replace(/^:/, '');
        dom.cmdline.value = '';
        setMode('normal');
        runCommand(text);
      }
    });
  }

  // ---------------------------------------------------------------------
  // FIND (in-page search) — '/' and '?' reuse #cmdline with a prefix char;
  // Enter sends {op:'find'}, n/N send find-next/find-prev, Escape cancels.
  // ---------------------------------------------------------------------
  let findActive = false;
  let findTerm = '';

  function enterFindMode(prefix) {
    setMode('find');
    if (dom.cmdline) {
      dom.cmdline.value = prefix;
      dom.cmdline.selectionStart = dom.cmdline.selectionEnd = dom.cmdline.value.length;
    }
  }

  function cancelFind() {
    findActive = false;
    findTerm = '';
    sendToRust({ op: 'find-cancel' });
    updateFindStatus();
  }

  function updateFindStatus() {
    if (!dom.statusbar) return;
    let el = dom.statusbar.querySelector('.status-find');
    if (!findActive) {
      if (el) el.remove();
      return;
    }
    if (!el) {
      el = document.createElement('span');
      el.className = 'status-find';
      dom.statusbar.appendChild(el);
    }
    el.textContent = '/' + findTerm;
  }

  // ---------------------------------------------------------------------
  // LINK HINTS ('f' / 'F') — the shell cannot see the content browser's DOM,
  // so hints are done entirely by injecting JS into it via {op:'js'}. The
  // injected script overlays a labelled badge on every clickable element and
  // exposes window.__hintPick(label) for the shell to call once the user has
  // typed a full 2-letter label.
  //
  // ponytail: hints are injected JS running in the content browser's own top
  // document — they cannot see inside cross-origin sub-frames (e.g. a login
  // widget or ad served from another origin), so elements inside those never
  // get a badge. That is a ceiling of the injected-JS approach, not a bug.
  // ---------------------------------------------------------------------
  let hintBuffer = '';

  function buildHintScript(action) {
    // action is one of 'click' | 'newtab' — a fixed enum, never interpolated
    // from anything untrusted.
    return '(function(){' +
      'var ALPHA="abcdefghijklmnopqrstuvwxyz";' +
      'function label(i){return ALPHA[Math.floor(i/26)%26]+ALPHA[i%26];}' +
      'if (window.__hintCleanup) window.__hintCleanup();' +
      'var els = Array.prototype.slice.call(document.querySelectorAll(' +
        '"a[href],button,input,[onclick],[role=button]"));' +
      'var overlay = document.createElement("div");' +
      'overlay.id = "__shell_hints__";' +
      'overlay.style.cssText = "position:fixed;top:0;left:0;width:0;height:0;z-index:2147483647;";' +
      'document.documentElement.appendChild(overlay);' +
      'var map = {};' +
      'els.forEach(function(el, i){' +
        'if (i > 675) return;' +
        'var r = el.getBoundingClientRect();' +
        'if (r.width === 0 && r.height === 0) return;' +
        'var lab = label(i);' +
        'map[lab] = el;' +
        'var badge = document.createElement("div");' +
        'badge.textContent = lab;' +
        'badge.style.cssText = "position:fixed;left:" + Math.max(0, r.left) + "px;top:" + ' +
          'Math.max(0, r.top) + "px;background:#e5c07b;color:#1b1e20;' +
          'font:bold 11px monospace;padding:1px 3px;border-radius:2px;' +
          'z-index:2147483647;pointer-events:none;box-shadow:0 0 0 1px #1b1e20;";' +
        'overlay.appendChild(badge);' +
      '});' +
      'window.__hintPick = function(lab){' +
        'var el = map[String(lab).toLowerCase()];' +
        'if (!el) return false;' +
        'try {' +
          (action === 'newtab'
            ? 'window.open(el.href || el.getAttribute("href") || "", "_blank");'
            : 'el.click();') +
        '} catch (e) {}' +
        'window.__hintCleanup();' +
        'return true;' +
      '};' +
      'window.__hintCleanup = function(){' +
        'var o = document.getElementById("__shell_hints__");' +
        'if (o) o.remove();' +
        'delete window.__hintPick;' +
        'delete window.__hintCleanup;' +
      '};' +
    '})();';
  }

  function startHints(action) {
    hintBuffer = '';
    setMode('hint');
    setStatus('Hints: type 2 letters (Esc to cancel)');
    sendToRust({ op: 'js', script: buildHintScript(action) });
  }

  function cancelHints() {
    hintBuffer = '';
    setMode('normal');
    sendToRust({ op: 'js', script: 'window.__hintCleanup && window.__hintCleanup();' });
  }

  function handleHintKey(e) {
    if (e.key === 'Escape') {
      e.preventDefault();
      cancelHints();
      return;
    }
    e.preventDefault();
    if (!/^[a-zA-Z]$/.test(e.key)) return; // swallow everything else while hinting
    hintBuffer += e.key.toLowerCase();
    setStatus('Hint: ' + hintBuffer);
    if (hintBuffer.length >= 2) {
      const label = hintBuffer;
      hintBuffer = '';
      setMode('normal');
      sendToRust({ op: 'js', script: 'window.__hintPick && window.__hintPick(' + JSON.stringify(label) + ');' });
    }
  }

  // ---------------------------------------------------------------------
  // COMMANDS
  //
  // runCommand implements the subset of qutebrowser command names used by
  // qute-keybindings.json. Unknown commands report an error via the
  // statusbar rather than throwing, matching qute's forgiving behavior.
  // ---------------------------------------------------------------------
  let clipboardFallback = ''; // used when navigator.clipboard is unavailable/blocked

  function splitArgs(str) {
    // minimal shell-like splitter: respects "--" and quoted strings
    const out = [];
    const re = /"([^"]*)"|'([^']*)'|(\S+)/g;
    let m;
    while ((m = re.exec(str))) out.push(m[1] !== undefined ? m[1] : m[2] !== undefined ? m[2] : m[3]);
    return out;
  }

  async function readClipboard() {
    try {
      if (navigator.clipboard && navigator.clipboard.readText) {
        return await navigator.clipboard.readText();
      }
    } catch (e) { /* permission denied or unsupported */ }
    return clipboardFallback;
  }

  async function writeClipboard(text) {
    clipboardFallback = text;
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        await navigator.clipboard.writeText(text);
        return;
      }
    } catch (e) { /* fall through to fallback */ }
  }

  function runCommand(str) {
    str = (str || '').trim();
    if (!str) return;
    const parts = splitArgs(str);
    const name = parts[0];
    const rest = parts.slice(1);
    // {url:pretty} / {clipboard} substitution used by qute-keybindings.json
    const expandAsync = async (args) => {
      const out = [];
      for (const a of args) {
        if (a.includes('{clipboard}')) {
          out.push(a.replace('{clipboard}', await readClipboard()));
        } else if (a.includes('{url:pretty}')) {
          const t = currentTab();
          out.push(a.replace('{url:pretty}', t ? t.url : ''));
        } else {
          out.push(a);
        }
      }
      return out;
    };

    try {
      switch (name) {
        case 'open': {
          expandAsync(rest).then((args) => {
            const tFlag = args.includes('-t');
            const url = args.filter((a) => a !== '-t' && a !== '--')[0];
            if (!url) { setStatus('open: missing url'); return; }
            if (tFlag) openTab(normalizeUrl(url));
            else navigate(url);
          });
          break;
        }
        case 'tab-open':
          runCommand('open -t ' + rest.join(' '));
          break;
        case 'tab-close':
          if (selectedId != null) closeTab(selectedId);
          break;
        case 'tab-only':
          closeOtherTabs();
          break;
        case 'tab-next':
          focusTabByIndex(1);
          break;
        case 'tab-prev':
          focusTabByIndex(-1);
          break;
        case 'tab-move':
          moveTab(rest[0] === '-' ? -1 : 1);
          break;
        case 'tab-pin':
          togglePin();
          break;
        case 'tab-mute':
          toggleMute();
          break;
        case 'tab-focus': {
          const n = parseInt(rest[0], 10);
          const regular = orderedTabs().regular;
          if (!isNaN(n) && regular[n - 1]) selectTab(regular[n - 1].id);
          break;
        }
        case 'back':
          goBack();
          break;
        case 'forward':
          goForward();
          break;
        case 'reload':
          sendToRust({ op: 'reload' });
          break;
        case 'stop':
          sendToRust({ op: 'stop' });
          setProgress(0);
          if (findActive) cancelFind();
          break;
        case 'fullscreen':
          if (!document.fullscreenElement) {
            document.documentElement.requestFullscreen && document.documentElement.requestFullscreen();
          } else {
            document.exitFullscreen && document.exitFullscreen();
          }
          break;
        case 'undo':
          undoClose();
          break;
        case 'yank': {
          const t = currentTab();
          if (rest[0] === 'url' && t) {
            writeClipboard(t.url);
            setStatus('Yanked: ' + t.url);
          }
          break;
        }
        case 'edit-url':
          enterCommandMode(':open ' + (currentTab() ? currentTab().url : ''));
          break;
        case 'cmd-set-text':
        case 'set-cmd-text': {
          // qute-keybindings.json uses "cmd-set-text -s :open" and variants
          const args = rest.filter((a) => a !== '-s');
          let text = args.join(' ');
          expandAsync(splitArgs(text)).then((expanded) => {
            enterCommandMode(':' + expanded.join(' '));
          });
          break;
        }
        case 'devtools':
          setStatus('devtools: no host command for this yet');
          break;
        case 'config-shortcuts':
        case 'config-edit':
          showPage(name === 'config-edit' ? 'settings' : 'shortcuts');
          break;
        case 'config-cycle': {
          setStatus('config-cycle ' + rest.join(' '));
          break;
        }
        case 'session-load':
          setStatus('session-load: ' + (rest[0] || 'default'));
          break;
        case 'quit':
        case 'close':
          setStatus('close/quit: no native window handle from JS; ignoring');
          break;
        case 'spawn': {
          // No Rust-side process API exists from this shell; report clearly
          // instead of failing silently.
          setStatus('spawn: unavailable in browser-chrome JS (no host bridge): ' + rest.join(' '));
          break;
        }

        // -- qutebrowser built-in keymap (P6) -----------------------------
        case 'scroll-down':          sendToRust({ op: 'scroll', dx: 0, dy: 40 }); break;
        case 'scroll-up':            sendToRust({ op: 'scroll', dx: 0, dy: -40 }); break;
        case 'scroll-left':          sendToRust({ op: 'scroll', dx: -40, dy: 0 }); break;
        case 'scroll-right':         sendToRust({ op: 'scroll', dx: 40, dy: 0 }); break;
        case 'scroll-halfpage-down': sendToRust({ op: 'scroll', dx: 0, dy: 300 }); break;
        case 'scroll-halfpage-up':   sendToRust({ op: 'scroll', dx: 0, dy: -300 }); break;
        case 'scroll-page-down':     sendToRust({ op: 'scroll', dx: 0, dy: 600 }); break;
        // top/bottom: a delta large enough that the content browser clamps
        // it against the real scroll extent, rather than a magic "go to end"
        // op the wire format doesn't define.
        case 'scroll-top':           sendToRust({ op: 'scroll', dx: 0, dy: -1e9 }); break;
        case 'scroll-bottom':        sendToRust({ op: 'scroll', dx: 0, dy: 1e9 }); break;

        case 'find-forward':  enterFindMode('/'); break;
        case 'find-backward': enterFindMode('?'); break;
        case 'find-next':     sendToRust({ op: 'find-next' }); break;
        case 'find-prev':     sendToRust({ op: 'find-prev' }); break;
        case 'find-cancel':   cancelFind(); break;

        case 'mode-enter': {
          const target = rest[0];
          if (target === 'insert') setMode('insert');
          else if (target === 'caret') {
            // Stub: enters caret mode and says so — does NOT implement real
            // text-selection/caret-navigation behaviour.
            setMode('caret');
            setStatus('Caret mode (stub — no selection behaviour implemented)');
          }
          break;
        }

        case 'hint-links':     startHints('click'); break;
        case 'hint-links-tab': startHints('newtab'); break;

        default:
          setStatus('Unknown command: ' + name);
      }
    } catch (e) {
      console.error('[shell] command error', str, e);
      setStatus('Error running: ' + str);
    }
  }

  // ---------------------------------------------------------------------
  // KEYBINDINGS
  //
  // Supports qute's key syntax:
  //   - single printable keys: t, w, H, L, <, >
  //   - modifier chords: <Ctrl-p>, <Alt-Left>, <Shift-Tab>, <F5>, <Escape>
  //   - multi-key sequences (prefix keys): gD, gI, gS, ,d, ,pp
  // A pending-sequence buffer holds partial input (e.g. after 'g' or ',')
  // and resets after ~1s of inactivity or once a full match/mismatch occurs.
  // ---------------------------------------------------------------------
  const SEQUENCE_TIMEOUT_MS = 1000;
  let pending = '';
  let pendingTimer = null;

  // qutebrowser's built-in normal-mode keymap (P6). Only the subset that maps
  // onto sendToRust ops or the mode/hint/find machinery below — layered
  // UNDER the custom KEYBINDINGS so a key already claimed in
  // keybindings.json (e.g. 'u' -> undo, 'H'/'L' -> back/forward, 'r' ->
  // reload) always wins. 'd' and 'u' are qute defaults for
  // scroll-halfpage-down/up; 'u' is skipped here because keybindings.json
  // already claims it for undo.
  const DEFAULT_BINDINGS = {
    j: { cmd: 'scroll-down' },
    k: { cmd: 'scroll-up' },
    h: { cmd: 'scroll-left' },
    l: { cmd: 'scroll-right' },
    d: { cmd: 'scroll-halfpage-down' },
    gg: { cmd: 'scroll-top' },
    G: { cmd: 'scroll-bottom' },
    '<Ctrl-d>': { cmd: 'scroll-halfpage-down' },
    '<Ctrl-u>': { cmd: 'scroll-halfpage-up' },
    '<Space>': { cmd: 'scroll-page-down' },
    '<PageDown>': { cmd: 'scroll-page-down' },
    '/': { cmd: 'find-forward' },
    '?': { cmd: 'find-backward' },
    n: { cmd: 'find-next' },
    N: { cmd: 'find-prev' },
    i: { cmd: 'mode-enter insert' },
    v: { cmd: 'mode-enter caret' },
    f: { cmd: 'hint-links' },
    F: { cmd: 'hint-links-tab' },
  };
  // Object.assign applies DEFAULT_BINDINGS first, then KEYBINDINGS on top —
  // any key present in both ends up with the custom entry, i.e. custom wins.
  const NORMAL_BINDINGS = Object.assign({}, DEFAULT_BINDINGS, KEYBINDINGS);

  function keyToToken(e) {
    // Build the qute-style token for this event: prefer named keys wrapped
    // in <...>, fall back to the literal character for plain keys.
    const namedKeys = {
      Tab: 'Tab', Escape: 'Escape', ArrowLeft: 'Left', ArrowRight: 'Right',
      ArrowUp: 'Up', ArrowDown: 'Down', F1: 'F1', F2: 'F2', F3: 'F3', F4: 'F4',
      F5: 'F5', F6: 'F6', F7: 'F7', F8: 'F8', F9: 'F9', F10: 'F10', F11: 'F11',
      F12: 'F12', Enter: 'Return', Backspace: 'Backspace', Delete: 'Delete',
      ' ': 'Space', PageDown: 'PageDown', PageUp: 'PageUp',
    };
    const mods = [];
    if (e.ctrlKey) mods.push('Ctrl');
    if (e.altKey) mods.push('Alt');
    if (e.shiftKey && (namedKeys[e.key] || e.key.length > 1)) mods.push('Shift');

    let base = namedKeys[e.key] || e.key;

    if (mods.length > 0) {
      return '<' + mods.join('-') + '-' + base + '>';
    }
    if (namedKeys[e.key]) {
      return '<' + base + '>';
    }
    // plain single character (letters/digits/punctuation) — case preserved
    // since qute distinguishes 't' from 'T'.
    return e.key;
  }

  function resetPending() {
    pending = '';
    if (pendingTimer) { clearTimeout(pendingTimer); pendingTimer = null; }
  }

  function armPendingTimeout() {
    if (pendingTimer) clearTimeout(pendingTimer);
    pendingTimer = setTimeout(resetPending, SEQUENCE_TIMEOUT_MS);
  }

  // Resolve a key token stream against the KEYBINDINGS map. Returns
  // { match: entry } | { prefix: true } | null
  function resolveSequence(seq, bindings) {
    bindings = bindings || NORMAL_BINDINGS;
    if (Object.prototype.hasOwnProperty.call(bindings, seq)) {
      return { match: bindings[seq] };
    }
    const isPrefix = Object.keys(bindings).some((k) => k !== seq && k.startsWith(seq));
    if (isPrefix) return { prefix: true };
    return null;
  }

  function handleKeydown(e) {
    if (mode === 'hint') {
      handleHintKey(e);
      return;
    }
    if (mode !== 'normal') {
      if ((mode === 'insert' || mode === 'caret') && e.key === 'Escape') {
        e.preventDefault();
        setMode('normal');
      }
      return; // never intercept keys while in insert/caret/command/find mode
    }
    if (isEditableTarget(document.activeElement)) {
      // focus is in an editable field somewhere in the chrome (not iframe
      // content, which we can't see) — treat as insert-like and skip.
      if (e.key === 'Escape') {
        document.activeElement.blur();
      }
      return;
    }
    if (e.key === ':' ) {
      e.preventDefault();
      resetPending();
      enterCommandMode(':');
      return;
    }

    const token = keyToToken(e);
    const seq = pending + token;
    const result = resolveSequence(seq);

    if (!result) {
      // also try treating this keypress as the START of a new sequence in
      // case `pending` was stale garbage that never matched
      const fresh = resolveSequence(token);
      resetPending();
      if (fresh && fresh.match) {
        e.preventDefault();
        runCommand(fresh.match.cmd);
      } else if (fresh && fresh.prefix) {
        pending = token;
        armPendingTimeout();
        e.preventDefault();
      }
      return;
    }

    if (result.match) {
      e.preventDefault();
      resetPending();
      runCommand(result.match.cmd);
      return;
    }
    if (result.prefix) {
      e.preventDefault();
      pending = seq;
      armPendingTimeout();
    }
  }

  document.addEventListener('keydown', handleKeydown, true);

  // click-away closes any open dropdown menus
  document.addEventListener('click', () => {
    document.querySelectorAll('.dropdown-menu').forEach((m) => m.classList.add('hidden'));
  });

  // ---------------------------------------------------------------------
  // BOOT: seed pinned tabs from MYDATA, wire iframe scroll updates
  // ---------------------------------------------------------------------
  function boot() {
    const pinned = DATA.pinned || [];
    pinned.forEach((p) => {
      const t = makeTab(p.url, { title: p.name, pinned: true });
      tabs.push(t);
    });
    // Always open the start page in a regular tab. Without this the only tabs were
    // the pins, so the tab strip was empty and the pinned Bookmarks page loaded as
    // the landing view -- not what qute does.
    tabs.push(makeTab(DATA.homepage || HOMEPAGE, { title: 'Home' }));

    // The launcher forwards a URL argument as #open=<base64>, because the shell
    // itself must stay the loaded document (see build.sh). Open it as a real tab
    // and focus it, so clicking a link in another app lands where you expect.
    const requested = requestedUrl();
    if (requested) tabs.push(makeTab(requested, {}));

    selectedId = tabs[tabs.length - 1].id;
    setMode('normal');
    render();
    loadSelected();

    if (dom.statusScroll) dom.statusScroll.textContent = '[top]';

    // window.__NAV, published by Rust via the STATE poller (state.js), may
    // report { url, title, loading, can_back, can_forward } for the content
    // browser. It may never arrive (P1/P2 wiring on the Rust side is
    // separate work) — guard every access.
    if (window.STATE && typeof window.STATE.on === 'function') {
      window.STATE.on('nav', applyNavState);
      if (typeof window.STATE.get === 'function') applyNavState(window.STATE.get('nav'));
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

  // ---------------------------------------------------------------------
  // PUBLIC API
  // ---------------------------------------------------------------------
  window.SHELL = {
    openTab,
    closeTab,
    focusTab: selectTab,
    navigate,
    runCommand,
    setStatus,
    showPage,
    hidePage,
    tabs: () => tabs.slice(),
    current: () => currentTab(),
    on,
  };

  // ---------------------------------------------------------------------
  // SELF-CHECK (not auto-run; call demo() from a devtools console)
  // ---------------------------------------------------------------------
  window.demo = function demo() {
    const testBindings = {
      'gD': { cmd: 'open -t qute://downloads' },
      'gI': { cmd: 'open -t qute://history' },
      'gg': { cmd: 'scroll-top' },
      ',d': { cmd: 'open file:///bookmarks.html' },
      '<Ctrl-p>': { cmd: 'tab-pin' },
      '<Ctrl-d>': { cmd: 'scroll-halfpage-down' },
      '<Alt-Left>': { cmd: 'back' },
      '<Shift-Tab>': { cmd: 'tab-prev' },
      '<F5>': { cmd: 'reload' },
      't': { cmd: 'cmd-set-text -s :open -t' },
      '/': { cmd: 'find-forward' },
      'f': { cmd: 'hint-links' },
    };

    // 'g' alone is a known prefix of 'gD'/'gI' -> should report prefix, not match
    let r = resolveSequence('g', testBindings);
    console.assert(r && r.prefix === true, 'demo: "g" should resolve as a pending prefix');

    // 'gD' completes the sequence
    r = resolveSequence('gD', testBindings);
    console.assert(r && r.match && r.match.cmd === 'open -t qute://downloads',
      'demo: "gD" should resolve to the downloads-page command');

    // ',' alone is a prefix of ',d'
    r = resolveSequence(',', testBindings);
    console.assert(r && r.prefix === true, 'demo: "," should resolve as a pending prefix');
    r = resolveSequence(',d', testBindings);
    console.assert(r && r.match && r.match.cmd.startsWith('open file:///bookmarks'),
      'demo: ",d" should resolve to the bookmarks command');

    // modifier-chord form
    r = resolveSequence('<Ctrl-p>', testBindings);
    console.assert(r && r.match && r.match.cmd === 'tab-pin',
      'demo: "<Ctrl-p>" should resolve to tab-pin');

    r = resolveSequence('<Alt-Left>', testBindings);
    console.assert(r && r.match && r.match.cmd === 'back',
      'demo: "<Alt-Left>" should resolve to back');

    r = resolveSequence('<Shift-Tab>', testBindings);
    console.assert(r && r.match && r.match.cmd === 'tab-prev',
      'demo: "<Shift-Tab>" should resolve to tab-prev');

    // single plain key, case-sensitive
    r = resolveSequence('t', testBindings);
    console.assert(r && r.match && r.match.cmd.includes('-s :open -t'),
      'demo: "t" should resolve to the new-tab-prompt command');

    // no match, no prefix -> null
    r = resolveSequence('Z', testBindings);
    console.assert(r === null, 'demo: unbound key "Z" should resolve to null');

    // -- P6: qutebrowser default keymap parsing --------------------------

    // 'gg' (repeated-key sequence): 'g' alone is still a prefix, 'gg' matches
    r = resolveSequence('g', testBindings);
    console.assert(r && r.prefix === true, 'demo: "g" should resolve as a pending prefix (gg)');
    r = resolveSequence('gg', testBindings);
    console.assert(r && r.match && r.match.cmd === 'scroll-top',
      'demo: "gg" should resolve to scroll-top');

    // '<Ctrl-d>' chord (default scroll-halfpage-down binding)
    r = resolveSequence('<Ctrl-d>', testBindings);
    console.assert(r && r.match && r.match.cmd === 'scroll-halfpage-down',
      'demo: "<Ctrl-d>" should resolve to scroll-halfpage-down');

    // '/' find-forward
    r = resolveSequence('/', testBindings);
    console.assert(r && r.match && r.match.cmd === 'find-forward',
      'demo: "/" should resolve to find-forward');

    // 'f' link hints
    r = resolveSequence('f', testBindings);
    console.assert(r && r.match && r.match.cmd === 'hint-links',
      'demo: "f" should resolve to hint-links');

    // custom config wins over the built-in default for a key present in both
    // (e.g. 'u' -> undo in keybindings.json vs. qute's default scroll-halfpage-up)
    console.assert(NORMAL_BINDINGS.u && NORMAL_BINDINGS.u.cmd === 'undo',
      'demo: custom "u" (undo) must win over the DEFAULT_BINDINGS entry');
    console.assert(DEFAULT_BINDINGS.u === undefined,
      'demo: DEFAULT_BINDINGS must not define "u" — keybindings.json already claims it');

    // keyToToken sanity checks using synthetic event-like objects
    const tokCtrlP = keyToToken({ key: 'p', ctrlKey: true, altKey: false, shiftKey: false });
    console.assert(tokCtrlP === '<Ctrl-p>', 'demo: keyToToken ctrl+p -> <Ctrl-p>, got ' + tokCtrlP);

    const tokAltLeft = keyToToken({ key: 'ArrowLeft', ctrlKey: false, altKey: true, shiftKey: false });
    console.assert(tokAltLeft === '<Alt-Left>', 'demo: keyToToken alt+ArrowLeft -> <Alt-Left>, got ' + tokAltLeft);

    const tokF5 = keyToToken({ key: 'F5', ctrlKey: false, altKey: false, shiftKey: false });
    console.assert(tokF5 === '<F5>', 'demo: keyToToken F5 -> <F5>, got ' + tokF5);

    const tokShiftTab = keyToToken({ key: 'Tab', ctrlKey: false, altKey: false, shiftKey: true });
    console.assert(tokShiftTab === '<Shift-Tab>', 'demo: keyToToken shift+Tab -> <Shift-Tab>, got ' + tokShiftTab);

    const tokPlainT = keyToToken({ key: 't', ctrlKey: false, altKey: false, shiftKey: false });
    console.assert(tokPlainT === 't', 'demo: keyToToken plain "t" -> "t", got ' + tokPlainT);

    const tokSpace = keyToToken({ key: ' ', ctrlKey: false, altKey: false, shiftKey: false });
    console.assert(tokSpace === '<Space>', 'demo: keyToToken " " -> <Space>, got ' + tokSpace);

    console.log('[shell] demo() self-checks complete — see console.assert output above for failures');
  };
})();
