// The `:` command line: what it accepts, and how it ranks what you have typed.
//
// Everything addressable is read out of TABS, so a tab added to that table is
// reachable here the moment it exists — by name, by number, and in the picker
// — with nothing else to keep in step.
use crate::dashboards::monitor::model::keys::MENU;
use crate::dashboards::monitor::model::tabs::{Sub, Tab, TABS};
use crate::dashboards::monitor::Overlay;

/// What a `:` line resolved to.
///
/// Split from the running of it so the language has a test that does not need
/// a whole dashboard on its feet: resolution is the part with rules in it, and
/// applying the answer is four lines of `match`.
#[derive(Debug, PartialEq)]
pub(crate) enum Cmd {
    /// Tab, and the mode within it. `None` keeps whichever mode that tab was
    /// left on — `:fleet` returns you to the network you were watching.
    Go(usize, Option<usize>),
    /// Put a modal up — measure, options, help, the free-memory menu.
    Open(Overlay),
    Quit,
    Export(bool),
    /// Append the declared units that are stopped or idle (the `v` toggle).
    Units,
    Err(String),
    Nothing,
}

/// What each MENU entry does, in ONE place.
///
/// The menu dispatched these by index in its own key handler and the command
/// line would have needed its own copy — two mappings from the same four names
/// to the same four actions, which is how a menu ends up opening something its
/// label does not mention. Both call this instead.
pub(crate) fn menu_cmd(i: usize) -> Cmd {
    match i {
        0 => Cmd::Open(Overlay::Target),
        1 => Cmd::Open(Overlay::Boxes),
        2 => Cmd::Open(Overlay::Help),
        _ => Cmd::Quit,
    }
}

/// The verbs that are NOT in the main menu. The menu's own four come from
/// MENU itself, so the picker cannot offer an entry the menu does not have,
/// and cannot miss one it does — which is exactly what happened: measure and
/// options were reachable by key and by menu, and invisible to `:`.
const VERBS: &[(&str, &str)] = &[
    ("free", "free memory — reap zombies, reclaim, find orphans"),
    ("units", "add or drop the declared units that are stopped or idle"),
    ("export", "write this machine to ~/.watchdog"),
    ("export all", "the same, with every fleet peer folded in"),
];

/// One thing the picker can offer.
pub(crate) struct Pick {
    pub(crate) name: String,
    pub(crate) desc: String,
}

/// Everything `:` accepts right now, in the order it is worth offering.
///
/// The `fN` entries depend on which tab you are on, which is the whole point
/// of them — `:f2` means something different in `proc` than in `fleet`, and a
/// picker that listed them tab-blind would be lying about half its entries.
pub(crate) fn candidates(cur: usize) -> Vec<Pick> {
    let mut v: Vec<Pick> = vec![];
    let t: &Tab = &TABS[cur.min(TABS.len() - 1)];
    for (i, sb) in t.subs.iter().enumerate() {
        v.push(Pick {
            name: format!("f{}", i + 1),
            desc: format!("{} · {} — {}", t.name, sb.name, sb.desc),
        });
    }
    for tab in TABS {
        v.push(Pick { name: tab.name.into(), desc: tab.desc.into() });
        for sb in tab.subs {
            // A sub-tab whose name repeats its tab's ("containers" in
            // "containers") would list the same word twice; the tab entry
            // above already covers it.
            if sb.name != tab.name {
                v.push(Pick {
                    name: sb.name.into(),
                    desc: format!("{} · {}", tab.name, sb.desc),
                });
            }
        }
    }
    for (n, d) in MENU {
        v.push(Pick { name: (*n).into(), desc: (*d).into() });
    }
    for (n, d) in VERBS {
        v.push(Pick { name: (*n).into(), desc: (*d).into() });
    }
    v
}

/// fzf-style subsequence match. `None` when the query is not a subsequence of
/// the candidate at all; otherwise a score, higher being better.
///
/// The scoring is what makes it feel right rather than merely correct:
/// a run of adjacent characters is worth far more than the same characters
/// scattered, a match at a word boundary beats one in the middle of a word,
/// and a shorter candidate wins a tie. That is why `wg6` puts wg0-ipv6 above
/// wg-public-ipv6, and `ea` puts "export all" above "fleet".
pub(crate) fn fuzzy(query: &str, cand: &str) -> Option<i32> {
    if query.is_empty() {
        return Some(0);
    }
    let q: Vec<char> = query.chars().flat_map(|c| c.to_lowercase()).collect();
    let c: Vec<char> = cand.chars().flat_map(|c| c.to_lowercase()).collect();
    let mut qi = 0usize;
    let mut score = 0i32;
    let mut last: Option<usize> = None;
    for (i, ch) in c.iter().enumerate() {
        if qi >= q.len() || *ch != q[qi] {
            continue;
        }
        if let Some(p) = last {
            if p + 1 == i {
                score += 10; // contiguous
            }
        }
        // Word starts: the beginning, or just after a separator. These are the
        // characters a person is actually aiming at when they type an acronym.
        if i == 0 || matches!(c.get(i.wrapping_sub(1)), Some('-') | Some('.') | Some(' ') | Some('_')) {
            score += 8;
        }
        score -= (i / 4) as i32; // earlier is better, gently
        last = Some(i);
        qi += 1;
    }
    if qi == q.len() {
        // Shorter candidate wins a tie: "tree" should beat "wg-public-ipv4"
        // for the query "tr" even though both contain it.
        Some(score - (c.len() as i32 - q.len() as i32))
    } else {
        None
    }
}

/// The candidates matching `query`, best first.
pub(crate) fn matches(query: &str, cur: usize) -> Vec<Pick> {
    let mut scored: Vec<(i32, Pick)> = candidates(cur)
        .into_iter()
        .filter_map(|p| fuzzy(query, &p.name).map(|s| (s, p)))
        .collect();
    // Stable by score then name, so the list does not reshuffle between two
    // equally-good candidates as you type.
    scored.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.name.cmp(&b.1.name)));
    scored.into_iter().map(|(_, p)| p).collect()
}

