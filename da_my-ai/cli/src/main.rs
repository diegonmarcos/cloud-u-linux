//! `my-ai` — goose via the my-ai-api OpenRouter router + Headroom compression
//! proxy. Fork of the claude-superset wrapper (claude-superset.nix) + session
//! engine (claude-superset-restore.mjs), swapped to goose as the agent and
//! my-ai-api (OpenRouter, not Claude) as the upstream. Universal: KDE / TTY / Termux.
use anyhow::{anyhow, Result};
use my_ai_core as core;
mod tray;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

const HELP: &str = include_str!("../../src/data/help.txt");

/// Exec the internal TUI engine (my-ai-dash, fetched into $STORE — never on
/// PATH; there is no standalone `my-ai-dash` command). `--help`/`-h`/no-args/
/// `dash` all land here; `my-ai h`/`help` prints the static HELP text instead.
fn launch_dash() -> Result<()> {
    let bin = core::dash_bin();
    if !bin.exists() {
        eprintln!("my-ai-dash not installed yet — run `my-ai h` for static help, or `./build.sh fetch` to install the TUI.");
        print!("{HELP}");
        return Ok(());
    }
    let err = Command::new(bin).exec();
    Err(anyhow!("failed to launch my-ai-dash: {err}"))
}

/// Exec `bin` (must be on PATH) with `passthrough_args`, replacing this process.
fn exec_passthrough(bin: &str, passthrough_args: &[String]) -> Result<()> {
    let err = Command::new(bin).args(passthrough_args).exec();
    Err(anyhow!("failed to launch {bin}: {err}"))
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // Install embedded scripts to ~/.local/bin on every launch (content-compare
    // skip makes this a cheap no-op when nothing changed).
    let _ = core::scripts_assets::install_to_local_bin();
    let ep = core::endpoints()?;

    match args.first().map(|s| s.as_str()) {
        // Plain static reference text (this used to be the "help" subcommand).
        Some("help" | "h") => {
            print!("{HELP}");
            Ok(())
        }
        Some("--version" | "-V") => {
            println!("my-ai {}", core::version());
            Ok(())
        }
        // --help / -h / dash / t / --tui → the live TUI dashboard. It's an
        // internal engine (my-ai-dash in $STORE, never on PATH) execed from
        // here — there is no standalone `my-ai-dash` command.
        Some("--help" | "-h" | "dash" | "t" | "--tui") => launch_dash(),
        // No args → straight into a fresh claude-superset session, remote
        // face, every plugin explicitly on. The dashboard is opt-in via
        // --help/-h/dash, not the default.
        None => route(
            ["remote", "headroom", "on", "rtk", "on", "caveman", "on", "ponytail", "full"]
                .iter()
                .map(|s| s.to_string())
                .collect(),
            &ep,
        ),
        Some("setup") => setup(&args[1..], &ep),
        Some("usage") => usage_cmd(&args[1..]),
        Some("sync-scripts") => {
            let written = core::scripts_assets::install_to_local_bin()?;
            println!("synced {} scripts to ~/.local/bin", written.len());
            Ok(())
        }
        // Thin hub passthroughs — exec the underlying tool's own binary with
        // the rest of argv. No wrapping/health/dashboard integration, just a
        // single entry point so `my-ai <tool>` works for every AI tool on the
        // desktop instead of only Claude.
        Some("ant") => exec_passthrough("ant", &args[1..]),
        Some("gemini") => exec_passthrough("gemini", &args[1..]),
        Some("antigravity") => exec_passthrough("antigravity", &args[1..]),
        _ => route(args, &ep),
    }
}

