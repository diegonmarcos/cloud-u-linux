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
#   mcp.desktop.json.tpl   HTTP + stdio extras
#
# Both tpls were hand-maintained until now, which is why cloud-cgc-pvt-mcp sat
# routed-but-unreachable for six weeks: cloud-infra declared it on 2026-08-23 and
# only the desktop list was ever updated by hand. Deriving both closes that gap —
# a new HTTP service now reaches every platform without anyone remembering to.
#
# Usage: ./gen-mcp-tpl.sh [--check]
#   --check  exit 1 if the committed tpls differ from what this would generate
set -euo pipefail

SOT="$(cd "$(dirname "$0")" && pwd)"
DIST="${CLOUD_INFRA_DIR:-$HOME/git/cloud-infra}/1_cloud-configs/dist/mcp.json"
POLICY="$SOT/mcp-policy.json"

[ -f "$DIST" ]   || { echo "missing derived HTTP set: $DIST" >&2; exit 1; }
[ -f "$POLICY" ] || { echo "missing policy: $POLICY" >&2; exit 1; }

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

python3 - "$DIST" "$POLICY" "$SOT" "$CHECK" <<'PY'
import json, sys, collections, os

dist_p, pol_p, sot, check = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
dist = json.load(open(dist_p))["mcpServers"]
pol = json.load(open(pol_p))

auth = pol["auth_header"]

# HTTP set: the derived url, plus concrete auth headers on everything served by
# the public MCP proxy — that whole vhost is behind the Authelia bearer gate.
#
# Deliberately NOT keyed on the deriver's headersHelper field: only one entry
# carries it, while eight of nine endpoints genuinely need the header, so using
# it as the gate silently strips auth from seven working servers.
auth_host = pol["auth_host"]
http = collections.OrderedDict()
for name in sorted(dist):
    src = dist[name]
    entry = collections.OrderedDict([("type", src.get("type", "http")), ("url", src["url"])])
    if auth_host in src["url"]:
        entry["headers"] = auth
    http[name] = entry

# Endpoints the proxy-based deriver cannot express (reached by direct mesh IP).
for name, entry in pol.get("direct_http", {}).items():
    http[name] = entry

http = collections.OrderedDict(sorted(http.items()))
stdio = pol.get("stdio_extras", {})

written = []
for plat, rules in pol["platforms"].items():
    servers = collections.OrderedDict(http)
    if rules.get("stdio"):
        servers.update(stdio)
    out = collections.OrderedDict()
    if rules.get("_doc"):
        out["_doc"] = rules["_doc"]
    out["mcpServers"] = collections.OrderedDict(sorted(servers.items()))

    target = os.path.join(sot, f"mcp.{plat}.json.tpl")
    new = json.dumps(out, indent=2, ensure_ascii=False) + "\n"
    old = open(target).read() if os.path.exists(target) else None

    if check:
        if old != new:
            print(f"::error::{os.path.basename(target)} is stale — run gen-mcp-tpl.sh")
            o = set(json.loads(old)["mcpServers"]) if old else set()
            n = set(out["mcpServers"])
            if n - o:
                print("    missing:", ", ".join(sorted(n - o)))
            if o - n:
                print("    extra:  ", ", ".join(sorted(o - n)))
            sys.exit(1)
    else:
        if old != new:
            open(target, "w").write(new)
            written.append(f"{os.path.basename(target)} ({len(out['mcpServers'])} servers)")

if check:
    print(f"OK: both tpls match the derived HTTP set ({len(http)} http servers)")
else:
    print("regenerated:", ", ".join(written) if written else "nothing changed")
PY
