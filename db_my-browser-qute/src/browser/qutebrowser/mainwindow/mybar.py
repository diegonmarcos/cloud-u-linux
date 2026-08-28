# SPDX-License-Identifier: GPL-3.0-or-later

"""my-browser (qute) fork: persistent bookmark + plugin chrome bar.

A native, always-visible toolbar shown at the top of every window's content
column (added to the main VBox in mainwindow._add_widgets). It is fully
DATA-DRIVEN: it reads `mybar.json` from qutebrowser's config dir, which the
my-browser home-manager module generates from qute-bookmarks.json (bookmark
folders + top-level links) and qute-plugins.json (enabled plugins, e.g.
Vaultwarden). No data is hardcoded here.

mybar.json schema:
  {
    "bookmarks": [
      {"name": "github", "icon": "", "url": "https://github.com/..."},
      {"name": "Dev", "icon": "", "links": {"mdn": "https://...", ...}}
    ],
    "plugins": [
      {"name": "Vaultwarden", "icon": "", "command": "spawn --userscript qute-bitwarden"}
    ]
  }

A `links` entry renders as a folder dropdown (QMenu); a bare `url` entry as a
single button. Plugins are separated from bookmarks by a divider and trigger a
qutebrowser command. Missing/invalid JSON → an empty (hidden) bar, never a crash.

This module ALSO mirrors qutebrowser's own browsing history to
history-recent.js in the DATA dir (~/.local/share/qutebrowser/, never the
config dir home-manager symlinks read-only) as `window.QUTE_HISTORY_RECENT =
[...]`. The dashboard (a file:// page) cannot fetch() qute://history/data —
verified empirically: WebEngine's LocalAccessAllowed scheme flag permits
<script src> and similar resource loads across local schemes/directories, but
NOT fetch()/XHR (CORS-mode network requests are still blocked). A same-origin
JS-file <script src> load sidesteps that wall entirely, so the dashboard reads
real history without qutebrowser needing to expose a network-facing API.

The dump is EVENT-DRIVEN off `history.web_history.changed` (a generic
pyqtSignal on qutebrowser's SqlTable base, fired on every insert/delete) —
not a poll — debounced so a burst of rapid navigations coalesces into one
write instead of one per page.
"""

import os
import json
import time
import functools

from qutebrowser.qt.core import QUrl, QTimer, Qt
from qutebrowser.qt.widgets import QToolBar, QToolButton, QMenu, QTabBar
from qutebrowser.commands import runners
from qutebrowser.browser import history
from qutebrowser.utils import objreg, standarddir, log


def _config_path():
    """Path to the data-driven bar spec (overridable for tests/standalone)."""
    return os.environ.get(
        'QUTE_MYBAR_JSON', os.path.join(standarddir.config(), 'mybar.json'))


def _load():
    try:
        with open(_config_path(), encoding='utf-8') as f:
            data = json.load(f)
    except OSError:
        data = {}
    except ValueError:
        log.misc.warning("my-browser bar: invalid JSON in %s" % _config_path())
        data = {}
    # Fall through so every key is defaulted in ONE place. The old early
    # returns omitted 'pinned', so seed_pinned's _load()['pinned'] raised
    # KeyError and killed startup whenever mybar.json was missing or invalid
    # (a fresh profile, or --temp-basedir).
    data.setdefault('bookmarks', [])
    data.setdefault('pinned', [])
    data.setdefault('plugins', [])
    return data


# ponytail: fixed cap, not configurable — this is a "recent history" widget,
# not a full history browser (qute://history already covers that; the
# dashboard's "Full History" link opens it). Raise if 40 ever feels tight.
HISTORY_DUMP_LIMIT = 40
HISTORY_DUMP_DEBOUNCE_MS = 1500


def _history_dump_path():
    return os.environ.get(
        'QUTE_HISTORY_DUMP_JS',
        os.path.join(standarddir.data(), 'history-recent.js'))


def _dump_history():
    """Write recent history as a JS global — see module docstring for why."""
    try:
        entries = history.web_history.entries_before(
            time.time(), limit=HISTORY_DUMP_LIMIT, offset=0)
        rows = [{'url': e.url, 'title': e.title or e.url, 'time': e.atime}
                for e in entries]
        js = 'window.QUTE_HISTORY_RECENT = ' + json.dumps(rows) + ';\n'
        path = _history_dump_path()
        tmp = path + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(js)
        os.replace(tmp, path)  # atomic — dashboard never sees a half-written file
    except Exception:
        log.misc.exception("my-browser bar: history dump failed")


# One shared debounce timer per process (history.web_history is a
# process-wide singleton — one dump target regardless of window count).
_dump_debounce = None


def _schedule_dump():
    global _dump_debounce
    if _dump_debounce is None:
        _dump_debounce = QTimer()
        _dump_debounce.setSingleShot(True)
        _dump_debounce.timeout.connect(_dump_history)
    _dump_debounce.start(HISTORY_DUMP_DEBOUNCE_MS)