// ── face + plugin + action routing (mirror of the wrapper) ───────────────────
fn route(mut args: Vec<String>, ep: &core::Endpoints) -> Result<()> {
    // ── Flags: agent / model / effort / mode (parsed first) ──────────────
    // --agent <id>: which agent my-ai wraps (goose | claude-cli | hermes).
    //   Default: MY_AI_AGENT env, else "goose". Stored in MY_AI_AGENT so the
    //   dash/launch and child processes inherit it.
    // --model <id>: sets GOOSE_MODEL (goose reads this env) + ANTHROPIC_MODEL
    // (parity for probes/dash). --effort: informational (MY_AI_EFFORT).
    // --auto/--plan/--interactive: recorded for display (goose has its own
    // approval model; no extra CLI flags).
    {
        let mut idx = 0;
        while idx < args.len() {
            match args[idx].as_str() {
                "--agent" => {
                    if let Some(a) = args.get(idx + 1) {
                        let agent = match a.as_str() {
                            "goose" | "claude-cli" | "claude-cli-ghost" | "hermes" | "claude-superset" => a.clone(),
                            _ => return Err(anyhow!("--agent: goose | claude-cli | claude-cli-ghost | hermes | claude-superset (got '{a}')")),
                        };
                        std::env::set_var("MY_AI_AGENT", &agent);
                        args.drain(idx..idx + 2);
                    } else {
                        return Err(anyhow!("--agent needs a value: goose | claude-cli | claude-cli-ghost | hermes | claude-superset"));
                    }
                }
                "--model" => {
                    if let Some(m) = args.get(idx + 1) {
                        std::env::set_var("GOOSE_MODEL", m);
                        std::env::set_var("ANTHROPIC_MODEL", m);
                        args.drain(idx..idx + 2);
                    } else { idx += 1; }
                }
                "--effort" => {
                    if let Some(e) = args.get(idx + 1) {
                        std::env::set_var("MY_AI_EFFORT", e);
                        args.drain(idx..idx + 2);
                    } else { idx += 1; }
                }
                "--auto" | "--plan" | "--interactive" => { args.remove(idx); }
                _ => break,
            }
        }
    }

    // Face: local | remote | goose | remote-tmux_<vm> (default remote). `goose` = plain bypass.
    let mut mode = "remote";
    let mut plain = false;
    let mut remote_tmux_vm: Option<String> = None;
    match args.first().map(|s| s.as_str()) {
        Some("goose") => {
            mode = "goose";
            plain = true;
            args.remove(0);
        }
        Some("local") => {
            if core::is_termux() {
                anyhow::bail!("local face requires docker (not available in Termux) — use remote or remote-tmux_<vm> instead");
            }
            mode = "local";
            args.remove(0);
        }
        Some("remote") => {
            mode = "remote";
            args.remove(0);
        }
        Some(s) if s.starts_with("remote-tmux_") => {
            remote_tmux_vm = Some(s["remote-tmux_".len()..].to_string());
            mode = "remote-tmux";
            args.remove(0);
        }
        // Friendly alias: remote-<vm>-tmux  (e.g. `my-ai remote-oci-apps-tmux`)
        // == remote-tmux_<vm> — a persistent claude session in tmux on that VM.
        Some(s) if s.starts_with("remote-") && s.ends_with("-tmux") => {
            let vm = &s["remote-".len()..s.len() - "-tmux".len()];
            remote_tmux_vm = Some(vm.to_string());
            mode = "remote-tmux";
            args.remove(0);
        }
        _ => {}
    }
    std::env::set_var("CLAUDE_SUPERSET_MODE", mode);
    std::env::set_var("MY_AI_MODE", mode);

    // Compression plugins default ON (headroom/rtk/caveman); plain `goose` face
    // stays fully bypassed. (ponytail is a Claude-Code hook system with no goose
    // equivalent — the toggle is still parsed but has no effect on goose.)
    if mode != "goose" {
        std::env::set_var("RTK_ENABLED", "1");
        std::env::set_var("CAVEMAN_ENABLED", "1");
    }

    // Plugin toggles (any order, before the session action).
    let mut headroom = true;
    // Set by the `claude <profile>` toggle; purely for the startup banner —
    // the flags themselves are exported to the env as the toggle is parsed.
    let mut claude_profile: Option<String> = None;
    let mut i = 0usize;
    while i < args.len() {
        match args[i].as_str() {
            "headroom" => {
                let v = args.get(i + 1).map(|s| s.as_str()).unwrap_or("on");
                headroom = v != "off";
                i += 2;
            }
            "ponytail" => {
                let v = args.get(i + 1).map(|s| s.as_str()).unwrap_or("on");
                let m = match v {
                    "on" => "full",
                    "off" => "off",
                    "lite" | "full" | "ultra" => v,
                    _ => return Err(anyhow!("ponytail: on|off|lite|full|ultra")),
                };
                std::env::set_var("PONYTAIL_DEFAULT_MODE", m);
                i += 2;
            }
            "rtk" => {
                match args.get(i + 1).map(|s| s.as_str()).unwrap_or("on") {
                    "on" => std::env::set_var("RTK_ENABLED", "1"),
                    "off" => std::env::remove_var("RTK_ENABLED"),
                    _ => return Err(anyhow!("rtk: on|off")),
                }
                i += 2;
            }
            "caveman" => {
                match args.get(i + 1).map(|s| s.as_str()).unwrap_or("on") {
                    "on" => std::env::set_var("CAVEMAN_ENABLED", "1"),
                    "off" => std::env::remove_var("CAVEMAN_ENABLED"),
                    _ => return Err(anyhow!("caveman: on|off")),
                }
                i += 2;
            }
            // Claude Code context profile. Only affects --agent claude-cli.
            // Tool schemas are built once at startup, so this must be chosen at
            // launch — switching model mid-session will NOT reload them.
            "claude" => {
                let v = args.get(i + 1).map(|s| s.as_str()).unwrap_or("lean");
                let prof = ep.claude_profiles.get(v).ok_or_else(|| {
                    let names: Vec<&str> = ep
                        .claude_profiles
                        .keys()
                        .map(|s| s.as_str())
                        .filter(|n| !n.starts_with('_') && *n != "default")
                        .collect();
                    anyhow!("claude: unknown profile {v:?} (have: {names:?})")
                })?;
                for (k, val) in &prof.flags {
                    std::env::set_var(k, val);
                }
                claude_profile = Some(format!(
                    "{v} (~{}k preload{}, {} flags)",
                    prof.tokens / 1000,
                    if prof.measured { "" } else { ", est" },
                    prof.flags.len()
                ));
                i += 2;
            }
            _ => break,
        }
    }
    let rest: Vec<String> = args[i.min(args.len())..].to_vec();

    // remote-tmux_<vm>: one SSH connection to the VM, tmux handles multiplexing there.
    if let Some(ref vm) = remote_tmux_vm {
        let fresh = rest.first().map(|s| s.as_str()) == Some("fresh");
        return do_remote_tmux(vm, ep, fresh);
    }

    // Resume tabs (from a restore fan-out) attach to the running proxy; they must
    // never manage the container.
    let is_resume = rest.iter().any(|a| a == "--resume");

    // local face uses exactly ONE container (like remote uses one VM). Bring it
    // up ONCE here, before any restore fan-out. Skipped for resume tabs / headroom off.
    if mode == "local" && headroom && !is_resume {
        match rest.first().map(|s| s.as_str()) {
            Some("down" | "stop") => {
                let f = write_local_compose(ep)?;
                let st = Command::new("docker")
                    .args(["compose", "-p", &ep.local.project, "-f"])
                    .arg(&f)
                    .arg("down")
                    .status();
                return match st {
                    Ok(s) if s.success() => Ok(()),
                    _ => Err(anyhow!("docker compose down failed")),
                };
            }
            _ => local_up_once(ep)?,
        }
    }

    // Session action (default fresh). sync / restore dispatch and return.
    match rest.first().map(|s| s.as_str()) {
        Some("sync") => return do_sync(ep, &core::device(), ep.sync_keep as u64),
        Some(k @ ("restore" | "restore-hours" | "list" | "list-hours")) => {
            let selector = if k.ends_with("-hours") { "hours" } else { "count" };
            let a = rest.get(1).cloned().unwrap_or_default();
            let b = rest.get(2).cloned().unwrap_or_default();
            let (devsel, val) = if a.is_empty() || a.chars().any(|c| !c.is_ascii_digit()) {
                (a, b) // non-numeric ⇒ device selector, value is the next token
            } else {
                ("local".to_string(), a)
            };
            let devsel = if devsel.is_empty() { "local".to_string() } else { devsel };
            let value: u64 = val.parse().unwrap_or(0);
            if value == 0 {
                return Err(anyhow!("{k} needs a positive number"));
            }
            if k.starts_with("list") {
                return do_list(ep, &devsel, selector, value);
            }
            return do_restore(ep, mode, &devsel, selector, value);
        }
        _ => {}
    }
    // strip a leading `fresh`
    let passthrough: Vec<String> = match rest.first().map(|s| s.as_str()) {
        Some("fresh") => rest[1..].to_vec(),
        _ => rest,
    };

    // Plain bypass face: no proxy, no plugins, no auto-sync.
    if plain {
        return exec_agent(&passthrough);
    }

    let agent = std::env::var("MY_AI_AGENT").unwrap_or_else(|_| "claude-superset".into());

    // Wire the agent → my-ai-api via a short /readyz probe.
    //   goose / hermes → OPENAI_BASE_URL (OpenAI shape); my-ai-api injects the
    //     real OPENROUTER_API_KEY. hermes pins GOOSE_MODEL to a Nous Hermes slug
    //     (unless --model overrode it).
    //   claude-cli → ANTHROPIC_BASE_URL (my-ai-api's /v1/messages anthropic shim,
    //     which is itself a shape-translation onto OpenRouter — NOT real Claude).
    // Ghost mode: point Claude at a throwaway config dir and wipe it to login-only
    // BEFORE launch — unconditional, so it holds even if headroom is off/unreachable.
    if agent == "claude-cli-ghost" {
        ghost_prepare()?;
    }
    if headroom {
        let url = if mode == "local" {
            ep.local.proxy.clone()
        } else {
            std::env::var("MY_AI_API_URL").unwrap_or_else(|_| ep.proxy.clone())
        };
        if probe(&url) {
            match agent.as_str() {
                "claude-cli" | "claude-cli-ghost" => {
                    std::env::set_var("ANTHROPIC_BASE_URL", &url);
                    if std::env::var("ANTHROPIC_API_KEY").is_err() {
                        std::env::set_var("ANTHROPIC_API_KEY", "my-ai-api-injects-key");
                    }
                    if agent == "claude-cli-ghost" {
                        eprintln!("[my-ai] agent=claude-cli-ghost via {mode} my-ai-api → {url} (ghost config, login-only, Headroom ON)");
                    } else {
                        eprintln!("[my-ai] agent=claude-cli via {mode} my-ai-api → {url} (anthropic shim → OpenRouter, Headroom ON)");
                    }
                    if let Some(p) = &claude_profile {
                        eprintln!("[my-ai] claude profile={p}");
                    }
                }
                "hermes" => {
                    std::env::set_var("GOOSE_PROVIDER", "openai");
                    std::env::set_var("OPENAI_BASE_URL", format!("{}/v1", url.trim_end_matches('/')));
                    if std::env::var("OPENAI_API_KEY").is_err() {
                        std::env::set_var("OPENAI_API_KEY", "my-ai-api-injects-key");
                    }
                    // Pin a Nous Hermes model unless --model overrode GOOSE_MODEL.
                    if std::env::var("GOOSE_MODEL").is_err() {
                        std::env::set_var("GOOSE_MODEL", "nousresearch/hermes-3-llama-3.1-405b");
                    }
                    eprintln!("[my-ai] agent=hermes via {mode} my-ai-api → {url} (Nous Hermes on OpenRouter, Headroom ON)");
                }
                "claude-superset" => {
                    // claude-superset is a self-contained wrapper: it does its own
                    // face/headroom/proxy probing (claude-superset.nix) once exec'd,
                    // so no ANTHROPIC_*/OPENAI_*/GOOSE_* env wiring here — setting
                    // any would be silently ignored noise at best, misleading at worst.
                    eprintln!("[my-ai] agent=claude-superset — deferring to claude-superset's own {mode} face/plugin wiring");
                }
                _ => {
                    // goose
                    std::env::set_var("GOOSE_PROVIDER", "openai");
                    std::env::set_var("OPENAI_BASE_URL", format!("{}/v1", url.trim_end_matches('/')));
                    if std::env::var("OPENAI_API_KEY").is_err() {
                        std::env::set_var("OPENAI_API_KEY", "my-ai-api-injects-key");
                    }
                    if std::env::var("GOOSE_MODEL").is_err() && !ep.local.model.is_empty() {
                        std::env::set_var("GOOSE_MODEL", &ep.local.model);
                    }
                    eprintln!("[my-ai] agent=goose via {mode} my-ai-api → {url} (Headroom ON, upstream=OpenRouter)");
                }
            }
        } else {
            if mode == "local" {
                eprintln!(
                    "[my-ai] local my-ai-api not ready — ensure OPENROUTER_API_KEY is wired (src/secrets.yaml) and `my-ai local` brought the container up",
                );
            }
            eprintln!("[my-ai] my-ai-api unreachable ({url}) — {agent} native provider, no compression");
        }
    } else {
        eprintln!("[my-ai] Headroom OFF — {agent} native provider, no compression");
    }

    // Auto-sync recent sessions to the hub (best-effort, detached) unless resuming.
    if !is_resume {
        spawn_bg_sync();
    }

    exec_agent(&passthrough)
}

