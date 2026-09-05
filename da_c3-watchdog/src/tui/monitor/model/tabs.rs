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
            Sub { name: "zombies", key: Some('z'), desc: "exited, waiting on a parent that never reaped them", net: None },
            // No key of its own: 'o' already opens a folder in the detail view,
            // and a letter that switches sub-tab in one place and opens a
            // directory in another is exactly the ambiguity these tables exist
            // to prevent. Reachable as 4, by tab, and as :parentless.
            Sub { name: "parentless", key: None, desc: "reparented to init — whatever started them is gone", net: None },
        ],
    },
    Tab {
        name: "containers",
        key: 'o',
        desc: "what is running, and what is on disk",
        // In deployment order, which is also the order the question gets
        // asked: what was declared, what that produced, what is running from
        // it, and what it left behind. compose comes first because it is the
        // only one of the five that is a STATEMENT of intent rather than a
        // reading of the machine.
        subs: &[
            Sub { name: "compose", key: None, desc: "the projects docker itself recorded, and what drifted from them", net: None },
            Sub { name: "images", key: Some('I'), desc: "every image on the box, enter for detail and actions", net: None },
            Sub { name: "containers", key: Some('o'), desc: "running containers, enter for detail and actions", net: None },
            Sub { name: "volumes", key: None, desc: "what the containers keep, and what nothing claims", net: None },
            Sub { name: "network", key: None, desc: "the docker networks and what they are for", net: None },
        ],
    },
    Tab {
        name: "fleet",
        key: 'f',
        desc: "every mesh peer's totals side by side",
        subs: &[
            Sub { name: "wg0-ipv4", key: None, desc: "the private mesh, 10.0.0.0/24", net: Some("10.0.0.") },
            // WRONG FOR AS LONG AS IT EXISTED: this said "wg0 carries no v6
            // address on this mesh" and declared no prefix, so the page was
            // permanently empty and said so as if it were a fact about the
            // network. cloud-infra's own config declares subnet_v6
            // fd0c:1d00::/64 and a wg_ipv6 for every VM and every client.
            Sub { name: "wg0-ipv6", key: None, desc: "the private mesh, fd0c:1d00::/64", net: Some("fd0c:1d00:") },
            Sub { name: "wg-public-ipv4", key: None, desc: "the public-facing tunnel, 10.1.0.0/24", net: Some("10.1.0.") },
            // `fd0c:` matched BOTH networks — the two differ in the fourth
            // group, 1d00 for wg0 and 1d01 for the public tunnel — so this
            // page would have claimed every private address as a public one
            // the moment anything recorded a v6 at all.
            Sub { name: "wg-public-ipv6", key: None, desc: "the public-facing tunnel, fd0c:1d01::/64", net: Some("fd0c:1d01:") },
            // Not a network — the things the fleet KEEPS rather than the roads
            // to it. It sits here because "where does this live" and "how do I
            // reach it" are the same question asked twice.
            Sub { name: "storage", key: None, desc: "every unit this fleet can mount — s3, git, rclone", net: None },
        ],
    },
    // WHAT IS EXPOSED. The firewall itself cannot be read without root and
    // this dashboard is deliberately unprivileged, so the tab answers the
    // question the firewall exists to answer instead: what is declared open,
    // what is actually bound, and where those two disagree.
    Tab {
        name: "firewall",
        // 'W', not 'w': lowercase w already cycles the CPU%/MEM% averaging
        // window, and a tab key that silently never arrives is worse than an
        // awkward one. The collision test would have caught it; checking
        // first was cheaper than a red build.
        key: 'W',
        desc: "what is declared open, what is actually listening",
        // Three views because there are two firewalls on this box and they do
        // not know about each other: the OS one, and docker's, which inserts
        // its own chain AHEAD of the user rules and so goes around whatever
        // the OS one says. Reading them merged hides exactly that. The
        // consolidated view exists to put the disagreement on one screen.
        subs: &[
            Sub { name: "consolidated", key: None, desc: "both firewalls on one screen, and where they disagree", net: None },
            Sub { name: "os", key: None, desc: "every socket bound here, and the ingress cloud-infra declares", net: None },
            Sub { name: "container", key: None, desc: "the ports docker published, from docker ps", net: None },
        ],
    },
    // The journal, read-only. Every sub-tab below is one journalctl invocation
    // and nothing else — this tab writes nothing, restarts nothing, and asks
    // for no privilege it does not already have.
    Tab {
        name: "logs",
        // 'L': lowercase l is free, but uppercase matches the other view tabs
        // added after the strip existed (I, F, W).
        key: 'L',
        desc: "the journal, one section at a time",
        subs: &[
            Sub { name: "summary", key: None, desc: "alerts per section over the last 24h", net: None },
            Sub { name: "kernel", key: None, desc: "journalctl -k", net: None },
            Sub { name: "system", key: None, desc: "the system manager's own journal", net: None },
            Sub { name: "user", key: None, desc: "this login's services", net: None },
            Sub { name: "docker", key: None, desc: "docker.service", net: None },
            Sub { name: "network", key: None, desc: "NetworkManager and wireguard", net: None },
            Sub { name: "ssh", key: None, desc: "sshd — who reached this box", net: None },
            Sub { name: "watchdog", key: None, desc: "c3-watchdog's own journal", net: None },
        ],
    },
    Tab { name: "history", key: 'y', desc: "what this machine did over the last day", subs: &[] },
    Tab { name: "files", key: 'F', desc: "home as four panes, one per level", subs: &[] },
    // 'b', not 'a': the frame owns r and a for refresh/auto and advertises
    // them in its own header, so a view key named 'a' silently never arrives.
    // Two modes, because "what this machine is" and "what will be done to it"
    // are different questions and only one of them was answerable here. The
    // guards freeze and kill whole slices on thresholds nobody could read
    // without going to /etc — so the rules are a page now, beside the identity.
    Tab { name: "about", key: 'b', desc: "what this machine is, and the rules it is governed by", subs: &[
        Sub { name: "about", key: None, desc: "hardware, kernel, uptime — what this machine IS", net: None },
        Sub { name: "rules", key: None, desc: "the guards: thresholds, protected slices, what gets frozen or killed", net: None },
        Sub { name: "update", key: None, desc: "sync the declarations, fetch the built binaries, switch — press u", net: None },
        Sub { name: "app-map", key: None, desc: "every page this panel has, generated from the tab table itself", net: None },
    ] },
];
