#!/usr/bin/env python3
"""linux-store TUI — cloud-superapp's Store screen, curses, every verb a page.

Tabs (1-5 / Tab):
  Cloud Constellation  the declaration realised: groups (Apps Libs Configs
                       Secrets) · StoreBar · chips · table by app · details
  Phone Apps           what is on this box, as cards, filtered by origin
  Generations          every generation: live marker, counts, built; switch
                       to one, roll back, diff against the live one
  Declaration          `show`: what the declaration resolves to, by layer;
                       edit, build, switch, update
  Status               status · summary · dev mode · pages · check/repair/gc
Every key runs a `linux-store` verb. Stdlib only.
"""
import curses, json, os, re, subprocess

BIN = os.environ.get("LINUX_STORE_BIN") or "linux-store"
ROOT = os.environ.get("LINUX_STORE_ROOT") or os.path.expanduser("~/.linux-store")
HOME = os.path.expanduser("~")
TABS = ["Cloud Constellation", "Phone Apps", "Generations", "Declaration", "Status"]
GROUPS = [("bin", "Apps"), ("lib", "Libs"), ("cfg", "Configs"), ("secret", "Secrets")]
BLURB = {"bin": "Full constellation apps — install, update, open, remove. Binaries on PATH: host, fetched releases, local builds, wrappers.",
         "lib": "One object per library: .so farms and script libs, never exported globally.",
         "cfg": "Configs: etc (linked through current) and activate (rendered real files).",
         "secret": "Secrets: names and modes only. Decrypted at switch, never in the store."}
CHIPS = [("all", "All"), ("absent", "◯ Absent"), ("present", "✓ Present")]
ORIGIN = {"host": "host", "host+wrap": "host", "fetch": "Cloud release", "path": "local build", "self": "self",
          "absent": "absent", "render": "render", "keys": "keys", "file": "vault file", "sops": "sops", "template": "template"}
SW, DH = 22, 7     # sidebar width, details pane height


def sh(*args, timeout=600):
    try:
        r = subprocess.run([BIN, *args], capture_output=True, text=True, timeout=timeout)
        return r.stdout + r.stderr
    except Exception as e:
        return f"{BIN} {' '.join(args)}: {e}\n"


def readlink(p):
    try:
        return os.readlink(p)
    except Exception:
        return ""


def load(p):
    try:
        return json.load(open(p))
    except Exception:
        return None


def app_of(e):
    if e.get("app"):
        return e["app"]
    return "host" if e["kind"] in ("host", "host+wrap") else "other"


def meta_of(e):
    if e["layer"] == "secret":
        try:
            return "mode " + json.loads(e["source"])["mode"]
        except Exception:
            return "secret"
    if e["kind"] == "absent":
        return "not installed  ·  " + e["source"].rsplit("/", 1)[-1]
    t = e["target"]
    if t.startswith(HOME + "/"):
        t = "~/" + t[len(HOME) + 1:]
    if "/store/" in t:
        t = "store/" + t.split("/store/", 1)[1]
    return t


