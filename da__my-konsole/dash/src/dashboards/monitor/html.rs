// The export, as a page.
//
// The panel is a terminal program and stays one. This is the same envelope the
// JSON/YAML/Markdown exports carry, rendered so it can be opened in a browser
// and read by someone who does not have the panel — or by the same person, on
// a phone, from a file the hub wrote hours ago.
//
// It looks like the panel on purpose. Same palette as view::draw (DIM borders,
// LABEL column heads, the same light blue on the active thing), the same
// rounded box with its title bracketed into the top edge and its count into
// the bottom, and a monospace face throughout — because the thing being
// described is a terminal, and a sans-serif card deck describing it reads as a
// different product.
//
// STRUCTURE comes from the CLI, CONTENT comes from the snapshot. The sidebar
// is TABS itself, so a tab added to the panel appears here with no edit; but
// which rows exist is still whatever the snapshot actually holds, so a field
// added to the sampler shows up on the next export and a machine that cannot
// report a section gets a dimmed node rather than an empty table.
//
// Self-contained: no CDN, no fetch, no external font. The envelope is embedded
// in the page, so the file works from a USB stick with the network off.

use super::model::tabs::TABS;
use serde_json::Value;

/// The sections worth a tab, in the order the panel shows them. Anything else
/// in the snapshot that is an array of objects is appended after these, so a
/// new section is never invisible just because this list has not heard of it.
const PREFERRED: &[&str] = &[
    "compose", "images", "containers", "volumes", "networks", "services", "slices", "disks",
    "storage", "proc_table",
];

/// Which snapshot array backs each node of the CLI's tab tree.
///
/// The sidebar is the panel's own tree, not a second invention: TABS is the
/// single source of the names, the order, the tab keys and the sub-tab
/// numbering, so the two interfaces can be talked about in the same words —
/// `:f2` is the second sub-tab in both. What TABS cannot know is which array
/// in the exported snapshot holds a given view's rows, and that is all this
/// table says.
///
/// An empty sub means the row belongs to the tab itself, which is how a tab
/// with no sub-tabs gets children: `about` is four tables the panel keeps in
/// its own header.
///
/// A node nothing claims still renders — dimmed and inert — because "the panel
/// has this view and the export does not carry it" is worth seeing. Dropping
/// it would read as the panel not having it either. Notably `logs` and
/// `history`: both are live journal reads, and a snapshot is not a journal.
const BACKED_BY: &[(&str, &str, &str)] = &[
    ("proc", "normal", "proc_table"),
    ("proc", "tree", "proc_spine"),
    ("containers", "compose", "compose"),
    ("containers", "images", "images"),
    ("containers", "containers", "containers"),
    ("containers", "volumes", "volumes"),
    ("containers", "network", "networks"),
    ("fleet", "storage", "storage"),
    // Both firewalls are read from the one `listening` array; the panel's
    // consolidated and container views are joins the export does not carry.
    ("firewall", "os", "listening"),
    ("files", "", "__files"),
    ("about", "", "cores"),
    ("about", "", "disks"),
    ("about", "", "services"),
    ("about", "", "slices"),
];

pub(crate) fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// Arrays of objects, which are the only thing that renders as a table.
fn sections(snap: &Value) -> Vec<String> {
    let Some(map) = snap.as_object() else { return vec![] };
    let tabular = |k: &String| {
        map.get(k)
            .and_then(|v| v.as_array())
            .map(|a| !a.is_empty() && a[0].is_object())
            .unwrap_or(false)
    };
    let mut out: Vec<String> =
        PREFERRED.iter().map(|s| s.to_string()).filter(|k| tabular(k)).collect();
    let mut rest: Vec<String> =
        map.keys().filter(|k| tabular(k) && !PREFERRED.contains(&k.as_str())).cloned().collect();
    rest.sort();
    out.append(&mut rest);
    out
}