// ── sync: push last <keep> local sessions to the hub ─────────────────────────
fn do_sync(ep: &core::Endpoints, device: &str, keep: u64) -> Result<()> {
    let hub = core::Hub::new(&ep.api);
    let picks: Vec<_> = core::local_sessions().into_iter().take(keep as usize).collect();
    let mut ok = 0usize;
    for s in &picks {
        if let Ok(body) = fs::read(&s.file) {
            if hub.put_session(device, &s.id, &body).is_ok() {
                ok += 1;
            }
        }
    }
    eprintln!("[my-ai] synced {ok}/{} sessions as device '{device}'", picks.len());
    Ok(())
}

// ── restore: reopen sessions, one per tab (local files or hub-pulled) ─────────
struct Entry {
    id: String,
    title: String,
    workdir: String,
}

fn do_restore(ep: &core::Endpoints, face: &str, devsel: &str, selector: &str, value: u64) -> Result<()> {
    let sel = if selector == "hours" {
        core::Selector::Hours(value)
    } else {
        core::Selector::Count(value)
    };
    let entries = if devsel == "local" {
        local_entries(&sel)
    } else {
        remote_entries(ep, devsel, selector, value)?
    };
    launch(&entries, face)
}

// ── list: print recent sessions (no launch), newest first ────────────────────
fn do_list(ep: &core::Endpoints, devsel: &str, selector: &str, value: u64) -> Result<()> {
    let sel = if selector == "hours" {
        core::Selector::Hours(value)
    } else {
        core::Selector::Count(value)
    };
    let entries = if devsel == "local" {
        local_entries(&sel)
    } else {
        remote_entries(ep, devsel, selector, value)?
    };
    if entries.is_empty() {
        eprintln!("[restore] no matching sessions");
        return Ok(());
    }
    for e in &entries {
        println!("{}  {}", e.id, e.title);
    }
    Ok(())
}

fn local_entries(sel: &core::Selector) -> Vec<Entry> {
    core::by_selector(core::local_sessions(), sel)
        .into_iter()
        .map(|s| {
            let text = fs::read_to_string(&s.file).unwrap_or_default();
            let (cwd, title) = core::inspect(&text, &s.id);
            Entry {
                id: s.id,
                title,
                workdir: cwd.unwrap_or_else(|| core::home().to_string_lossy().into_owned()),
            }
        })
        .collect()
}

fn remote_entries(ep: &core::Endpoints, devsel: &str, selector: &str, value: u64) -> Result<Vec<Entry>> {
    let hub = core::Hub::new(&ep.api);
    let mut list = match hub.list() {
        Ok(l) => l,
        Err(e) => {
            eprintln!("[my-ai] hub unreachable: {e}");
            return Ok(vec![]);
        }
    };
    if devsel != "all" {
        list.retain(|s| s.device == devsel);
    }
    list.sort_by(|a, b| b.mtime.cmp(&a.mtime));
    let picks: Vec<_> = if selector == "hours" {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let cutoff = now.saturating_sub(value * 3_600_000);
        list.into_iter().filter(|s| s.mtime >= cutoff).collect()
    } else {
        list.into_iter().take(value as usize).collect()
    };

    let home = core::home();
    let home_dir = core::projects_dir().join(core::encode_cwd(&home.to_string_lossy()));
    fs::create_dir_all(&home_dir).ok();
    let mut entries = Vec::new();
    for s in picks {
        if let Ok(text) = hub.get_session(&s.device, &s.id) {
            // Re-home under $HOME so goose can import the session on this device.
            // (goose session import → goose session --resume --session-id <id>)
            fs::write(home_dir.join(format!("{}.jsonl", s.id)), &text).ok();
            let (_cwd, title) = core::inspect(&text, &s.id);
            let t: String = format!("{}:{}", s.device, title).chars().take(40).collect();
            entries.push(Entry {
                id: s.id,
                title: t,
                workdir: home.to_string_lossy().into_owned(),
            });
        }
    }
    Ok(entries)
}

