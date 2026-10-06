#!/usr/bin/env python3
"""linux-account TUI — the Account dashboard, curses.

Left: every section of the vault bundle (profile-secrets.json) plus Fleet,
Infos, Apps, Repos. Right: the FULL data of the selected section as a tree
(keys and values, secrets masked to their length), or the fleet cockpit with
its lights. Keys act through the same CLI verbs (`linux-account …`).
Stdlib only (curses + json + subprocess); no menus, no number prompts.
"""
import curses, json, os, re, subprocess, sys

BIN = os.environ.get("LINUX_ACCOUNT_BIN") or "linux-account"
CFG = os.environ.get("LINUX_ACCOUNT_HOME") or os.path.expanduser("~/.config/linux-account")
SECRET = re.compile(r"token|password|passwd|private|secret|api[_-]?key|bearer|cookie|_key$", re.I)
ORDER = ["about", "electronics", "mesh", "mail", "git", "ai", "autocomplete", "settings", "peers", "apps"]
BIG = 40  # a subtree with more leaves than this starts collapsed


def sh(*args):
    try:
        return subprocess.run([BIN, *args], capture_output=True, text=True, timeout=120).stdout
    except Exception as e:  # ponytail: one catch, shown as text
        return f"{BIN} {' '.join(args)}: {e}\n"


def state():
    try:
        return json.load(open(os.path.join(CFG, "state.json")))
    except Exception:
        return {}


def bundle():
    p = os.environ.get("LINUX_ACCOUNT_BUNDLE") or state().get("bundle")
    if not p or not os.path.isfile(p):
        return None
    b = json.load(open(p))
    return b.get("bundle", b)


def leaves(v):
    if isinstance(v, dict):
        return sum(leaves(x) for x in v.values())
    if isinstance(v, list):
        return sum(leaves(x) for x in v)
    return 1


def mask(path, v):
    tail = "/".join(str(x) for x in path[-2:])
    if isinstance(v, str):
        if SECRET.search(tail):
            return f"●●● hidden, {len(v)} chars"
        return (v[:96] + "…") if len(v) > 96 else v
    return json.dumps(v)


class Node:
    __slots__ = ("key", "val", "depth", "open", "kids", "path")

    def __init__(self, key, val, depth, path):
        self.key, self.val, self.depth, self.path = key, val, depth, path
        self.kids = []
        if isinstance(val, dict):
            self.kids = [Node(k, v, depth + 1, path + [k]) for k, v in val.items()]
        elif isinstance(val, list):
            self.kids = [Node(f"[{i}]", v, depth + 1, path + [i]) for i, v in enumerate(val)]
        self.open = bool(self.kids) and leaves(val) <= BIG

    def line(self):
        pad = "  " * self.depth
        if self.kids:
            if isinstance(self.val, dict) and self.val.get("pending") is True:
                return f"{pad}{self.key}  ·  pending: {self.val.get('reason') or self.val.get('source') or ''}", "warn"
            arrow = "▾" if self.open else "▸"
            n = leaves(self.val)
            kind = f"{len(self.val)} keys" if isinstance(self.val, dict) else f"{len(self.val)} items"
            return f"{pad}{arrow} {self.key}  ({kind}, {n} values)", "key"
        s = mask(self.path, self.val)
        return f"{pad}{self.key} = {s}", ("secret" if s.startswith("●●●") else "val")

    def flat(self, out):
        out.append(self)
        if self.open:
            for k in self.kids:
                k.flat(out)
        return out


STATE_COLOR = {"MATCH": "ok", "DIFFERS": "bad", "ABSENT": "bad", "PENDING": "warn",
               "ON": "ok", "OFF": "bad", "UNKNOWN": "warn", "UNVERIFIABLE": "dim"}


