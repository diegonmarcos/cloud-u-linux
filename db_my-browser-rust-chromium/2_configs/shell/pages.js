// pages.js — internal chrome pages (qute:// equivalents) for the CEF/Chromium shell.
//
// Rendered into the overlay panel (#pages-body) by shell.js via SHELL.showPage(name)
// and PAGES.render(name, el). Reads live data from window.MYDATA (bookmarks, pinned,
// plugins, keybindings, settings, searchEngines) and window.SHELL (openTab, closeTab,
// focusTab, navigate, runCommand, setStatus, showPage, hidePage, tabs, current, on).
//
// No external resources. No alert()/confirm()/prompt() — those block CEF's message
// loop and would freeze the whole browser window. All confirmations are inline UI.

(function () {
  'use strict';

  // ---------------------------------------------------------------------
  // small helpers
  // ---------------------------------------------------------------------

  function escapeHtml(s) {
    if (s === null || s === undefined) return '';
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function el(tag, attrs, children) {
    const node = document.createElement(tag);
    if (attrs) {
      for (const k in attrs) {
        if (k === 'class') node.className = attrs[k];
        else if (k === 'text') node.textContent = attrs[k];
        else if (k.slice(0, 2) === 'on' && typeof attrs[k] === 'function') node.addEventListener(k.slice(2), attrs[k]);
        else node.setAttribute(k, attrs[k]);
      }
    }
    (children || []).forEach(function (c) {
      if (c === null || c === undefined) return;
      node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    });
    return node;
  }

  function readJSON(key, fallback) {
    try {
      const raw = localStorage.getItem(key);
      if (!raw) return fallback;
      const parsed = JSON.parse(raw);
      return parsed === null || parsed === undefined ? fallback : parsed;
    } catch (e) {
      return fallback;
    }
  }

  function writeJSON(key, value) {
    try {
      localStorage.setItem(key, JSON.stringify(value));
      return true;
    } catch (e) {
      return false;
    }
  }

  function fmtTime(ts) {
    try {
      const d = new Date(ts);
      if (isNaN(d.getTime())) return String(ts);
      return d.toLocaleString();
    } catch (e) {
      return String(ts);
    }
  }

  function MYDATA() {
    return window.MYDATA || {};
  }

  function SHELL() {
    return window.SHELL || null;
  }

  // A minimal page-specific stylesheet, injected exactly once. shell.css owns the
  // real chrome palette/classes; this only fills small gaps (empty-state icon dimming,
  // the color-swatch square, the inline confirm row) that don't obviously map to an
  // existing shell.css class name. Values are restricted to the shell palette so the
  // pages never introduce a new color: #1b1e20 #31363b #2a2e32 #3daee9 #eff0f1 #27ae60.
  let styleInjected = false;
  function ensureStyle() {
    if (styleInjected) return;
    styleInjected = true;
    const css = [
      '.pg-swatch{display:inline-block;width:12px;height:12px;border-radius:2px;',
      'border:1px solid #eff0f1;vertical-align:middle;margin-right:6px}',
      '.pg-empty{opacity:.65;padding:24px 8px}',
      '.pg-confirm{background:#2a2e32;border:1px solid #3daee9;border-radius:3px;padding:8px;margin:6px 0}',
      '.pg-badge{display:inline-block;padding:1px 6px;border-radius:3px;background:#31363b;',
      'color:#eff0f1;font-size:.85em}',
      '.pg-badge-on{background:#27ae60;color:#eff0f1}',
      '.pg-row-hover:hover{background:#2a2e32;cursor:pointer}',
      '.pg-group-title{color:#3daee9;margin:14px 0 4px}',
      '.pg-mono{font-family:inherit;color:#eff0f1}'
    ].join('');
    const style = document.createElement('style');
    style.setAttribute('data-pages-style', '1');
    style.textContent = css;
    document.head.appendChild(style);
  }

  function clearEl(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
  }

  // ---------------------------------------------------------------------
  // history — mybrowser.history
  // ---------------------------------------------------------------------

  const HISTORY_KEY = 'mybrowser.history';
  const HISTORY_CAP = 2000;

  function historyLoad() {
    return readJSON(HISTORY_KEY, []);
  }

  function historySave(list) {
    writeJSON(HISTORY_KEY, list);
  }

  // Record a visit. De-dupes consecutive identical URLs (a reload / SPA push of the
  // same URL doesn't spam the log), newest first, capped at HISTORY_CAP.
  function historyRecord(url, title) {
    if (!url) return;
    const list = historyLoad();
    if (list.length && list[0].url === url) {
      // same URL again (e.g. reload) — just refresh time/title instead of duplicating
      list[0].time = Date.now();
      if (title) list[0].title = title;
    } else {
      list.unshift({ url: url, title: title || url, time: Date.now() });
    }
    if (list.length > HISTORY_CAP) list.length = HISTORY_CAP;
    historySave(list);
  }

  let historyWired = false;
  function wireHistoryRecording() {
    if (historyWired) return;
    const shell = SHELL();
    if (!shell || typeof shell.on !== 'function') return;
    historyWired = true;
    shell.on('navigate', function (payload) {
      payload = payload || {};
      historyRecord(payload.url, payload.title);
    });
    shell.on('tabchange', function (payload) {
      payload = payload || {};
      if (payload.url) historyRecord(payload.url, payload.title);
    });
  }

  function renderHistory(root) {
    ensureStyle();
    wireHistoryRecording();
    clearEl(root);

    const searchBox = el('input', {
      type: 'text',
      placeholder: 'Search history…',
      class: 'pg-mono'
    });
    const clearBtn = el('button', { text: 'Clear history' });
    const confirmRow = el('div', { class: 'pg-confirm', hidden: 'hidden' });
    const table = el('div', {});
    const header = el('div', {}, [
      el('span', { text: 'Time' }),
      el('span', { text: 'Title' }),
      el('span', { text: 'URL' })
    ]);

    function draw(filterText) {
      clearEl(table);
      const q = (filterText || '').toLowerCase();
      const list = historyLoad();
      const filtered = q
        ? list.filter(function (h) {
            return (h.title || '').toLowerCase().indexOf(q) !== -1 || (h.url || '').toLowerCase().indexOf(q) !== -1;
          })
        : list;

      if (filtered.length === 0) {
        table.appendChild(el('div', { class: 'pg-empty', text: q ? 'No matches.' : 'No history yet.' }));
        return;
      }

      filtered.forEach(function (h) {
        const row = el('div', { class: 'pg-row-hover' }, [
          el('span', { text: fmtTime(h.time) }),
          el('span', { text: h.title || h.url }),
          el('span', { text: h.url })
        ]);
        row.addEventListener('click', function () {
          const shell = SHELL();
          if (shell && typeof shell.navigate === 'function') shell.navigate(h.url);
        });
        table.appendChild(row);
      });
    }

    searchBox.addEventListener('input', function () {
      draw(searchBox.value);
    });

    clearBtn.addEventListener('click', function () {
      clearEl(confirmRow);
      confirmRow.hidden = false;
      const msg = el('span', { text: 'Clear all history? This cannot be undone. ' });
      const yes = el('button', { text: 'Yes, clear' });
      const no = el('button', { text: 'Cancel' });
      yes.addEventListener('click', function () {
        historySave([]);
        confirmRow.hidden = true;
        draw(searchBox.value);
        const shell = SHELL();
        if (shell && typeof shell.setStatus === 'function') shell.setStatus('History cleared');
      });
      no.addEventListener('click', function () {
        confirmRow.hidden = true;
      });
      confirmRow.appendChild(msg);
      confirmRow.appendChild(yes);
      confirmRow.appendChild(no);
    });

    root.appendChild(el('h2', { text: 'History' }));
    root.appendChild(el('div', {}, [searchBox, clearBtn]));
    root.appendChild(confirmRow);
    root.appendChild(header);
    root.appendChild(table);
    draw('');
  }

  // ---------------------------------------------------------------------
  // downloads — mybrowser.downloads
  // ---------------------------------------------------------------------
  //
  // ponytail: CEILING — an HTML shell page cannot see, start, or intercept real
  // browser downloads; there is no DOM/JS event for "the underlying CEF browser
  // began saving a file". This page can only display entries that something else
  // (native Rust code) wrote into localStorage. Upgrade path: wire a CefDownloadHandler
  // on the Rust side (OnBeforeDownload / OnDownloadUpdated) that records each
  // download's filename/url/time/status into this same localStorage key (or pushes
  // an IPC message this page listens for) — until that lands, this page is honest
  // about being empty rather than fabricating entries.

  const DOWNLOADS_KEY = 'mybrowser.downloads';

  function downloadsLoad() {
    return readJSON(DOWNLOADS_KEY, []);
  }

  // Rust writes real download data to shell/state/downloads.js (see
  // state.js for the exact wire format); that beats the localStorage stub
  // whenever it exists. Kept as a single point of truth so both the initial
  // draw and the STATE.on callback agree on precedence.
  function downloadsCurrent() {
    if (window.STATE && typeof window.STATE.get === 'function') {
      const fromState = window.STATE.get('downloads');
      if (fromState !== undefined && fromState !== null) return fromState;
    }
    return downloadsLoad();
  }

  // Only one STATE.on('downloads', ...) subscription is ever registered
  // (STATE has no unsubscribe); repeated visits to this page just repoint
  // downloadsRedraw at the latest draw(). draw() itself no-ops once its
  // table has been detached from the DOM, so a stale subscription from a
  // page the user has since navigated away from does nothing.
  let downloadsRedraw = null;
  let downloadsSubscribed = false;

  function renderDownloads(root) {
    ensureStyle();
    clearEl(root);

    const clearBtn = el('button', { text: 'Clear list' });
    const table = el('div', {});
    const header = el('div', {}, [
      el('span', { text: 'Filename' }),
      el('span', { text: 'URL' }),
      el('span', { text: 'Progress' }),
      el('span', { text: 'Status' }),
      el('span', { text: 'Time' })
    ]);

    function draw() {
      if (!table.isConnected) return; // page navigated away; nothing to redraw
      clearEl(table);
      const list = downloadsCurrent();
      if (!list || list.length === 0) {
        table.appendChild(
          el('div', { class: 'pg-empty' }, [
            el('p', {
              text:
                'No downloads yet. The Rust shell has not written shell/state/downloads.js — ' +
                'once it wires up a download handler and starts writing entries there, this ' +
                'page updates automatically.'
            })
          ])
        );
        return;
      }
      list.forEach(function (d) {
        const state = d.state || d.status || 'unknown';
        const pct = typeof d.percent === 'number' ? Math.round(d.percent) + '%' : '';
        const when = d.timestamp !== undefined ? d.timestamp : d.time;
        table.appendChild(
          el('div', {}, [
            el('span', { text: d.filename || '(unknown)' }),
            el('span', { text: d.url || '' }),
            el('span', { text: pct }),
            el('span', { text: state }),
            el('span', { text: fmtTime(when) })
          ])
        );
      });
    }

    clearBtn.addEventListener('click', function () {
      writeJSON(DOWNLOADS_KEY, []);
      draw();
    });

    root.appendChild(el('h2', { text: 'Downloads' }));
    root.appendChild(clearBtn);
    root.appendChild(header);
    root.appendChild(table);
    draw();

    downloadsRedraw = draw;
    if (!downloadsSubscribed && window.STATE && typeof window.STATE.on === 'function') {
      downloadsSubscribed = true;
      window.STATE.on('downloads', function () {
        if (typeof downloadsRedraw === 'function') downloadsRedraw();
      });
    }
  }

  // ---------------------------------------------------------------------
  // config — read-only view of MYDATA.settings
  // ---------------------------------------------------------------------

  const HEX_RE = /^#[0-9a-f]{3,8}$/i;

  function flattenSettings(obj, prefix, out) {
    if (obj === null || obj === undefined) return out;
    if (typeof obj !== 'object' || Array.isArray(obj)) {
      out.push({ key: prefix, value: obj });
      return out;
    }
    for (const k in obj) {
      if (!Object.prototype.hasOwnProperty.call(obj, k)) continue;
      if (k.charAt(0) === '_') continue; // skip _description / _note / etc
      const path = prefix ? prefix + '.' + k : k;
      const v = obj[k];
      if (v && typeof v === 'object' && !Array.isArray(v)) {
        flattenSettings(v, path, out);
      } else {
        out.push({ key: path, value: Array.isArray(v) ? v.join(', ') : v });
      }
    }
    return out;
  }

  function renderConfig(root) {
    ensureStyle();
    clearEl(root);
    const settings = MYDATA().settings || {};

    const groups = {
      colors: flattenSettings(settings.colors, 'colors', []),
      fonts: flattenSettings(settings.fonts, 'fonts', []),
      other: []
    };
    for (const k in settings) {
      if (!Object.prototype.hasOwnProperty.call(settings, k)) continue;
      if (k.charAt(0) === '_' || k === 'colors' || k === 'fonts') continue;
      flattenSettings(settings[k], k, groups.other);
    }

    root.appendChild(el('h2', { text: 'Config' }));

    ['colors', 'fonts', 'other'].forEach(function (groupName) {
      const rows = groups[groupName];
      if (!rows.length) return;
      root.appendChild(el('h3', { class: 'pg-group-title', text: groupName }));
      const box = el('div', {});
      rows.forEach(function (row) {
        const valStr = String(row.value);
        const line = [];
        if (HEX_RE.test(valStr)) {
          const swatch = el('span', { class: 'pg-swatch' });
          swatch.style.background = valStr;
          line.push(swatch);
        }
        line.push(el('span', { class: 'pg-mono', text: row.key }));
        line.push(el('span', { class: 'pg-mono', text: valStr }));
        box.appendChild(el('div', {}, line));
      });
      root.appendChild(box);
    });

    if (!groups.colors.length && !groups.fonts.length && !groups.other.length) {
      root.appendChild(el('div', { class: 'pg-empty', text: 'No settings available (MYDATA.settings is empty).' }));
    }
  }

  // ---------------------------------------------------------------------
  // plugins — MYDATA.plugins, grouped by surface
  // ---------------------------------------------------------------------

  const PLUGIN_STATE_KEY = 'mybrowser.plugins';

  function pluginStateLoad() {
    return readJSON(PLUGIN_STATE_KEY, {});
  }

  function pluginStateSave(state) {
    writeJSON(PLUGIN_STATE_KEY, state);
  }

  function renderPlugins(root) {
    ensureStyle();
    clearEl(root);
    const plugins = MYDATA().plugins || [];

    root.appendChild(el('h2', { text: 'Plugins' }));

    const bySurface = { config: [], userscript: [], daemon: [] };
    plugins.forEach(function (p) {
      const surface = p.surface || 'config';
      if (!bySurface[surface]) bySurface[surface] = [];
      bySurface[surface].push(p);
    });

    const state = pluginStateLoad();

    const surfaceLabel = {
      config: 'Config — runtime-toggleable settings',
      userscript: 'Userscript — runs only when invoked',
      daemon: 'Daemon — system service, always running independently'
    };

    ['config', 'userscript', 'daemon'].forEach(function (surface) {
      const list = bySurface[surface] || [];
      if (!list.length) return;
      root.appendChild(el('h3', { class: 'pg-group-title', text: surfaceLabel[surface] || surface }));

      list.forEach(function (p) {
        const nameEl = el('strong', { text: p.name || p.id });
        const badge = el('span', { class: 'pg-badge', text: surface });
        const desc = el('div', { text: p.description || '' });
        const rowChildren = [nameEl, ' ', badge];

        if (surface === 'config' && p.option) {
          const savedOn = Object.prototype.hasOwnProperty.call(state, p.id) ? !!state[p.id] : !!p.enabled;
          const toggle = el('button', {
            text: savedOn ? 'On — click to disable' : 'Off — click to enable',
            class: savedOn ? 'pg-badge-on' : ''
          });
          toggle.addEventListener('click', function () {
            const nextOn = !(Object.prototype.hasOwnProperty.call(state, p.id) ? !!state[p.id] : !!p.enabled);
            state[p.id] = nextOn;
            pluginStateSave(state);
            const shell = SHELL();
            const value = nextOn ? p.on_value : p.off_value;
            if (shell && typeof shell.runCommand === 'function') {
              shell.runCommand('config-cycle ' + p.option + ' ' + p.on_value + ' ' + p.off_value);
            }
            toggle.textContent = nextOn ? 'On — click to disable' : 'Off — click to enable';
            toggle.className = nextOn ? 'pg-badge-on' : '';
            if (shell && typeof shell.setStatus === 'function') {
              shell.setStatus(p.name + ' -> ' + (nextOn ? p.on_value : p.off_value) + ' (' + value + ')');
            }
          });
          rowChildren.push(' ', toggle);
        } else {
          const why =
            surface === 'userscript'
              ? 'Userscripts run only on invocation (a keybinding or command spawns them) — there is no persistent on/off state to toggle here.'
              : 'Daemons are external system services managed outside the browser (systemd user units) — this page cannot start/stop them.';
          rowChildren.push(' ', el('span', { text: why }));
        }

        root.appendChild(el('div', {}, rowChildren));
        root.appendChild(desc);
      });
    });

    if (!plugins.length) {
      root.appendChild(el('div', { class: 'pg-empty', text: 'No plugins available (MYDATA.plugins is empty).' }));
    }
  }

  // ---------------------------------------------------------------------
  // shortcuts — MYDATA.keybindings.normal, grouped by `group`
  // ---------------------------------------------------------------------

  function renderShortcuts(root) {
    ensureStyle();
    clearEl(root);
    const keybindings = MYDATA().keybindings || {};
    const normal = keybindings.normal || {};

    // normalize: skip non-object entries (e.g. stray _comment_* strings)
    const entries = [];
    for (const key in normal) {
      if (!Object.prototype.hasOwnProperty.call(normal, key)) continue;
      const v = normal[key];
      if (!v || typeof v !== 'object') continue;
      entries.push({ key: key, cmd: v.cmd || '', desc: v.desc || '', group: v.group || 'Other' });
    }

    const searchBox = el('input', { type: 'text', placeholder: 'Search shortcuts…', class: 'pg-mono' });
    const body = el('div', {});

    function draw(filterText) {
      clearEl(body);
      const q = (filterText || '').toLowerCase();
      const filtered = q
        ? entries.filter(function (e2) {
            return (
              e2.key.toLowerCase().indexOf(q) !== -1 ||
              e2.desc.toLowerCase().indexOf(q) !== -1 ||
              e2.cmd.toLowerCase().indexOf(q) !== -1
            );
          })
        : entries;

      if (!filtered.length) {
        body.appendChild(el('div', { class: 'pg-empty', text: 'No matches.' }));
        return;
      }

      const groups = {};
      const order = [];
      filtered.forEach(function (e2) {
        if (!groups[e2.group]) {
          groups[e2.group] = [];
          order.push(e2.group);
        }
        groups[e2.group].push(e2);
      });

      order.forEach(function (g) {
        body.appendChild(el('h3', { class: 'pg-group-title', text: g }));
        const header = el('div', {}, [
          el('span', { text: 'Key' }),
          el('span', { text: 'Description' }),
          el('span', { text: 'Command' })
        ]);
        body.appendChild(header);
        groups[g].forEach(function (e2) {
          body.appendChild(
            el('div', {}, [
              el('span', { class: 'pg-mono', text: e2.key }),
              el('span', { text: e2.desc }),
              el('span', { class: 'pg-mono', text: e2.cmd })
            ])
          );
        });
      });
    }

    searchBox.addEventListener('input', function () {
      draw(searchBox.value);
    });

    root.appendChild(el('h2', { text: 'Shortcuts' }));
    root.appendChild(searchBox);
    root.appendChild(body);
    draw('');
  }

  // ---------------------------------------------------------------------
  // bookmarks — MYDATA.bookmarks
  // ---------------------------------------------------------------------

  function renderBookmarks(root) {
    ensureStyle();
    clearEl(root);
    const bookmarks = MYDATA().bookmarks || [];

    root.appendChild(el('h2', { text: 'Bookmarks' }));

    if (!bookmarks.length) {
      root.appendChild(el('div', { class: 'pg-empty', text: 'No bookmarks available (MYDATA.bookmarks is empty).' }));
      return;
    }

    function navigateTo(url) {
      const shell = SHELL();
      if (shell && typeof shell.navigate === 'function') shell.navigate(url);
    }

    bookmarks.forEach(function (b) {
      if (b && b.links && typeof b.links === 'object') {
        // dropdown entry: {name, icon?, links: {label: url}}
        root.appendChild(el('h3', { class: 'pg-group-title', text: (b.icon ? b.icon + ' ' : '') + (b.name || '') }));
        const box = el('div', {});
        for (const label in b.links) {
          if (!Object.prototype.hasOwnProperty.call(b.links, label)) continue;
          const url = b.links[label];
          const row = el('div', { class: 'pg-row-hover' }, [
            el('span', { text: label }),
            el('span', { class: 'pg-mono', text: url })
          ]);
          row.addEventListener('click', function () {
            navigateTo(url);
          });
          box.appendChild(row);
        }
        root.appendChild(box);
      } else if (b && b.url) {
        // simple entry: {name, icon?, url}
        const row = el('div', { class: 'pg-row-hover' }, [
          el('span', { text: (b.icon ? b.icon + ' ' : '') + (b.name || b.url) }),
          el('span', { class: 'pg-mono', text: b.url })
        ]);
        row.addEventListener('click', function () {
          navigateTo(b.url);
        });
        root.appendChild(row);
      }
    });
  }

  // ---------------------------------------------------------------------
  // registry
  // ---------------------------------------------------------------------

  const PAGE_RENDERERS = {
    history: renderHistory,
    downloads: renderDownloads,
    config: renderConfig,
    plugins: renderPlugins,
    shortcuts: renderShortcuts,
    bookmarks: renderBookmarks
  };

  function render(name, targetEl) {
    const root = targetEl || document.getElementById('pages-body');
    if (!root) return false;
    const fn = PAGE_RENDERERS[name];
    if (!fn) {
      clearEl(root);
      root.appendChild(el('div', { class: 'pg-empty', text: 'Unknown page: ' + escapeHtml(name) }));
      return false;
    }
    fn(root);
    return true;
  }

  function list() {
    return Object.keys(PAGE_RENDERERS);
  }

  window.PAGES = { render: render, list: list };

  // ---------------------------------------------------------------------
  // self-check (console.assert only — not auto-run)
  // ---------------------------------------------------------------------

  window.PAGES._demo = function demo() {
    const key = HISTORY_KEY;
    const backup = localStorage.getItem(key);
    try {
      historySave([]);
      historyRecord('https://example.com/a', 'A');
      historyRecord('https://example.com/a', 'A again'); // consecutive dup -> should NOT add a new row
      console.assert(historyLoad().length === 1, 'demo: consecutive duplicate URL should not create a new entry');
      historyRecord('https://example.com/b', 'B');
      console.assert(historyLoad().length === 2, 'demo: distinct URL should add a new entry');
      console.assert(historyLoad()[0].url === 'https://example.com/b', 'demo: newest entry should be first');

      // cap holding: push past HISTORY_CAP and confirm it clamps
      const many = [];
      for (let i = 0; i < HISTORY_CAP + 50; i++) {
        many.push({ url: 'https://example.com/' + i, title: 't' + i, time: i });
      }
      historySave(many);
      // simulate one more record beyond the cap
      historyRecord('https://example.com/new', 'new');
      console.assert(historyLoad().length === HISTORY_CAP, 'demo: history should be capped at ' + HISTORY_CAP);
      console.assert(historyLoad()[0].url === 'https://example.com/new', 'demo: cap should keep the newest entry, not drop it');
    } finally {
      if (backup === null) localStorage.removeItem(key);
      else localStorage.setItem(key, backup);
    }
  };
})();