fn launch(entries: &[Entry], face: &str) -> Result<()> {
    if entries.is_empty() {
        return Err(anyhow!("no matching sessions"));
    }
    let selfcmd = std::env::var("CAS_SELF").unwrap_or_else(|_| "my-ai".into());
    let sh = std::env::var("SHELL").unwrap_or_else(|_| "/bin/bash".into());
    // Interactive shell that STAYS after goose exits: Ctrl+C soft-kills goose
    // (which prints its `goose session --resume` hint) and drops back to a shell —
    // the tab is NOT killed.
    let bare = |id: &str| format!("{selfcmd} {face} --resume {id}");
    let cmd = |id: &str| format!("{sh} -c \"{}; exec {sh} -i\"", bare(id));
    // POSIX single-quote for safe embedding inside a generated /bin/sh script.
    let shq = |s: &str| format!("'{}'", s.replace('\'', "'\\''"));
    let home = core::home();
    let home = home.to_string_lossy();
    // Per-session launcher script: cd <workdir> ; <resume> ; exec <shell> -i
    let tab_script = |e: &Entry| {
        format!(
            "#!/bin/sh\ncd {} 2>/dev/null || cd {}\n{}\nexec {sh} -i\n",
            shq(&e.workdir), shq(&home), bare(&e.id)
        )
    };
    eprintln!("[my-ai] restoring {} session(s)", entries.len());

    let konsole = env_bin("CAS_KONSOLE", "konsole");
    if let Some(konsole) = konsole.filter(|_| std::env::var_os("DISPLAY").is_some()) {
        let dir = PathBuf::from(std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into()));
        // konsole's --tabs-from-file tokenizes `command:` on whitespace WITHOUT
        // shell quoting, so a quoted `sh -c "…; exec sh -i"` gets split apart, the
        // shell dies on the fragment, and the tab closes with nothing restored
        // (the exec keep-alive never runs). Reference a bare `sh <script>` instead.
        let mut lines: Vec<String> = Vec::with_capacity(entries.len());
        for e in entries {
            let scr = dir.join(format!("my-ai-tab-{}.sh", e.id));
            fs::write(&scr, tab_script(e))?;
            #[cfg(unix)]
            { use std::os::unix::fs::PermissionsExt;
              fs::set_permissions(&scr, fs::Permissions::from_mode(0o755)).ok(); }
            lines.push(format!("title: {} ;; command: {} {}", e.title, sh, scr.display()));
        }
        let tabs = dir.join("my-ai-tabs");
        fs::write(&tabs, lines.join("\n") + "\n")?;
        Command::new(konsole)
            .arg("--tabs-from-file")
            .arg(&tabs)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()?;
        return Ok(());
    }

    if let Some(tmux) = env_bin("CAS_TMUX", "tmux") {
        let s = "my-ai";
        Command::new(&tmux).args(["kill-session", "-t", s]).status().ok();
        Command::new(&tmux)
            .args(["new-session", "-d", "-s", s, "-n", &entries[0].title, "-c", &entries[0].workdir, &cmd(&entries[0].id)])
            .status()?;
        for e in &entries[1..] {
            Command::new(&tmux)
                .args(["new-window", "-t", s, "-n", &e.title, "-c", &e.workdir, &cmd(&e.id)])
                .status()?;
        }
        if std::env::var_os("TMUX").is_some() {
            Command::new(&tmux).args(["switch-client", "-t", s]).status().ok();
        } else {
            Command::new(&tmux).args(["attach", "-t", s]).status().ok();
        }
        return Ok(());
    }

    eprintln!("[my-ai] no konsole/tmux — run these yourself:");
    for e in entries {
        println!("(cd {} && {})   # {}", e.workdir, bare(&e.id), e.title);
    }
    Ok(())
}

// ── local face: one container via docker compose (data-driven from endpoints) ─
fn write_local_compose(ep: &core::Endpoints) -> Result<PathBuf> {
    let lo = &ep.local;
    let store = core::home().join(".local/share/my-ai");
    fs::create_dir_all(&store)?;
    let bind = |p: u16| format!("127.0.0.1:{p}:{p}");
    // JSON is valid YAML — docker compose reads it fine (same as the nix writeText).
    // my-ai-api has NO transparent-proxy face (it routes OpenRouter directly), so
    // we bind only app/ollama/headroom (proxy port 0 → skipped). OPENROUTER_API_KEY
    // is interpolated from the host env (or a local .env) — never baked in.
    let mut port_bindings = vec![
        bind(lo.ports.app),
        bind(lo.ports.ollama),
        bind(lo.ports.headroom),
    ];
    if lo.ports.proxy > 0 {
        port_bindings.push(bind(lo.ports.proxy));
    }
    let mut compose = serde_json::json!({
        "services": { "my-ai-api": {
            "image": lo.image,
            "container_name": lo.container_name,
            "pull_policy": "always",
            "init": true,
            "ports": port_bindings,
            "environment": {
                "HOME": "/home/appuser",
                "BRIDGE_PORT": lo.ports.app.to_string(),
                "BRIDGE_BIND": "0.0.0.0",
                "BRIDGE_OLLAMA_PORT": lo.ports.ollama.to_string(),
                "BRIDGE_OLLAMA_BIND": "0.0.0.0",
                "BRIDGE_DEFAULT_MODEL": lo.model,
                "BRIDGE_MAX_CONCURRENCY": lo.max_concurrency.to_string(),
                "BRIDGE_CALL_TIMEOUT_MS": lo.call_timeout_ms.to_string(),
                "HEADROOM_ENABLED": "1",
                "HEADROOM_HOST": "0.0.0.0",
                "HEADROOM_BIND": "0.0.0.0",
                "HEADROOM_PORT": lo.ports.headroom.to_string(),
                "HEADROOM_SAVINGS_PROFILE": lo.savings_profile,
                "HEADROOM_MIN_TOKENS": lo.min_tokens_to_compress.to_string(),
                "HEADROOM_WORKSPACE_DIR": "/home/appuser/.headroom",
                "OPENROUTER_API_KEY": "${OPENROUTER_API_KEY:-}"
            },
            "volumes": [format!("{}:/home/appuser", lo.volume)]
        }}
    });
    // Dynamic volume key can't go through the json! macro — insert it directly.
    let mut volumes = serde_json::Map::new();
    volumes.insert(lo.volume.clone(), serde_json::json!({ "name": lo.volume }));
    compose["volumes"] = serde_json::Value::Object(volumes);
    let path = store.join("local-compose.json");
    fs::write(&path, serde_json::to_vec_pretty(&compose)?)?;
    Ok(path)
}

fn local_up_once(ep: &core::Endpoints) -> Result<()> {
    let f = write_local_compose(ep)?;
    eprintln!("[my-ai] local — ensuring the ONE container is up ({})", ep.local.container_name);
    let st = Command::new("docker")
        .args(["compose", "-p", &ep.local.project, "-f"])
        .arg(&f)
        .args(["up", "-d"])
        .status();
    if !matches!(st, Ok(s) if s.success()) {
        return Err(anyhow!("docker compose up failed — is dockerd running?"));
    }
    // Wait until the local proxy answers /readyz (≈45 × 2s).
    for _ in 0..45 {
        if probe(&ep.local.proxy) {
            break;
        }
        std::thread::sleep(Duration::from_secs(2));
    }
    Ok(())
}

