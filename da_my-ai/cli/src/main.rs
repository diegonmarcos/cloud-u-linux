//! `my-ai` — goose via the my-ai-api OpenRouter router + Headroom compression
//! proxy. Fork of the claude-superset wrapper (claude-superset.nix) + session
//! engine (claude-superset-restore.mjs), swapped to goose as the agent and
//! my-ai-api (OpenRouter, not Claude) as the upstream. Universal: KDE / TTY / Termux.
use anyhow::{anyhow, Result};
use my_ai_core as core;
use std::fs;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

const HELP: &str = include_str!("../../src/data/help.txt");

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let ep = core::endpoints()?;

    match args.first().map(|s| s.as_str()) {
        Some("help") => {
            print!("{HELP}");
            Ok(())
        }
        Some("--version" | "-V") => {
            println!("my-ai {}", core::version());
            Ok(())
        }
        // --help / -h / dash / no-args → the live dashboard (my-ai-dash).
        Some("--help" | "-h" | "dash") | None => launch_dash(),
        Some("setup") => setup(&args[1..], &ep),
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
                            "goose" | "claude-cli" | "hermes" => a.clone(),
                            _ => return Err(anyhow!("--agent: goose | claude-cli | hermes (got '{a}')")),
                        };
                        std::env::set_var("MY_AI_AGENT", &agent);
                        args.drain(idx..idx + 2);
                    } else {
                        return Err(anyhow!("--agent needs a value: goose | claude-cli | hermes"));
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

    // Face: local | remote | goose (default remote). `goose` = plain bypass.
    let mut mode = "remote";
    let mut plain = false;
    match args.first().map(|s| s.as_str()) {
        Some("goose") => {
            mode = "goose";
            plain = true;
            args.remove(0);
        }
        Some("local") => {
            mode = "local";
            args.remove(0);
        }
        Some("remote") => {
            mode = "remote";
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
            _ => break,
        }
    }
    let rest: Vec<String> = args[i.min(args.len())..].to_vec();

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

    let agent = std::env::var("MY_AI_AGENT").unwrap_or_else(|_| "goose".into());

    // Wire the agent → my-ai-api via a short /readyz probe.
    //   goose / hermes → OPENAI_BASE_URL (OpenAI shape); my-ai-api injects the
    //     real OPENROUTER_API_KEY. hermes pins GOOSE_MODEL to a Nous Hermes slug
    //     (unless --model overrode it).
    //   claude-cli → ANTHROPIC_BASE_URL (my-ai-api's /v1/messages anthropic shim,
    //     which is itself a shape-translation onto OpenRouter — NOT real Claude).
    if headroom {
        let url = if mode == "local" {
            ep.local.proxy.clone()
        } else {
            std::env::var("MY_AI_API_URL").unwrap_or_else(|_| ep.proxy.clone())
        };
        if probe(&url) {
            match agent.as_str() {
                "claude-cli" => {
                    std::env::set_var("ANTHROPIC_BASE_URL", &url);
                    if std::env::var("ANTHROPIC_API_KEY").is_err() {
                        std::env::set_var("ANTHROPIC_API_KEY", "my-ai-api-injects-key");
                    }
                    eprintln!("[my-ai] agent=claude-cli via {mode} my-ai-api → {url} (anthropic shim → OpenRouter, Headroom ON)");
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

// ── helpers ──────────────────────────────────────────────────────────────────
fn probe(url: &str) -> bool {
    let u = format!("{}/readyz", url.trim_end_matches('/'));
    ureq::get(&u)
        .timeout(Duration::from_secs(2))
        .call()
        .map(|r| r.status() < 500)
        .unwrap_or(false)
}

fn exec_agent(args: &[String]) -> Result<()> {
    let agent = std::env::var("MY_AI_AGENT").unwrap_or_else(|_| "goose".into());
    match agent.as_str() {
        "claude-cli" => {
            // Claude Code CLI. Restore fan-out passes `--resume <id>`; pass through
            // to `claude` verbatim (claude's own --resume semantics).
            let err = Command::new("claude").args(args).exec();
            Err(anyhow!("failed to exec claude: {err}"))
        }
        "hermes" => {
            // Hermes = goose shim pinned to a Nous Hermes model on OpenRouter
            // (no standalone hermes CLI exists). Same goose exec path; the model
            // pin + OPENAI_BASE_URL are set in the route() wiring above.
            exec_goose(args)
        }
        _ => exec_goose(args), // goose (default)
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

fn launch_dash() -> Result<()> {
    // Prefer a sibling my-ai-dash (installed next to this binary), else PATH.
    let sibling = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.join("my-ai-dash")))
        .filter(|p| p.exists());
    let bin = sibling.unwrap_or_else(|| PathBuf::from("my-ai-dash"));
    let err = Command::new(bin).exec();
    Err(anyhow!("failed to launch my-ai-dash: {err}"))
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
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|d| d.join(bin))
            .find(|p| p.exists())
            .map(|p| p.to_string_lossy().into_owned())
    })
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
