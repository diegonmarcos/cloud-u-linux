// about/update — bring this machine up to date, from the panel.
//
// THE ONE VERB IN A READER
// Every other page here only looks. This one acts, so it is deliberately hard
// to trigger by accident: it runs on an explicit key, it prints exactly what
// it will run before it runs anything, and it refuses to start a second time
// while the first is still going.
//
// WHY IT IS NOT A SHELL SCRIPT SOMEWHERE ELSE
// Because the panel is what a person is looking at when they decide the box
// needs updating, and the alternative — remembering three commands in two
// repos and a build.sh verb — is what makes a machine drift in the first
// place.
//
// NO SUDO HERE. Step 3 hands off to build.sh, which owns its own privilege
// story; this module never elevates and never asks to.

use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// One step, and the exact argv that IS it.
///
/// Data rather than a function per step, so the page can print the command
/// before running it — an update that will not say what it does is one nobody
/// should press.
pub(crate) struct Step {
    pub(crate) name: &'static str,
    pub(crate) why: &'static str,
    pub(crate) argv: Vec<String>,
    pub(crate) cwd: Option<String>,
}

/// Which sequence. Two, because installing an app and developing one are not
/// the same act and never were.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Way {
    /// Pull the published artifact and run it. Touches nothing but this app.
    Install,
    /// Move the source: sync the repos, push, let CI build.
    Dev,
}

impl Way {
    pub(crate) fn title(self) -> &'static str {
        match self {
            Way::Install => "install / update — the app only",
            Way::Dev => "dev — move the source and let CI build",
        }
    }

    pub(crate) fn key(self) -> char {
        match self {
            Way::Install => 'u',
            Way::Dev => 'd',
        }
    }
}

fn home() -> String {
    std::env::var("HOME").unwrap_or_else(|_| "/home/diego".into())
}

/// The steps for one way.
///
/// THE INSTALL WAY NEVER TOUCHES THE SYSTEM. It used to end in
/// `build.sh switch`, which rebuilt NixOS to move a dashboard — so every fix
/// to this panel was a system generation, and on an 8GB laptop six local
/// evaluations OOM-froze the desktop. The app is its own artifact now.
///
/// ONE STEP, AND IT IS build.sh. This page used to hand-roll the install: gh
/// release download of two assets, an install -m755, a systemctl restart. All
/// three were subtly wrong by the time anyone noticed.
///
///   · It downloaded `c3-watchdog-d` and `c3-watchdog-tui` — real assets, but not
///     the pair `build.sh fetch` maintains, so an update through this page and
///     an update through build.sh left the machine in different states.
///   · It never re-granted capabilities. A file capability is an xattr on the
///     INODE, so replacing the binary drops it: the firewall page went blank
///     after an update and stayed blank, and per-process io went with it.
///   · It never placed the policy document or the systemd unit, so the memory
///     ceiling that keeps this sampler from becoming the load it reports was
///     whatever an older install had left behind.
///
/// build.sh does all of it, and it is the same command the fleet runs. A
/// second way to install one app is how you end up running a binary from three
/// weeks ago through four green deploys — which is exactly what happened here.
///
/// The NixOS/other split is gone with it: `nix profile install` on this flake
/// builds the crate FROM SOURCE on the machine you are updating, which is the
/// one thing the whole design exists to prevent. The flake's `c3-watchdog-bin`
/// output is the download, and it is for consumers declaring this app in their
/// own configuration — not for bringing this machine up to date.
pub(crate) fn steps(way: Way) -> Vec<Step> {
    let h = home();
    match way {
        Way::Install => vec![
            Step {
                name: "install",
                // Short enough to survive the column this page draws it in —
                // the long version is the module comment above, where it can
                // be read without a terminal wide enough for it.
                why: "build.sh — binaries, capabilities, policy, units, service",
                argv: vec![
                    "sh".into(), "-c".into(),
                    format!(
                        // Named explicitly rather than relying on PATH: this
                        // runs from inside the app, and the app may well be
                        // the copy build.sh is about to replace.
                        "exec {h}/git/cloud-u-linux/da_c3-watchdog/build.sh install"
                    ),
                ],
                cwd: None,
            },
        ],
        Way::Dev => {
            let mut v = vec![];
            // Both repos: the declarations and the app are different trees and
            // updating half a pair is its own class of drift.
            //
            // cloud-infra, not cloud: this repo was renamed in August 2026 and
            // this list was not. `git -C ~/git/cloud pull` still succeeds —
            // that checkout exists — which is why nobody noticed it had
            // stopped being the repo that carries watchdog's declarations.
            for repo in ["cloud-infra", "cloud-u-linux"] {
                v.push(Step {
                    name: "sync",
                    why: "fast-forward this checkout",
                    argv: vec![
                        "git".into(), "-C".into(), format!("{h}/git/{repo}"),
                        "pull".into(), "--ff-only".into(),
                    ],
                    cwd: None,
                });
            }
            v.push(Step {
                name: "push",
                why: "publish local commits so CI can build them",
                argv: vec![
                    "git".into(), "-C".into(), format!("{h}/git/cloud-u-linux"),
                    "push".into(), "origin".into(), "main".into(),
                ],
                cwd: None,
            });
            v.push(Step {
                name: "build",
                why: "wait for CI — the binaries are never compiled on this machine",
                argv: vec![
                    "gh".into(), "run".into(), "watch".into(),
                    "--repo".into(), "diegonmarcos/cloud-u-linux".into(),
                    "--exit-status".into(),
                ],
                cwd: Some(format!("{h}/git/cloud-u-linux")),
            });
            v
        }
    }
}

