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
#   ../../../../cloud-u-containers/.../claude-config/mcp.tpl.json   the agent runner
#
# All three were hand-maintained at some point, which is why cloud-cgc-pvt-mcp sat
# routed-but-unreachable: cloud-infra declared it and only one list was ever updated
# by hand. The container list was the last one still hand-written and it cost the
# most — it named SEVEN servers under keys of its own invention, so every headless
# agent on the fleet was told to consult the code graph over a private server its
# client had never been offered. Deriving all three closes that gap: a new HTTP
# service now reaches every platform without anyone remembering to.
#
# A platform's list may differ from the others ONLY through a field it declares in
# mcp-policy.json. Everything else is the same derived set for everyone.
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
import json, sys, collections, os

dist_p, pol_p, sot, check, git_base = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1", sys.argv[5])
dist = json.load(open(dist_p))["mcpServers"]
pol = json.load(open(pol_p))

WARNING = ("GENERATED — DO NOT EDIT. Derived from cloud-infra/1_cloud-configs/dist/mcp.json "
           "+ mcp-policy.json by cloud-u-linux da_my-ai/data/claude/gen-mcp-tpl.sh. "
           "Hand-editing this file is the bug it exists to prevent: edit the service "
           "declaration or mcp-policy.json and regenerate.")

# The HTTP set for one platform: the derived url, plus concrete auth headers on
# everything served by the public MCP proxy — that whole vhost is behind the
# Authelia bearer gate.
#
# Deliberately NOT keyed on the deriver's headersHelper field: only one entry
# carries it, while eight of nine endpoints genuinely need the header, so using
# it as the gate silently strips auth from seven working servers.
auth_host = pol["auth_host"]


def http_set(auth):
    servers = collections.OrderedDict()
    for name in sorted(dist):
        src = dist[name]
        entry = collections.OrderedDict([("type", src.get("type", "http")), ("url", src["url"])])
        if auth_host in src["url"]:
            entry["headers"] = auth
        servers[name] = entry
    # Endpoints the proxy-based deriver cannot express (reached by direct mesh IP).
    for name, entry in pol.get("direct_http", {}).items():
        servers[name] = entry
    return collections.OrderedDict(sorted(servers.items()))


stdio = pol.get("stdio_extras", {})
written, skipped, count = [], [], 0

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

    servers = http_set(rules.get("auth_header", pol["auth_header"]))
    if rules.get("stdio"):
        servers.update(stdio)
    count = len(servers)

    out = collections.OrderedDict([("_warning", WARNING)])
    if rules.get("_doc"):
        out["_doc"] = rules["_doc"]
    out["mcpServers"] = collections.OrderedDict(sorted(servers.items()))
    label = os.path.relpath(target, sot)

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
        written.append(f"{label} ({count} servers)")

for s in skipped:
    print(f"skipped: {s}")

if check:
    print(f"OK: every generated list matches the derived HTTP set ({count} http servers)")
else:
    print("regenerated:", ", ".join(written) if written else "nothing changed")
PY