/// One page: the envelope, the Markdown report, and the panel's tab tree.
///
/// `title` names the machine and the moment, so a directory of these is
/// readable from the tab bar alone. `switcher` is the other machines in the
/// same export, already rendered — this module knows how a machine list looks,
/// the exporter knows which machines there are.
pub(crate) fn page(title: &str, envelope: &Value, markdown: &str, switcher: &str) -> String {
    let snap = envelope.get("snapshot").unwrap_or(envelope);
    let tabs = sections(snap);
    let files =
        envelope.get("files").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0);
    let measured = envelope.get("measured").and_then(|v| v.as_str()).unwrap_or("local").to_string();

    let count = |k: &str| snap.get(k).and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0);
    let has = |k: &str| tabs.iter().any(|t| t == k);

    // One row of the tree. `num` is the number the panel addresses the sub-tab
    // by, kept visible for the same reason the panel prints it.
    let row = |num: Option<usize>, label: &str, target: Option<&str>, badge: Option<String>| {
        let n = num.map(|n| format!("<i class=\"n\">{n}</i>")).unwrap_or_default();
        let b = badge.map(|b| format!("<b>{b}</b>")).unwrap_or_default();
        match target {
            Some(k) => {
                format!("<li><a class=\"t\" data-k=\"{}\">{n}{}{b}</a></li>", esc(k), esc(label))
            }
            None => format!("<li><a class=\"off\">{n}{}</a></li>", esc(label)),
        }
    };
    let head = |name: &str, key: &str| {
        let k = if key.is_empty() {
            String::new()
        } else {
            format!("<i class=\"k\">{}</i>", esc(key))
        };
        format!("<div class=\"grp\"><div class=\"tab\">{}{k}</div><ul>", esc(name))
    };

    let mut nav = head("overview", "");
    nav.push_str("<li><a class=\"t on\" data-k=\"__report\">report</a></li>");
    nav.push_str(&row(None, "raw envelope", Some("__raw"), None));
    nav.push_str("</ul></div>");

    let mut claimed: Vec<&str> = vec![];
    for t in TABS {
        nav.push_str(&head(t.name, &t.key.to_string()));
        if t.subs.is_empty() {
            let mine: Vec<&str> = BACKED_BY
                .iter()
                .filter(|(tab, sub, _)| *tab == t.name && sub.is_empty())
                .map(|(_, _, k)| *k)
                .collect();
            // Neither sub-tabs nor an array behind it. Label the node with
            // what the tab IS rather than repeating the name one line above
            // it — which is the only thing `desc` is good for out here.
            if mine.is_empty() {
                nav.push_str(&row(None, t.desc, None, None));
            }
            for k in mine {
                if k == "__files" {
                    nav.push_str(&row(None, "files", Some(k), Some(files.to_string())));
                } else if has(k) {
                    claimed.push(k);
                    nav.push_str(&row(None, k, Some(k), Some(count(k).to_string())));
                } else {
                    nav.push_str(&row(None, k, None, None));
                }
            }
        } else {
            for (i, sb) in t.subs.iter().enumerate() {
                let k = BACKED_BY
                    .iter()
                    .find(|(tab, sub, _)| *tab == t.name && *sub == sb.name)
                    .map(|(_, _, k)| *k);
                match k {
                    Some(k) if has(k) => {
                        claimed.push(k);
                        nav.push_str(&row(
                            Some(i + 1),
                            sb.name,
                            Some(k),
                            Some(count(k).to_string()),
                        ));
                    }
                    _ => nav.push_str(&row(Some(i + 1), sb.name, None, None)),
                }
            }
        }
        nav.push_str("</ul></div>");
    }

    let rest: Vec<&String> = tabs.iter().filter(|t| !claimed.contains(&t.as_str())).collect();
    if !rest.is_empty() {
        nav.push_str(&head("other", ""));
        for t in rest {
            nav.push_str(&row(None, t, Some(t), Some(count(t).to_string())));
        }
        nav.push_str("</ul></div>");
    }

    // The envelope goes in as JSON inside a script tag of a non-JS type, so
    // the browser hands it over as text and nothing in it can execute. `</` is
    // the only sequence that could close the tag early.
    // The report rides INSIDE the envelope rather than in a second tag. A
    // <script type="text/plain"> would need its own escaping rules, and JSON
    // string escaping is one set of rules already written and already correct.
    let mut with_report = envelope.clone();
    if let Some(o) = with_report.as_object_mut() {
        o.insert("report".into(), Value::String(markdown.to_string()));
    }
    let data =
        serde_json::to_string(&with_report).unwrap_or_else(|_| "{}".into()).replace("</", "<\\/");

    // A template with sentinels rather than format!: the page is mostly CSS
    // and JavaScript, both of which are made of braces, and `format!` would
    // need every one of them doubled — a transformation that is invisible when
    // it goes wrong and breaks the page rather than the build.
    TEMPLATE
        .replace("__TITLE__", &esc(title))
        .replace("__MEASURED__", &esc(&measured))
        .replace("__FILES__", &files.to_string())
        .replace("__NAV__", &nav)
        .replace("__SWITCH__", switcher)
        .replace("__DATA__", &data)
}

