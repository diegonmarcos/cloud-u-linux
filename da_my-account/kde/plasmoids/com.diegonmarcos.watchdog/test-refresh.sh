#!/usr/bin/env bash
# test-refresh.sh — verify the watchdog applet's refresh()/refreshGuard().
#
# WHAT IT TESTS, AND WHY THIS SHAPE
# The two things that went wrong in production:
#   1. the XHR callback throwing when the component was destroyed mid-flight
#      (196 "TypeError: Value is null" pairs in one session, thrown from
#      inside the catch block so even the error path failed), and
#   2. re-assigning root.snap on every poll regardless of whether the
#      publisher had moved — which invalidates every binding in the applet,
#      seven instances over, for identical bytes.
# Both live in plain JavaScript inside main.qml, so they are testable without
# a QML runtime.
#
# It extracts the REAL function bodies out of main.qml and runs those. It does
# NOT re-implement them. A hand-copied duplicate is how the hm-auto-update
# errexit bug survived its own test suite for months: the suite exercised a
# shell that did not exist in production and passed every time. Edit main.qml
# and this test follows; edit it wrongly and this test fails.
#
# Run: bash test-refresh.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QML="$SELF_DIR/contents/ui/main.qml"
TMP="$(mktemp -d -t test-watchdog.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM

pass(){ echo "  ✓ $1"; }
fail(){ echo "FAIL: $1" >&2; exit 1; }

echo "=== watchdog refresh() ==="
[ -r "$QML" ] || fail "main.qml not found at $QML"
command -v node >/dev/null 2>&1 || fail "node not found — needed to run the extracted functions"

# Extract one `function NAME() { ... }` by brace counting from its opening line.
# Naive line matching would stop at the first "}" and silently test a fragment.
extract(){
  awk -v want="function $1(" '
    index($0, want) { grabbing = 1 }
    grabbing {
      print
      n = gsub(/{/, "{"); m = gsub(/}/, "}")
      depth += n - m
      if (depth == 0 && seen) exit
      if (n > 0) seen = 1
    }
  ' "$QML"
}

extract refresh      > "$TMP/refresh.js"
extract refreshGuard > "$TMP/refreshGuard.js"
extract clip         > "$TMP/clip.js"
[ -s "$TMP/clip.js" ] || fail "could not extract clip() from main.qml"
[ -s "$TMP/refresh.js" ]      || fail "could not extract refresh() from main.qml"
[ -s "$TMP/refreshGuard.js" ] || fail "could not extract refreshGuard() from main.qml"
grep -q 'xhr.send()' "$TMP/refresh.js" || fail "extracted refresh() looks truncated (no xhr.send)"
pass "extracted refresh() and refreshGuard() from the real main.qml"

cat > "$TMP/harness.js" <<'HARNESS'
let lastXhr = null;   // the leak check below inspects the object refresh() built
// Stub XMLHttpRequest: one queued response per send().
//
// Delivery is synchronous by default, but `defer` holds the response so a test
// can fire the callback LATER. That matters for the destroyed-component case:
// the real failure is the callback landing after the applet is gone, while
// refresh() itself ran normally against a live root. Nulling root before
// calling refresh() would instead throw at `xhr.open("GET", root.snapUrl)`,
// which is outside the callback and not the bug being tested.
let queue = [], defer = false, pending = [];
function XMLHttpRequest() {
  lastXhr = this;
  this.readyState = 0;
  this.responseText = "";
  this.onreadystatechange = null;
  this.open = function (m, u) { this.url = u; };
  this.send = function () {
    const next = queue.shift();
    const fire = () => {
      this.readyState = XMLHttpRequest.DONE;
      this.responseText = (next === undefined ? "" : next);
      if (this.onreadystatechange) this.onreadystatechange();
    };
    if (defer) pending.push(fire); else fire();
  };
}
XMLHttpRequest.DONE = 4;
function deliverPending() { const p = pending; pending = []; p.forEach(f => f()); }

// `root` with a counting setter on the two properties whose assignment is what
// invalidates bindings. snapWrites is the number the fix is about.
let snapWrites = 0, guardWrites = 0;
let root = {
  snapUrl: "file:///snap.json", guardUrl: "file:///guard.json",
  stale: true, guardStale: true, lastTs: -1, lastGuardTs: -1,
  _snap: {}, _guard: {},
  get snap()  { return this._snap; },
  set snap(v) { snapWrites++;  this._snap = v; },
  get guardSnap()  { return this._guard; },
  set guardSnap(v) { guardWrites++; this._guard = v; },
};

HARNESS

cat "$TMP/refresh.js" "$TMP/refreshGuard.js" >> "$TMP/harness.js"

cat >> "$TMP/harness.js" <<'CHECKS'

const now = Math.floor(Date.now() / 1000);
const results = [];
function check(name, cond) { results.push([name, !!cond]); }

// 1. a first payload is applied
queue.push(JSON.stringify({ ts: now, cpu: 1 }));
refresh();
check("first payload applied", snapWrites === 1 && root.snap.cpu === 1);

// 2. the SAME ts must not re-assign snap (this is the fix)
queue.push(JSON.stringify({ ts: now, cpu: 1 }));
refresh();
check("unchanged ts does not rebind", snapWrites === 1);

