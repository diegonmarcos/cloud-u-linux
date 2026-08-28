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
/* view::draw's palette, lifted value for value. The panel and this page
   describe the same machine and should not look like two products. */
:root{
  --bg:#0b0e14;      /* the terminal under the panel */
  --dim:#3a3e4a;     /* draw::DIM — every border the panel draws */
  --label:#788091;   /* draw::LABEL — column heads, inactive tabs */
  --accent:#78c8ff;  /* the active tab and every box title */
  --ok:#40dc78;      /* grad(0.0) */
  --warn:#f0de40;    /* grad(0.5) */
  --bad:#f04848;     /* grad(1.0) */
  --fg:#c8ccd4;
  --rule:#1b1f27;
  --w:272px;
}
*{box-sizing:border-box}
/* Monospace throughout: the subject is a terminal. */
body{margin:0;background:var(--bg);color:var(--fg);
  font:13px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,"DejaVu Sans Mono",monospace}

/* ── the frame's top line ────────────────────────────────────────────────── */
.bar{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin:0 0 16px}
.chip{background:var(--accent);color:var(--bg);font-weight:700;padding:1px 8px}
.asof{color:var(--label)}
.tag{color:var(--label);border:1px solid var(--dim);padding:0 6px;font-size:11px}
.keys{color:var(--dim);font-size:11px;margin-left:auto}

/* ── the drawer ──────────────────────────────────────────────────────────── */
.ham{position:fixed;top:10px;left:10px;z-index:60;background:var(--bg);color:var(--accent);
  border:1px solid var(--dim);border-radius:5px;padding:2px 9px;font:inherit;cursor:pointer}
.scrim{position:fixed;inset:0;background:#000a;opacity:0;pointer-events:none;
  transition:opacity .18s;z-index:39}
.scrim.on{opacity:1;pointer-events:auto}
.sidebar{position:fixed;top:0;left:0;bottom:0;width:var(--w);z-index:40;
  background:var(--bg);border-right:1px solid var(--dim);padding:10px 0 28px;overflow-y:auto;
  transform:translateX(-100%);transition:transform .18s ease}
.sidebar.open{transform:none}
.sb-head{display:flex;align-items:center;justify-content:space-between;padding:2px 12px 8px}
.sb-head h2{margin:0;font-size:12px;color:var(--accent);font-weight:700}
.x{background:none;border:none;color:var(--label);font:inherit;font-size:16px;cursor:pointer}

/* ── the tab tree ────────────────────────────────────────────────────────── */
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
.grp a.on{color:var(--accent);font-weight:700}
/* A view the panel has that this export does not carry. Shown, not hidden. */
.grp a.off{color:var(--dim);cursor:default}
.grp a .n{color:var(--dim);font-style:normal;font-size:11px}
.grp a b{margin-left:auto;color:var(--dim);font-weight:400;font-size:11px}
.grp a.on b{color:var(--accent)}

/* ── content ─────────────────────────────────────────────────────────────── */
.content{padding:52px 16px 40px}
@media (min-width:1000px){
  .ham,.scrim,.x{display:none}
  .sidebar{transform:none}
  .content{margin-left:var(--w);padding-top:18px}
}

/* draw::bbox — rounded frame, title bracketed into the top edge, the count
   bracketed into the bottom-right where the panel parks its hint. */
.panel{position:relative;border:1px solid var(--dim);border-radius:6px;margin:0 0 18px}
.panel-head h3{position:absolute;top:-9px;left:12px;margin:0;padding:0 3px;background:var(--bg);
  font-size:12px;font-weight:700;color:var(--accent)}
.panel-head h3::before{content:"\2524";color:var(--dim);font-weight:400}
.panel-head h3::after{content:"\251C";color:var(--dim);font-weight:400}
.panel-head .count{position:absolute;bottom:-9px;right:12px;padding:0 3px;background:var(--bg);
  color:var(--dim);font-size:11px}
.panel-head .count::before{content:"\2524"}
.panel-head .count::after{content:"\251C"}
.panel-body{padding:16px 13px 13px}
pre{margin:0;white-space:pre-wrap;word-break:break-word;color:var(--fg);font:inherit}

/* Wide tables scroll inside their own box; the page itself never does. */
.scroll{overflow:auto;max-height:76vh;margin:14px 2px 6px;border-radius:0 0 5px 5px}
table{border-collapse:collapse;width:100%;font-size:12px}
th,td{text-align:left;padding:3px 10px;white-space:nowrap;border-bottom:1px solid var(--rule)}
th{position:sticky;top:0;z-index:1;background:var(--bg);color:var(--label);font-weight:400;
  font-size:11px;letter-spacing:.06em;text-transform:uppercase;border-bottom:1px solid var(--dim)}
td.num{text-align:right;font-variant-numeric:tabular-nums}
td.nil{color:var(--dim)}
tr:hover td{background:#141821}
tr:last-child td{border-bottom:none}
.pill{border:1px solid var(--dim);border-radius:3px;padding:0 5px;font-size:11px}
.pill.ok{color:var(--ok);border-color:#235c3a}
.pill.warn{color:var(--warn);border-color:#5c5423}
.pill.bad{color:var(--bad);border-color:#5c2323}
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
function esc(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
/* The panel colours a socket by who can reach it; so does this. */
const SCOPE = { world:'bad', mesh:'warn', loopback:'ok', running:'ok', exited:'bad', dead:'bad' };
function cell(v){
  if (v === null || v === undefined || v === '') return '<td class="nil">-</td>';
  if (typeof v === 'boolean') return '<td><span class="pill ' + (v?'ok':'bad') + '">' + v + '</span></td>';
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
  const body = rows.map(r => '<tr>' + cols.map(c => cell(r[c])).join('') + '</tr>').join('');
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
