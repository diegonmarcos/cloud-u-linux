#!/usr/bin/env bash
# test-search.sh — verify /__api__/search's three modes.
#
# It EXTRACTS the real walk() out of src/my-webserver.cjs and runs that against
# an in-memory tree. It does not re-implement it: a hand-copied duplicate is how
# a test keeps passing against a function that no longer exists in production.
# Edit the handler and this test follows; edit it wrongly and this test fails.
#
# The case that matters for 'folder': a matching directory nested under a
# NON-matching one. Narrowing the walk instead of narrowing the reporting would
# stop at the non-matching parent and silently miss it.
#
# Run: bash test-search.sh
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SELF_DIR/src/my-webserver.cjs"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Lift `async function walk` out of the handler, brace-balanced from its header.
node -e '
const fs = require("fs");
const s = fs.readFileSync(process.argv[1], "utf8");
const i = s.indexOf("async function walk(dir, rel)");
if (i < 0) { console.error("walk() not found in my-webserver.cjs"); process.exit(1); }
let d = 0, j = s.indexOf("{", i);
for (let k = j; k < s.length; k++) {
  if (s[k] === "{") d++;
  else if (s[k] === "}" && --d === 0) { j = k + 1; break; }
}
fs.writeFileSync(process.argv[2], s.slice(i, j));
' "$SRC" "$TMP/walk.js" || exit 1

cat > "$TMP/run.js" <<'JS'
// Tree: a matching dir nested under a non-matching one, plus a same-named file.
const TREE = {
  "":                      ["notes", "zzz", "target.txt", ".target-hidden"],
  ".target-hidden":        [".inner-target"],
  ".target-hidden/.inner-target": [],
  "notes":                 ["target", "other.md"],
  "notes/target":          ["deep.txt"],
  "notes/other.md":        null,
  "notes/target/deep.txt": null,
  "zzz":                   ["target"],
  "zzz/target":            [],
  "target.txt":            null,
};
const CONTENT = { "notes/other.md": "mentions target inside the body" };
// "loop" is a directory that always contains "back", and every path inside it
// reports the SAME dev:ino — a symlink pointing back up its own tree. Without
// the visited-set the walk descends it until the budget runs out; with it, the
// second visit is recognised as somewhere it has already been.
const inLoop  = (p) => p === "loop" || p.startsWith("loop/");
const isDir   = (p) => inLoop(p) || Array.isArray(TREE[p]);
// Counted, and hard-capped: without the visited-set a cycle recurses forever,
// and a test that HANGS reports nothing. The cap turns that into a throw, so
// the runaway fails the check instead of wedging the suite.
let readdirCalls = 0;
const readdir = async (p) => {
  if (++readdirCalls > 5000) throw new Error("runaway walk");
  return inLoop(p) ? ["back"] : (TREE[p] || []);
};
let nextIno = 1; const INO = {};
const inoOf = (p) => inLoop(p) ? 999 : (INO[p] = INO[p] || ++nextIno);
const stat  = async (p) => ({ isDirectory: () => isDir(p), size: 10, dev: 1, ino: inoOf(p) });
const readFile = async (p) => CONTENT[p] ?? "";
const join = (a, b) => (a ? a + "/" + b : b);

let results, mode, q, showDot, budget, seen, aborted;
JS
cat "$TMP/walk.js" >> "$TMP/run.js"
cat >> "$TMP/run.js" <<'JS'

const out = [];
const check = (n, ok) => out.push([n, ok]);
const BUDGET0 = 50000;
async function run(m, term, dot, opts) {
  opts = opts || {};
  results = []; mode = m; q = term; showDot = !!dot;
  budget = opts.budget === undefined ? BUDGET0 : opts.budget;
  seen = new Set(); aborted = false;
  if (opts.abortNow) aborted = true;
  await walk(opts.from === undefined ? "" : opts.from, "");
  return results.map(r => (r.isDir ? "d:" : "f:") + r.path).sort();
}
(async () => {
  const fn = await run("filename", "target");
  // deep.txt does NOT match: the comparison is on the basename, not the path.
  check("filename finds dirs and files",
    fn.join() === ["d:notes/target","d:zzz/target","f:target.txt"].sort().join());

  const fo = await run("folder", "target");
  check("folder finds only directories",
    fo.join() === ["d:notes/target","d:zzz/target"].join());
  check("folder descends through a NON-matching parent",
    fo.includes("d:notes/target"));
  check("folder excludes the same-named file", !fo.includes("f:target.txt"));

  const co = await run("content", "target");
  check("content still matches file bodies", co.includes("f:notes/other.md"));
  check("content reports no directories", co.every(r => r.startsWith("f:")));

  // Dotfiles: hidden unless asked for, and the walk must not DESCEND into a
  // hidden dir either — otherwise a nested match leaks a path whose parent the
  // listing refuses to show, which is worse than either behaviour on its own.
  const dOff = await run("folder", "target", false);
  check("dot dirs hidden by default", !dOff.some(r => r.includes(".target-hidden")));

  const dOn = await run("folder", "target", true);
  check("dot dirs shown when asked", dOn.includes("d:.target-hidden"));
  check("nested dot dir found only with dot on", dOn.includes("d:.target-hidden/.inner-target"));

  // The three bounds. Each is checked by what it COSTS, not just by the answer:
  // a walk that returns the right list after visiting the whole disk is still
  // the bug this was written for.
  readdirCalls = 0;
  let looped = false;
  try { await run("filename", "back", false, { from: "loop" }); }
  catch (e) { looped = true; }
  check("symlink cycle does not walk forever", !looped && readdirCalls < 10);

  await run("filename", "target", false, { budget: 3 });
  check("budget is honoured", budget <= 0);

  const ab = await run("filename", "target", false, { abortNow: true });
  check("abort stops the walk immediately", ab.length === 0 && budget === BUDGET0);

  let bad = 0;
  for (const [n, ok] of out) { console.log((ok ? "  ok   — " : "  FAIL — ") + n); if (!ok) bad++; }
  process.exit(bad === 0 ? 0 : 1);
})();
JS

echo "=== my-webserver search modes ==="
node "$TMP/run.js" || exit 1
echo "=== my-webserver search modes: PASS ==="
