#!/usr/bin/env bash
# gen-dashboard.sh — render the qutebrowser dashboard start page, DATA-DRIVEN.
#
# Inputs (all overridable via env for reproducible/CI builds):
#   BOOKMARKS_JSON      section SoT (curated links/folders + source markers)
#   CLOUD_DESKTOP_JSON  cloud-data's build-flakes_desktop.json (per-service domain + proxy.primary.wg_only)
#   FRONT_TOPOLOGY_JSON front's I_front-data/front-topology.json (projects[] with category + path)
#   FRONT_ROOT          front repo root for file:// links (default ~/git/front)
#   HISTORY_SQLITE      qutebrowser history db for the "Last Sessions" section
#   TEMPLATE            dashboard.template.html (has the __BOOKMARKS_JSON__ token)
#   OUT                 output qute-bookmarks.html
#
# Section model: sections[] → each has direct `links` and/or `folders[]`.
# DATA-DRIVEN sources (never hardcoded):
#   section source:"history" → last 5 distinct URLs from history.sqlite (empty if absent)
#   section source:"front"   → one folder per front category (^[abc]-) from front-topology.json
#   folder  source:"cloud:public" → services whose proxy.primary.wg_only is not true
#   folder  source:"cloud:app"    → the WG-only services (internal *.app names)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BOOKMARKS_JSON="${BOOKMARKS_JSON:-$HERE/../2_configs/qute-bookmarks.json}"
CLOUD_DESKTOP_JSON="${CLOUD_DESKTOP_JSON:-$HOME/git/cloud-infra/2_configs/dist/build-flakes_desktop.json}"
FRONT_TOPOLOGY_JSON="${FRONT_TOPOLOGY_JSON:-$HOME/git/front/front-topology.json}"
FRONT_ROOT="${FRONT_ROOT:-$HOME/git/front}"
HISTORY_SQLITE="${HISTORY_SQLITE:-$HOME/.local/share/qutebrowser/history.sqlite}"
# Live history.js dumped by the fork (mybar.py, event-driven off history.web_history.changed)
# — matches its default standarddir.data() path exactly. See dashboard.template.html's
# __HISTORY_JS_PATH__ token for why this can't just be a fetch() of qute://history/data.
HISTORY_JS_PATH="${HISTORY_JS_PATH:-$HOME/.local/share/qutebrowser/history-recent.js}"
TEMPLATE="${TEMPLATE:-$HERE/dashboard.template.html}"
OUT="${OUT:-$HERE/../../dist/qute-bookmarks.html}"

[ -r "$BOOKMARKS_JSON" ] || { echo "gen-dashboard: missing $BOOKMARKS_JSON" >&2; exit 1; }
[ -r "$TEMPLATE" ]       || { echo "gen-dashboard: missing $TEMPLATE" >&2; exit 1; }

# cloud services → { "label": "url", ... }. Two projections of the SAME service set:
#   mode=public : the public Caddy domain  (.domain → https://sub.diegonmarcos.com[/path])
#   mode=app    : the internal WG name      (.dns    → https://<name>.app)
# Empty {} if the cloud file is absent (page still builds without the cloud repo).
cloud_links() { # $1 = public|app
  local mode="$1"
  if [ -r "$CLOUD_DESKTOP_JSON" ]; then
    jq --arg mode "$mode" '
      [ .services // {} | to_entries[]
        | select(.value.enabled != false)
        | { name: .key, domain: .value.domain, dns: .value.dns }
        | if $mode == "app"
          then select(.dns) | { key: (.dns|sub("\\.app$";"")), url: ("https://" + .dns) }
          else select(.domain) | { key: ( if (.domain|contains("/")) then (.domain|split("/")|last)
                                           else (.domain|split(".")|first) end ),
                                   url: ("https://" + .domain) }
          end
      ] | sort_by(.key) | reduce .[] as $x ({}; .[$x.key] = $x.url)
    ' "$CLOUD_DESKTOP_JSON"
  else
    echo '{}'
  fi
}