// 3. a new ts must apply
queue.push(JSON.stringify({ ts: now + 2, cpu: 9 }));
refresh();
check("new ts applies", snapWrites === 2 && root.snap.cpu === 9);

// 4. staleness is still evaluated on a poll that did NOT rebind — a dead
//    publisher has to be noticed even when its last bytes are unchanged
root.stale = false;
queue.push(JSON.stringify({ ts: now - 600, cpu: 9 }));
refresh();                       // old ts, different from lastTs, so it applies
root.stale = false;
queue.push(JSON.stringify({ ts: now - 600, cpu: 9 }));
refresh();                       // same ts -> no rebind, but stale must still flip
check("stale still set on a non-rebinding poll", root.stale === true);

// 5. malformed JSON -> stale, no throw
const before = snapWrites;
queue.push("{not json");
refresh();
check("bad JSON sets stale without throwing", root.stale === true && snapWrites === before);

// 6. guard: same gating
const g0 = guardWrites;
queue.push(JSON.stringify({ ts: now, voters: 2 }));
refreshGuard();
queue.push(JSON.stringify({ ts: now, voters: 2 }));
refreshGuard();
check("guard unchanged ts does not rebind", guardWrites === g0 + 1);

// 7. guard failure clears once, not on every poll
root.lastGuardTs = 5; root._guard = { x: 1 };
const g1 = guardWrites;
queue.push("nope"); refreshGuard();
queue.push("nope"); refreshGuard();
check("guard failure clears once, then stops", guardWrites === g1 + 1);

// 8. THE CRASH: the applet is destroyed while a request is IN FLIGHT, and the
//    callback lands afterwards. refresh() itself ran against a live root; only
//    the callback sees null. Before the fix this threw TypeError — and from
//    inside the catch block, so the error path failed too.
const saved = root;
let threw = false;
defer = true;
queue.push(JSON.stringify({ ts: now + 99 }));
refresh();          // issued while alive
queue.push(JSON.stringify({ ts: now + 99 }));
refreshGuard();     // issued while alive
root = null;        // panel edit / shell restart destroys the applet
try { deliverPending(); } catch (e) { threw = true; }
defer = false;
root = saved;
check("callback after destruction does not throw", threw === false);

// 10. The handler must be released once the response is in. `xhr` is captured
//     by its own onreadystatechange, so the pair is a reference cycle holding
//     a 25KB responseText, and V4 only breaks it on a cycle-tracing pass that
//     nothing prompts (the buffer is native memory the JS heap never feels).
//     Seven instances at 1.5s leaked plasmashell 12.8 MB/h of anonymous heap,
//     measured 2026-08-24. Delete the null assignment in main.qml and this
//     fails — which is the only reason it survives someone tidying it away.
queue.push(JSON.stringify({ ts: now + 500 }));
refresh();
check("refresh() releases its XHR handler", lastXhr.onreadystatechange === null);
queue.push(JSON.stringify({ ts: now + 501 }));
refreshGuard();
check("refreshGuard() releases its XHR handler", lastXhr.onreadystatechange === null);

let bad = 0;
for (const [name, ok] of results) {
  console.log((ok ? "  ✓ " : "  ✗ ") + name);
  if (!ok) bad++;
}
process.exit(bad === 0 ? 0 : 1);
CHECKS

node "$TMP/harness.js" || fail "one or more behaviour checks failed"

# ── clip(): the panel-overflow guard ────────────────────────────────────────
# 2026-09-02: proctable_head fed an UNBOUNDED daemon-supplied process name into
# a Label with no elide, whose implicitWidth reached compactRoot's
# Layout.minimumWidth -- so the applet claimed the whole top panel and pushed
# every other widget off the bar. clip() is what bounds that string; if it ever
# stops truncating, the overflow comes straight back.
cat > "$TMP/clip-harness.js" <<'CLIPCHECKS'
const src = require("fs").readFileSync(process.argv[2], "utf8");
eval(src);
const results = [];
const check = (n, ok) => results.push([n, ok]);

check("long name is truncated to n chars", clip("ld-linux-x86-64.so.2", 14).length === 14);
check("truncated name ends in an ellipsis", clip("ld-linux-x86-64.so.2", 14).endsWith("\u2026"));
check("short name is untouched", clip("fish", 14) === "fish");
check("exact-length name is untouched", clip("abcdefghijklmn", 14) === "abcdefghijklmn");
// The accessors around this one are all `|| 0`-defensive; a throw here blanks
// the whole binding and the widget renders nothing at all.
check("undefined does not throw", clip(undefined, 14) === "");
check("null does not throw", clip(null, 14) === "");
check("non-string does not throw", clip(12345678901234567890, 14).length <= 14);

let bad = 0;
for (const [name, ok] of results) {
  console.log((ok ? "  \u2713 " : "  \u2717 ") + name);
  if (!ok) bad++;
}
process.exit(bad === 0 ? 0 : 1);
CLIPCHECKS

node "$TMP/clip-harness.js" "$TMP/clip.js" || fail "clip() no longer bounds the string — panel overflow will return"



echo
echo "=== watchdog refresh(): PASS ==="
