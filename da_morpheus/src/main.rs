// c3-morpheus — the cloud's workflow orchestrator, v1.
//
// THE SPLIT, in one line each:
//   c3-watchdog keeps what is running ALIVE   — reactive stability.
//   c3-morpheus decides what RUNS             — intentional orchestration.
//
// This is the first version and it is deliberately small: it READS the two
// workflow surfaces the cloud already has (Dagu on workflows.diegonmarcos.com
// and GitHub Actions across the repos) and prints them side by side, so there
// is one place that answers "what workflows exist and how did they last do".
//
// WHAT IT DOES NOT DO, AND SAYS SO.
// It cannot trigger anything yet. `c3-morpheus run` exits non-zero with the
// reason and the exact call that is missing, rather than printing "started"
// and doing nothing. That failure mode — a green message over a no-op — is the
// one this fleet has paid for repeatedly, and a brand-new surface is not where
// to reintroduce it.
//
// The trigger path is being built in ab_cloud-libs-shared/libs/ops (Dagu
// POST /api/v1/dags/{name}/start with a fresh client_credentials token per
// run, plus a server-side GHA dispatch proxy). When that lands, `run` calls it
// — there is deliberately no second trigger client here to diverge from it.

use std::env;
use std::process::{Command, Stdio};

const DAGU_URL_DEFAULT: &str = "https://workflows.diegonmarcos.com";
const PACA_URL: &str = "https://paca.diegonmarcos.com";

// THE PROBE REGISTRY, CARRIED IN THE BINARY.
//
// Embedded rather than read from a path, so `probes` can never degrade into
// an empty list because a file was not deployed — the one failure mode this
// command exists to prevent. MORPHEUS_PROBES overrides it for local edits.
const PROBES_EMBEDDED: &str = include_str!("../data/probes.json");

// Where the ntfy topic registry lives. Publishing to an unregistered topic
// returns HTTP 200 (ntfy runs auth-default-access: read-write), so a probe's
// alerts can land where nothing subscribes while every publish looks fine.
// `probes validate` reads this file; it is the only thing that can tell.
const NTFY_REGISTRY_DEFAULT: &str =
    "cloud-infra/a_solutions/infra-obs_ntfy/src/build.json";

// The repos whose GitHub Actions are part of the cloud's workflow surface.
// Overridable with MORPHEUS_GH_REPOS (comma separated) rather than hardcoded
// in two places: the list is data, and a new repo should not need a rebuild.
const GH_REPOS_DEFAULT: &str =
    "diegonmarcos/cloud-infra,diegonmarcos/cloud-u-android,diegonmarcos/cloud-u-linux";

fn env_or(key: &str, fallback: &str) -> String {
    match env::var(key) {
        Ok(v) if !v.trim().is_empty() => v,
        _ => fallback.to_string(),
    }
}

/// Is a tool on PATH. A missing tool is reported AS a missing tool — never
/// swallowed into an empty list that reads like "no workflows exist".
fn have(tool: &str) -> bool {
    Command::new("sh")
        .arg("-c")
        .arg(format!("command -v {tool} >/dev/null 2>&1"))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn require(tools: &[&str]) -> Result<(), String> {
    let missing: Vec<&str> = tools.iter().copied().filter(|t| !have(t)).collect();
    if missing.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "missing on PATH: {} — install them or use `nix develop` in da_morpheus",
            missing.join(", ")
        ))
    }
}

/// Run a shell pipeline, returning stdout on success and the command's own
/// stderr on failure. The server's message is carried through verbatim: its
/// wording is always more useful than anything invented here.
fn sh(script: &str) -> Result<String, String> {
    let out = Command::new("sh")
        .arg("-c")
        .arg(script)
        .output()
        .map_err(|e| format!("could not spawn sh: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        Err(if err.is_empty() {
            format!("exited {}", out.status)
        } else {
            err
        })
    }
}

