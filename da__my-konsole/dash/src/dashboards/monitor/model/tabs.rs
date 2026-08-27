// The tab strip, as data: what exists and what each one is for.
//
// Moved out of monitor/mod.rs, which had grown to 6007 lines. Same code,
// same order; only the file it lives in changed.

/// One mode of a tab.
///
/// `key` is the direct shortcut where the mode used to be a tab of its own —
/// t, z and I still land exactly where they always did, they simply arrive at
/// a sub-tab now instead of a sibling. `net` is only read by the fleet tab.
pub(crate) struct Sub {
    pub(crate) name: &'static str,
    pub(crate) key: Option<char>,
    /// Shown in the help. Here rather than in a match beside the help text,
    /// which is how the old strip ended up describing tabs it no longer had.
    pub(crate) desc: &'static str,
    /// Address prefix this sub-tab shows. `None` means the mesh has no
    /// addresses on that network — see wg0-ipv6 below.
    pub(crate) net: Option<&'static str>,
}

/// The tab strip, BOTH LEVELS, in one table.
///
/// There were eight top-level tabs pretending to be siblings, and three of
/// them were not: tree and zombies are the process list ordered and filtered
/// differently, images is the container tab looking at what is on disk rather
/// than what is running. They are modes of a view, so they are sub-tabs of
/// it, and the strip now says so.
///
/// The fleet's modes are the four mesh networks. "Is the peer up" has a
/// different answer on wg0 than on wg-public, and one merged list hid that.
pub(crate) struct Tab {
    pub(crate) name: &'static str,
    pub(crate) key: char,
    pub(crate) desc: &'static str,
    /// Empty for a tab with a single mode; the strip draws no second row.
    pub(crate) subs: &'static [Sub],
}

pub(crate) const TABS: &[Tab] = &[
    Tab {
        name: "proc",
        key: 'p',
        desc: "the process list",
        subs: &[
            Sub { name: "normal", key: Some('p'), desc: "the flat list", net: None },
            Sub { name: "tree", key: Some('t'), desc: "parents and children, indented", net: None },
            Sub { name: "zombies", key: Some('z'), desc: "only the ones nothing owns", net: None },
        ],
    },
    Tab {
        name: "containers",
        key: 'o',
        desc: "what is running, and what is on disk",
        subs: &[
            Sub { name: "containers", key: Some('o'), desc: "running containers, enter for detail and actions", net: None },
            Sub { name: "images", key: Some('I'), desc: "every image on the box, enter for detail and actions", net: None },
        ],
    },
    Tab {
        name: "fleet",
        key: 'f',
        desc: "every mesh peer's totals side by side",
        subs: &[
            Sub { name: "wg0-ipv4", key: None, desc: "the private mesh, 10.0.0.0/24", net: Some("10.0.0.") },
            // wg0 is v4-only on this mesh. The tab exists so that is VISIBLE
            // rather than implied by an absence; the day wg0 gets a v6
            // address this is one `Some` and nothing else changes.
            Sub { name: "wg0-ipv6", key: None, desc: "wg0 carries no v6 address on this mesh", net: None },
            Sub { name: "wg-public-ipv4", key: None, desc: "the public-facing tunnel, 10.1.0.0/24", net: Some("10.1.0.") },
            Sub { name: "wg-public-ipv6", key: None, desc: "the public-facing tunnel, fd0c::/64", net: Some("fd0c:") },
            // Not a network — the things the fleet KEEPS rather than the roads
            // to it. It sits here because "where does this live" and "how do I
            // reach it" are the same question asked twice.
            Sub { name: "storage", key: None, desc: "every unit this fleet can mount — s3, git, rclone", net: None },
        ],
    },
    Tab { name: "history", key: 'y', desc: "what this machine did over the last day", subs: &[] },
    Tab { name: "files", key: 'F', desc: "home as four panes, one per level", subs: &[] },
    // 'b', not 'a': the frame owns r and a for refresh/auto and advertises
    // them in its own header, so a view key named 'a' silently never arrives.
    Tab { name: "about", key: 'b', desc: "what this machine is, not what it is doing", subs: &[] },
];
