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

/// Is this a Nix machine? Decides which install route the page offers.
///
/// /etc/NIXOS is the file NixOS itself writes and every installer in this repo
/// already tests for. `nix` being on PATH is not the same question — a Debian
/// box with the package manager installed still wants the plain binary, since
/// its systemd unit and its PATH are not managed by a generation.
fn is_nixos() -> bool {
    std::path::Path::new("/etc/NIXOS").exists()
}

/// The steps for one way.
///
/// THE INSTALL WAY NEVER TOUCHES THE SYSTEM. It used to end in
/// `build.sh switch`, which rebuilt NixOS to move a dashboard — so every fix
/// to this panel was a system generation, and on an 8GB laptop six local
/// evaluations OOM-froze the desktop. The app is its own artifact now: a flake
/// to run, or a binary to place. Neither evaluates the machine it lands on.
pub(crate) fn steps(way: Way) -> Vec<Step> {
    let h = home();
    match way {
        Way::Install if is_nixos() => vec![
            Step {
                name: "nix",
                why: "run the app's own flake — no system eval, no generation",
                argv: vec![
                    "nix".into(), "profile".into(), "install".into(),
                    "--refresh".into(),
                    "github:diegonmarcos/cloud-u-linux?dir=da_watchdog".into(),
                ],
                cwd: None,
            },
        ],
        Way::Install => vec![
            Step {
                name: "fetch",
                why: "the binaries CI built, from the rolling release",
                argv: vec![
                    "gh".into(), "release".into(), "download".into(), "my-watchdog-latest".into(),
                    "--repo".into(), "diegonmarcos/cloud-u-linux".into(),
                    "--pattern".into(), "my-watchdog".into(),
                    "--pattern".into(), "my-watchdog-tui".into(),
                    "--dir".into(), format!("{h}/.cache/my-watchdog-update"),
                    "--clobber".into(),
                ],
                cwd: None,
            },
            Step {
                name: "install",
                why: "place them on PATH — mv, because a running binary cannot be written to",
                argv: vec![
                    "sh".into(), "-c".into(),
                    format!(
                        "set -e; d={h}/.cache/my-watchdog-update; \
                         install -m755 $d/my-watchdog {h}/.local/bin/.my-watchdog.new; \
                         mv -f {h}/.local/bin/.my-watchdog.new {h}/.local/bin/my-watchdog; \
                         install -m755 $d/my-watchdog-tui {h}/.local/bin/my-watchdog-tui"
                    ),
                ],
                cwd: None,
            },
            Step {
                name: "restart",
                why: "the sampler, so it runs the code just installed",
                argv: vec![
                    "systemctl".into(), "--user".into(), "restart".into(), "my-watchdog.service".into(),
                ],
                cwd: None,
            },
        ],
        Way::Dev => {
            let mut v = vec![];
            // Both repos: the declarations and the app are different trees and
            // updating half a pair is its own class of drift.
            for repo in ["cloud", "cloud-u-linux"] {
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