const TEMPLATE: &str = r##"<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>__TITLE__</title>
<style>
/* ── the terminal ──────────────────────────────────────────────────────────
   This page is a screenshot of the panel, not a web dashboard that happens to
   be dark. Everything below exists to hold that: one monospace cell grid, the
   panel's own palette lifted from view/draw.rs rather than eyeballed, meters
   drawn from the same block glyphs, and a phosphor surface over the lot.

   The colours are the constants, not approximations of them. DIM is
   Rgb(58,62,74), LABEL is Rgb(120,128,145), the accent is the Rgb(120,200,255)
   that draw.rs gives a focused tab, and --ok/--warn/--bad are the three stops
   of grad(). Change one there and change it here; nowhere else. */
:root{
  --bg:#0b0e14; --bg-lift:#101520; --rule:#171c26;
  --dim:#3a3e4a; --floor:#404040; --label:#788091; --accent:#78c8ff;
  --ok:#40dc78; --warn:#f0de40; --bad:#f04848; --fg:#c8ccd4;
  --w:272px;
  /* One cell. Every horizontal measure below is a multiple of it, so columns
     land on the grid the way they do in a terminal instead of near it. */
  --cell:7.8px; --line:1.55;
}
*{box-sizing:border-box}
html{background:var(--bg)}
body{
  margin:0; background:var(--bg); color:var(--fg);
  /* A terminal font, and the fallbacks that actually carry U+2580-259F and
     U+2800-28FF — the blocks the meters are made of and the braille the
     sparklines are. A stack that falls back to a proportional face would
     break the grid, so the last resort is still monospace. */
  font-family:ui-monospace,"JetBrainsMono Nerd Font","JetBrains Mono",
    "FiraCode Nerd Font","Fira Code","Cascadia Code",Menlo,Consolas,
    "DejaVu Sans Mono","Liberation Mono",monospace;
  font-size:13px; line-height:var(--line);
  /* Ligatures turn "->" into an arrow that is one glyph wide where the panel
     prints two characters. Off, everywhere. */
  font-variant-ligatures:none; font-feature-settings:"liga" 0,"calt" 0;
  font-variant-numeric:tabular-nums;
  -webkit-font-smoothing:antialiased;
  text-rendering:optimizeSpeed;
}

/* ── the phosphor surface ──────────────────────────────────────────────────
   Two fixed overlays, both inert. Scanlines first, then a vignette that pulls
   the corners down the way a curved tube does. Kept subtle on purpose: this
   should read as "a terminal" at a glance and disappear by the second glance,
   because the numbers underneath are the point. */
body::before,body::after{content:"";position:fixed;inset:0;pointer-events:none}
body::before{
  z-index:98;
  background:
    radial-gradient(130% 100% at 50% 42%,transparent 52%,rgba(0,0,0,.62) 100%),
    radial-gradient(90% 60% at 50% 0%,rgba(120,200,255,.045),transparent 70%);
}
body::after{
  z-index:99; opacity:.55;
  background:repeating-linear-gradient(180deg,
    rgba(0,0,0,.22) 0 1px, transparent 1px 3px);
}
/* Anything the eye should read as lit rather than printed. Bloom is cheap and
   it is most of what separates a CRT from a dark stylesheet. */
.glow{text-shadow:0 0 7px currentColor,0 0 18px rgba(120,200,255,.22)}

/* ── the header line ───────────────────────────────────────────────────────
   The panel's top row: what is being measured, when, and the keys. */
.bar{display:flex;align-items:center;gap:10px;flex-wrap:wrap;
  margin:0 8px 14px;padding:0 4px 10px;border-bottom:1px solid var(--rule)}
.bar h1{margin:0;font-size:13px;font-weight:700;color:var(--accent);
  letter-spacing:.04em;text-shadow:0 0 7px rgba(120,200,255,.45)}
.bar h1::before{content:"\2500\2500\2524\00a0";color:var(--dim);font-weight:400;
  text-shadow:none}
.bar h1::after{content:"\00a0\251C\2500\2500";color:var(--dim);font-weight:400;
  text-shadow:none}
.chip{border:1px solid var(--dim);border-radius:3px;padding:0 6px;
  font-size:11px;color:var(--label)}
