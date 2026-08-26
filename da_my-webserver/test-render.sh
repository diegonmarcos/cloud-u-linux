#!/usr/bin/env bash
# test-render.sh — verify the structured .json/.yaml renderer.
#
# It EXTRACTS the real render functions out of the template literal inside
# src/my-webserver.cjs and runs them under a minimal DOM shim, against a real
# watchdog snapshot shape. It does not re-implement them.
#
# The bug this was written for: renderObjectSections inferred the layout for a
# whole object from subKeys[0] alone. A snapshot whose first sub-key is an
# object but whose other 18 sub-keys are plain numbers sent all 38 down the
# card path — and renderKVTable(88.0) is Object.entries(88.0) === [], an empty
# card. cpu, mem, slice_pct and every other headline metric rendered as a
# heading over a blank table.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

node -e '
const fs=require("fs");
const s=fs.readFileSync(process.argv[1],"utf8");
// BIG is the collapse threshold — grabbed as a line, not re-declared here, so
// the test cannot disagree with production about what counts as large.
let out="";
const bigLine = s.match(/^const BIG = \d+;$/m);
if (!bigLine) { console.error("const BIG not found"); process.exit(1); }
out += bigLine[0] + "\n";
for (const fn of ["function sizeOf","function addCount","function makeSortable","function renderValue","function renderArrayTable","function renderKVTable","function renderObjectSections"]) {
  const i=s.indexOf(fn);
  if(i<0){console.error("missing "+fn);process.exit(1);}
  let d=0,j=s.indexOf("{",i);
  for(let k=j;k<s.length;k++){ if(s[k]==="{")d++; else if(s[k]==="}"&&--d===0){j=k+1;break;} }
  out+=s.slice(i,j)+"\n";
}
fs.writeFileSync(process.argv[2],out);
' "$SELF_DIR/src/my-webserver.cjs" "$TMP/render.js" || exit 1

cat > "$TMP/run.js" <<'JS'
// Minimal DOM: only what the render functions touch.
function El(tag){ return { tag, children:[], className:"", textContent:"", innerHTML:"",
  appendChild(c){ this.children.push(c); return c; }, addEventListener(){} }; }
global.document = { createElement:(t)=>El(t), createTextNode:(t)=>({tag:"#text",textContent:t,children:[]}) };
function escHtml(s){ return String(s); }
function prettyKey(k){ return k; }
function copyToClipboard(){}
JS
cat "$TMP/render.js" >> "$TMP/run.js"
cat >> "$TMP/run.js" <<'JS'

const fs=require("fs");
const snapFile=process.argv[2];
const rawTxt=fs.readFileSync(snapFile,"utf8");
// .yaml goes through the SAME vendored parser the page loads, so this test
// fails if that bundle is missing or stops exporting load().
const data = /\.ya?ml$/.test(snapFile)
  ? require(process.argv[3]).load(rawTxt)
  : JSON.parse(rawTxt);

const out=[]; const check=(n,ok)=>out.push([n,ok]);
function text(n){ return (n.textContent||"") + n.children.map(text).join(" "); }
function rowsOf(n){ let c = n.tag==="tr" ? 1 : 0; return c + n.children.reduce((a,k)=>a+rowsOf(k),0); }

const root=El("div");
renderObjectSections(root, data);
const all=text(root);

// 1. The headline scalars must actually appear with their values.
const snap=data.snapshot;
const scal=Object.keys(snap).filter(k=>snap[k]===null||typeof snap[k]!=="object");
check("scalar metrics are rendered, not dropped",
  scal.filter(k=>String(snap[k])!=="null").every(k=>all.includes(String(snap[k]))));

// 2. No card may be empty — an empty card is the exact old symptom.
function cards(n){ return (n.className==="card"?[n]:[]).concat(n.children.flatMap(cards)); }
// A card is empty only with no rows AND no text. An array of scalars (cores
// is list[8] of float) legitimately renders as one joined div with no <tr>,
// so counting rows alone called a correct card empty.
function bodyText(n){ return n.children.map(c=>c.tag==="h4"?"":text(c)).join("").trim(); }
const empties=cards(root).filter(c=>rowsOf(c)===0 && bodyText(c)==="");
check("no empty cards", empties.length===0);

// 3. Nesting must produce tables, not a JSON blob.
function tables(n){ return (n.tag==="table"?1:0)+n.children.reduce((a,k)=>a+tables(k),0); }
check("nested objects become tables", tables(root) > 5);
check("nested objects are not stringified",
  !all.includes('{"') || tables(root) > 20);

  // ---- collapsing -------------------------------------------------------
  function detailsOf(n){ return (n.tag==="details"?[n]:[]).concat(n.children.flatMap(detailsOf)); }
  function summaryText(d){ const su=d.children.find(c=>c.tag==="summary"); return su?text(su):""; }
  const dets = detailsOf(root);
  check("sections and cards are <details>", dets.length > 0);

  // A container bigger than BIG must start closed; that is the whole point —
  // the 358-entry file list is what you scroll past to reach the metrics.
  const big = dets.filter(d => { const m = summaryText(d).match(/\((\d+)\)/); return m && +m[1] > BIG; });
  check("large containers start collapsed", big.length > 0 && big.every(d => d.open === false));

  const small = dets.filter(d => { const m = summaryText(d).match(/\((\d+)\)/); return m && +m[1] > 0 && +m[1] <= BIG; });
  check("small containers stay open", small.length === 0 || small.every(d => d.open === true));

  // A collapsed section with no count is indistinguishable from an absent one.
  check("every collapsed container shows its count",
    dets.filter(d => d.open === false).every(d => /\(\d+\)/.test(summaryText(d))));

let bad=0;
for(const [n,ok] of out){ console.log((ok?"  ok   — ":"  FAIL — ")+n); if(!ok)bad++; }
console.log("  (tables built: "+tables(root)+", cards: "+cards(root).length+", empty cards: "+empties.length+")");
process.exit(bad===0?0:1);
JS

SNAP="${1:-$(ls -t "$HOME"/.watchdog/*.json 2>/dev/null | head -1)}"
[ -f "$SNAP" ] || { echo "no watchdog snapshot to test against"; exit 0; }
echo "=== structured render vs $(basename "$SNAP") ==="
node "$TMP/run.js" "$SNAP" "$SELF_DIR/src/lib/js-yaml.min.js" || exit 1
echo "=== structured render: PASS ==="