class App:
    def __init__(self, scr):
        self.scr = scr
        curses.curs_set(0); curses.use_default_colors()
        for i, fg in enumerate([curses.COLOR_GREEN, curses.COLOR_RED, curses.COLOR_YELLOW, curses.COLOR_BLUE, curses.COLOR_MAGENTA, 8, curses.COLOR_CYAN], 1):
            curses.init_pair(i, fg, -1)
        self.ok, self.bad, self.warn, self.blue, self.mag, self.dim, self.cyan = [curses.color_pair(i) for i in range(1, 8)]
        self.tab = 0
        self.side = {t: 0 for t in range(5)}       # sidebar selection per tab
        self.chip = 0
        self.row = self.top = 0
        self.filter = ""
        self.msg = ""
        self.detail_text = []                         # extra lines for the details pane (diff output etc.)
        self.reload()

    # ── data ──────────────────────────────────────────────────────────────
    def reload(self):
        live = readlink(os.path.join(ROOT, "current"))
        self.gen = os.path.basename(live) if live else "none"
        self.m = load(os.path.join(live, "manifest.json")) or {"entries": [], "objects": []}
        self.profile = sh("profile", timeout=20).strip() or "?"
        self.summary = (open(os.path.join(ROOT, "ui", "summary.txt")).read().strip() if os.path.exists(os.path.join(ROOT, "ui", "summary.txt")) else "not switched yet — Install all builds the first generation")
        try:
            self.size = subprocess.run(["du", "-sh", os.path.join(ROOT, "store")], capture_output=True, text=True).stdout.split()[0]
        except Exception:
            self.size = "?"
        self.gens = []
        gd = os.path.join(ROOT, "generations")
        if os.path.isdir(gd):
            for g in sorted(os.listdir(gd), key=lambda n: (n.rsplit("-", 1)[0], int(n.rsplit("-", 1)[1]) if n.rsplit("-", 1)[-1].isdigit() else 0)):
                mf = load(os.path.join(gd, g, "manifest.json"))
                if mf:
                    self.gens.append((g, mf))
        self.dev = []
        dl = os.path.join(ROOT, "dev.list")
        if os.path.exists(dl):
            self.dev = [l.strip() for l in open(dl) if l.strip()]
        self.decl = None
        self.plan = None

    def entries(self, group, chip="all", m=None):
        m = m or self.m
        def in_group(e):
            if group == "cfg":
                return e["layer"] in ("etc", "activate")
            if group == "all":
                return True
            return e["layer"] == group
        es = [e for e in m["entries"] if in_group(e)]
        if chip == "absent":
            es = [e for e in es if e["kind"] == "absent"]
        elif chip == "present":
            es = [e for e in es if e["kind"] != "absent"]
        return sorted(es, key=lambda e: (app_of(e), e["name"].lower()))

    def counts(self, group, m=None):
        es = self.entries(group, m=m)
        a = sum(1 for e in es if e["kind"] == "absent")
        return len(es), len(es) - a, a

    def origins(self):
        o = {}
        for e in self.entries("all"):
            k = ORIGIN.get(e["kind"], e["kind"]); o[k] = o.get(k, 0) + 1
        return sorted(o.items())

    def plan_rows(self):
        if self.plan is None:
            self.plan = []
            for ln in sh("show", timeout=120).splitlines()[1:]:
                mm = re.match(r"\s+(\w+)/(\S+)\s+(.*)", ln)
                if mm:
                    try:
                        v = json.loads(mm.group(3))
                    except Exception:
                        v = {"raw": mm.group(3)}
                    self.plan.append((mm.group(1), mm.group(2), v))
        return self.plan

    # rows: list of (kind, text, attr, payload); kind = head | row | sub
    def rows(self):
        out = []
        f = self.filter.lower()
        if self.tab == 0:
            g = GROUPS[self.side[0]][0]; last = None
            for e in self.entries(g, CHIPS[self.chip][0]):
                if f and f not in (e["name"] + app_of(e) + e["kind"] + meta_of(e)).lower():
                    continue
                a = app_of(e)
                if a != last:
                    out.append(("head", a, self.warn | curses.A_BOLD, None)); last = a
                out.append(("row", e, 0, e))
        elif self.tab == 1:
            sel = self.side[1]; o = self.origins()
            want = o[sel - 1][0] if 0 < sel <= len(o) else None
            for e in self.entries("all"):
                if want and ORIGIN.get(e["kind"], e["kind"]) != want:
                    continue
                if f and f not in (e["name"] + app_of(e) + e["kind"]).lower():
                    continue
                absent = e["kind"] == "absent"
                out.append(("row", e["name"], curses.A_BOLD, e))
                out.append(("sub", f"   {e['layer']} · {e['kind']} · {app_of(e)}", self.dim, e))
                out.append(("sub", ("   ◯ " + meta_of(e) + "  ·  installs via switch") if absent else ("   ✓ " + meta_of(e)), self.mag if absent else self.ok, e))
                out.append(("sub", f"   [Update] [Open] [Details] [Remove]   {ORIGIN.get(e['kind'], e['kind'])}", self.dim, e))
        elif self.tab == 2:
            prof = [None, "termux", "desktop"][self.side[2]]
            for g, mf in self.gens:
                if prof and mf.get("profile") != prof:
                    continue
                if f and f not in g.lower():
                    continue
                out.append(("row", g, 0, (g, mf)))
        elif self.tab == 3:
            layers = [None, "bin", "lib", "etc", "activate", "secret"]
            want = layers[self.side[3]]; last = None
            for layer, name, v in self.plan_rows():
                if want and layer != want:
                    continue
                if f and f not in (layer + name + json.dumps(v)).lower():
                    continue
                if layer != last:
                    out.append(("head", layer, self.warn | curses.A_BOLD, None)); last = layer
                out.append(("row", (layer, name, v), 0, (layer, name, v)))
        else:
            items = [("live generation", self.gen), ("profile", self.profile), ("store", f"{len(self.m.get('objects', []))} objects · {self.size}"),
                     ("declared", " · ".join(f"{n} {self.counts(g)[0]}" for g, n in GROUPS)), ("absent", str(self.counts('all')[2])),
                     ("summary", self.summary), ("dev mode", ", ".join(self.dev) or "—"),
                     ("declaration", (self.m.get("declaration") or "—").replace(HOME, "~")),
                     ("page", "~/.linux-store/ui/index.html  ·  http://localhost:8000/.linux-store/ui/"),
                     ("account page", "~/.linux-store/ui/account.html")]
            for k, v in items:
                out.append(("row", f"{k:<16} {v}", 0, (k, v)))
        if not out:
            out.append(("head", "Nothing here.", self.dim, None))
        return out

    # ── drawing ───────────────────────────────────────────────────────────
    def put(self, win, y, x, text, attr=0):
        h, W = win.getmaxyx()
        if 0 <= y < h and 0 <= x < W - 1:
            try:
                win.addnstr(y, x, text, W - x - 1, attr)
            except curses.error:
                pass

    def bar(self, win, y, text, attr):
        self.put(win, y, 0, " " * (win.getmaxyx()[1] - 1), attr); self.put(win, y, 0, text, attr)

    def chips(self, win, y, x, items, active, color=None):
        for i, name in enumerate(items):
            a = ((color or self.mag) | curses.A_REVERSE | curses.A_BOLD) if i == active else self.dim
            self.put(win, y, x, f" {name} ", a); x += len(name) + 3
        return x

    def draw(self):
        scr = self.scr; scr.erase()
        H, W = scr.getmaxyx()
        # title bar with the tab strip
        self.bar(scr, 0, " ▣ Store ", curses.A_REVERSE | curses.A_BOLD)
        x = 10
        for i, t in enumerate(TABS):
            s = f" {i + 1} {t} "
            self.put(scr, 0, x, s, (curses.A_BOLD | self.mag) if i == self.tab else curses.A_REVERSE); x += len(s) + 1
        right = f" {self.profile} · {self.gen} · {self.size} "
        self.put(scr, 0, max(x, W - len(right) - 1), right, curses.A_REVERSE)
        # sidebar
        side = scr.derwin(H - 2, SW, 1, 0); side.box()
        items, title = [], ""
        if self.tab == 0:
            title = " Groups "; items = [f"{n:<9}{self.counts(g)[1]:>3}/{self.counts(g)[0]:<3}" for g, n in GROUPS]
        elif self.tab == 1:
            title = " Origins "; items = [f"{'all':<14}{self.counts('all')[0]:>3}"] + [f"{k:<14}{n:>3}" for k, n in self.origins()]
        elif self.tab == 2:
            title = " Profile "; items = ["all", "termux", "desktop"]
        elif self.tab == 3:
            title = " Layers "; items = ["all", "bin", "lib", "etc", "activate", "secret"]
        else:
            title = " Actions "; items = ["c  check", "p  repair", "G  gc", "h  html", "w  serve", "t  tui (account)"]
        self.put(side, 0, 2, title, curses.A_BOLD)
        for i, it in enumerate(items):
            active = i == self.side[self.tab] and self.tab != 4
            self.put(side, 2 + i, 1, f"{'▸' if active else ' '} {it}", (self.mag | curses.A_BOLD) if active else 0)
        if self.tab in (0, 1):
            y0 = 2 + len(items) + 1
            self.put(side, y0, 1, "─" * (SW - 2), self.dim); self.put(side, y0 + 1, 1, " Legend", curses.A_BOLD)
            self.put(side, y0 + 2, 2, "✓ present", self.ok); self.put(side, y0 + 3, 2, "◯ absent", self.blue)
            self.put(side, y0 + 4, 2, "⬇ switch fetches", self.dim)
        if self.filter:
            self.put(side, H - 5, 1, f" / {self.filter}", self.cyan)
        # main
        main = scr.derwin(H - 2 - DH, W - SW, 1, SW); main.box()
        MW = W - SW; y = 1
        if self.tab == 0:
            cb, cl, cc, cs = (self.counts(g)[0] for g, _ in GROUPS)
            self.put(main, y, 2, f"{cb} Apps · {cl} Libs · {cc} Configs · {cs} Secrets · linux-store is the fleet manager", self.dim); y += 1
            self.put(main, y, 2, BLURB[GROUPS[self.side[0]][0]], self.dim); y += 2
        if self.tab in (0, 1):
            x = 2
            for label, col in (("↻ Check all", self.blue), ("⬇ Install all", self.blue), ("⬆ Update all", self.blue), ("↶ Rollback", self.dim)):
                self.put(main, y, x, f" {label} ", col | curses.A_BOLD | curses.A_REVERSE); x += len(label) + 4
            y += 1
            self.put(main, y, 2, self.summary, self.dim); y += 2
        if self.tab == 0:
            t, p, a = self.counts(GROUPS[self.side[0]][0])
            x = self.chips(main, y, 2, [n for _, n in CHIPS], self.chip)
            self.put(main, y, x + 2, f"{t} total · {p} present · {a} absent", self.dim); y += 2
            self.put(main, y, 2, f"{'':2} {'name':<24} {'kind':<10} {'app':<18} where", curses.A_UNDERLINE | self.dim); y += 1
        elif self.tab == 1:
            self.put(main, y, 2, " ⇪ Export app list ", self.blue | curses.A_REVERSE | curses.A_BOLD)
            self.put(main, y, 24, " ⇩ Import app list ", self.dim | curses.A_REVERSE)
            t, p, a = self.counts("all")
            self.put(main, y, 46, f"{t} entries · {a} not installed", self.dim); y += 2
        elif self.tab == 2:
            self.put(main, y, 2, f"{len(self.gens)} generations · live {self.gen} · keep {os.environ.get('LINUX_STORE_KEEP', '5')} per profile", self.dim); y += 2
            self.put(main, y, 2, f"{'':2} {'generation':<14} {'built':<22} {'bin':>4} {'lib':>4} {'cfg':>4} {'sec':>4} {'absent':>7}  declaration", curses.A_UNDERLINE | self.dim); y += 1
        elif self.tab == 3:
            self.put(main, y, 2, f"what {(self.m.get('declaration') or '').replace(HOME, '~')} resolves to for {self.profile}", self.dim); y += 2
            self.put(main, y, 2, f"{'name':<28} {'source':<40} options", curses.A_UNDERLINE | self.dim); y += 1
        else:
            self.put(main, y, 2, "Status", curses.A_BOLD); y += 2
        rows = self.rows()
        sel = [i for i, r in enumerate(rows) if r[0] == "row"]
        if not sel:
            self.row = 0
        elif self.row not in sel:
            self.row = min(sel, key=lambda i: abs(i - self.row))
        mh = main.getmaxyx()[0]; avail = max(1, mh - y - 1)
        if self.row < self.top:
            self.top = self.row
        while self.row >= self.top + avail:
            self.top += 1
        for i, (kind, text, attr, pl) in enumerate(rows[self.top:self.top + avail]):
            idx = self.top + i; cur = idx == self.row and kind == "row"
            if cur:
                self.put(main, y + i, 1, " " * (MW - 2), curses.A_REVERSE)
            a = attr | (curses.A_REVERSE if cur else 0)
            if kind == "head":
                self.put(main, y + i, 2, f"▍ {text}", attr)
            elif self.tab == 0:
                e = pl; absent = e["kind"] == "absent"
                self.put(main, y + i, 2, f"{'◯' if absent else '✓':2} {e['name']:<24} {e['kind']:<10} {app_of(e):<18} {meta_of(e)}", a | (self.blue if absent and not cur else self.ok if not cur else 0))
            elif self.tab == 2:
                g, mf = pl; live = g == self.gen
                c = lambda L: self.counts(L, mf)
                self.put(main, y + i, 2, f"{'●' if live else ' ':2} {g:<14} {mf.get('created', '')[:19]:<22} {c('bin')[0]:>4} {c('lib')[0]:>4} {c('cfg')[0]:>4} {c('secret')[0]:>4} {c('all')[2]:>7}  {(mf.get('declaration') or '').rsplit('/', 1)[-1]}", a | (self.ok if live and not cur else 0))
            elif self.tab == 3:
                layer, name, v = pl
                src = v.get("path") or v.get("host") or v.get("fetch") or v.get("copy") or v.get("sops") or v.get("file") or v.get("template") or ",".join(v.get("render", [])) or v.get("keys") or ""
                opts = " ".join(k for k in ("exe", "optional", "env", "libs", "entry", "mode", "values") if k in v)
                self.put(main, y + i, 2, f"{name:<28} {str(src)[:40]:<40} {opts}", a)
            else:
                self.put(main, y + i, 2, text, a)
        if len(rows) > avail:
            self.put(main, mh - 1, MW - 9, f" {int(100 * min(1, (self.top + avail) / len(rows))):>3}% ", self.dim)
        # details
        det = scr.derwin(DH, W - SW, H - 1 - DH, SW); det.box()
        cur = rows[self.row][3] if rows and rows[self.row][0] == "row" else None
        self.put(det, 0, 2, " Details ", curses.A_BOLD)
        lines = self.details(cur)
        for i, (t, a) in enumerate(lines[:DH - 2]):
            self.put(det, 1 + i, 2, t, a)
        # key bar
        keys = {0: " ↑↓ move  ⇥/1-5 tab  ←→ group  f chip  / filter  ⏎ json  c check  i install  u update  r rollback  v dev  x diff  q ",
                1: " ↑↓ move  ⇥/1-5 tab  ←→ origin  / filter  ⏎ json  e export  c check  i install  u update  q ",
                2: " ↑↓ move  ⇥/1-5 tab  ←→ profile  ⏎ switch-generation  r rollback  x diff vs live  G gc  q ",
                3: " ↑↓ move  ⇥/1-5 tab  ←→ layer  / filter  ⏎ json  E edit  b build  i switch  u update  q ",
                4: " ⇥/1-5 tab  c check  p repair  G gc  h html  w serve  t account tui  q "}[self.tab]
        self.bar(scr, H - 1, (self.msg + " │ " if self.msg else "") + keys, curses.A_REVERSE)
        scr.refresh()

    def details(self, cur):
        if self.detail_text:
            return self.detail_text
        if cur is None:
            return [("select a row", self.dim)]
        if self.tab in (0, 1):
            e = cur; src = e["source"]
            if e["layer"] == "secret":
                try:
                    j = json.loads(src); src = f"{j['kind']} · {j.get('file') or j.get('template')}"
                except Exception:
                    pass
            out = [(f"{e['name']}   {e['layer']}/{e['kind']} · {app_of(e)}", curses.A_BOLD), (f"source  {src}", self.dim)]
            if e.get("host"):
                out.append((f"host    {e['host']}", self.dim))
            out.append(("◯ not installed  ·  Install all (switch) fetches or builds it", self.blue) if e["kind"] == "absent" else ("✓ up to date  ·  " + meta_of(e), self.ok))
            if e["layer"] == "etc":
                out.append(("dev mode: " + ("ON (linked to the repo source)" if e["name"] in self.dev else "off  ·  v toggles"), self.cyan))
            return out
        if self.tab == 2:
            g, mf = cur
            return [(f"{g}   {'LIVE' if g == self.gen else ''}", curses.A_BOLD), (f"built {mf.get('created', '')}  ·  {len(mf.get('objects', []))} objects", self.dim),
                    (f"declaration {(mf.get('declaration') or '').replace(HOME, '~')}  sha {(mf.get('declaration_sha256') or '')[:12]}", self.dim),
                    ("⏎ switch-generation   r rollback   x diff vs live", self.mag)]
        if self.tab == 3:
            layer, name, v = cur
            return [(f"{layer}/{name}", curses.A_BOLD)] + [(l, self.dim) for l in json.dumps(v, indent=1).splitlines()[1:-1][:4]]
        return [(f"{cur[0]}: {cur[1]}", 0)]

    # ── actions ───────────────────────────────────────────────────────────
    def run(self, *args, reload=True):
        curses.endwin(); os.system("clear")
        print(f"$ {BIN} {' '.join(args)}\n"); subprocess.call([BIN, *args]); input("\n[Enter]")
        self.scr.refresh(); self.msg = f"ran {' '.join(args)}"
        if reload:
            self.reload()

    def prompt(self, label):
        H, W = self.scr.getmaxyx(); curses.echo(); curses.curs_set(1)
        self.bar(self.scr, H - 1, label, curses.A_REVERSE); self.scr.refresh()
        try:
            s = self.scr.getstr(H - 1, len(label) + 1, 80).decode()
        except Exception:
            s = ""
        curses.noecho(); curses.curs_set(0); return s

    def loop(self):
        while True:
            self.draw()
            k = self.scr.getch()
            rows = self.rows(); sel = [i for i, r in enumerate(rows) if r[0] == "row"]
            cur = rows[self.row][3] if rows and rows[self.row][0] == "row" else None
            nsides = {0: 4, 1: len(self.origins()) + 1, 2: 3, 3: 6, 4: 1}[self.tab]
            self.detail_text = []
            if k in (ord("q"), 27):
                if self.filter:
                    self.filter = ""; continue
                return
            elif k in (9, curses.KEY_BTAB):
                self.tab = (self.tab + (1 if k == 9 else -1)) % 5; self.row = self.top = 0
            elif ord("1") <= k <= ord("5"):
                self.tab = k - ord("1"); self.row = self.top = 0
            elif k in (curses.KEY_DOWN, ord("j")):
                nxt = [i for i in sel if i > self.row]; self.row = nxt[0] if nxt else self.row
            elif k in (curses.KEY_UP, ord("k")):
                prv = [i for i in sel if i < self.row]; self.row = prv[-1] if prv else self.row
            elif k == curses.KEY_NPAGE:
                nxt = [i for i in sel if i > self.row][:10]; self.row = nxt[-1] if nxt else self.row
            elif k == curses.KEY_PPAGE:
                prv = [i for i in sel if i < self.row][-10:]; self.row = prv[0] if prv else self.row
            elif k == ord("g"):
                self.row = sel[0] if sel else 0
            elif k == ord("G") and self.tab in (2, 4):
                self.run("gc")
            elif k == ord("G"):
                self.row = sel[-1] if sel else 0
            elif k in (curses.KEY_RIGHT, ord("l")):
                self.side[self.tab] = (self.side[self.tab] + 1) % nsides; self.row = self.top = 0
            elif k in (curses.KEY_LEFT, ord("h")) and self.tab != 4:
                self.side[self.tab] = (self.side[self.tab] - 1) % nsides; self.row = self.top = 0
            elif k == ord("h") and self.tab == 4:
                self.run("html")
            elif k == ord("f") and self.tab == 0:
                self.chip = (self.chip + 1) % len(CHIPS); self.row = self.top = 0
            elif k == ord("/"):
                self.filter = self.prompt("filter:"); self.row = self.top = 0
            elif k in (10, 13, curses.KEY_ENTER) and cur is not None:
                if self.tab == 2:
                    self.run("switch-generation", cur[0])
                elif self.tab == 4:
                    pass
                else:
                    curses.endwin(); print(json.dumps(cur if self.tab != 3 else {"layer": cur[0], "name": cur[1], **cur[2]}, indent=2)); input("\n[Enter]"); self.scr.refresh()
            elif k == ord("c"):
                self.run("check")
            elif k == ord("i"):
                self.run("switch")
            elif k == ord("u"):
                self.run("update")
            elif k == ord("r"):
                self.run("rollback")
            elif k == ord("p") and self.tab == 4:
                self.run("repair")
            elif k == ord("w") and self.tab == 4:
                self.run("serve")
            elif k == ord("t") and self.tab == 4:
                curses.endwin(); subprocess.call(["linux-account", "tui"]); self.scr.refresh()
            elif k == ord("e") and self.tab == 1:
                curses.endwin(); subprocess.call(["linux-account", "apps", "export"]); input("\n[Enter]"); self.scr.refresh()
            elif k == ord("E") and self.tab == 3:
                curses.endwin(); subprocess.call([os.environ.get("EDITOR", "vi"), self.m.get("declaration") or ""]); self.scr.refresh(); self.plan = None
            elif k == ord("b") and self.tab == 3:
                self.run("build")
            elif k == ord("v") and self.tab == 0 and cur is not None and cur["layer"] == "etc":
                self.run("dev", *(["--off", cur["name"]] if cur["name"] in self.dev else [cur["name"]]))
            elif k == ord("x") and cur is not None and self.tab in (0, 2):
                if self.tab == 2:
                    out = sh("diff", cur[0], timeout=120)
                else:
                    try:
                        n = int(self.gen.rsplit("-", 1)[1])
                    except Exception:
                        n = 1
                    out = "\n".join(l for l in sh("diff", str(n - 1), timeout=120).splitlines() if cur["name"] in l) if n > 1 else "(no previous generation)"
                self.detail_text = [(l, self.ok if l.startswith("+") else self.bad if l.startswith("-") else self.dim) for l in (out.splitlines() or ["(no change)"])[:DH - 2]]
                self.msg = "diff"
            elif k == curses.KEY_RESIZE:
                pass


def main(scr):
    App(scr).loop()


if __name__ == "__main__":
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass
