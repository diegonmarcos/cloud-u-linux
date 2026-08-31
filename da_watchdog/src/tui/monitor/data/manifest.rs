// The page manifest: one list of what exists, and a test that the three
// surfaces still agree about it.
//
// WHY
// The panel, the exported HTML report and the phone are three renderers over
// one product, and every page added since transcription landed has had to be
// wired into each of them by hand. Two have already drifted silently:
//
//   - boxMesh listed every machine, but only inside legacyOverview(), which
//     nothing renders any more — the fleet was in the envelope and on no page.
//   - the rules envelope changed from {head,lines} to {head,rows} while the
//     APK still carried a renderer that read `lines`.
//
// Neither produced an error. A page that exists on one surface and not another
// looks exactly like a page nobody has opened yet.
//
// So the list is DATA, and [`tests::html_pages_match_the_renderer`] reads the
// TypeScript to prove the web renderer implements exactly it — not more, not
// fewer. The check runs in CI on every push, which is the only place all three
// surfaces exist at once.

/// One page of the product, and which surfaces are expected to have it.
pub(crate) struct Page {
    /// The key the web renderer dispatches on, or "" for a panel-only page.
    pub(crate) web: &'static str,
    /// The panel tab (or tab/sub-tab) that is the same page, or "".
    pub(crate) cli: &'static str,
    pub(crate) desc: &'static str,
}

/// Every page the HTML report and the phone render.
///
/// The panel's own tab tree is generated from TABS by [`super::appmap`] — this
/// is the OTHER list, the one that cannot be generated because it lives in
/// TypeScript, and therefore the one that needs a test.
pub(crate) const PAGES: &[Page] = &[
    Page { web: "__overview",  cli: "overview",     desc: "the panel's screen, transcribed" },
    Page { web: "__appmap",    cli: "about/app-map", desc: "every page, generated from the tab table" },
    Page { web: "__machines",  cli: "fleet",         desc: "the fleet, and measuring any of it" },
    Page { web: "__rules",     cli: "about/rules",   desc: "the guards' thresholds and fire counts" },
    Page { web: "__report",    cli: "",              desc: "the markdown export" },
    Page { web: "__files",     cli: "files",         desc: "the file tree the panel read" },
    Page { web: "__raw",       cli: "",              desc: "the envelope itself" },
];

#[cfg(test)]
mod tests {
    use super::PAGES;

    /// The web renderer implements exactly the manifest.
    ///
    /// Reads report.ts at COMPILE time, so this cannot pass against a stale
    /// build of the bundle: the assertion is about the authored source, which
    /// is the thing a person edits and forgets to wire up.
    #[test]
    fn html_pages_match_the_renderer() {
        const TS: &str = include_str!("../../../../web/src/report.ts");

        // Every manifest page must have a dispatch branch.
        for p in PAGES {
            let branch = format!("k === '{}'", p.web);
            assert!(
                TS.contains(&branch),
                "{} is in the manifest but report.ts has no `{}` branch — \
                 the page is declared and unreachable",
                p.web,
                branch
            );
        }

        // And every branch must be in the manifest, or the manifest is a
        // partial list — which is worse than none, because it reads complete.
        let mut found = vec![];
        let mut rest = TS;
        while let Some(i) = rest.find("k === '__") {
            let tail = &rest[i + 7..];
            if let Some(end) = tail[1..].find('\'') {
                found.push(&tail[1..1 + end]);
            }
            rest = &rest[i + 9..];
        }
        for f in found {
            assert!(
                PAGES.iter().any(|p| p.web == f),
                "report.ts renders `{f}` but it is not in the manifest — \
                 add it, or the other surfaces will never learn it exists"
            );
        }
    }

    /// The nav offers every page the renderer implements.
    ///
    /// The two are written in different files and different languages, and a
    /// nav row without a branch is a dead link while a branch without a row is
    /// a page nobody can reach. Both have happened.
    #[test]
    fn every_page_is_reachable_from_the_nav() {
        const HTML: &str = include_str!("../html.rs");
        for p in PAGES {
            assert!(
                HTML.contains(p.web),
                "{} is in the manifest but html.rs never emits it — \
                 the page exists and the nav cannot reach it",
                p.web
            );
        }
    }
}
