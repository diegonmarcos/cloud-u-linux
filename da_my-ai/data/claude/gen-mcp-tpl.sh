#!/usr/bin/env bash
# Generate the Claude MCP client lists from the derived HTTP set + platform policy.
#
#   cloud-infra/1_cloud-configs/dist/mcp.json   the HTTP set, derived from the
#                                               service declarations (url + headersHelper)
#   mcp-policy.json                             what that derivation cannot know:
#                                               direct-IP endpoints, desktop-only
#                                               stdio servers, per-platform policy
#        |
#        v
#   mcp.termux.json.tpl    HTTP only
#   mcp.desktop.json.tpl   HTTP only
#   ../../../../cloud-u-containers/.../claude-config/mcp.tpl.json   the claude runner
#   ../../../../cloud-u-containers/.../goose-config.yaml            the goose runner (filtered, region)
#   ../../../../cloud-u-containers/.../hermes config.yaml           the hermes runner (filtered, region)
#
# Every one of these was hand-maintained at some point, which is why
# cloud-cgc-pvt-mcp sat routed-but-unreachable and the claude runner named seven
# servers under keys of its own invention: a new HTTP service reached each new
# list only if someone remembered to edit it. The claude container list was the
# last one still hand-written and it cost the most — every headless agent on the
# fleet was told to consult the code graph over a private server its client had
# never been offered. Deriving ALL of them closes that gap: a new HTTP service
# now reaches every platform without anyone remembering to.
#
# A platform's list may differ from the others ONLY through fields it declares
# in mcp-policy.json:
#   filter     — subset of the derived set, when the client legitimately wants
#                fewer servers than the fleet exposes. A subset is DECLARED, not
#                copied: the names must exist in the derived set or --check fails.
#   url_mode   — "mesh" rewrites each url to http://{ip}:{port}/mcp from that
#                server's own fleet declaration (dist/build-<name>.json), for
#                clients that run on the mesh and carry no bearer token.
#   format     — "goose-yaml" / "hermes-yaml" render a marked REGION inside the
#                client's own config file instead of the whole file, so the
#                surrounding hand-authored config (env, providers, gateway,
#                toolsets) stays put while the server list is generated.
# Everything else is the same derived set for everyone.
#
# Usage: ./gen-mcp-tpl.sh [--check]
#   --check  exit 1 if a committed list differs from what this would generate
set -euo pipefail

SOT="$(cd "$(dirname "$0")" && pwd)"
DIST="${CLOUD_INFRA_DIR:-$HOME/git/cloud-infra}/1_cloud-configs/dist/mcp.json"
POLICY="$SOT/mcp-policy.json"
# Where a platform's `output` path is anchored. Same variable settings.base.json
# exports, so a machine with a non-default checkout layout relocates every
# out-of-repo target at once.
GIT_BASE="${GIT_BASE:-$HOME/git}"

[ -f "$DIST" ]   || { echo "missing derived HTTP set: $DIST" >&2; exit 1; }
[ -f "$POLICY" ] || { echo "missing policy: $POLICY" >&2; exit 1; }

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

python3 - "$DIST" "$POLICY" "$SOT" "$CHECK" "$GIT_BASE" <<'PY'
import json, sys, collections, os, difflib

dist_p, pol_p, sot, check, git_base = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1", sys.argv[5])
dist_dir = os.path.dirname(dist_p)
dist = json.load(open(dist_p))["mcpServers"]
pol = json.load(open(pol_p))

WARNING = ("GENERATED — DO NOT EDIT. Derived from cloud-infra/1_cloud-configs/dist/mcp.json "
           "+ mcp-policy.json by cloud-u-linux da_my-ai/data/claude/gen-mcp-tpl.sh. "
           "Hand-editing this file is the bug it exists to prevent: edit the service "
           "declaration or mcp-policy.json and regenerate.")

# The region markers for the YAML container platforms. This script owns the text
# BETWEEN the two marker lines (inclusive); the surrounding config file is
# hand-authored. The marker text is greppable from the cloud-u-containers side,
# which runs the same --check with GIT_BASE pointed at its own checkout.
BEGIN_GEN = "BEGIN GENERATED MCP SERVERS"
END_GEN = "END GENERATED MCP SERVERS"

