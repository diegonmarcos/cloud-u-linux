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

fn esc(s: &str) -> String {
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
pub(crate) fn page(title: &str, envelope: &Value, markdown: &str) -> String {
    let snap = envelope.get("snapshot").unwrap_or(&Value::Null);
    let tabs = sections(snap);
    let files = envelope.get("files").and_then(|f| f.as_array()).map(|a| a.len()).unwrap_or(0);
    let measured =
        envelope.get("measured").and_then(|m| m.as_str()).unwrap_or("local").to_string();

    let mut nav = String::from(
        "<button class=\"t on\" data-k=\"__report\">report</button>\
         <button class=\"t\" data-k=\"__files\">files</button>",
    );
    for k in &tabs {
        nav.push_str(&format!("<button class=\"t\" data-k=\"{}\">{}</button>", esc(k), esc(k)));
    }
    nav.push_str("<button class=\"t\" data-k=\"__raw\">raw</button>");

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
        .replace("__DATA__", &data)
}

const TEMPLATE: &str = r##"<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>__TITLE__</title>
<style>
:root{--bg:#0b0e14;--fg:#c9d1d9;--dim:#6b7684;--acc:#7ee787;--warn:#e3b341;--bad:#f85149;--line:#1f2630}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
header{padding:14px 18px;border-bottom:1px solid var(--line)}
h1{margin:0;font-size:15px;color:var(--acc);font-weight:600}
.sub{color:var(--dim);font-size:12px;margin-top:4px}
nav{display:flex;flex-wrap:wrap;gap:4px;padding:10px 14px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg)}
.t{background:transparent;border:1px solid var(--line);color:var(--dim);padding:4px 10px;border-radius:3px;cursor:pointer;font:inherit}
.t:hover{color:var(--fg)}
.t.on{color:var(--bg);background:var(--acc);border-color:var(--acc)}
main{padding:14px 18px}
.wrap{overflow-x:auto}
table{border-collapse:collapse;width:100%;min-width:max-content}
th{text-align:left;color:var(--dim);font-weight:600;border-bottom:1px solid var(--line);padding:5px 12px 5px 0;white-space:nowrap}
td{padding:3px 12px 3px 0;border-bottom:1px solid #12171f;white-space:nowrap}
tr:hover td{background:#111721}
pre{white-space:pre-wrap;word-break:break-word;margin:0}
.count{color:var(--dim);margin-bottom:8px}
.no{color:var(--dim)}
.v-false{color:var(--bad)} .v-true{color:var(--acc)}
</style>
<header><h1>__TITLE__</h1><div class="sub">measured: __MEASURED__ · __FILES__ paths · this page is the export, not a live view</div></header>
<nav>__NAV__</nav>
<main id="out"></main>
<script type="application/json" id="d">__DATA__</script>
<script>
const E = JSON.parse(document.getElementById('d').textContent);
const S = E.snapshot || {};
const out = document.getElementById('out');
function esc(s){ return s.replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
function cell(v){
  if (v === null || v === undefined || v === '') return '<td class="no">—</td>';
  if (typeof v === 'boolean') return '<td class="v-' + v + '">' + v + '</td>';
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
  return '<div class="count">' + rows.length + ' rows</div><div class="wrap"><table><thead><tr>'
       + head + '</tr></thead><tbody>' + body + '</tbody></table></div>';
}
function show(k){
  if (k === '__report') { out.innerHTML = '<pre>' + esc(E.report || '') + '</pre>'; return; }
  if (k === '__files')  { const f = E.files || []; out.innerHTML = '<div class="count">' + f.length + ' paths</div><pre>' + esc(f.join('\n')) + '</pre>'; return; }
  if (k === '__raw')    { out.innerHTML = '<pre>' + esc(JSON.stringify(E, null, 2)) + '</pre>'; return; }
  out.innerHTML = table(S[k] || []);
}
document.querySelectorAll('.t').forEach(b => b.onclick = () => {
  document.querySelectorAll('.t').forEach(x => x.classList.remove('on'));
  b.classList.add('on');
  show(b.dataset.k);
});
show('__report');
</script>
"##;

/// A directory listing, rewritten on every export.
///
/// Newest first, because the reason you open this is almost always "what did I
/// just export". Plain links: the pages are files, and a file listing that
/// needs a server to work is not a file listing.
pub(crate) fn index(dir: &str) -> String {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.ends_with(".html") && n != "index.html")
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names.reverse();
    let items: String = names
        .iter()
        .map(|n| format!("<li><a href=\"{0}\">{0}</a></li>", esc(n)))
        .collect();
    format!(
        r#"<!doctype html><meta charset="utf-8"><title>watchdog exports</title>
<style>body{{margin:0;padding:24px;background:#0b0e14;color:#c9d1d9;font:13px/1.7 ui-monospace,Menlo,Consolas,monospace}}
h1{{font-size:15px;color:#7ee787;margin:0 0 4px}}.sub{{color:#6b7684;margin-bottom:16px}}
ul{{list-style:none;padding:0;margin:0}}a{{color:#c9d1d9;text-decoration:none}}a:hover{{color:#7ee787}}</style>
<h1>watchdog exports</h1><div class="sub">{n} pages · newest first</div><ul>{items}</ul>
"#,
        n = names.len(),
        items = items
    )
}
