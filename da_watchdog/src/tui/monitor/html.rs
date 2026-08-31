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

/// The page with no machine in it — the UI the phone app ships.
///
/// The report was always written with its data already baked in, which made
/// the UI a property of having measured something. On a phone that is wrong
/// twice over: the app has to open before it can reach a machine, and the
/// machine it reaches answers over ssh a second or two later. An app whose
/// interface only exists once a remote command has succeeded shows an error
/// where a dashboard should be, every time the phone is out of range of the
/// thing it monitors.
///
/// So the shell is generated once, at release time, and carried in the APK:
/// the app bar, the drawer, the tab tree and every panel frame, rendered
/// against an empty machine. `window.__wdRender` then swaps a real envelope in
/// when one arrives, and the reader keeps whichever panel they were on.
///
/// One placeholder row per section, because [`sections`] admits a tab only for
/// a non-empty array of objects, and a drawer of dead entries is not a menu.
/// The rows are `{}` rather than fake fields: an empty object gives a table
/// with no columns instead of a column of invented ones.
pub(crate) fn app_shell() -> String {
    let mut snap = serde_json::Map::new();
    for k in PREFERRED {
        snap.insert((*k).into(), serde_json::json!([{}]));
    }
    let env = serde_json::json!({
        "snapshot": Value::Object(snap),
        "files": [],
        "machines": [],
        "exported": "",
        "measured": "device",
    });
    page("watchdog", &env, "", "", "data-view=\"mobile\"")
}

/// One page: the envelope, the Markdown report, and the panel's tab tree.
///
/// `title` names the machine and the moment, so a directory of these is
/// readable from the tab bar alone. `switcher` is the other machines in the
/// same export, already rendered — this module knows how a machine list looks,
/// the exporter knows which machines there are.
/// `view` is "" for the desktop page and `data-view="mobile"` for the phone
/// one. The same template, the same envelope and the same compiled renderer —
/// one attribute decides how they dress, because two page generators would be
/// two places for the palette and the box order to drift apart.
pub(crate) fn page(
    title: &str,
    envelope: &Value,
    markdown: &str,
    switcher: &str,
    view: &str,
) -> String {
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
    nav.push_str("<li><a class=\"t on\" data-k=\"__overview\">overview</a></li>");
    nav.push_str("<li><a class=\"t\" data-k=\"__report\">report</a></li>");
    // ALWAYS PRESENT, like report and raw — never gated on the envelope
    // carrying rules. The app shell is generated against an EMPTY machine, so
    // a nav row that appears only when there is a policy would be missing from
    // the APK's own interface and could never come back: the shell ships in
    // the APK and only the data arrives later.
    // Unconditional for the same reason rules is: the app shell is generated
    // against an empty machine, so a row gated on the fleet being present
    // would be missing from the APK's interface and could never appear.
    nav.push_str(&row(None, "machines", Some("__machines"), None));
    nav.push_str(&row(None, "rules", Some("__rules"), None));
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

    // The stylesheet and the renderer are not written here. They are authored as
    // SCSS and TypeScript in da_watchdog/web/src/report.{scss,ts} and compiled by
    // that project's build.sh into its committed dist/ — because a stylesheet
    // living as a Rust string literal cannot be compiled, linted, or diffed as a
    // stylesheet, and a renderer living there cannot be type-checked at all.
    //
    // include_str! rather than a runtime read: the report has to render from a
    // single binary on a machine that has never seen this repo.
    const CSS: &str = include_str!("../../../web/dist/report.css");
    const JS: &str = include_str!("../../../web/dist/report.js");

    // A template with sentinels rather than format!: the page is mostly CSS
    // and JavaScript, both of which are made of braces, and `format!` would
    // need every one of them doubled — a transformation that is invisible when
    // it goes wrong and breaks the page rather than the build.
    TEMPLATE
        // The two compiled artifacts first: they carry no sentinels of their
        // own, and doing them here keeps the page's own substitutions from
        // having to walk 20KB of stylesheet looking for them.
        .replace("__VIEW__", view)
        .replace("__CSS__", CSS)
        .replace("__JS__", JS)
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
<style>__CSS__</style></head><body __VIEW__>
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
<script>__JS__</script>
</body></html>
"##;