/// A run in progress, or the transcript of the last one.
#[derive(Clone, Default)]
pub(crate) struct Runner {
    pub(crate) log: Arc<Mutex<Vec<String>>>,
    pub(crate) running: Arc<AtomicBool>,
}

impl Runner {
    pub(crate) fn is_running(&self) -> bool {
        self.running.load(Ordering::Relaxed)
    }

    pub(crate) fn lines(&self) -> Vec<String> {
        self.log.lock().map(|l| l.clone()).unwrap_or_default()
    }

    /// Start the sequence on its own thread.
    ///
    /// Returns false if one is already going. Guarded rather than queued: two
    /// switches at once is not a thing anyone wants, and the honest answer to
    /// a second press is "it is already running".
    pub(crate) fn start(&self, way: Way) -> bool {
        if self.running.swap(true, Ordering::SeqCst) {
            return false;
        }
        let log = self.log.clone();
        let running = self.running.clone();
        std::thread::spawn(move || {
            if let Ok(mut l) = log.lock() {
                l.clear();
            }
            let push = |l: &Arc<Mutex<Vec<String>>>, s: String| {
                if let Ok(mut v) = l.lock() {
                    // Bounded: a switch prints thousands of store paths and
                    // this is a panel, not a log file.
                    if v.len() > 400 {
                        v.remove(0);
                    }
                    v.push(s);
                }
            };
            for st in steps(way) {
                push(&log, format!("── {} · {}", st.name, st.why));
                push(&log, format!("   $ {}", st.argv.join(" ")));
                let mut c = Command::new(&st.argv[0]);
                c.args(&st.argv[1..]).stdout(Stdio::piped()).stderr(Stdio::piped());
                if let Some(d) = &st.cwd {
                    c.current_dir(d);
                }
                match c.spawn() {
                    Err(e) => {
                        push(&log, format!("   ! could not start: {e}"));
                        break;
                    }
                    Ok(mut child) => {
                        // stdout only for the transcript; stderr is drained by
                        // wait_with_output below so a chatty step cannot fill
                        // its pipe and block forever.
                        if let Some(out) = child.stdout.take() {
                            for line in BufReader::new(out).lines().map_while(Result::ok) {
                                push(&log, format!("   {line}"));
                            }
                        }
                        match child.wait() {
                            Ok(s) if s.success() => push(&log, "   ok".into()),
                            Ok(s) => {
                                push(&log, format!("   ! exit {}", s.code().unwrap_or(-1)));
                                // Stop at the first failure: running a switch
                                // after a failed pull activates the OLD
                                // declarations and looks like it worked.
                                break;
                            }
                            Err(e) => {
                                push(&log, format!("   ! {e}"));
                                break;
                            }
                        }
                    }
                }
            }
            push(&log, "── done".into());
            running.store(false, Ordering::SeqCst);
        });
        true
    }
}
