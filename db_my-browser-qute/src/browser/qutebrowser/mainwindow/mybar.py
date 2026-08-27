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

from qutebrowser.qt.core import QUrl, QTimer
from qutebrowser.qt.widgets import QToolBar, QToolButton, QMenu
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
        return {'bookmarks': [], 'plugins': []}
    except ValueError:
        log.misc.warning("my-browser bar: invalid JSON in %s" % _config_path())
        return {'bookmarks': [], 'plugins': []}
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


class PinBar(MyBar):

    """Row 2: pinned tabs — fixed shortcuts from mybar.json's `pinned` list.

    Row 1 is MyBar (bookmarks + plugins), row 3 is qutebrowser's own tab bar,
    which already sits directly below us when tabs.position is 'top'.

    ponytail: these are shortcut buttons, not real pinned tabs — clicking one
    opens it in a new tab like any bookmark. Promote to genuine pinned tabs
    (tabbed_browser.widget.set_tab_pinned) only if the always-open-and-reused
    semantics are actually wanted.
    """

    def __init__(self, win_id, parent=None):
        super().__init__(win_id, parent)
        self.setObjectName('PinBar')

    def rebuild(self):
        pinned = _load()['pinned']
        self.clear()
        for entry in pinned:
            self._add_bookmark(entry)
        self.setVisible(bool(pinned))