# The HTTP set for one platform: the derived url, plus concrete auth headers on
# everything served by the public MCP proxy — that whole vhost is behind the
# Authelia bearer gate.
#
# Deliberately NOT keyed on the deriver's headersHelper field: only one entry
# carries it, while eight of nine endpoints genuinely need the header, so using
# it as the gate silently strips auth from seven working servers.
#
# `filter_names` (declared in mcp-policy.json, `filter`) narrows the set when a
# platform legitimately wants fewer servers. The names must exist in the derived
# set; a typo fails the caller's --check rather than silently shipping nothing.
auth_host = pol["auth_host"]


def http_set(auth, filter_names=None):
    servers = collections.OrderedDict()
    for name in sorted(dist):
        if filter_names is not None and name not in filter_names:
            continue
        src = dist[name]
        entry = collections.OrderedDict([("type", src.get("type", "http")), ("url", src["url"])])
        if auth_host in src["url"]:
            entry["headers"] = auth
        servers[name] = entry
    # Endpoints the proxy-based deriver cannot express (reached by direct mesh IP).
    for name, entry in pol.get("direct_http", {}).items():
        if filter_names is not None and name not in filter_names:
            continue
        servers[name] = entry
    return collections.OrderedDict(sorted(servers.items()))


def mesh_url(name):
    # The container platforms reach their subset over the WireGuard mesh, not the
    # public proxy: they run network_mode: host on oci-apps and carry no bearer
    # token. The ip+port come from the fleet's own declaration of each server
    # (dist/build-<name>.json) — the same source the cloud-u-containers contract
    # tests assert against, so the client and the test cannot disagree.
    declaration = os.path.join(dist_dir, f"build-{name}.json")
    if not os.path.isfile(declaration):
        raise SystemExit(
            f"mesh url for {name}: missing fleet declaration {declaration} — "
            "run 1_cloud-configs/build.sh derive")
    d = json.load(open(declaration))
    return f"http://{d['services'][name]['ip']}:{d['container']['port']}/mcp"


def render_region(plat, rules, servers, catalogue=None):
    # Each container client owns its own file format around the MCP block; this
    # script owns ONLY the marked region. `indent` matches the mapping level the
    # block sits at in the surrounding file (goose nests under `extensions:`).
    fmt = rules.get("format")
    indent = 2 if fmt == "goose-yaml" else 0
    pad = " " * indent
    provenance = ("cloud-infra/1_cloud-configs/dist/mcp.json + mcp-policy.json by "
                  "cloud-u-linux da_my-ai/data/claude/gen-mcp-tpl.sh")
    lines = [f"{pad}# ══ {BEGIN_GEN} — do not edit; derived from {provenance} (platform: {plat}) ══"]
    if fmt == "hermes-yaml":
        lines.append("mcp_servers:")
        for name in sorted(servers):
            entry = servers[name]
            lines.append(f"  {name}:")
            lines.append(f"    type: {entry.get('type', 'http')}")
            lines.append(f"    url: {entry['url']}")
        if catalogue:
            # A comment, not an entry: hermes' config schema has no verified
            # "declared but disabled" form, and guessing one risks loading the
            # very 147-tool server this budget exists to keep out. Names stay
            # visible; an agent runs tools/list against the url on demand.
            lines.append("  # names-only (NOT loaded — run tools/list on demand):")
            for name in sorted(catalogue):
                lines.append(f"  #   {name}: {catalogue[name]['url']}")
    elif fmt == "goose-yaml":
        display = rules.get("server_names", {})
        for name in sorted(servers):
            entry = servers[name]
            lines.append(f"{pad}{name}:")
            lines.append(f"{pad}  name: {display.get(name, name)}")
            lines.append(f"{pad}  type: streamable_http")
            lines.append(f"{pad}  uri: {entry['url']}")
            lines.append(f"{pad}  enabled: true")
            lines.append(f"{pad}  timeout: 300")
        # Catalogue: the NAME is here so the agent knows the server exists, but
        # `enabled: false` means goose never fetches its tools, so it costs no
        # context. Flip one to true only if its measured cost fits the budget.
        for name in sorted(catalogue or {}):
            lines.append(f"{pad}{name}:")
            lines.append(f"{pad}  name: {display.get(name, name)}")
            lines.append(f"{pad}  type: streamable_http")
            lines.append(f"{pad}  uri: {catalogue[name]['url']}")
            lines.append(f"{pad}  enabled: false")
            lines.append(f"{pad}  timeout: 300")
    else:
        raise SystemExit(f"unknown region format {fmt!r} for platform {plat}")
    lines.append(f"{pad}# ══ {END_GEN} ══")
    return "\n".join(lines) + "\n"