# cloud services grouped BY CATEGORY → [ {name:<Category>, links:{svc:url}} ],
# one folder per category (agi/app/cloud/data/fin/mic/net/obs/sec/tools). URL =
# public domain when the service has one, else its internal .app (WG-only). This
# is the "break each url per category of purpose" view. Category label is the raw
# code Title-cased. Empty [] if the cloud file is absent.
cloud_by_category() {
  if [ -r "$CLOUD_DESKTOP_JSON" ]; then
    jq '
      [ .services // {} | to_entries[]
        | select(.value.enabled != false)
        | { cat: (.value.category // "other"), name: .key,
            url: ( if .value.domain then ("https://" + .value.domain)
                   elif .value.dns  then ("https://" + .value.dns)
                   else null end ) }
        | select(.url) ]
      | group_by(.cat)
      | map({ name: ((.[0].cat | .[0:1] | ascii_upcase) + (.[0].cat | .[1:])),
              links: (reduce (sort_by(.name)[]) as $s ({}; .[$s.name] = $s.url)) })
      | sort_by(.name)
    ' "$CLOUD_DESKTOP_JSON"
  else
    echo '[]'
  fi
}

# front categories → [ { name, links:{proj:file://…} } ], one folder per ^[abc]- category.
# file:// links point at each project's index.html under FRONT_ROOT/<path>.
front_folders() {
  if [ -r "$FRONT_TOPOLOGY_JSON" ]; then
    jq --arg root "$FRONT_ROOT" '
      [ .projects // [] | .[]
        | select(.category | test("^[abc]-"))
        | { cat: .category, name: .name,
            url: ("file://" + $root + "/" + .path
                  + (if .has_dist then "/dist/index.html" else "/index.html" end)) } ]
      | group_by(.cat)
      | map({ name: (.[0].cat),
              links: (reduce .[] as $p ({}; .[$p.name] = $p.url)) })
    ' "$FRONT_TOPOLOGY_JSON"
  else
    echo '[]'
  fi
}

# last 5 distinct URLs from qutebrowser history → { label: url }.
# Skips the dashboard itself; label = page title (fallback host). Empty if no db/sqlite3.
history_links() {
  if command -v sqlite3 >/dev/null 2>&1 && [ -r "$HISTORY_SQLITE" ]; then
    # TSV: url \t title  (newest first, distinct url, real navigations only)
    sqlite3 -separator $'\t' "$HISTORY_SQLITE" \
      "SELECT url, COALESCE(NULLIF(title,''), url) FROM History
         WHERE redirect=0 AND url NOT LIKE 'file://%qute-bookmarks.html'
         GROUP BY url ORDER BY max(atime) DESC LIMIT 5;" 2>/dev/null \
    | jq -R -s '
        split("\n") | map(select(length>0) | split("\t"))
        | reduce .[] as $r ({}; .[($r[1] // $r[0])] = $r[0])'
  else
    echo '{}'
  fi
}

PUBLIC="$(cloud_links public)"
WGONLY="$(cloud_links app)"
CLOUDCATS="$(cloud_by_category)"
FRONT="$(front_folders)"
HISTORY="$(history_links)"

# Normalise every section to { name, desc, links, folders:[{name,desc,links}] },
# resolving all data-driven sources. Direct section links (QuickMarks) stay in
# .links; folder-bearing sections resolve each folder's source.
DATA="$(jq -n \
  --slurpfile bm "$BOOKMARKS_JSON" \
  --argjson public "$PUBLIC" \
  --argjson wgonly "$WGONLY" \
  --argjson cloudcats "$CLOUDCATS" \
  --argjson front  "$FRONT" \
  --argjson history "$HISTORY" '
  { sections: (
      $bm[0].sections
      | map({
          name: .name,
          desc: (.desc // ""),
          recent: (.source == "history"),
          links: ( if   .source == "history" then ((.links // {}) + $history)
                   else (.links // {}) end ),
          folders: ( if   .source == "front"            then $front
                     elif .source == "cloud:categories" then $cloudcats
                     else ( .folders // []
                            | map({ name: .name, desc: (.desc // ""),
                                    links: ( if   .source == "cloud:public" then $public
                                             elif .source == "cloud:app"    then $wgonly
                                             else (.links // {}) end ) }) )
                     end )
        })
    ) }
')"

# Keybindings → flat array [{key,cmd,desc,group}] for the dashboard Shortcuts tab.
# SoT is qute-keybindings.json (same file the home-module projects into qutebrowser);
# skip _doc keys and any non-object value. Empty [] if the file is absent.
KEYBINDINGS_JSON="${KEYBINDINGS_JSON:-$HERE/../2_configs/qute-keybindings.json}"
if [ -r "$KEYBINDINGS_JSON" ]; then
  KEYBINDINGS="$(jq '[ .normal // {} | to_entries[]
    | select((.key|startswith("_"))|not) | select(.value|type=="object")
    | { key: .key, cmd: .value.cmd, desc: (.value.desc // ""), group: (.value.group // "Other") } ]' \
    "$KEYBINDINGS_JSON")"
else
  KEYBINDINGS='[]'
fi

# Dashboard search bar → web-search URL template. SoT is qute-search-engines.json's
# "qw" (Qwant) entry — the SAME engine qutebrowser itself uses for `qw <query>` in
# the `:` bar, so the dashboard's Enter-to-search and qutebrowser's own bang stay
# in lockstep. `{}` is replaced with the URL-encoded query client-side.
SEARCH_ENGINES_JSON="${SEARCH_ENGINES_JSON:-$HERE/../2_configs/qute-search-engines.json}"
if [ -r "$SEARCH_ENGINES_JSON" ]; then
  SEARCH_URL="$(jq -r '.qw // .DEFAULT // "https://www.qwant.com/?q={}"' "$SEARCH_ENGINES_JSON")"
else
  SEARCH_URL="https://www.qwant.com/?q={}"
fi

# Plugin registry → the dashboard's Plugins tab (:plugins / #plugins). SoT is
# qute-plugins.json (same file the home-module wires into qutebrowser). Drop
# _-prefixed doc keys from actions so the card renders cleanly.
PLUGINS_JSON="${PLUGINS_JSON:-$HERE/../2_configs/qute-plugins.json}"
if [ -r "$PLUGINS_JSON" ]; then
  PLUGINS="$(jq '[ .plugins // [] | .[]
    | { id, name, category, surface, enabled: (.enabled // false),
        status: (.status // ""), keybinding: (.keybinding // ""),
        option: (.option // ""), description: (.description // ""),
        footprint: (.footprint // ""),
        actions: ((.actions // {}) | with_entries(select(.key | startswith("_") | not))) } ]' \
    "$PLUGINS_JSON")"
else
  PLUGINS='[]'
fi

mkdir -p "$(dirname "$OUT")"
# Inject five tokens. LITERAL replacement via index()/substr() + ENVIRON —
# NOT gsub() and NOT `-v`: awk gsub treats `&` in the replacement as "the
# matched text" (so a plugin name like "Ad & Tracker Blocking" or any URL
# query-string `?a=1&b=2` corrupts the output), and `-v` runs C-escape
# processing on the value (mangling JSON's \" \\ ). ENVIRON + substr avoids
# both entirely — the injected JSON is inserted byte-for-byte.
BM="$DATA" KB="$KEYBINDINGS" PL="$PLUGINS" SU="$SEARCH_URL" HJ="$HISTORY_JS_PATH" awk '
  function inject(s, tok, val,   i, out) {
    out = ""
    while ((i = index(s, tok)) > 0) { out = out substr(s, 1, i-1) val; s = substr(s, i + length(tok)) }
    return out s
  }
  { line = inject($0,   "__BOOKMARKS_JSON__",   ENVIRON["BM"])
    line = inject(line, "__KEYBINDINGS_JSON__", ENVIRON["KB"])
    line = inject(line, "__PLUGINS_JSON__",     ENVIRON["PL"])
    line = inject(line, "__SEARCH_URL__",       ENVIRON["SU"])
    line = inject(line, "__HISTORY_JS_PATH__",  ENVIRON["HJ"])
    print line }' "$TEMPLATE" > "$OUT"
nsec=$(jq -r '.sections|length' <<<"$DATA")
nlink=$(jq -r '[.sections[] | (.links|length) + ([.folders[].links|length]|add // 0)]|add' <<<"$DATA")
echo "gen-dashboard: wrote $OUT ($nlink links across $nsec sections)"

# Also emit qutebrowser's native bookmarks file (one "url  Section/[Folder/]name"
# per line) from the SAME fully-resolved link set — so the built-in Bookmarks page
# carries the identical list (curated + cloud + front). "Last Sessions" is skipped
# (transient history, not a bookmark). Deployed by home-module.nix.
BOOKMARKS_URLS="${BOOKMARKS_URLS:-$HERE/../../dist/qute-bookmarks-urls}"
jq -r '.sections[] | select(.name != "Last Sessions") as $s
       | ( ($s.links // {}) | to_entries[] | "\(.value)  \($s.name)/\(.key)" ),
         ( ($s.folders // [])[] as $f | $f.links | to_entries[]
           | "\(.value)  \($s.name)/\($f.name)/\(.key)" )' <<<"$DATA" > "$BOOKMARKS_URLS"
echo "gen-dashboard: wrote $BOOKMARKS_URLS ($(wc -l < "$BOOKMARKS_URLS") bookmarks)"

# Emit mybar.json — the SoT for the FORK's native chrome bar (mybar.py). Two
# lanes, both DATA-DRIVEN from the same resolved set:
#   bookmarks[] — each section's direct links → {name,url} buttons; each folder
#                 → {name,links} dropdown. "Last Sessions" skipped (transient).
#   plugins[]   — enabled plugins from qute-plugins.json that have an in-browser
#                 command: an explicit `command` (Vaultwarden) or, for config
#                 plugins, the generated `plugin-toggle-<id>` alias. Daemon-only
#                 plugins (fido2, OS autofill) have no command → omitted.
# ponytail: labels are text (bookmark/plugin name). Real favicons/emoji need an
# `icon` field added to the source JSON — bar reads entry.icon when present.
MYBAR_JSON="${MYBAR_JSON:-$HERE/../../dist/mybar.json}"
BM_BAR="$(jq '[ .sections[] | select(.name != "Last Sessions")
       | ( ( (.links // {}) | to_entries[] | { name: .key, url: .value } ),
           ( (.folders // [])[] | { name: .name, links: .links } ) ) ]' <<<"$DATA")"
PL_BAR="$(jq '[ .plugins // [] | .[] | select(.enabled == true)
       | if .command then { name: .name, command: .command }
         elif .surface == "config" then { name: .name, command: ("plugin-toggle-" + .id) }
         else empty end ]' "$PLUGINS_JSON" 2>/dev/null || echo '[]')"
jq -n --argjson bookmarks "$BM_BAR" --argjson plugins "$PL_BAR" \
   '{ bookmarks: $bookmarks, plugins: $plugins }' > "$MYBAR_JSON"
echo "gen-dashboard: wrote $MYBAR_JSON ($(jq '.bookmarks|length' "$MYBAR_JSON") bar entries, $(jq '.plugins|length' "$MYBAR_JSON") plugins)"