.tag{color:var(--accent);font-size:11px}
.asof{color:var(--label);font-size:11px}
.keys{color:var(--dim);font-size:11px;margin-left:auto}
/* The command line the panel parks at the bottom, with its cursor still
   blinking. Nothing types into it — it is the frame of the thing, and the
   page looks unfinished without it. */
.keys::after{content:"\00a0:\2588";color:var(--accent);animation:blink 1.1s steps(1) infinite}
@keyframes blink{0%,49%{opacity:1}50%,100%{opacity:0}}
@media (prefers-reduced-motion:reduce){.keys::after{animation:none}}

/* ── the hamburger and its scrim ───────────────────────────────────────── */
.ham{position:fixed;top:10px;left:10px;z-index:60;background:var(--bg);
  color:var(--accent);border:1px solid var(--dim);border-radius:4px;
  font:inherit;font-size:15px;line-height:1;padding:5px 9px;cursor:pointer}
.ham:hover{border-color:var(--accent);box-shadow:0 0 12px rgba(120,200,255,.25)}
.scrim{position:fixed;inset:0;z-index:50;background:rgba(4,6,10,.72);
  opacity:0;visibility:hidden;transition:opacity .18s}
.scrim.on{opacity:1;visibility:visible}

/* ── the sidebar: the panel's own tab tree ─────────────────────────────── */
.sidebar{position:fixed;top:0;left:0;bottom:0;width:var(--w);z-index:55;
  background:var(--bg-lift);border-right:1px solid var(--dim);
  overflow-y:auto;transform:translateX(-100%);transition:transform .2s}
.sidebar.on{transform:none}
.sb-head{display:flex;align-items:center;gap:8px;padding:12px 12px 10px;
  border-bottom:1px solid var(--rule)}
.sb-head h2{margin:0;font-size:12px;font-weight:700;color:var(--accent);
  letter-spacing:.1em;text-transform:uppercase;
  text-shadow:0 0 8px rgba(120,200,255,.4)}
.x{margin-left:auto;background:none;border:0;color:var(--label);font:inherit;
  font-size:17px;line-height:1;cursor:pointer}
.x:hover{color:var(--bad)}

.grp{margin-top:10px}
.tab{display:flex;align-items:center;gap:6px;padding:0 12px 3px;
  color:var(--label);font-size:11px;letter-spacing:.09em;text-transform:uppercase}
.tab .k{color:var(--dim);border:1px solid var(--dim);border-radius:3px;
  padding:0 4px;font-size:10px;font-style:normal}
.grp ul{list-style:none;margin:0;padding:0}
/* The spine and the elbows, drawn rather than typed: same shape the panel
   prints, and it stays right when a branch is the last one. */
.grp li{position:relative;padding-left:24px}
.grp li::before{content:"";position:absolute;left:14px;top:0;height:100%;
  border-left:1px solid var(--dim)}
.grp li:last-child::before{height:50%}
.grp li::after{content:"";position:absolute;left:14px;top:50%;width:6px;
  border-top:1px solid var(--dim)}
.grp a{display:flex;align-items:baseline;gap:6px;padding:2px 12px 2px 0;
  color:var(--label);text-decoration:none;cursor:pointer}
.grp a:hover{color:var(--fg)}
/* Reverse video, the way a terminal marks the row under the cursor. A tinted
   background is the web's idea of selection; this is the panel's. */
.grp a.on{color:var(--bg);background:var(--accent);font-weight:700;
  box-shadow:0 0 14px rgba(120,200,255,.35)}
.grp a.on .n,.grp a.on b{color:var(--bg);opacity:.7}
/* A view the panel has that this export does not carry. Shown, not hidden. */
.grp a.off{color:var(--dim);cursor:default}
.grp a .n{color:var(--dim);font-style:normal;font-size:11px}
.grp a b{margin-left:auto;color:var(--dim);font-weight:400;font-size:11px}

/* ── content ─────────────────────────────────────────────────────────────── */
.content{padding:52px 16px 40px}
@media (min-width:1000px){
  .ham,.scrim,.x{display:none}
  .sidebar{transform:none}
  .content{margin-left:var(--w);padding-top:18px}
}

/* draw::bbox — rounded frame, title bracketed into the top edge, the count
   bracketed into the bottom-right where the panel parks its hint. */