def extract_region(text):
    # The region is BEGIN marker line .. END marker line, each inclusive. Both
    # must be present and ordered; anything else means the file was never seeded.
    start = end = None
    for i, line in enumerate(text.splitlines()):
        if start is None:
            if BEGIN_GEN in line:
                start = i
        elif END_GEN in line:
            end = i
            break
    if start is None or end is None:
        return None
    return "\n".join(text.splitlines()[start:end + 1]) + "\n"


stdio = pol.get("stdio_extras", {})
written, skipped, counts = [], [], []

# ── Exposure tiering + token budget ────────────────────────────────────────
# A REGISTERED server injects every tool schema into context on every turn.
# Measured 2026-09-20 with a real initialize -> tools/list handshake: 310+
# tools / ~39,700 tokens across nine servers, about double the 20k ceiling.
# Only the `full` tier is registered; every other server becomes a catalogue
# entry (name + url) that an agent queries with tools/list when it needs it.
exp = pol.get("exposure")
if not exp:
    print("::error::mcp-policy.json has no `exposure` block — the token budget "
          "would be unenforced and every server would load full schemas", file=sys.stderr)
    sys.exit(1)

budget = exp["budget_tokens"]
full_names = set(exp["full"])
measured = {k: v for k, v in exp["measured_tokens"].items() if not k.startswith("_")}
per_name = exp["names_only_tokens_each"]

def split_exposure(servers):
    """(registered, catalogue) — catalogue keeps the NAME of every other server."""
    reg, cat = collections.OrderedDict(), collections.OrderedDict()
    for n, e in servers.items():
        if n in full_names:
            reg[n] = e
        else:
            cat[n] = collections.OrderedDict([
                ("url", e.get("url", "")),
                ("exposure", "names_only"),
                ("tools", "run tools/list against this url when you need it"),
            ])
    return reg, cat

def exposure_cost(reg, cat):
    """Projected context cost. An UNMEASURED registered server is a failure,
    never a zero — a missing number must not read as a free server."""
    total = 0
    for n in reg:
        if n not in measured:
            print(f"::error::{n} is registered `full` but has no measured_tokens "
                  f"entry — its real cost is unknown and would count as 0", file=sys.stderr)
            sys.exit(1)
        total += measured[n]
    return total + per_name * len(cat)