// ── setup: ensure `goose` is installed (the agent for this stack) ────────────
fn setup(args: &[String], ep: &core::Endpoints) -> Result<()> {
    if have("goose") && args.first().map(|s| s.as_str()) != Some("rescue") {
        eprintln!("[my-ai setup] goose already installed: {}", which("goose").unwrap_or_default());
        return Ok(());
    }
    match args.first().map(|s| s.as_str()) {
        Some("--shell") => {
            // Ephemeral: run goose via nix-shell without a permanent install.
            eprintln!("[my-ai setup] ephemeral nix-shell (temporary):");
            println!("nix shell nixpkgs#goose -c goose \"$@\"");
            Ok(())
        }
        Some("rescue") => setup_rescue(&args[1..], ep),
        _ => {
            // Declarative platforms are flake-managed; imperative ones get the native installer.
            if is_nix() || is_termux() {
                eprintln!("[my-ai setup] nix/termux = flake-managed. `goose` is delivered declaratively —");
                eprintln!("               rebuild your flake (build.sh switch), or use `my-ai setup --shell`.");
                return Ok(());
            }
            eprintln!("[my-ai setup] native install: {}", ep.setup.installer_url);
            eprintln!("[my-ai setup]   download the goose binary for your arch from the releases page,");
            eprintln!("[my-ai setup]   put it on PATH, then `my-ai setup --shell` to verify without installing.");
            Ok(())
        }
    }
}

// Last-resort fallback chain: nix → podman → cargo (goose is the agent for this stack).
fn setup_rescue(passthrough: &[String], _ep: &core::Endpoints) -> Result<()> {
    let chains: Vec<(&str, Vec<String>)> = vec![
        ("nix", vec!["shell".into(), "nixpkgs#goose".into(), "-c".into(), "goose".into()]),
        ("podman", vec!["run".into(), "--rm".into(), "-it".into(), "ghcr.io/block/goose:latest".into()]),
        ("cargo", vec!["install".into(), "goose-cli".into()]),
    ];
    for (bin, base) in chains {
        if have(bin) {
            eprintln!("[my-ai setup rescue] via {bin}");
            let mut a = base;
            a.extend(passthrough.iter().cloned());
            let _ = Command::new(bin).args(&a).status();
            return Ok(());
        }
    }
    Err(anyhow!("rescue: none of nix/podman/cargo available"))
}

// ── usage: native ccusage-equivalent token-usage counter ─────────────────────
fn usage_cmd(args: &[String]) -> Result<()> {
    let mut json_mode = false;
    let mut statusline = false;
    let mut daemon = false;
    let mut interval = core::usage::DAEMON_INTERVAL_SECS;
    let mut since_hours: Option<u64> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--json" => {
                json_mode = true;
                i += 1;
            }
            "--statusline" => {
                statusline = true;
                i += 1;
            }
            "--daemon" => {
                daemon = true;
                i += 1;
            }
            "--interval" => {
                let s = args
                    .get(i + 1)
                    .and_then(|s| s.parse::<u64>().ok())
                    .filter(|s| *s > 0)
                    .ok_or_else(|| anyhow!("--interval needs a positive seconds value"))?;
                interval = s;
                i += 2;
            }
            "--since" => {
                let h = args
                    .get(i + 1)
                    .and_then(|s| s.parse::<u64>().ok())
                    .ok_or_else(|| anyhow!("--since needs an hours value"))?;
                since_hours = Some(h);
                i += 2;
            }
            a => return Err(anyhow!(
                "usage: unknown flag '{a}' (expected --json | --statusline | --daemon | --interval <s> | --since <h>)"
            )),
        }
    }

    if daemon {
        return usage_daemon(interval);
    }
    if statusline {
        return usage_statusline();
    }

    let pricing = core::usage::Pricing::load();
    let mut entries = core::usage::collect_entries(&core::projects_dir())?;
    if let Some(h) = since_hours {
        let cutoff = core::usage::now_ms() - (h as i64) * 3_600_000;
        entries.retain(|e| e.ts_ms >= cutoff);
    }
    let blocks = core::usage::bucket_blocks(&entries, &pricing);
    let now = core::usage::now_ms();

    if json_mode {
        print_usage_json(&blocks, now);
    } else {
        print_usage_report(&blocks, now);
    }
    Ok(())
}

fn print_usage_json(blocks: &[core::usage::Block], now: i64) {
    let block_json = |b: &core::usage::Block| {
        let t = &b.totals;
        serde_json::json!({
            "start": b.start_ms,
            "reset_at": b.end_ms(),
            "input": t.input,
            "output": t.output,
            "cache_write": t.cache_write,
            "cache_read": t.cache_read,
            "total": t.total_tokens(),
            "cost": t.cost(),
        })
    };
    let active_idx = core::usage::active_block_index(blocks, now);
    let active_json = active_idx.map(|idx| {
        let b = &blocks[idx];
        let mut v = block_json(b);
        v["burn_per_min"] = serde_json::json!(core::usage::burn_rate(b, now));
        v["minutes_elapsed"] = serde_json::json!((now - b.start_ms) / 60_000);
        v
    });
    let blocks_json: Vec<_> = blocks.iter().map(block_json).collect();
    let out = serde_json::json!({ "active_block": active_json, "blocks": blocks_json });
    println!("{}", serde_json::to_string_pretty(&out).unwrap_or_default());
}

fn print_usage_report(blocks: &[core::usage::Block], now: i64) {
    if blocks.is_empty() {
        println!("[usage] no Claude Code usage found under ~/.claude/projects/");
        return;
    }
    let active_idx = core::usage::active_block_index(blocks, now);
    let start = blocks.len().saturating_sub(5);
    println!(
        "{:<18} {:>9} {:>9} {:>9} {:>9} {:>9} {:>9}",
        "BLOCK START(UTC)", "INPUT", "CACHE-W", "CACHE-R", "OUTPUT", "TOTAL", "COST$"
    );
    for (idx, b) in blocks.iter().enumerate().skip(start) {
        let t = &b.totals;
        let marker = if Some(idx) == active_idx { "  *ACTIVE*" } else { "" };
        println!(
            "{:<18} {:>9} {:>9} {:>9} {:>9} {:>9} {:>9.2}{marker}",
            core::usage::fmt_utc(b.start_ms),
            core::usage::fmt_tokens(t.input),
            core::usage::fmt_tokens(t.cache_write),
            core::usage::fmt_tokens(t.cache_read),
            core::usage::fmt_tokens(t.output),
            core::usage::fmt_tokens(t.total_tokens()),
            t.cost(),
        );
    }
    println!();
    match active_idx {
        Some(idx) => {
            let b = &blocks[idx];
            let mins_left = (b.end_ms() - now).max(0) / 60_000;
            println!(
                "Active block: burn {:.0} tok/min, resets in {}h {}m",
                core::usage::burn_rate(b, now),
                mins_left / 60,
                mins_left % 60
            );
        }
        None => println!("No active block (idle)."),
    }
}