/// Dagu's internal run status int. The mapping is Dagu's, mirrored from
/// libs/ops/.../dagu/DaguModels.kt so the CLI and the phone agree on words.
fn dagu_status(code: &str) -> &'static str {
    match code {
        "1" => "running",
        "2" => "FAILED",
        "3" => "cancelled",
        "4" => "success",
        "5" => "skipped",
        "6" => "partial",
        _ => "never run",
    }
}

// ── dags ────────────────────────────────────────────────────────────────────

// Both payload shapes Dagu has shipped are probed, current one first, exactly
// as DaguClient.listDags does — a server upgrade in either direction must not
// blank the list.
const DAGU_JQ: &str = r#"
  (.dags // .DAGs // [])[]
  | . as $e
  | (($e.dag // $e.Config // $e.DAG // $e)) as $c
  | (($e.latestDAGRun // $e.Status // $e.status // {})) as $s
  | [ (($c.name // $c.Name // $e.fileName // "?") | tostring)
    , (($s.status // $s.Status // 0) | tostring)
    , ((try ($c.schedule[0].expression) catch null) // $c.Schedule // "manual")
    , (($s.finishedAt // $s.FinishedAt // "-") | tostring)
    ] | @tsv
"#;

fn cmd_dags() -> Result<(), String> {
    require(&["curl", "jq"])?;
    let url = env_or("MORPHEUS_DAGU_URL", DAGU_URL_DEFAULT);
    let token = env::var("MORPHEUS_DAGU_TOKEN").unwrap_or_default();
    if token.trim().is_empty() {
        return Err(format!(
            "no Dagu token.\n  \
             Every route on {url} sits behind Authelia forward_auth, so an\n  \
             unauthenticated request gets a 302 to auth.diegonmarcos.com, not a DAG list.\n  \
             Set MORPHEUS_DAGU_TOKEN to an Authelia bearer token:\n    \
             cloud-vault/A0_keys/providers/authelia/oauth/get_token.py"
        ));
    }

    // --fail-with-body, not --fail: a 4xx from the edge carries the reason in
    // the body, and throwing it away turns "your token expired" into "22".
    let body = sh(&format!(
        "curl -sS --fail-with-body -H 'Authorization: Bearer {token}' {url}/api/v1/dags"
    ))
    .map_err(|e| format!("Dagu {url}: {e}"))?;

    let rows = sh(&format!(
        "printf '%s' {} | jq -r {}",
        shell_quote(&body),
        shell_quote(DAGU_JQ)
    ))
    .map_err(|e| format!("could not read the Dagu payload: {e}"))?;

    let rows: Vec<&str> = rows.lines().filter(|l| !l.trim().is_empty()).collect();
    println!("DAGU  {url}");
    if rows.is_empty() {
        println!("  (the server answered, and it has no DAGs registered)");
        return Ok(());
    }
    for line in rows {
        let f: Vec<&str> = line.split('\t').collect();
        let name = f.first().copied().unwrap_or("?");
        let status = dagu_status(f.get(1).copied().unwrap_or("0"));
        let schedule = f.get(2).copied().unwrap_or("manual");
        let finished = f.get(3).copied().unwrap_or("-");
        println!("  {name:<28} {status:<10} {schedule:<16} {finished}");
    }
    Ok(())
}

// ── gha ─────────────────────────────────────────────────────────────────────

fn cmd_gha(limit: u32) -> Result<(), String> {
    require(&["gh"])?;
    let repos = env_or("MORPHEUS_GH_REPOS", GH_REPOS_DEFAULT);
    for repo in repos.split(',').map(str::trim).filter(|r| !r.is_empty()) {
        println!("GITHUB ACTIONS  {repo}");
        // gh's own --jq, so this leg needs no jq on PATH of its own.
        let script = format!(
            "gh run list -R {repo} -L {limit} \
             --json workflowName,status,conclusion,createdAt,databaseId \
             --jq '.[] | [.workflowName, (.conclusion // .status), .createdAt, (.databaseId|tostring)] | @tsv'"
        );
        match sh(&script) {
            Ok(out) => {
                let lines: Vec<&str> = out.lines().filter(|l| !l.trim().is_empty()).collect();
                if lines.is_empty() {
                    println!("  (no runs)");
                }
                for line in lines {
                    let f: Vec<&str> = line.split('\t').collect();
                    println!(
                        "  {:<38} {:<12} {:<22} run {}",
                        f.first().copied().unwrap_or("?"),
                        f.get(1).copied().unwrap_or("?"),
                        f.get(2).copied().unwrap_or("?"),
                        f.get(3).copied().unwrap_or("?")
                    );
                }
            }
            // One unreachable repo must not hide the others, and must not be
            // mistaken for that repo having no workflows.
            Err(e) => println!("  UNREADABLE: {e}"),
        }
        println!();
    }
    Ok(())
}

// ── run ─────────────────────────────────────────────────────────────────────

fn cmd_run(target: Option<&String>) -> Result<(), String> {
    let target = target.map(String::as_str).unwrap_or("<name>");
    Err(format!(
        "NOT WIRED YET — nothing was started, and '{target}' is still idle.\n\n  \
         Triggering is a privileged capability and this v1 deliberately does not\n  \
         own one. The authenticated path is being built once, in\n  \
         ab_cloud-libs-shared/libs/ops:\n    \
         Dagu  POST /api/v1/dags/{{name}}/start, fresh client_credentials token per run\n    \
         GHA   workflow dispatch, proxied server-side\n\n  \
         A second client here would be a second thing to keep in sync with\n  \
         Authelia, so morpheus will call that one rather than reimplement it.\n\n  \
         Until then, start it where it already works:\n    \
         Dagu  {DAGU_URL_DEFAULT} (web UI Start button)\n    \
         GHA   gh workflow run <file> -R <repo>"
    ))
}

// ── boards ──────────────────────────────────────────────────────────────────

fn cmd_boards() -> Result<(), String> {
    println!("PM BOARDS  {PACA_URL}");
    println!(
        "  Paca — oci-apps, port 8095. It has NO usable board API: /api/health,\n  \
         /api/v1/boards and /api/boards all 404, and every route 302s to\n  \
         auth.diegonmarcos.com behind Authelia forward_auth. So there is nothing\n  \
         for a CLI to list. The board IS the Paca app, which is why the phone\n  \
         renders the real SPA inline instead of wrapping an API that isn't there.\n  \
         Open the URL above, or the Boards tab in the Cloud-Morpheus app."
    );
    Ok(())
}

// ── probes ──────────────────────────────────────────────────────────────────

fn probes_json() -> Result<String, String> {
    match env::var("MORPHEUS_PROBES") {
        Ok(p) if !p.trim().is_empty() => std::fs::read_to_string(&p)
            .map_err(|e| format!("MORPHEUS_PROBES={p}: {e}")),
        _ => Ok(PROBES_EMBEDDED.to_string()),
    }
}

fn jq(input: &str, program: &str) -> Result<String, String> {
    sh(&format!(
        "printf '%s' {} | jq -r {}",
        shell_quote(input),
        shell_quote(program)
    ))
}

/// List the declarations. Reading only — it starts nothing and measures
/// nothing, and says which of the two each entry is.
fn cmd_probes_list() -> Result<(), String> {
    require(&["jq"])?;
    let doc = probes_json()?;

    println!("ENDPOINT PROBES  (morpheus measures these itself — `c3-morpheus probe`)");
    let rows = jq(
        &doc,
        r#"(.endpoint_probes // [])[] | [.name, .reach, .url, .topic] | @tsv"#,
    )?;
    for line in rows.lines().filter(|l| !l.trim().is_empty()) {
        let f: Vec<&str> = line.split('\t').collect();
        println!(
            "  {:<10} {:<7} {:<34} -> {}",
            f.first().copied().unwrap_or("?"),
            f.get(1).copied().unwrap_or("?"),
            f.get(2).copied().unwrap_or("?"),
            f.get(3).copied().unwrap_or("?")
        );
    }

    println!();
    println!("SCRIPT PROBES  (cloud-infra owns them, Dagu schedules them — NOT run from here)");
    let rows = jq(
        &doc,
        r#"(.script_probes // [])[] | [.name, .dag, .topic, (.known_defect // "")] | @tsv"#,
    )?;
    for line in rows.lines().filter(|l| !l.trim().is_empty()) {
        let f: Vec<&str> = line.split('\t').collect();
        println!(
            "  {:<26} dag {:<26} -> {}",
            f.first().copied().unwrap_or("?"),
            f.get(1).copied().unwrap_or("?"),
            f.get(2).copied().unwrap_or("?")
        );
        if let Some(d) = f.get(3).filter(|d| !d.trim().is_empty()) {
            println!("      KNOWN DEFECT: {d}");
        }
    }
    Ok(())
}

/// Cross-check every declared topic against the ntfy registry.
///
/// ntfy answers 200 for a publish to a topic nobody registered, so the wire
/// cannot tell you this and neither can the script that published. Only the
/// registry can.
fn cmd_probes_validate() -> Result<(), String> {
    require(&["jq"])?;
    let doc = probes_json()?;
    let registry = env_or("MORPHEUS_NTFY_REGISTRY", NTFY_REGISTRY_DEFAULT);
    let reg = std::fs::read_to_string(&registry).map_err(|e| {
        format!(
            "cannot read the ntfy topic registry at {registry}: {e}\n  \
             Without it nothing here can be validated, so this reports NOTHING\n  \
             rather than reporting every topic as fine. Point MORPHEUS_NTFY_REGISTRY\n  \
             at cloud-infra/a_solutions/infra-obs_ntfy/src/build.json."
        )
    })?;
    let known = jq(&reg, r#"(.topics // [])[] | .name"#)?;
    let known: Vec<&str> = known.lines().map(str::trim).filter(|s| !s.is_empty()).collect();

    let declared = jq(
        &doc,
        r#"((.endpoint_probes // []) + (.script_probes // []))[] | [.name, .topic] | @tsv"#,
    )?;

    let mut bad = 0usize;
    println!("topic registry: {registry} ({} topics)", known.len());
    for line in declared.lines().filter(|l| !l.trim().is_empty()) {
        let f: Vec<&str> = line.split('\t').collect();
        let name = f.first().copied().unwrap_or("?");
        let topic = f.get(1).copied().unwrap_or("");
        if topic.is_empty() {
            println!("  NO TOPIC    {name}");
            bad += 1;
        } else if known.contains(&topic) {
            println!("  ok          {name:<26} -> {topic}");
        } else {
            println!("  UNREGISTERED {name:<25} -> {topic}  (alerts would land where nothing subscribes)");
            bad += 1;
        }
    }
    if bad > 0 {
        return Err(format!("{bad} probe(s) point at a topic the registry does not declare"));
    }
    Ok(())
}

/// Measure the endpoint probes. Three states, and the third one is the point.
fn cmd_probe(only: Option<&String>) -> Result<(), String> {
    require(&["curl", "jq"])?;
    let doc = probes_json()?;
    let rows = jq(
        &doc,
        r#"(.endpoint_probes // [])[] | [.name, .reach, .url, ((.expect_status // [200]) | map(tostring) | join(","))] | @tsv"#,
    )?;

    let mut ran = 0usize;
    let mut down = 0usize;
    let mut unavailable = 0usize;

    for line in rows.lines().filter(|l| !l.trim().is_empty()) {
        let f: Vec<&str> = line.split('\t').collect();
        let name = f.first().copied().unwrap_or("?");
        if only.is_some_and(|w| w.as_str() != name) {
            continue;
        }
        let reach = f.get(1).copied().unwrap_or("public");
        let url = f.get(2).copied().unwrap_or("");
        let expect: Vec<&str> = f.get(3).copied().unwrap_or("200").split(',').collect();
        ran += 1;

        // Exit code and HTTP code are asked for separately, because they are
        // different questions. curl exiting non-zero means the request never
        // got an answer — no route, no DNS, timed out — which is UNAVAILABLE,
        // not DOWN. Only an actual HTTP status can say a service is wrong.
        let out = sh(&format!(
            "code=$(curl -sS -o /dev/null -w '%{{http_code}}' --max-time 10 {}) ; \
             printf '%s %s' \"$?\" \"$code\"",
            shell_quote(url)
        ))
        .unwrap_or_else(|_| "99 000".to_string());
        let mut parts = out.split_whitespace();
        let rc = parts.next().unwrap_or("99");
        let code = parts.next().unwrap_or("000");

        if rc != "0" || code == "000" {
            unavailable += 1;
            let why = if reach == "mesh" {
                "mesh-only target and there is no route from here — \
                 this is NOT evidence the service is down"
            } else {
                "no answer: no route, DNS failure or timeout"
            };
            println!("  UNAVAILABLE {name:<10} {url}\n              {why} (curl exit {rc})");
        } else if expect.contains(&code) {
            println!("  UP          {name:<10} {url}  HTTP {code}");
        } else {
            down += 1;
            println!("  DOWN        {name:<10} {url}  HTTP {code} (expected one of {})", expect.join(","));
        }
    }

    if ran == 0 {
        return Err(match only {
            Some(n) => format!("no endpoint probe named '{n}' — `c3-morpheus probes` lists them"),
            None => "the registry declares no endpoint probes".to_string(),
        });
    }
    println!("\n  {ran} probed — {down} down, {unavailable} unavailable (could not measure)");
    if unavailable > 0 {
        println!("  `unavailable` is not `healthy`. Nothing above was checked for those.");
    }
    // Non-zero when anything is down OR anything could not be measured. A run
    // that failed to measure must not exit 0 and read as green in a cron.
    if down + unavailable > 0 {
        std::process::exit(2);
    }
    Ok(())
}

// ── doctor ──────────────────────────────────────────────────────────────────

fn cmd_doctor() -> Result<(), String> {
    let mark = |ok: bool| if ok { "ok     " } else { "MISSING" };
    println!("tools");
    for t in ["curl", "jq", "gh"] {
        println!("  {} {t}", mark(have(t)));
    }
    println!("config");
    println!(
        "  {} MORPHEUS_DAGU_TOKEN   (Authelia bearer; without it `dags` cannot read anything)",
        mark(env::var("MORPHEUS_DAGU_TOKEN").map(|v| !v.trim().is_empty()).unwrap_or(false))
    );
    println!("  ok      MORPHEUS_DAGU_URL     {}", env_or("MORPHEUS_DAGU_URL", DAGU_URL_DEFAULT));
    println!("  ok      MORPHEUS_GH_REPOS     {}", env_or("MORPHEUS_GH_REPOS", GH_REPOS_DEFAULT));
    println!("  {} ntfy topic registry   {}",
        mark(std::path::Path::new(&env_or("MORPHEUS_NTFY_REGISTRY", NTFY_REGISTRY_DEFAULT)).exists()),
        env_or("MORPHEUS_NTFY_REGISTRY", NTFY_REGISTRY_DEFAULT));
    println!("capabilities");
    println!("  ok      read    — dags, gha, boards");
    println!("  ok      measure — probe (endpoint probes only)");
    println!("  absent  start   — see `c3-morpheus run` for what is missing");
    println!("  absent  run a script probe — cloud-infra owns those, Dagu schedules them");
    Ok(())
}

// ── plumbing ────────────────────────────────────────────────────────────────

/// Single-quote a string for `sh -c`. The Dagu payload and the jq program are
/// both interpolated into a shell line, and a quote inside either would
/// otherwise end the argument and hand the rest to the shell.
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

fn usage() {
    println!(
        "c3-morpheus — the cloud's workflow orchestrator (v1, read-only)

  dags              list the Dagu DAGs and how each last ran
  gha [limit]       list recent GitHub Actions runs per repo (default 5)
  list              both of the above
  probes            the probe registry — what 'healthy' is declared to mean
  probes validate   check every probe's ntfy topic is actually registered
  probe [name]      measure the endpoint probes: up / down / UNAVAILABLE
  boards            where the PM board lives and why it has no API
  run <name>        NOT WIRED YET — prints why, starts nothing
  doctor            what is configured and what is missing

environment
  MORPHEUS_DAGU_TOKEN     Authelia bearer token (required by `dags`)
  MORPHEUS_DAGU_URL       default {DAGU_URL_DEFAULT}
  MORPHEUS_GH_REPOS       comma separated, default the three cloud repos
  MORPHEUS_PROBES         override the embedded probe registry
  MORPHEUS_NTFY_REGISTRY  default {NTFY_REGISTRY_DEFAULT}

exit codes
  0  everything asked for was measured and was fine
  1  the command itself could not run
  2  something is down, OR something could not be measured — never green

c3-watchdog keeps what is running alive. c3-morpheus decides what runs."
    );
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let cmd = args.first().map(String::as_str).unwrap_or("help");

    let result = match cmd {
        "dags" => cmd_dags(),
        "gha" => cmd_gha(
            args.get(1).and_then(|s| s.parse().ok()).unwrap_or(5),
        ),
        "list" => {
            // Both legs always run. An unreachable Dagu must not stop the GHA
            // half from printing — a partial answer beats no answer, as long
            // as the missing half says it is missing.
            if let Err(e) = cmd_dags() {
                println!("DAGU  UNREADABLE: {e}");
            }
            println!();
            cmd_gha(5)
        }
        "probes" => match args.get(1).map(String::as_str) {
            Some("validate") => cmd_probes_validate(),
            None | Some("list") => cmd_probes_list(),
            Some(other) => Err(format!(
                "unknown `probes` subcommand '{other}' — try `probes` or `probes validate`"
            )),
        },
        "probe" => cmd_probe(args.get(1)),
        "boards" => cmd_boards(),
        "run" => cmd_run(args.get(1)),
        "doctor" => cmd_doctor(),
        "help" | "-h" | "--help" => {
            usage();
            Ok(())
        }
        other => Err(format!("unknown command '{other}' — try `c3-morpheus help`")),
    };

    if let Err(e) = result {
        eprintln!("c3-morpheus: {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_words_match_dagu() {
        assert_eq!(dagu_status("1"), "running");
        assert_eq!(dagu_status("2"), "FAILED");
        assert_eq!(dagu_status("4"), "success");
        assert_eq!(dagu_status("0"), "never run");
        assert_eq!(dagu_status("nonsense"), "never run");
    }

    #[test]
    fn quoting_survives_a_quote() {
        assert_eq!(shell_quote("a'b"), r"'a'\''b'");
    }

    /// paca must stay declared mesh-only. Flipping it to `public` would make
    /// every probe run call a healthy service DOWN, because there is no public
    /// edge certificate for that name and the request measures 000.
    #[test]
    fn paca_is_declared_mesh_only() {
        let doc = PROBES_EMBEDDED;
        let i = doc.find("\"name\": \"paca\"").expect("paca probe must be declared");
        let tail = &doc[i..i + 400.min(doc.len() - i)];
        assert!(tail.contains("\"reach\": \"mesh\""));
        assert!(!tail.contains("https://paca.diegonmarcos.com/\","));
    }

    /// The registry must keep saying that a probe which cannot run is neither
    /// healthy nor failing. This is the whole reason it is a file and not
    /// three constants.
    #[test]
    fn registry_states_the_third_state() {
        assert!(PROBES_EMBEDDED.contains("unavailable"));
        assert!(PROBES_EMBEDDED.contains("COULD NOT MEASURE"));
    }

    /// The one behaviour this version must guarantee: `run` never reports
    /// success. Eight bugs in one day were no-ops that said they worked.
    #[test]
    fn run_never_claims_success() {
        let r = cmd_run(Some(&"anything".to_string()));
        assert!(r.is_err());
        assert!(r.unwrap_err().contains("NOT WIRED YET"));
    }
}
