// The panel's own map: every page, in the order the strip shows them.
//
// WHY IT IS GENERATED
// Built from TABS and MENU — the same tables the tab strip and the menu are
// drawn from — so the map cannot describe a page that does not exist or miss
// one that does. A hand-written map is a second list to maintain, and the one
// thing worse than no map is a map that lies. The comment in
// aa_cloud-superapp/activity_main.xml naming the wrong menu per home star is
// exactly that failure, and it survived for months.
//
// It travels in the envelope, so the html report and the phone show the same
// tree without either of them knowing what a Tab is.

use super::super::model::keys::MENU;
use super::super::model::tabs::TABS;

/// One node of the map. `depth` rather than nesting, because the only thing
/// any renderer does with it is indent — and a tree of owned children costs
/// three renderers a recursive walk to draw a list.
pub(crate) struct Node {
    pub(crate) depth: u8,
    /// The key that reaches it, where one exists.
    pub(crate) key: String,
    pub(crate) name: String,
    pub(crate) desc: String,
}

/// Every page, in strip order, then the overlays the menu reaches.
pub(crate) fn map() -> Vec<Node> {
    let mut out = vec![];

    out.push(Node {
        depth: 0,
        key: String::new(),
        name: "pages".into(),
        desc: "the tab strip, in the order it is drawn".into(),
    });

    for t in TABS {
        out.push(Node {
            depth: 1,
            key: t.key.to_string(),
            name: t.name.to_string(),
            desc: t.desc.to_string(),
        });
        // Sub-tabs are numbered from 1 because that is how the strip addresses
        // them and how `:f1`…`:f9` reach them — the index is part of the UI,
        // not an implementation detail worth hiding here.
        for (i, s) in t.subs.iter().enumerate() {
            out.push(Node {
                depth: 2,
                key: s.key.map(|c| c.to_string()).unwrap_or_else(|| (i + 1).to_string()),
                name: s.name.to_string(),
                desc: s.desc.to_string(),
            });
        }
    }

    out.push(Node {
        depth: 0,
        key: "m".into(),
        name: "menu".into(),
        desc: "overlays — they cover a page rather than being one".into(),
    });
    for (name, desc) in MENU.iter() {
        out.push(Node {
            depth: 1,
            key: String::new(),
            name: (*name).to_string(),
            desc: (*desc).to_string(),
        });
    }

    // The keys that are not pages and not menu entries, but are the difference
    // between a panel someone can use and one they can only look at.
    for (key, name, desc) in [
        ("h", "help", "every key this build binds"),
        ("esc", "help", "the first thing anyone presses on an unfamiliar TUI"),
        (":", "command", "a tab or sub-tab by name — :tree :images :wg0-ipv4"),
        ("tab", "next sub-tab", "shift-tab for the previous one"),
        ("k", "kill", "the guarded kill mailbox"),
        ("x", "optimize", "reclaim, cache, journal, docker, nix"),
        ("r", "refresh", "re-read the snapshot now"),
    ] {
        out.push(Node {
            depth: 0,
            key: key.into(),
            name: name.into(),
            desc: desc.into(),
        });
    }

    out
}
