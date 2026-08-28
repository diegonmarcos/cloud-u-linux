// The export, as a page.
//
// The panel is a terminal program and stays one. This is the same envelope the
// JSON/YAML/Markdown exports carry, rendered so it can be opened in a browser
// and read by someone who does not have the panel — or by the same person, on
// a phone, from a file the hub wrote hours ago.
//
// It is DATA-DRIVEN on purpose: the tab list is not a copy of the CLI's tab
// list, it is whatever arrays-of-objects the snapshot actually holds. A field
// added to the sampler shows up here on the next export with no edit, and a
// section a machine cannot report simply has no tab instead of an empty one
// that looks like a failure.
//
// Self-contained: no CDN, no fetch, no external font. The envelope is embedded
// in the page, so the file works from a USB stick with the network off.

use serde_json::Value;

/// The sections worth a tab, in the order the panel shows them. Anything else
/// in the snapshot that is an array of objects is appended after these, so a
/// new section is never invisible just because this list has not heard of it.
const PREFERRED: &[&str] = &[
    "compose", "images", "containers", "volumes", "networks", "services", "slices", "disks",
    "storage", "proc_table",
];

/// The parent each section hangs under in the sidebar. A flat list of tabs was
/// fine at eight and is not at thirty, and this page grows every time the
/// sampler learns a new array.
///
/// Same rule as PREFERRED above: this is an ordering hint, NOT a filter. A
/// section no group claims lands under "other" rather than disappearing,
/// because a field added to the sampler must never need an edit here to be
/// visible.
const GROUPS: &[(&str, &[&str])] = &[
    ("docker", &["compose", "containers", "images", "volumes", "networks"]),
    ("system", &["services", "slices", "proc_table", "units"]),
    ("storage", &["disks", "storage", "mounts"]),
    ("network", &["listening", "ifaces", "routes"]),
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

/// One page: the envelope, the Markdown report, and the tabs.
///
/// `title` names the machine and the moment, so a directory of these is
/// readable without opening any of them.
pub(crate) fn page(title: &str, envelope: &Value, markdown: &str, switcher: &str) -> String {
    let snap = envelope.get("snapshot").unwrap_or(&Value::Null);
    let tabs = sections(snap);
    let files = envelope.get("files").and_then(|f| f.as_array()).map(|a| a.len()).unwrap_or(0);
    let measured =
        envelope.get("measured").and_then(|m| m.as_str()).unwrap_or("local").to_string();

    // The sidebar is built here rather than in the page's JavaScript because
    // the row counts come from the snapshot, and a menu that can say how big
    // each section is before you open it is the difference between navigating
    // and guessing.
    let count = |k: &str| snap.get(k).and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0);
    let item = |k: &str, n: Option<usize>, on: bool| -> String {
        format!(
            "<li><a class=\"t{}\" data-k=\"{}\">{}{}</a></li>",
            if on { " on" } else { "" },
            esc(k),
            esc(k.trim_start_matches('_')),
            n.map(|n| format!("<b>{n}</b>")).unwrap_or_default()
        )
    };
    let open = |g: &str| format!("<div class=\"sidebar-section\"><h3>{}</h3><ul>", esc(g));

    let mut nav = open("overview");
    nav.push_str(&item("__report", None, true));
    nav.push_str(&item("__files", Some(files), false));
    nav.push_str(&item("__raw", None, false));
    nav.push_str("</ul></div>");

    let mut claimed: Vec<&str> = vec![];
    for (g, keys) in GROUPS {
        let mine: Vec<&String> = tabs.iter().filter(|t| keys.contains(&t.as_str())).collect();
        if mine.is_empty() {
            continue;
        }
        nav.push_str(&open(g));
        for t in mine {
            claimed.push(t.as_str());
            nav.push_str(&item(t, Some(count(t)), false));
        }
        nav.push_str("</ul></div>");
    }
    let rest: Vec<&String> = tabs.iter().filter(|t| !claimed.contains(&t.as_str())).collect();
    if !rest.is_empty() {
        nav.push_str(&open("other"));
        for t in rest {
            nav.push_str(&item(t, Some(count(t)), false));
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

const TEMPLATE: &str = r##"<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>__TITLE__</title>
<style>
/* Same palette and shell as vm-pilot and the watchdog web page: one machine
   panel should not look like a different product depending on which of the
   three wrote it. */
:root{--bg:#0d1117;--panel:#161b22;--border:#30363d;--fg:#c9d1d9;--muted:#8b949e;--accent:#58a6ff;--ok:#3fb950;--warn:#d29922;--bad:#f85149;--w:264px}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,"Segoe UI",Roboto,sans-serif}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
pre{margin:0;white-space:pre-wrap;word-break:break-word;font:12px/1.6 ui-monospace,Menlo,Consolas,monospace}

/* SIDEBAR — pinned on a wide screen, drawer on a narrow one. The hamburger
   is not decoration: this list is the section index and it grows every time
   the sampler learns a new array. */
.hamburger{position:fixed;top:12px;left:12px;z-index:1000;background:var(--panel);color:var(--fg);border:1px solid var(--border);border-radius:8px;padding:5px 11px;font-size:16px;cursor:pointer}
.sidebar{position:fixed;top:0;left:0;bottom:0;width:var(--w);z-index:999;background:var(--panel);border-right:1px solid var(--border);padding:16px;overflow-y:auto;transform:translateX(-100%);transition:transform .2s ease}
.sidebar.open{transform:translateX(0)}
.sidebar-header{display:flex;align-items:baseline;justify-content:space-between;gap:8px}
.sidebar-header h2{margin:0;font-size:.95rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.close-btn{background:none;border:none;color:var(--muted);font-size:20px;cursor:pointer;line-height:1}
.sidebar-section{margin-top:18px}
.sidebar-section h3{margin:0 0 6px;font-size:.7rem;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.sidebar-section ul{margin:0;padding:0;list-style:none}
.sidebar-section li{padding:1px 0}
.sidebar-section a{display:flex;justify-content:space-between;gap:8px;padding:4px 8px;border-radius:6px;font-size:.85rem;color:var(--fg);cursor:pointer}
.sidebar-section a:hover{background:#1f2630;text-decoration:none}
.sidebar-section a.on{background:#1f6feb26;color:var(--accent);box-shadow:inset 2px 0 0 var(--accent)}
.sidebar-section a b{font-weight:600;color:var(--muted);font-variant-numeric:tabular-nums}
.sidebar-section a.on b{color:var(--accent)}
.scrim{position:fixed;inset:0;background:#0008;z-index:998;display:none}
.scrim.on{display:block}

.content{padding:56px 16px 24px}
.status-bar{display:flex;align-items:center;flex-wrap:wrap;gap:8px;margin-bottom:14px}
.dot{width:9px;height:9px;border-radius:50%;background:var(--ok);flex:none}
.crumb{color:var(--muted);font-size:.85rem}
.crumb b{color:var(--fg);font-weight:600}

/* PANEL — a table is a child of the section that names it, not a bare grid
   dropped on the page. */
.panel{background:var(--panel);border:1px solid var(--border);border-radius:8px;min-width:0;overflow:hidden}
.panel-head{display:flex;align-items:baseline;justify-content:space-between;gap:8px;padding:10px 12px;border-bottom:1px solid var(--border)}
.panel-head h3{margin:0;font-size:.9rem}
.panel-head .count{color:var(--muted);font-size:.78rem;font-variant-numeric:tabular-nums}
.panel-body{padding:12px}
/* Wide tables scroll inside their own panel; the page itself never does. */
.scroll{overflow:auto;max-height:70vh}
table{border-collapse:collapse;width:100%;font-size:.8rem}
th,td{text-align:left;padding:5px 10px;white-space:nowrap;border-bottom:1px solid var(--border)}
th{color:var(--muted);font-weight:600;position:sticky;top:0;background:var(--panel);z-index:1}
tbody tr:hover td{background:#1f26304d}
tr:last-child td{border-bottom:none}
td.num{text-align:right;font-variant-numeric:tabular-nums}
td.no{color:var(--muted)}
.pill{padding:1px 7px;border-radius:10px;font-size:.72rem;border:1px solid var(--border);color:var(--muted)}
.pill.ok{color:var(--ok);border-color:#3fb95066}
.pill.bad{color:var(--bad);border-color:#f8514966}

@media (min-width:1000px){
  .hamburger,.scrim{display:none}
  .sidebar{transform:none}
  .content{margin-left:var(--w);padding-top:20px}
}
</style>

<button class="hamburger" id="ham" aria-label="sections">&#9776;</button>
<div class="scrim" id="scrim"></div>

<aside class="sidebar" id="sb">
  <div class="sidebar-header">
    <h2>__TITLE__</h2>
    <button class="close-btn" id="cls" aria-label="close">&times;</button>
  </div>

  <!-- MACHINES first: which box you are reading is a bigger question than
       which section of it, so it sits above the sections rather than in
       them. Plain links to sibling files — no fetch, works from a USB stick. -->
  <div class="sidebar-section">
    <h3>machine</h3>
    <ul class="switch">__SWITCH__</ul>
  </div>
  __NAV__
</aside>

<div class="content">
  <div class="status-bar">
    <span class="dot"></span>
    <span class="crumb"><b>__TITLE__</b></span>
    <span class="crumb">· measured __MEASURED__ · __FILES__ paths</span>
  </div>
  <div id="out"></div>
</div>

<script type="application/json" id="d">__DATA__</script>
<script>
const E = JSON.parse(document.getElementById('d').textContent);
const S = E.snapshot || {};
const out = document.getElementById('out');
function esc(s){ return s.replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
function cell(v){
  if (v === null || v === undefined || v === '') return '<td class="no">&mdash;</td>';
  if (typeof v === 'boolean') return '<td><span class="pill ' + (v?'ok':'bad') + '">' + v + '</span></td>';
  if (typeof v === 'number') return '<td class="num">' + v + '</td>';
  if (typeof v === 'object') return '<td>' + esc(JSON.stringify(v)) + '</td>';
  return '<td>' + esc(String(v)) + '</td>';
}
function table(rows){
  // Columns are the UNION of every row's keys: a row missing one is a row
  // missing a value, not a reason to drop the column for everyone else.
  const cols = [];
  for (const r of rows) for (const k of Object.keys(r)) if (!cols.includes(k)) cols.push(k);
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
"##;