// Cache: my-ai renders on every statusline tick, so a fresh scan of every
// ~/.claude/projects/**/*.jsonl on each call would be too expensive. Reuse a
// cached line while it's younger than STATUSLINE_CACHE_TTL_SECS (tunable in
// core::usage), keyed off the cache file's own mtime.
/// Publish the 5h-window segment on a loop so the status line never computes.
///
/// This is the producer half of the contract documented on `usage::seg_path()`:
/// one process for the whole machine, at a fixed interval, instead of one heavy
/// process per status-line repaint per session. Memory stays flat and bounded,
/// so no repaint burst can push /user.slice past oomd's pressure limit.
///
/// A scan failure is logged and skipped rather than fatal — a transient unreadable
/// transcript must not take the daemon down and silently stop all updates.
fn usage_daemon(interval: u64) -> Result<()> {
    let projects = core::projects_dir();
    let pricing = core::usage::Pricing::load();
    eprintln!(
        "[my-ai] usage daemon: publishing {} + {} every {interval}s",
        core::usage::snapshot_path().display(),
        core::usage::seg_path().display()
    );
    // ONE scanner for the process lifetime: the first tick reads the whole
    // corpus, every tick after it reads only what was appended. Rebuilding the
    // world every interval (what this used to do) cost ~27% of a core forever.
    // The binary owns the status line's assets, so it installs them. Doing this
    // on every start makes the dependency self-healing: `global_blocks()` shells
    // out to these scripts, and if a different component shipped them they could
    // drift out of step with this binary and leave `.blocks` silently empty.
    match core::statusline_assets::install(&core::statusline_assets::claude_dir()) {
        Ok(w) if !w.is_empty() => eprintln!("[my-ai] statusline assets installed: {}", w.join(", ")),
        Ok(_) => {}
        Err(e) => eprintln!("[my-ai] statusline asset install failed: {e}"),
    }
    let mut scanner = core::usage::Scanner::new();

    // Real system tray (ksni/StatusNotifierItem), only where a desktop session
    // could plausibly show one — same $WAYLAND_DISPLAY/$DISPLAY signal
    // build.sh's wrapper already used to decide GUI-vs-headless, now reused
    // here since this path is the default ExecStart either way. A failed
    // spawn (no D-Bus session, no StatusNotifierWatcher, headless/SSH/CI) is
    // logged once by tray::try_spawn and must never take the publish loop
    // down with it.
    let has_display = std::env::var_os("WAYLAND_DISPLAY").is_some() || std::env::var_os("DISPLAY").is_some();
    let tray_handle = if has_display { tray::try_spawn() } else { None };

    loop {
        scanner.tick(&projects, &pricing);
        let now = core::usage::now_ms();
        // The snapshot is the contract: all the DATA the status line draws.
        let snapshot_json = scanner.snapshot_json(&pricing, now);
        if let Err(e) = core::usage::publish_snapshot(&snapshot_json) {
            eprintln!("[my-ai] usage daemon: snapshot publish failed: {e}");
        }
        // The pre-rendered segment stays for the tray and for any consumer that
        // wants a ready line rather than fields.
        let seg_line = scanner.statusline(&pricing, now);
        if let Err(e) = core::usage::publish_seg(&seg_line) {
            eprintln!("[my-ai] usage daemon: segment publish failed: {e}");
        }
        // Tooltip reuses exactly what was just published above — no second scan.
        if let Some(t) = &tray_handle {
            t.update(&seg_line, &snapshot_json);
        }
        std::thread::sleep(std::time::Duration::from_secs(interval));
    }
}

fn usage_statusline() -> Result<()> {
    // Prefer whatever the daemon published — it is already fresh, and this turns
    // the call into a single file read with no scan at all.
    if let Some(line) = core::usage::read_seg() {
        print!("{line}");
        return Ok(());
    }
    let cache_path = core::store_dir().join("usage-statusline.cache");
    if let Ok(meta) = fs::metadata(&cache_path) {
        if let Ok(age) = meta.modified().and_then(|m| m.elapsed().map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))) {
            if age.as_secs() < core::usage::STATUSLINE_CACHE_TTL_SECS {
                if let Ok(cached) = fs::read_to_string(&cache_path) {
                    print!("{cached}");
                    return Ok(());
                }
            }
        }
    }
    let pricing = core::usage::Pricing::load();
    let entries = core::usage::collect_entries(&core::projects_dir())?;
    let blocks = core::usage::bucket_blocks(&entries, &pricing);
    let now = core::usage::now_ms();
    let line = core::usage::format_statusline(&blocks, now).unwrap_or_default();
    if let Some(parent) = cache_path.parent() {
        fs::create_dir_all(parent).ok();
    }
    fs::write(&cache_path, &line).ok();
    print!("{line}");
    Ok(())
}

// ── helpers ──────────────────────────────────────────────────────────────────

/// SSH to a VM and multiplex sessions inside a tmux session there.
/// One TCP connection from the phone; tmux protects sessions from network drops.
/// Default (fresh=false): attach to existing "my-ai" session (or create with agent in window 0).
/// Fresh (fresh=true):    attach or create, then always open a new window with the agent.
///
/// Target design: SSH to `<login>@<ip>` (the VM's host login user, e.g. `ubuntu` on
/// oci-apps — NOT the phone's local `nix-on-droid`, which is why a bare-IP ssh got
/// `nix-on-droid@10.0.0.6: Permission denied`), then run `claude` (Anthropic Claude
/// Code CLI) INSIDE the my-ai-api container via `docker exec`. The container carries
/// the Anthropic shim on localhost:3217 (ANTHROPIC_BASE_URL), so `claude` there needs
/// no real Anthropic key — my-ai-api injects the upstream (OpenRouter / claude-superset-api).
/// tmux runs on the host and wraps the `docker exec`, so a network drop never kills the
/// container-side session.
fn do_remote_tmux(vm: &str, ep: &core::Endpoints, fresh: bool) -> Result<()> {
    let ip = ep
        .mesh
        .get(vm)
        .ok_or_else(|| anyhow!("remote-tmux: unknown VM '{vm}' (known: {:?})", ep.mesh.keys().collect::<Vec<_>>()))?;

    // The host login user for the target VM. mesh values are bare IPs, and neither
    // ~/.ssh/config's `Host *` nor the bare IP carry a `User`, so ssh would otherwise
    // default to the phone's local login ($USER = nix-on-droid) and fail publickey.
    // Overridable via MY_AI_REMOTE_USER for VMs whose login isn't `ubuntu`.
    let user = std::env::var("MY_AI_REMOTE_USER").unwrap_or_else(|_| "ubuntu".into());
    let target = format!("{user}@{ip}");

    let session = "my-ai";
    let container = std::env::var("MY_AI_REMOTE_CONTAINER").unwrap_or_else(|_| "my-ai-api".into());

    // Collect current plugin env to forward into the remote agent command. These are
    // consumed by my-ai-api's plugin pipeline (RTK/Caveman/Ponytail), passed through
    // `docker exec -e`.
    let mut exec_env: Vec<String> = Vec::new();
    for var in &["PONYTAIL_DEFAULT_MODE", "RTK_ENABLED", "CAVEMAN_ENABLED"] {
        if let Ok(v) = std::env::var(var) {
            exec_env.push("-e".into());
            exec_env.push(format!("{var}={v}"));
        }
    }
    let env_flags = if exec_env.is_empty() { String::new() } else { format!("{} ", exec_env.join(" ")) };

    // `claude` inside the container, pointed at the container-local my-ai-api Anthropic
    // shim (127.0.0.1:3217). ANTHROPIC_API_KEY is a placeholder — my-ai-api injects the
    // real upstream key, so no Anthropic credential ever leaves the box.
    let agent_cmd = format!(
        "docker exec -it {env_flags}-e ANTHROPIC_BASE_URL=http://127.0.0.1:3217 -e ANTHROPIC_API_KEY=my-ai-api-injects-key {container} claude"
    );

    // \\; in Rust = \; in the string = literal ; passed to tmux by the remote shell,
    // where tmux uses ; as a multi-command separator.
    let ssh_cmd = if fresh {
        format!("tmux new-session -A -s {session} \\; new-window '{agent_cmd}'")
    } else {
        format!("tmux new-session -A -s {session} '{agent_cmd}'")
    };

    eprintln!("[my-ai] remote-tmux → {target} (1 SSH, tmux session '{session}', docker exec {container} claude)");
    let err = Command::new("ssh").args(["-t", &target, &ssh_cmd]).exec();
    Err(anyhow!("ssh exec: {err}"))
}