class App:
    def __init__(self, scr):
        self.scr = scr
        curses.curs_set(0)
        curses.use_default_colors()
        for i, (fg) in enumerate([curses.COLOR_GREEN, curses.COLOR_RED, curses.COLOR_YELLOW, curses.COLOR_CYAN, curses.COLOR_MAGENTA, 8], 1):
            curses.init_pair(i, fg, -1)
        self.c = {"ok": curses.color_pair(1), "bad": curses.color_pair(2), "warn": curses.color_pair(3),
                  "key": curses.color_pair(4) | curses.A_BOLD, "sel": curses.color_pair(5) | curses.A_BOLD,
                  "dim": curses.color_pair(6), "val": 0, "secret": curses.color_pair(6)}
        self.reload()
        self.left = 0        # selected section index
        self.row = 0         # selected line in the right pane
        self.top = 0         # scroll of the right pane
        self.pane = 1        # 0 = sections, 1 = content
        self.filter = ""
        self.msg = ""
        self.cache = {}

    # ── data ──────────────────────────────────────────────────────────────
    def reload(self):
        self.b = bundle()
        self.st = state()
        self.sections = ["Fleet"] + ([s for s in ORDER if s in self.b] + [s for s in self.b if s not in ORDER and not s.startswith("_") and s != "schema_version"] if self.b else []) + ["Infos", "Apps", "Repos"]
        self.trees = {s: Node(s, self.b[s], 0, [s]) for s in self.sections if self.b and s in self.b}
        for t in self.trees.values():
            t.open = True
        self.cache = {}

    def fleet_lines(self):
        if "fleet" not in self.cache:
            lines = []
            for ln in sh("fleet", "--json").splitlines():
                try:
                    c = json.loads(ln)
                except Exception:
                    continue
                lines.append((f"{'●' if c['light']=='ON' else '○' if c['light']=='OFF' else '◌' if c['light']=='UNVERIFIABLE' else '◍'} {c['card']}  {c['light']}", STATE_COLOR.get(c["light"], "val")))
                for r in c["rows"]:
                    lines.append((f"    {r['state']:<9} {r['label']:<30} {r['note']}", STATE_COLOR.get(r["state"], "val")))
                lines.append(("", "val"))
            self.cache["fleet"] = lines or [("not connected — press c to connect the vault checkout", "warn")]
        return self.cache["fleet"]

    def text_lines(self, key, *args):
        if key not in self.cache:
            self.cache[key] = [(l, "val") for l in sh(*args).splitlines()] or [("(nothing)", "dim")]
        return self.cache[key]

    def content(self):
        s = self.sections[self.left] if self.sections else ""
        if s == "Fleet":
            lines = self.fleet_lines()
        elif s == "Infos":
            lines = self.text_lines("infos", "infos")
        elif s == "Apps":
            lines = self.text_lines("apps", "apps", "compare")
        elif s == "Repos":
            lines = self.text_lines("repos", "repos", "list")
        elif s in self.trees:
            lines = [n.line() + (n,) for n in self.trees[s].flat([])]
        else:
            lines = [("(not in bundle)", "dim")]
        if self.filter:
            f = self.filter.lower()
            lines = [l for l in lines if f in l[0].lower()]
        return lines

    # ── drawing ───────────────────────────────────────────────────────────
    def put(self, y, x, text, attr=0, w=None):
        h, W = self.scr.getmaxyx()
        if y < 0 or y >= h or x >= W:
            return
        if w is None:
            w = W - x
        try:
            self.scr.addnstr(y, x, text, max(0, min(w, W - x - 1)), attr)
        except curses.error:
            pass

    def draw(self):
        self.scr.erase()
        h, W = self.scr.getmaxyx()
        lw = min(18, W // 4)
        dots = sh("journey")
        dots = " ".join(l.strip()[0] for l in dots.splitlines() if l.strip())
        who = self.st.get("identity_email", "—")
        dev = self.st.get("device_id", "—")
        self.put(0, 0, f" linux-account  {dots}   {dev} · {who}   {self.st.get('bundle_source', 'not connected')}", self.c["key"])
        for i, s in enumerate(self.sections):
            y = 2 + i
            if y >= h - 2:
                break
            a = self.c["sel"] if i == self.left else (self.c["key"] if self.pane == 0 else 0)
            mark = "▶ " if i == self.left else "  "
            self.put(y, 0, f"{mark}{s}", a, lw)
        for y in range(1, h - 1):
            self.put(y, lw, "│", self.c["dim"])
        lines = self.content()
        avail = h - 3
        if self.row >= len(lines):
            self.row = max(0, len(lines) - 1)
        if self.row < self.top:
            self.top = self.row
        if self.row >= self.top + avail:
            self.top = self.row - avail + 1
        for i, ln in enumerate(lines[self.top:self.top + avail]):
            text, kind = ln[0], ln[1]
            a = self.c.get(kind, 0)
            if self.pane == 1 and self.top + i == self.row:
                a |= curses.A_REVERSE
            self.put(2 + i, lw + 2, text, a)
        sec = self.sections[self.left] if self.sections else ""
        pos = f"{self.row + 1}/{len(lines)}" if lines else "0/0"
        flt = f"  filter: {self.filter}" if self.filter else ""
        self.put(1, lw + 2, f"{sec}  {pos}{flt}", self.c["dim"])
        foot = " ↑↓/jk move  ⇥ pane  ⏎ fold  / filter  r refresh  c connect  a apply  s switch  p push  e export  q quit "
        self.put(h - 1, 0, (self.msg + "  " if self.msg else "") + foot, self.c["dim"])
        self.scr.refresh()

    # ── actions ───────────────────────────────────────────────────────────
    def run(self, *args):
        curses.endwin()
        os.system("clear")
        print(f"$ {BIN} {' '.join(args)}\n")
        subprocess.call([BIN, *args])
        input("\n[Enter]")
        self.scr.refresh()
        self.reload()
        self.msg = f"ran {' '.join(args)}"

    def prompt(self, label):
        h, W = self.scr.getmaxyx()
        curses.echo(); curses.curs_set(1)
        self.put(h - 1, 0, " " * (W - 1))
        self.put(h - 1, 0, label)
        self.scr.refresh()
        try:
            s = self.scr.getstr(h - 1, len(label) + 1, 120).decode()
        except Exception:
            s = ""
        curses.noecho(); curses.curs_set(0)
        return s

    def loop(self):
        while True:
            self.draw()
            k = self.scr.getch()
            lines = self.content()
            if k in (ord("q"), 27) and not self.filter:
                return
            elif k == 27:
                self.filter = ""
            elif k in (curses.KEY_DOWN, ord("j")):
                if self.pane == 0:
                    self.left = min(self.left + 1, len(self.sections) - 1); self.row = self.top = 0
                else:
                    self.row = min(self.row + 1, max(0, len(lines) - 1))
            elif k in (curses.KEY_UP, ord("k")):
                if self.pane == 0:
                    self.left = max(self.left - 1, 0); self.row = self.top = 0
                else:
                    self.row = max(self.row - 1, 0)
            elif k == curses.KEY_NPAGE:
                self.row = min(self.row + 20, max(0, len(lines) - 1))
            elif k == curses.KEY_PPAGE:
                self.row = max(self.row - 20, 0)
            elif k == ord("g"):
                self.row = 0
            elif k == ord("G"):
                self.row = max(0, len(lines) - 1)
            elif k in (9, curses.KEY_LEFT, curses.KEY_RIGHT, ord("h"), ord("l")):
                self.pane = 1 - self.pane
            elif k in (10, 13, curses.KEY_ENTER, ord(" ")):
                if self.pane == 0:
                    self.pane = 1
                elif lines and len(lines[self.row]) > 2:
                    n = lines[self.row][2]
                    if n.kids:
                        n.open = not n.open
            elif k == ord("/"):
                self.filter = self.prompt("filter:"); self.row = self.top = 0
            elif k == ord("r"):
                self.reload(); self.msg = "reloaded"
            elif k == ord("c"):
                self.run("connect")
            elif k == ord("a"):
                self.run("apply")
            elif k == ord("s"):
                curses.endwin(); subprocess.call(["linux-store", "switch"]); input("\n[Enter]"); self.reload()
            elif k == ord("p"):
                self.run("infos", "push")
            elif k == ord("e"):
                self.run("apps", "export")
            elif k == ord("d"):
                self.run("device")
            elif k == ord("w"):
                self.run("who")
            elif k == curses.KEY_RESIZE:
                pass


def main(scr):
    App(scr).loop()


if __name__ == "__main__":
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass
