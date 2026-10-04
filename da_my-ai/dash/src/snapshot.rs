//! `my-ai-dash --snapshot` — run offline reads + all probes once and print a JSON
//! snapshot. The Tauri GUI (my-ai-gui) shells out to this so `dash` stays the
//! single owner of dashboard data (no duplicated probe logic).
use crate::collect::{collectors, parse_df, parse_repo, run, Slot, REPOS};
use crate::offline;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::thread;

fn slot_json(s: &Slot) -> Value {
    match s {
        Slot::NotProbed => json!({ "st": "na" }),
        Slot::Pending => json!({ "st": "pending" }),
        Slot::Timeout => json!({ "st": "to" }),
        Slot::Stdio => json!({ "st": "stdio" }),
        Slot::Up { ms, body } => json!({ "st": "up", "ms": ms, "body": body }),
        Slot::Down { ms } => json!({ "st": "dn", "ms": ms }),
        Slot::Cmd(o) => json!({ "st": "cmd", "out": o }),
        Slot::Image(a) => json!({ "st": "image", "arches": a }),
    }
}

pub fn snapshot(ep: &my_ai_core::Endpoints) -> Value {
    let mcps = offline::load_mcps();
    let plugins = offline::load_plugins();
    let hooks = offline::load_hooks();
    let sessions = offline::load_sessions();
    let cfg = offline::claude_config(mcps.len());

    // Fire every probe on its own thread and join — each is hard-bounded, so
    // wall-clock ≈ the slowest single probe (~3s), not the sum.
    let data: Arc<Mutex<BTreeMap<String, Slot>>> = Arc::new(Mutex::new(BTreeMap::new()));
    let cols = collectors(ep, &mcps);
    let mut handles = Vec::new();
    for (id, probe) in cols {
        let data = data.clone();
        handles.push(thread::spawn(move || {
            let v = run(&probe);
            data.lock().unwrap().insert(id, v);
        }));
    }
    for h in handles {
        let _ = h.join();
    }
    let d = data.lock().unwrap();
    let get = |k: &str| d.get(k).map(slot_json).unwrap_or(json!({ "st": "na" }));

    let services: Value = ["proxy", "api", "ollama", "compress", "direct"]
        .iter()
        .map(|k| (k.to_string(), get(k)))
        .collect::<serde_json::Map<_, _>>()
        .into();
    let mesh: Value = ep.mesh.keys().map(|n| (n.clone(), get(&format!("mesh:{n}")))).collect::<serde_json::Map<_, _>>().into();
    let public: Value = ep.public.keys().map(|n| (n.clone(), get(&format!("pub:{n}")))).collect::<serde_json::Map<_, _>>().into();
    let mcp_json: Vec<Value> = mcps
        .iter()
        .map(|m| json!({ "name": m.name, "kind": m.kind, "slot": if m.kind == "http" { get(&format!("mcp:{}", m.name)) } else { json!({"st":"stdio"}) } }))
        .collect();
    let repos: Value = REPOS
        .iter()
        .map(|rp| {
            let raw = d.get(&format!("repo:{rp}")).cloned().unwrap_or(Slot::NotProbed);
            let v = match &raw {
                Slot::Cmd(out) => {
                    let r = parse_repo(out);
                    json!({ "st": "ok", "br": r.br, "ahead": r.ahead, "behind": r.behind, "dirty": r.dirty })
                }
                other => slot_json(other),
            };
            (rp.to_string(), v)
        })
        .collect::<serde_json::Map<_, _>>()
        .into();
    let disks: Value = match d.get("hostdisk") {
        Some(Slot::Cmd(out)) => parse_df(out)
            .into_iter()
            .map(|r| json!({ "mount": r.mount, "pct": r.pct, "used": r.used, "size": r.size, "avail": r.avail }))
            .collect(),
        _ => json!(null),
    };

    let sess_list: Vec<Value> = sessions
        .list
        .iter()
        .map(|s| json!({ "title": s.title, "age": s.age, "kb": s.kb, "msgs": s.msgs, "cwd": s.cwd }))
        .collect();
    let plugins_json: Vec<Value> = plugins.iter().map(|p| json!({ "label": p.label, "detail": p.detail, "on": p.on })).collect();
    let hooks_json: Vec<Value> = hooks.iter().map(|h| json!({ "name": h.name, "kb": h.kb })).collect();

    json!({
        "services": services,
        "container": get("health"),
        "tokens": get("tokens"),
        "image": get("image"),
        "server": get("server"),
        "mesh": mesh,
        "public": public,
        "mcps": mcp_json,
        "repos": repos,
        "host": { "disks": disks },
        "sessions": { "total": sessions.total, "mb": sessions.bytes / 1_048_576, "list": sess_list },
        "claude": {
            "model": cfg.model,
            "statusline": cfg.statusline,
            "mcp_count": cfg.mcp_count,
            "skills": cfg.skills,
            "plugins": plugins_json,
            "hooks": hooks_json
        }
    })
}