.panel{position:relative;border:1px solid var(--dim);border-radius:6px;
  margin:0 0 18px;background:linear-gradient(180deg,rgba(120,200,255,.02),transparent 120px)}
.panel:hover{border-color:#4a5060}
.panel-head h3{position:absolute;top:-9px;left:12px;margin:0;padding:0 3px;
  background:var(--bg);font-size:12px;font-weight:700;color:var(--accent);
  text-shadow:0 0 8px rgba(120,200,255,.35)}
.panel-head h3::before{content:"\2524";color:var(--dim);font-weight:400;text-shadow:none}
.panel-head h3::after{content:"\251C";color:var(--dim);font-weight:400;text-shadow:none}
.panel-head .count{position:absolute;bottom:-9px;right:12px;padding:0 3px;
  background:var(--bg);color:var(--dim);font-size:11px}
.panel-head .count::before{content:"\2524"}
.panel-head .count::after{content:"\251C"}
.panel-body{padding:16px 13px 13px}
pre{margin:0;white-space:pre-wrap;word-break:break-word;color:var(--fg);font:inherit}

/* ── meters ────────────────────────────────────────────────────────────────
   draw::meter, in a browser: a run of U+2588 over a run of U+2591, coloured by
   grad() at the same fraction. Not a styled div — the actual glyphs, so it
   lines up with the text beside it and survives being copied out of the page.
   The empty half sits at GRAPH_FLOOR, which is where the panel leaves it. */
.mtr{white-space:pre;letter-spacing:-.5px}
.mtr .e{color:var(--floor)}
td .mtr{margin-right:8px}

/* Wide tables scroll inside their own box; the page itself never does. */
.scroll{overflow:auto;max-height:76vh;margin:14px 2px 6px;border-radius:0 0 5px 5px}
table{border-collapse:collapse;width:100%;font-size:12px}
th,td{text-align:left;padding:3px 10px;white-space:nowrap;border-bottom:1px solid var(--rule)}
th{position:sticky;top:0;z-index:1;background:var(--bg);color:var(--label);font-weight:400;
  font-size:11px;letter-spacing:.06em;text-transform:uppercase;border-bottom:1px solid var(--dim)}
td.num{text-align:right;font-variant-numeric:tabular-nums}
td.nil{color:var(--dim)}
/* The cursor row, inverted, like the process list under the panel's cursor. */
tr:hover td{background:#141821;color:#e6ebf2}
tr:hover td.nil{color:var(--label)}
tr:last-child td{border-bottom:none}
.pill{border:1px solid var(--dim);border-radius:3px;padding:0 5px;font-size:11px}
.pill.ok{color:var(--ok);border-color:#235c3a}
.pill.warn{color:var(--warn);border-color:#5c5423}
.pill.bad{color:var(--bad);border-color:#5c2323}

/* Scrollbars that belong to the same machine as the rest of it. */
*::-webkit-scrollbar{width:9px;height:9px}
*::-webkit-scrollbar-track{background:var(--bg)}
*::-webkit-scrollbar-thumb{background:var(--dim);border:2px solid var(--bg);border-radius:5px}
*::-webkit-scrollbar-thumb:hover{background:var(--label)}
*{scrollbar-width:thin;scrollbar-color:var(--dim) var(--bg)}
::selection{background:var(--accent);color:var(--bg)}
</style></head><body>
<button class="ham" id="ham">&#9776;</button>
<div class="scrim" id="scrim"></div>
<nav class="sidebar" id="sb">
  <div class="sb-head"><h2>my-konsole</h2><button class="x" id="cls">&times;</button></div>
  <div class="grp"><div class="tab">machine</div><ul>__SWITCH__</ul></div>
  __NAV__
</nav>
<main class="content">
  <div class="bar">
    <span class="chip">__TITLE__</span>
    <span class="asof">measured __MEASURED__</span>
    <span class="tag">static</span>
    <span class="keys">__FILES__ files tracked</span>
  </div>
  <div id="out"></div>
</main>
<script type="application/json" id="env">__DATA__</script>
<script>
const E = JSON.parse(document.getElementById('env').textContent);
const S = E.snapshot || {};
const out = document.getElementById('out');
/* draw::grad — the same two lerps, so a bar here is the colour it is there.
   green(64,220,120) -> yellow(240,222,64) -> red(240,72,72), split at 0.5. */
function grad(t){
  t = Math.max(0, Math.min(1, t));
  const L = (a, b, x) => Math.round(a + (b - a) * x);
  return t < 0.5
    ? 'rgb(' + L(64,240,t*2) + ',' + L(220,222,t*2) + ',' + L(120,64,t*2) + ')'
    : 'rgb(' + L(240,240,(t-.5)*2) + ',' + L(222,72,(t-.5)*2) + ',' + L(64,72,(t-.5)*2) + ')';
}
/* draw::meter — a run of full blocks over a run of light shade, the real
   glyphs rather than a styled div, so it sits on the same cell grid as the
   text beside it and still means something when copied out of the page. */
function meter(frac, w){
  w = w || 14;
  const f = Math.max(0, Math.min(w, Math.round(frac * w)));
  return '<span class="mtr"><i style="color:' + grad(frac) + '">'
       + '\u2588'.repeat(f) + '</i><i class="e">' + '\u2591'.repeat(w - f) + '</i></span>';
}
/* A column is a meter when it is a percentage: the panel draws a bar for
   every one of these and a bare number for nothing else. */
const PCT = /(^|_)(pct|percent|usage)$|%/i;
function esc(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
/* The panel colours a socket by who can reach it; so does this. */
const SCOPE = { world:'bad', mesh:'warn', loopback:'ok', running:'ok', exited:'bad', dead:'bad' };
function cell(v, col){
  if (v === null || v === undefined || v === '') return '<td class="nil">-</td>';
  if (typeof v === 'boolean') return '<td><span class="pill ' + (v?'ok':'bad') + '">' + v + '</span></td>';
  if (typeof v === 'number' && col && PCT.test(col))
    return '<td class="num">' + meter(v / 100, 12) + v.toFixed(1) + '%</td>';
  if (typeof v === 'number') return '<td class="num">' + v + '</td>';
  if (typeof v === 'object') return '<td>' + esc(JSON.stringify(v)) + '</td>';
  const c = SCOPE[String(v).toLowerCase()];
  if (c) return '<td><span class="pill ' + c + '">' + esc(v) + '</span></td>';
  return '<td>' + esc(v) + '</td>';
}
function table(rows){
  if (!rows.length) return '<div class="panel-body"><pre>no rows</pre></div>';
  /* Union of keys, not the first row's: a row that carries one extra field
     must not make that field invisible for the whole table. */
  const cols = [];
  rows.forEach(r => Object.keys(r).forEach(k => { if (!cols.includes(k)) cols.push(k); }));
  const head = cols.map(c => '<th>' + esc(c) + '</th>').join('');
  const body = rows.map(r => '<tr>' + cols.map(c => cell(r[c], c)).join('') + '</tr>').join('');
  return '<div class="scroll"><table><thead><tr>' + head + '</tr></thead><tbody>'
       + body + '</tbody></table></div>';
}
function panel(title, count, inner, pad){
  return '<div class="panel"><div class="panel-head"><h3>' + esc(title) + '</h3>'
       + (count === null ? '' : '<span class="count">' + count + '</span>')
       + '</div>' + (pad ? '<div class="panel-body">' + inner + '</div>' : inner) + '</div>';
}
function show(k){
  if (k === '__report') { out.innerHTML = panel('report', null, '<pre>' + esc(E.report || '') + '</pre>', 1); }
  else if (k === '__files') { const f = E.files || []; out.innerHTML = panel('files', f.length + ' paths', '<pre>' + esc(f.join('\n')) + '</pre>', 1); }
  else if (k === '__raw') { out.innerHTML = panel('raw envelope', null, '<pre>' + esc(JSON.stringify(E, null, 2)) + '</pre>', 1); }
  else { const rows = S[k] || []; out.innerHTML = panel(k, rows.length + ' rows', table(rows), 0); }
  if (window.innerWidth < 1000) close();
  window.scrollTo(0, 0);
}
const sb = document.getElementById('sb'), scrim = document.getElementById('scrim');
function close(){ sb.classList.remove('open'); scrim.classList.remove('on'); }
document.getElementById('ham').onclick = () => { sb.classList.add('open'); scrim.classList.add('on'); };
document.getElementById('cls').onclick = close;
scrim.onclick = close;
document.querySelectorAll('.t').forEach(b => b.onclick = () => {
  document.querySelectorAll('.t').forEach(x => x.classList.remove('on'));
  b.classList.add('on');
  show(b.dataset.k);
});
show('__report');
</script>
</body></html>
"##;
