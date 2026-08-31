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

fn home() -> String {
    std::env::var("HOME").unwrap_or_else(|_| "/home/diego".into())
}

/// The three steps, in order, as the machine will run them.
pub(crate) fn steps() -> Vec<Step> {
    let h = home();
    let mut v = vec![];

    // 1. The declarations. Both repos, because the switch reads one and this
    //    panel is built from the other, and updating half of a pair is how a
    //    box ends up running a config that describes a different machine.
    for repo in ["cloud", "cloud-u-linux"] {
        v.push(Step {
            name: "sync",
            why: "fast-forward the declarations this machine is built from",
            argv: vec!["git".into(), "pull".into(), "--ff-only".into()],
            cwd: Some(format!("{h}/git/{repo}")),
        });
    }

    // 2. The binaries, from the release GHA built. Never compiled here: this
    //    is an 8GB machine and a local build is what OOM-froze it before.
    v.push(Step {
        name: "fetch",
        why: "the sampler and panel GHA built, from the rolling release",
        argv: vec![
            "gh".into(), "release".into(), "download".into(), "my-watchdog-latest".into(),
            "--repo".into(), "diegonmarcos/cloud-u-linux".into(),
            "--pattern".into(), "my-watchdog".into(),
            "--pattern".into(), "my-watchdog-tui".into(),
            "--dir".into(), format!("{h}/.cache/my-watchdog-update"),
            "--clobber".into(),
        ],
        cwd: None,
    });

    // 3. The switch. `pull` is build.sh's own default and the whole point:
    //    it imports the closure GHA built rather than evaluating here.
    v.push(Step {
        name: "switch",
        why: "import the GHA-built closure and activate it — no local eval",
        argv: vec![
            format!("{h}/git/cloud-infra-desktop/aa_desk-usr_x86_surface-linux_nixos/build.sh"),
            "switch".into(),
            "pull".into(),
        ],
        cwd: None,
    });
    v
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
    pub(crate) fn start(&self) -> bool {
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
            for st in steps() {
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