for plat, rules in pol["platforms"].items():
    # A platform writes beside this script unless it declares somewhere else.
    # `output` is for a consumer that cannot read this checkout at all — the
    # container image is built from a context in another repository — so its
    # copy has to be committed there rather than fetched from here.
    out_path = rules.get("output")
    if out_path:
        target = os.path.join(git_base, out_path)
        if not os.path.isdir(os.path.dirname(target)):
            skipped.append(f"{plat} ({os.path.dirname(out_path)} not checked out)")
            continue
    else:
        target = os.path.join(sot, f"mcp.{plat}.json.tpl")

    filter_names = rules.get("filter")
    if filter_names:
        unknown = sorted(set(filter_names) - set(dist) - set(pol.get("direct_http", {})))
        if unknown:
            raise SystemExit(f"{plat}: filter names not in the derived set: {unknown}")

    servers = http_set(rules.get("auth_header", pol["auth_header"]), filter_names)
    if rules.get("stdio"):
        servers.update(stdio)
    if rules.get("url_mode") == "mesh":
        for name in list(servers):
            servers[name] = collections.OrderedDict(
                [("type", servers[name].get("type", "http")), ("url", mesh_url(name))])
    counts.append(len(servers))

    # Cap enforced here, above the format branch: goose-yaml and hermes-yaml
    # `continue` below, so a check placed after them would silently exempt
    # exactly the two agent platforms this ceiling exists to protect.
    registered, catalogue = split_exposure(servers)
    projected = exposure_cost(registered, catalogue)
    if projected > budget:
        print(f"::error::{plat}: projected MCP exposure {projected} tokens exceeds "
              f"the {budget} ceiling. Registered: "
              f"{', '.join(f'{n}={measured[n]}' for n in registered)}. "
              f"Move a server out of exposure.full, or collapse it to meta-tools.",
              file=sys.stderr)
        sys.exit(1)
    servers = registered

    fmt = rules.get("format", "json")
    label = os.path.relpath(target, sot)

    if fmt in ("goose-yaml", "hermes-yaml"):
        # Region formats: rewrite only the marked block inside the client's own
        # config file, never the whole file.
        region = render_region(plat, rules, servers, catalogue)
        old = open(target).read() if os.path.exists(target) else None
        got = extract_region(old) if old else None
        if check:
            if got is None:
                print(f"::error::{label}: region markers {BEGIN_GEN!r}/{END_GEN!r} "
                      f"absent from the committed file — add them around the MCP "
                      f"block (see mcp-policy.json platform {plat})")
                sys.exit(1)
            if got != region:
                print(f"::error::{label} is stale — run gen-mcp-tpl.sh")
                sys.stdout.writelines(difflib.unified_diff(
                    got.splitlines(True), region.splitlines(True),
                    fromfile="committed", tofile="generated"))
                sys.exit(1)
        else:
            if old is None:
                raise SystemExit(
                    f"refusing to create {label}: the MCP region needs the "
                    f"surrounding file to anchor into — add the file with "
                    f"{BEGIN_GEN!r}/{END_GEN!r} markers first")
            if got is None:
                raise SystemExit(
                    f"refusing to rewrite {label}: markers absent — add "
                    f"{BEGIN_GEN!r}/{END_GEN!r} lines around the MCP block first")
            if got != region:
                open(target, "w").write(old.replace(got, region, 1))
                written.append(f"{label} ({len(servers)} servers, region)")
        continue

    # Whole-file formats (JSON): the committed template is the ENTIRE file.
    out = collections.OrderedDict([("_warning", WARNING)])
    if rules.get("_doc"):
        out["_doc"] = rules["_doc"]
    out["_exposure"] = collections.OrderedDict([
        ("_doc", "Only mcpServers below are registered and preload tool schemas. "
                 "Every server in _mcp_catalogue is reachable but NOT preloaded: "
                 "run tools/list against its url at the moment you need it."),
        ("budget_tokens", budget),
        ("projected_tokens", projected),
    ])
    out["mcpServers"] = collections.OrderedDict(sorted(registered.items()))
    out["_mcp_catalogue"] = collections.OrderedDict(sorted(catalogue.items()))

    new = json.dumps(out, indent=2, ensure_ascii=False) + "\n"
    old = open(target).read() if os.path.exists(target) else None

    if check:
        if old != new:
            print(f"::error::{label} is stale — run gen-mcp-tpl.sh")
            o = set(json.loads(old).get("mcpServers", {})) if old else set()
            n = set(out["mcpServers"])
            if n - o:
                print("    missing:", ", ".join(sorted(n - o)))
            if o - n:
                print("    extra:  ", ", ".join(sorted(o - n)))
            if o == n and old is not None:
                print("    same servers, different content (url, headers or shape)")
            sys.exit(1)
    elif old != new:
        os.makedirs(os.path.dirname(target), exist_ok=True)
        open(target, "w").write(new)
        written.append(f"{label} ({len(servers)} servers)")

for s in skipped:
    print(f"skipped: {s}")

if check:
    print(f"OK: every generated list matches the derived HTTP set "
          f"({', '.join(map(str, counts))} servers per platform)")
else:
    print("regenerated:", ", ".join(written) if written else "nothing changed")
PY