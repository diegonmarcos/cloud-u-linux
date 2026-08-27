// The home-directory tree, local or over ssh, and its per-machine cache.
//
// Moved out of monitor/mod.rs, which had grown to 6007 lines. Same code,
// same order; only the file it lives in changed.

/// `tree -L 4` over the home directory, or the nearest thing available.
///
/// Shelled out rather than walked here: tree(1) already draws the box-drawing
/// prefixes this panel wants, and reimplementing that to avoid one process is
/// work for no benefit. find(1) is the fallback for a box without tree, with a
/// flat listing — less pretty, still the answer.
///
/// Bounded on purpose. -L 4 because past four levels a home directory is
/// mostly node_modules and .git objects, and the output is capped because a
/// tree with a million entries is not a view, it is a hang.
pub(crate) fn file_tree(hidden: bool, target: Option<&str>) -> [Vec<String>; 4] {
    // ONE script, run locally or over ssh. The tab used to shell out to `tree`
    // on this machine unconditionally, so measuring a peer showed you THIS
    // home directory under that peer's name — the one place in the panel where
    // the numbers came from a different machine than the heading claimed.
    //
    // $HOME is printed first and resolves on whichever side runs it, so the
    // depth-splitting below needs no idea where home is.
    //
    // The OUTPUT is the signal, not the exit code: tree returns 2 whenever any
    // directory could not be opened, which in a home directory is routine and
    // still prints everything else. `||` would have concatenated both.
    // -l FOLLOWS SYMLINKED DIRECTORIES, and on a home-manager box that is the
    // difference between a file tree and a list of one repo. Every top-level
    // entry on those peers — containers/, bin/, .config/ — is a symlink into
    // /nix/store, and `tree -d` without -l descends into none of them: the only
    // real directory left is ~/git, which is exactly what the tab was showing.
    // -L 4 still bounds it, and tree prints [recursive] rather than looping.
    let a = if hidden { "-a " } else { "" };
    let script = format!(
        "printf '%s\\n' \"$HOME\"; \
         t=$(tree -d -f -i -l -L 4 --noreport {a}-I '.git|node_modules|.cache|target' \"$HOME\" 2>/dev/null); \
         if [ -n \"$t\" ]; then printf '%s\\n' \"$t\"; \
         else find -L \"$HOME\" -maxdepth 4 \\( -name .git -o -name node_modules -o -name .cache -o -name target \\) -prune -o -type d -print 2>/dev/null; fi"
    );
    let out = match target {
        // `sh -s` with the script on STDIN, not as an argument — the same
        // thing mesh.rs does, and for a reason worth keeping: several peers
        // here log in to FISH, which rejects `t=$(...)` outright. Handing the
        // script to a named shell means the peer's login shell never gets a
        // vote on the syntax.
        //
        // The guards are mesh.rs's too: never prompt, never hang on a peer
        // that stopped answering, and accept a new host key once.
        Some(alias) => (|| {
            use std::io::Write;
            let mut ch = std::process::Command::new("ssh")
                .args([
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=4",
                    "-o", "StrictHostKeyChecking=accept-new",
                    alias,
                    "sh -s",
                ])
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .spawn()?;
            let _ = ch.stdin.take().map(|mut w| w.write_all(script.as_bytes()));
            ch.wait_with_output()
        })(),
        None => std::process::Command::new("sh").arg("-c").arg(&script).output(),
    };
    let text = out
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();

    let mut lines = text.lines();
    let Some(home) = lines.next().map(|h| h.trim_end_matches('/').to_string()) else {
        return Default::default();
    };
    let mut levels: [Vec<String>; 4] = Default::default();
    for line in lines {
        // A symlinked directory prints as "path -> target"; the path is what
        // this view is about.
        let path = line.split(" -> ").next().unwrap_or(line).trim_end_matches('/');
        let Some(rel) = path.strip_prefix(&home).map(|r| r.trim_start_matches('/')) else {
            continue;
        };
        if rel.is_empty() {
            continue; // home itself
        }
        let depth = rel.matches('/').count();
        if depth < 4 {
            levels[depth].push(rel.to_string());
        }
    }
    levels
}

/// The files tree, fetched OFF the render thread and keyed by WHICH MACHINE.
///
/// Local `tree` was fast enough to run inline; an ssh round trip to a peer is
/// not, and this panel exists to catch things that block. The key is
/// target-plus-hidden, so switching machines or pressing `.` invalidates it —
/// the old cache was keyed by nothing at all, which is why a peer's tab showed
/// the last machine's directories.
#[derive(Clone, Default)]
pub(crate) struct TreeCache {
    pub(crate) inner: std::sync::Arc<std::sync::Mutex<(String, Option<[Vec<String>; 4]>)>>,
}

impl TreeCache {
    /// (tree, still loading). A tree for a DIFFERENT key counts as neither:
    /// it belongs to a machine you are no longer looking at.
    pub(crate) fn view(&self, key: &str) -> (Option<[Vec<String>; 4]>, bool) {
        match self.inner.lock() {
            Ok(g) if g.0 == key => (g.1.clone(), g.1.is_none()),
            _ => (None, false),
        }
    }

    /// Start a fetch unless this key is already loaded or in flight. The key
    /// is claimed synchronously, so holding `.` cannot open a thread per press.
    pub(crate) fn fetch(&self, key: String, target: Option<String>, hidden: bool) {
        {
            let Ok(mut g) = self.inner.lock() else { return };
            if g.0 == key {
                return;
            }
            *g = (key.clone(), None);
        }
        let out = self.inner.clone();
        std::thread::spawn(move || {
            let t = file_tree(hidden, target.as_deref());
            if let Ok(mut g) = out.lock() {
                // Only if nobody re-keyed while we were out on the network.
                if g.0 == key {
                    g.1 = Some(t);
                }
            }
        });
    }
}