/// Resolve one command line against TABS.
///
/// NAMES, not codes. `:fleet` goes to the fleet, `:f3` to the third sub-tab of
/// wherever you are, `:wg-public-ipv6` straight there from anywhere.
pub(crate) fn resolve(line: &str, cur: usize) -> Cmd {
    let c = line.trim().to_ascii_lowercase();
    if c.is_empty() {
        return Cmd::Nothing;
    }
    // :f2 or :2 — a sub-tab of the tab you are on, by the number the strip is
    // already showing under it. `:files` must not parse as this, which is why
    // the tail has to BE a number rather than merely start with one.
    if let Ok(n) = c.strip_prefix('f').unwrap_or(&c).parse::<usize>() {
        let subs = TABS[cur].subs.len();
        return if n >= 1 && n <= subs {
            Cmd::Go(cur, Some(n - 1))
        } else {
            Cmd::Err(format!("{} has {subs} sub-tab(s), not {n}", TABS[cur].name))
        };
    }
    // The main menu's own entries, by their own names, read out of MENU.
    if let Some(i) = MENU.iter().position(|(n, _)| *n == c.as_str()) {
        return menu_cmd(i);
    }
    match c.as_str() {
        "q" | "quit" => return Cmd::Quit,
        "h" | "help" => return Cmd::Open(Overlay::Help),
        "m" | "menu" => return Cmd::Open(Overlay::Menu),
        "free" => return Cmd::Open(Overlay::Free),
        "units" | "v" => return Cmd::Units,
        "e" | "export" => return Cmd::Export(false),
        "ea" | "export all" => return Cmd::Export(true),
        _ => {}
    }
    // Exact name wins outright; otherwise a prefix, but only if it is
    // unambiguous. Guessing between two tabs is worse than naming the two.
    let mut hits: Vec<(usize, Option<usize>, &str)> = vec![];
    for (i, t) in TABS.iter().enumerate() {
        if t.name == c {
            return Cmd::Go(i, None);
        }
        if t.name.starts_with(&c) {
            hits.push((i, None, t.name));
        }
        for (j, sb) in t.subs.iter().enumerate() {
            let sb: &Sub = sb;
            if sb.name == c {
                return Cmd::Go(i, Some(j));
            }
            if sb.name.starts_with(&c) {
                hits.push((i, Some(j), sb.name));
            }
        }
    }
    match hits.len() {
        1 => Cmd::Go(hits[0].0, hits[0].1),
        0 => Cmd::Err(format!("no such command: {c}")),
        _ => Cmd::Err(format!(
            "{c} is ambiguous: {}",
            hits.iter().map(|(_, _, n)| *n).collect::<Vec<_>>().join(", ")
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fuzzy_requires_a_subsequence_and_rewards_the_right_things() {
        // Not a subsequence at all.
        assert_eq!(fuzzy("zzz", "fleet"), None);
        // Out of order is not a match either — this is a subsequence match,
        // not a bag of characters.
        assert_eq!(fuzzy("teerf", "fleet"), None);
        assert!(fuzzy("fle", "fleet").is_some());
        // Case-insensitive both ways.
        assert!(fuzzy("FLE", "fleet").is_some());
        assert!(fuzzy("wg", "WG0-ipv4").is_some());

        // Contiguous beats scattered.
        let tight = fuzzy("tre", "tree").unwrap();
        let loose = fuzzy("tre", "the-rest-e").unwrap();
        assert!(tight > loose, "contiguous {tight} should beat scattered {loose}");

        // A word-boundary acronym beats the same letters mid-word.
        let acro = fuzzy("wi", "wg0-ipv4").unwrap();
        let mid = fuzzy("wi", "switch").unwrap();
        assert!(acro > mid, "boundary {acro} should beat mid-word {mid}");

        // An empty query matches everything, so the picker opens full.
        assert_eq!(fuzzy("", "anything"), Some(0));
    }

    #[test]
    fn the_picker_ranks_the_obvious_thing_first() {
        let proc = TABS.iter().position(|t| t.name == "proc").unwrap();
        let top = |q: &str| matches(q, proc).into_iter().next().map(|p| p.name);

        assert_eq!(top("tree").as_deref(), Some("tree"));
        assert_eq!(top("fleet").as_deref(), Some("fleet"));
        assert_eq!(top("zomb").as_deref(), Some("zombies"));
        assert_eq!(top("quit").as_deref(), Some("quit"));
        // The fN entries are the CURRENT tab's, so proc offers f1..f3.
        assert!(matches("f", proc).iter().any(|p| p.name == "f2"));
        // Nonsense matches nothing rather than offering something random.
        assert!(matches("qqqq", proc).is_empty());
        // An empty query offers everything, which is what an fzf prompt does.
        assert_eq!(matches("", proc).len(), candidates(proc).len());
    }

    // The main menu and the command line must offer the SAME four things.
    // measure and options were reachable by key and by menu and invisible to
    // `:`, which is the whole reason MENU is read here rather than copied.
    #[test]
    fn the_picker_offers_every_main_menu_entry() {
        let proc = TABS.iter().position(|t| t.name == "proc").unwrap();
        let names: Vec<String> = candidates(proc).into_iter().map(|p| p.name).collect();
        for (n, _) in MENU {
            assert!(names.iter().any(|x| x == n), "{n:?} is in the menu but not in the picker");
            // and typing it must do what the menu does
            assert_eq!(
                resolve(n, proc),
                menu_cmd(MENU.iter().position(|(m, _)| *m == n).unwrap()),
                "{n:?} resolves to something the menu does not do"
            );
        }
        // The non-menu verbs are there too.
        for n in ["free", "units", "export", "export all"] {
            assert!(names.iter().any(|x| x == n), "{n:?} missing from the picker");
        }
    }

    #[test]
    fn every_offered_candidate_actually_resolves() {
        // The picker must never show something that then fails to run.
        for (cur, _) in TABS.iter().enumerate() {
            for p in candidates(cur) {
                assert!(
                    !matches!(resolve(&p.name, cur), Cmd::Err(_) | Cmd::Nothing),
                    "picker offers {:?} but it does not resolve from tab {}",
                    p.name,
                    TABS[cur].name
                );
            }
        }
    }
}