def _init_history_dump():
    """Wire the event-driven dump once per process (idempotent)."""
    if getattr(history.web_history, '_mybar_dump_wired', False):
        return
    history.web_history.changed.connect(_schedule_dump)
    history.web_history._mybar_dump_wired = True
    _schedule_dump()  # cover history already loaded from a previous session


class MyBar(QToolBar):

    """The bookmark + plugin chrome bar."""

    def __init__(self, win_id, parent=None):
        super().__init__(parent)
        self.setObjectName('MyBar')
        self.setMovable(False)
        self.setFloatable(False)
        self.setContentsMargins(0, 0, 0, 0)
        self._win_id = win_id
        self.rebuild()
        _init_history_dump()

    def rebuild(self):
        """(Re)populate the bar from mybar.json. Hidden when empty."""
        self.clear()
        data = _load()
        for entry in data['bookmarks']:
            self._add_bookmark(entry)
        plugins = data['plugins']
        if plugins:
            if data['bookmarks']:
                self.addSeparator()
            for plugin in plugins:
                self._add_plugin(plugin)
        self.setVisible(bool(data['bookmarks'] or plugins))

    def _button(self, entry, fallback):
        btn = QToolButton(self)
        btn.setText(entry.get('icon') or entry.get('name') or fallback)
        btn.setToolTip(entry.get('name', ''))
        btn.setAutoRaise(True)
        return btn

    def _add_bookmark(self, entry):
        links = entry.get('links') or {}
        if not links and entry.get('url'):
            btn = self._button(entry, '?')
            btn.clicked.connect(functools.partial(self._open, entry['url']))
            self.addWidget(btn)
            return
        # Folder → instant-popup dropdown menu.
        btn = self._button(entry, '')
        btn.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        menu = QMenu(btn)
        for label, url in links.items():
            act = menu.addAction(label)
            act.triggered.connect(functools.partial(self._open, url))
        btn.setMenu(menu)
        self.addWidget(btn)

    def _add_plugin(self, plugin):
        btn = self._button(plugin, '')
        cmd = plugin.get('command')
        if cmd:
            btn.clicked.connect(functools.partial(self._run, cmd))
        else:
            btn.setEnabled(False)
        self.addWidget(btn)

    def _open(self, url):
        try:
            tabbed = objreg.get('tabbed-browser', scope='window',
                                window=self._win_id)
            tabbed.tabopen(QUrl(url))
        except Exception:
            log.misc.exception("my-browser bar: failed to open %s" % url)

    def _run(self, cmd):
        try:
            runners.CommandRunner(self._win_id).run_safely(cmd)
        except Exception:
            log.misc.exception("my-browser bar: failed to run '%s'" % cmd)


class PinBar(QTabBar):

    """Row 2: the window's PINNED TABS — real tabs, not links.

    This is a live mirror of every tab whose `data.pinned` is set, in the same
    TabbedBrowser as row 3. TabBar (row 3) gives pinned tabs zero size and
    skips them in paintEvent, so each tab is drawn in exactly one row: pinned
    here, everything else below. Selecting one here selects the real tab.

    `:tab-pin` on any tab therefore promotes it into this row and `:tab-pin`
    again drops it back down — the row is qutebrowser's own pinned-tab model,
    not a separate bookmark list. mybar.json's `pinned` entries only SEED the
    row on window creation (see seed_pinned).
    """

    def __init__(self, win_id, parent=None):
        super().__init__(parent)
        self.setObjectName('PinBar')
        self._win_id = win_id
        self._indices = []
        self.setDrawBase(False)
        self.setExpanding(False)
        self.setMovable(False)
        self.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.currentChanged.connect(self._on_selected)
        self.setVisible(False)

    def _widget(self):
        return objreg.get('tabbed-browser', scope='window',
                          window=self._win_id).widget

    def sync(self):
        """Rebuild from the real tab list. Cheap; called on every tab change.

        A pinned tab is labelled with mybar.json's `name` when it has one --
        the watchdog page calls itself "watchdog exports", and the row should
        say what the user named it. Tabs pinned by hand are not in mybar.json
        and keep their page title.
        """
        try:
            widget = self._widget()
        except KeyError:
            return  # window still being constructed
        self.blockSignals(True)  # rebuilding must not re-enter _on_selected
        try:
            while self.count():
                self.removeTab(0)
            self._indices = []
            # Built once per sync, not per tab: sync runs on every tab change
            # and _load() re-reads mybar.json from disk each call.
            names = {_url_key(QUrl(e['url'])): e.get('name')
                     for e in _load()['pinned'] if e.get('url')}
            for i in range(widget.count()):
                tab = widget.widget(i)
                if tab is not None and tab.data.pinned:
                    title = widget.page_title(i) or ''
                    self.addTab(names.get(_pinned_tab_url(tab)) or title)
                    self._indices.append(i)
            cur = widget.currentIndex()
            self.setCurrentIndex(
                self._indices.index(cur) if cur in self._indices else -1)
        finally:
            self.blockSignals(False)
        self.setVisible(bool(self._indices))

    def _on_selected(self, idx):
        if 0 <= idx < len(self._indices):
            try:
                self._widget().setCurrentIndex(self._indices[idx])
            except KeyError:
                pass