fn probe(url: &str) -> bool {
    let u = format!("{}/readyz", url.trim_end_matches('/'));
    ureq::get(&u)
        .timeout(Duration::from_secs(2))
        .call()
        .map(|r| r.status() < 500)
        .unwrap_or(false)
}

fn exec_agent(args: &[String]) -> Result<()> {
    let agent = std::env::var("MY_AI_AGENT").unwrap_or_else(|_| "claude-superset".into());
    let mode = std::env::var("MY_AI_MODE").unwrap_or_else(|_| "remote".into());
    match agent.as_str() {
        "claude-cli" | "claude-cli-ghost" => {
            // Claude Code CLI. Restore fan-out passes `--resume <id>`; pass through
            // to `claude` verbatim (claude's own --resume semantics). For ghost mode
            // HOME + CLAUDE_CONFIG_DIR relocation + login-only wipe are already applied
            // in route(); here we also force the ghost's dedicated MCP file so it
            // ignores user MCP and the project ./.mcp.json.
            let mut a: Vec<String> = Vec::new();
            if let Ok(mcp) = std::env::var("MY_AI_GHOST_MCP") {
                a.push("--strict-mcp-config".into());
                a.push("--mcp-config".into());
                a.push(mcp);
            }
            a.extend_from_slice(args);
            let bin = which("claude").unwrap_or_else(|| "claude".into());
            let err = Command::new(&bin).args(&a).exec();
            Err(anyhow!("failed to exec claude ({bin}): {err}"))
        }
        "claude-superset" => {
            // claude-superset's own CLI contract (see claude-superset.nix):
            //   claude-superset [local|remote|claude] [headroom on|off]
            //     [ponytail on|off|lite|full|ultra] [rtk on|off] [caveman on|off]
            //     [restore N | restore-hours N | sync | fresh [claude-args…]]
            // `args` here is my-ai's own passthrough, which mirrors that exact
            // shape (route() above is a port of the same wrapper), so it can be
            // forwarded verbatim.
            let bin = which("claude-superset").unwrap_or_else(|| "claude-superset".into());
            let err = Command::new(&bin).args(args).exec();
            Err(anyhow!("failed to exec claude-superset ({bin}): {err}"))
        }
        "hermes" => {
            // Hermes = goose shim pinned to a Nous Hermes model on OpenRouter
            // (no standalone hermes CLI exists). Same goose exec path; the model
            // pin + OPENAI_BASE_URL are set in the route() wiring above.
            exec_goose(args)
        }
        _ => {
            // goose (default): remote face connects to the server-side goosed agent
            // over HTTP/SSE — the agent loop runs on oci-apps, not locally. Local face
            // keeps the traditional exec-goose path (agent runs locally, LLM is remote).
            if mode == "remote" {
                let ep = core::endpoints()?;
                goosed_repl(&ep.goosed)
            } else {
                exec_goose(args)
            }
        }
    }
}

fn exec_goose(args: &[String]) -> Result<()> {
    // goose session is the interactive agent. Translate claude-style
    // `--resume <id>` (from a restore fan-out) into goose's `--resume --session-id <id>`.
    // A bare `my-ai` (fresh, no args) → `goose session` (interactive REPL). Other
    // args (e.g. `--name foo`) pass through to `goose session` verbatim.
    let mut goose_args: Vec<String> = vec!["session".into()];
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--resume" && i + 1 < args.len() {
            goose_args.push("--resume".into());
            goose_args.push("--session-id".into());
            goose_args.push(args[i + 1].clone());
            i += 2;
        } else {
            goose_args.push(args[i].clone());
            i += 1;
        }
    }
    let err = Command::new("goose").args(&goose_args).exec();
    Err(anyhow!("failed to exec goose: {err}"))
}

// ── claude-cli-ghost: throwaway Claude HOME, login-only ──────────────────────
// A REAL ghost isolates every layer Claude Code reads, not just the config dir:
//   ~/.claude/            (config dir; CLAUDE_CONFIG_DIR)
//   ~/.claude.json        (global state: user MCP servers, project index, onboarding)
//   ~/CLAUDE.md           (home-level memory)
// Redirecting CLAUDE_CONFIG_DIR alone leaves the other two leaking. Instead we
// relocate HOME to a throwaway dir, so ALL of them resolve fresh in one move —
// and because nothing real is ever renamed, a crash / kill -9 can never strand
// the user's real config (no stash+restore trap to skip). Login is preserved by
// copying just the credential into the ghost ~/.claude. Wiped every launch.
//
// MCP is the one layer HOME can't reset: the project ./.mcp.json lives in cwd,
// not HOME. So the ghost gets its OWN curated MCP file (~/.config/my-ai/
// mcp-ghost.json, persistent — outside the wiped dir) and launches with
// `--mcp-config … --strict-mcp-config`, which makes claude use ONLY that file
// and ignore both user MCP and the project ./.mcp.json. (A project-local
// ./CLAUDE.md still loads — that is cwd too, matching "anonymous Claude working
// in your real repo".)
fn ghost_prepare() -> Result<()> {
    let home = std::env::var("HOME").map_err(|_| anyhow!("HOME unset"))?;
    let real_cfg = std::env::var("CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(&home).join(".claude"));
    let ghost_home = PathBuf::from(&home).join(".claude-ghost");
    let ghost_cfg = ghost_home.join(".claude");

    // Clean slate every launch — no leftover history/projects/settings.
    if ghost_home.exists() {
        let _ = fs::remove_dir_all(&ghost_home);
    }
    fs::create_dir_all(&ghost_cfg)?;

    // Keep login only: carry the credential across (nothing else).
    let cred = real_cfg.join(".credentials.json");
    if cred.exists() {
        let _ = fs::copy(&cred, ghost_cfg.join(".credentials.json"));
    } else {
        eprintln!(
            "[my-ai] ghost: no {} to carry over — Claude may prompt a login",
            cred.display()
        );
    }

    // Dedicated ghost MCP file, OUTSIDE the wiped throwaway so it persists and
    // you can curate it. Seeded to zero servers on first use; edit to add
    // ghost-only MCP. exec_agent passes it via --mcp-config --strict-mcp-config.
    let ghost_mcp = PathBuf::from(&home).join(".config/my-ai/mcp-ghost.json");
    if !ghost_mcp.exists() {
        if let Some(parent) = ghost_mcp.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&ghost_mcp, "{\n  \"mcpServers\": {}\n}\n")?;
    }
    std::env::set_var("MY_AI_GHOST_MCP", &ghost_mcp);

    std::env::set_var("HOME", &ghost_home);
    std::env::set_var("CLAUDE_CONFIG_DIR", &ghost_cfg);
    Ok(())
}