def sync_pinned(win_id):
    """Refresh a window's PinBar. Safe to call before the bar exists."""
    win = objreg.window_registry.get(win_id)
    bar = getattr(win, '_pinbar', None)
    if bar is not None:
        bar.sync()


# Two URLs name the same pinned page when they differ only by fragment or a
# trailing slash. The filebrowser at :8000 is a hash-routed SPA that lands on
# ".../#/", so the raw string never equalled mybar.json's ":8000" and the tab
# was re-seeded on every launch. Dropping the fragment also means whatever
# route the SPA is on still counts as the one pinned tab, which is what a
# pinned tab means.
_URL_KEY_OPTS = (QUrl.UrlFormattingOption.RemoveFragment
                 | QUrl.UrlFormattingOption.StripTrailingSlash
                 | QUrl.UrlFormattingOption.NormalizePathSegments)


def _url_key(url):
    """Canonical form used to decide whether two URLs are the same pinned page."""
    # rstrip: StripTrailingSlash leaves the ROOT slash alone, so ":8000" and
    # ":8000/" would still differ without it.
    return url.adjusted(_URL_KEY_OPTS).toString().rstrip('/')


def _pinned_tab_url(tab):
    """Best-effort URL for a pinned tab that may not have loaded yet.

    url() is empty until the page commits, and with a lazy session restore it
    stays empty until the tab is focused -- so a restored pinned tab was
    invisible to seed_pinned's dedupe and got seeded a second time on every
    single launch. Fall back to the requested URL, then to the session history
    entry, so a tab is identifiable before it ever loads.
    """
    candidates = [tab.url(), tab.url(requested=True)]
    try:
        if len(tab.history) > 0:
            candidates.append(tab.history.current_item().url())
    except Exception:  # pragma: no cover - history access is backend-specific
        pass
    for url in candidates:
        if url.isValid() and not url.isEmpty():
            return _url_key(url)
    return None


def seed_pinned(win_id):
    """Open mybar.json's `pinned` URLs as real pinned tabs, once per window.

    ponytail: seeds by URL only — a seeded tab the user later unpins stays
    unpinned for that window's life, but comes back in the next window. Persist
    per-window state only if that turns out to matter.
    """
    entries = [e for e in _load()['pinned'] if e.get('url')]
    if not entries:
        return
    try:
        tabbed = objreg.get('tabbed-browser', scope='window', window=win_id)
    except KeyError:
        return
    # Dedupe against PINNED tabs only. url.start_pages opens the bookmarks page
    # as an ordinary row-3 tab, and counting that as "already open" would
    # suppress the row-2 pinned copy of the same page. A restored *pinned* tab
    # still dedupes, which is the case this guard exists for.
    pinned_tabs = [w for w in (tabbed.widget.widget(i)
                               for i in range(tabbed.widget.count()))
                   if getattr(w, 'data', None) is not None and w.data.pinned]
    open_urls = set()
    for tab in pinned_tabs:
        url = _pinned_tab_url(tab)
        if url is None:
            continue
        if url in open_urls:
            # Self-heal. Seeding used to be invisible to its own dedupe, so
            # every launch restored the pinned row and then seeded it again;
            # existing sessions carry several copies of each entry. Closing an
            # exact-URL duplicate of a tab we already counted converges the row
            # back to one tab per mybar.json entry.
            log.misc.debug("my-browser bar: closing duplicate pinned %s" % url)
            tabbed.close_tab(tab, add_undo=False)
            continue
        open_urls.add(url)
    for entry in entries:
        url = QUrl(entry['url'])
        if _url_key(url) in open_urls:
            continue
        try:
            tab = tabbed.tabopen(url, background=True)
            tab.set_pinned(True)
        except Exception:
            log.misc.exception(
                "my-browser bar: failed to seed pinned %s" % entry['url'])
    sync_pinned(win_id)


def install(win_id, pinbar, tabbed_widget):
    """Wire a window's PinBar: follow tab selection, then seed the pinned row.

    ponytail: seeding is deferred by SEED_DELAY_MS so a restored session's tabs
    are already open and the URL dedupe in seed_pinned can see them — otherwise
    a restored pinned tab would be duplicated. If a slow session restore ever
    outruns it, hook the session-load-finished path instead of waiting.
    """
    tabbed_widget.currentChanged.connect(lambda _idx: pinbar.sync())
    QTimer.singleShot(SEED_DELAY_MS, functools.partial(seed_pinned, win_id))


SEED_DELAY_MS = 500