// ── goosed remote REPL: thin HTTP/SSE client for the server-side agent ───────
// The agent loop executes on oci-apps inside the my-ai-api container (goosed,
// port 3227). This function is a minimal blocking REPL:
//   1. POST /sessions → creates a session, gets session_id.
//   2. Loop: read user line from stdin → POST /sessions/{id}/reply (SSE response)
//            → print accumulated assistant text → repeat.
// Secret: GOOSE_SERVER__SECRET_KEY env var (same key the container reads from sops).
// If the endpoint is unreachable or the secret is unset, we print a clear error
// and return — no silent fallback to a local agent.
fn goosed_repl(base_url: &str) -> Result<()> {
    if base_url.is_empty() {
        return Err(anyhow!(
            "[my-ai] goosed endpoint not configured (endpoints.json 'goosed' key is empty)"
        ));
    }
    let secret = std::env::var("GOOSE_SERVER__SECRET_KEY").map_err(|_| {
        anyhow!(
            "[my-ai] GOOSE_SERVER__SECRET_KEY is not set — \
             export it from your vault before using FACE=remote with agent=goose"
        )
    })?;
    if secret.is_empty() {
        return Err(anyhow!(
            "[my-ai] GOOSE_SERVER__SECRET_KEY is set but empty"
        ));
    }

    let base = base_url.trim_end_matches('/');

    // 1. Create a session on the remote goosed.
    let create_url = format!("{}/sessions", base);
    let create_resp = ureq::post(&create_url)
        .set("X-Secret-Key", &secret)
        .set("Content-Type", "application/json")
        .timeout(Duration::from_secs(10))
        .send_string("{}")
        .map_err(|e| anyhow!("[my-ai] goosed unreachable at {base_url}: {e}\nIs the WireGuard tunnel up?"))?;

    let session_json: serde_json::Value = create_resp.into_json()
        .map_err(|e| anyhow!("[my-ai] goosed /sessions response parse error: {e}"))?;
    let session_id = session_json
        .get("session_id")
        .or_else(|| session_json.get("id"))
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("[my-ai] goosed /sessions response missing session_id: {session_json}"))?
        .to_string();

    eprintln!("[my-ai] goosed session {session_id} on {base_url} (agent runs server-side)");
    eprintln!("[my-ai] Type your message and press Enter. Ctrl+D to exit.");

    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    loop {
        print!("> ");
        stdout.flush().ok();
        let mut line = String::new();
        match stdin.lock().read_line(&mut line) {
            Ok(0) => break, // EOF (Ctrl+D)
            Err(e) => return Err(anyhow!("stdin read error: {e}")),
            Ok(_) => {}
        }
        let user_input = line.trim_end_matches('\n').trim_end_matches('\r');
        if user_input.is_empty() {
            continue;
        }

        // 2. POST /sessions/{id}/reply — response is an SSE stream.
        let reply_url = format!("{}/sessions/{}/reply", base, session_id);
        let body = serde_json::json!({ "content": user_input }).to_string();
        let response = ureq::post(&reply_url)
            .set("X-Secret-Key", &secret)
            .set("Content-Type", "application/json")
            .timeout(Duration::from_secs(120))
            .send_string(&body)
            .map_err(|e| anyhow!("[my-ai] goosed /reply error: {e}"))?;

        // 3. Read SSE stream: each line is `data: <json>` or blank.
        // Accumulate assistant text from delta/text/content/message fields.
        let reader = BufReader::new(response.into_reader());
        let mut printed_any = false;
        for raw in reader.lines() {
            let raw = match raw {
                Ok(l) => l,
                Err(_) => break,
            };
            let data = match raw.strip_prefix("data: ") {
                Some(d) => d.trim(),
                None => continue, // blank line or `event:` line — skip
            };
            if data == "[DONE]" {
                break;
            }
            // Parse the JSON payload defensively — grab any string field that
            // looks like assistant text (goose ACP may use delta/text/content/message).
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(data) {
                let text = val.get("delta")
                    .or_else(|| val.get("text"))
                    .or_else(|| val.get("content"))
                    .or_else(|| val.get("message"))
                    .and_then(|v| v.as_str());
                if let Some(t) = text {
                    print!("{t}");
                    stdout.flush().ok();
                    printed_any = true;
                }
                // Check for a finish/done signal inside the payload.
                if val.get("done").and_then(|v| v.as_bool()).unwrap_or(false) {
                    break;
                }
            }
        }
        if printed_any {
            println!(); // newline after last chunk
        }
    }
    Ok(())
}

fn spawn_bg_sync() {
    if let Ok(exe) = std::env::current_exe() {
        let _ = Command::new(exe)
            .arg("sync")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn();
    }
}

fn have(bin: &str) -> bool {
    which(bin).is_some()
}
fn which(bin: &str) -> Option<String> {
    if bin.contains('/') {
        return std::path::Path::new(bin).exists().then(|| bin.to_string());
    }
    if let Some(hit) = std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|d| d.join(bin))
            .find(|p| p.exists())
            .map(|p| p.to_string_lossy().into_owned())
    }) {
        return Some(hit);
    }
    // Fallback: my-ai is a plain compiled binary that can be launched from
    // contexts with a minimal PATH (systemd --user, a desktop-launcher .desktop
    // entry, the Tauri systray) that never sourced the interactive shell's
    // nix-profile PATH additions — `claude`/`claude-superset` live there and
    // would otherwise silently fail to exec with "No such file or directory".
    // Check the well-known install locations directly before giving up.
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        for dir in [".nix-profile/bin", ".local/bin", ".local/state/nix/profile/bin"] {
            let cand = home.join(dir).join(bin);
            if cand.exists() {
                return Some(cand.to_string_lossy().into_owned());
            }
        }
    }
    for dir in ["/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin", "/usr/local/bin", "/usr/bin"] {
        let cand = PathBuf::from(dir).join(bin);
        if cand.exists() {
            return Some(cand.to_string_lossy().into_owned());
        }
    }
    None
}
/// A binary from an env override (e.g. CAS_KONSOLE) or PATH lookup of `name`.
fn env_bin(var: &str, name: &str) -> Option<String> {
    if let Ok(v) = std::env::var(var) {
        return (!v.is_empty()).then_some(v);
    }
    which(name)
}
fn is_nix() -> bool {
    std::path::Path::new("/etc/NIXOS").exists() || have("nix")
}
fn is_termux() -> bool {
    std::env::var("PREFIX").map(|p| p.contains("com.termux")).unwrap_or(false)
}
