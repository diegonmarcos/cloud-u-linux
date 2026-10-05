#!/bin/sh
# test-linux-store.sh — exercises the engine in a throwaway $HOME.
#
# Never touches the real ~/.linux-store, ~/.claude or ~/.claude.json: HOME,
# GIT_BASE and the declaration all point into a mktemp sandbox, and the profile
# is pinned so the run means the same thing on the phone and on the desktop.
#
# Usage: sh test/test-linux-store.sh        (exit 0 = all green)
set -u

ENGINE="$(cd "$(dirname "$0")/.." && pwd)/linux-store"
T="$(mktemp -d "${TMPDIR:-/tmp}/linux-store-test.XXXXXX")"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

export HOME="$T/home" GIT_BASE="$T/git" LINUX_STORE_DECLARATION="$T/store.json"
export LINUX_STORE_PROFILE=termux PATH="$T/hostbin:$PATH"
unset LINUX_STORE_ROOT LINUX_STORE_FAULT LINUX_STORE_KEEP
R="$HOME/.linux-store"
C="$GIT_BASE/conf"

pass=0; failn=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no()  { failn=$((failn + 1)); printf '  FAIL %s\n' "$1"; [ -z "${2:-}" ] || printf '       %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else no "$1" "$2"; fi; }
ls_()  { sh "$ENGINE" "$@" >"$T/out" 2>&1; }
section() { printf '\n── %s\n' "$1"; }
live()  { basename "$(readlink "$R/current")"; }
objs()  { ls -1 "$R/store" | wc -l | tr -d ' '; }

# ── fixture ────────────────────────────────────────────────────────────────
mkdir -p "$HOME" "$T/hostbin" "$C/agents" "$C/plugins"
printf '#!/bin/sh\necho hello-from-host\n' > "$T/hostbin/hello"; chmod +x "$T/hostbin/hello"
printf '#!/bin/sh\necho "$GREETING|$LD_LIBRARY_PATH"\n' > "$C/tool.sh"
echo 'ELF-ish' > "$C/libfake.so.1"
echo 'plugin' > "$C/plugins/p.so"
echo 'util() { :; }' > "$C/util.sh"
echo 'review agent v1' > "$C/agents/review.md"
echo '.claude/projects/' > "$C/rgignore"
echo '{"a":1,"env":{"X":"@HOME@/x"},"arr":[1,2]}' > "$C/base.json"
echo '{"b":2,"arr":[3]}' > "$C/termux.json"
echo '{"_doc":"x","keys":{"remoteControlAtStartup":true}}' > "$C/cj.json"
echo '{"auth":"secret","remoteControlAtStartup":false}' > "$HOME/.claude.json"
echo 'fetched payload' > "$T/payload"
PSHA="$(sha256sum "$T/payload" | cut -d' ' -f1)"

cat > "$T/store.json" <<EOF
{
  "settings": { "roots": { "c": "conf" } },
  "common": {
    "bin": {
      "hello": { "host": "hello" },
      "tool":  { "path": "c:tool.sh", "exe": true, "env": { "GREETING": "hi there" },
                 "libs": ["libfake.so.1", "plugins"] }
    },
    "lib": {
      "libfake.so.1": { "path": "c:libfake.so.1" },
      "plugins":      { "path": "c:plugins" },
      "util.sh":      { "path": "c:util.sh" },
      "payload":      { "fetch": "file://$T/payload", "sha256": "$PSHA" }
    },
    "etc": {
      ".claude/agents":   { "path": "c:agents" },
      ".claude/rgignore": { "path": "c:rgignore" },
      ".desktop-only":    { "path": "c:rgignore" }
    },
    "activate": {
      ".claude/settings.json": { "render": ["c:base.json"] },
      ".claude.json":          { "keys": "c:cj.json" }
    }
  },
  "termux":  { "etc": { ".desktop-only": null },
               "activate": { ".claude/settings.json": { "render": ["c:termux.json"] } } },
  "desktop": { "bin": { "hello": null } }
}
EOF

# ── tests ──────────────────────────────────────────────────────────────────
section "profile"
LINUX_STORE_PROFILE=bogus ls_ profile; check "unknown profile is refused" '[ $? -ne 0 ] && grep -q "neither termux nor desktop" "$T/out"'
ls_ profile; check "override pins termux" 'grep -qx termux "$T/out"'

section "apply"
ls_ switch; rc=$?
check "first apply succeeds and verifies" '[ $rc -eq 0 ] && grep -q "ok — termux-1" "$T/out"'
[ $rc -eq 0 ] || cat "$T/out"
check "current -> termux-1" '[ "$(live)" = termux-1 ]'
check "etc: ~/.claude/agents links through current" '[ "$(readlink "$HOME/.claude/agents")" = "$R/current/etc/.claude/agents" ]'
check "etc: content is the store copy" 'grep -q "v1" "$HOME/.claude/agents/review.md"'
check "etc: null in profile removes a common entry" '[ ! -e "$HOME/.desktop-only" ] && [ ! -L "$HOME/.desktop-only" ]'
check "bin: host binary runs" '[ "$("$R/current/bin/hello")" = hello-from-host ]'
check "bin: engine itself is on bin/" '[ -x "$R/current/bin/linux-store" ]'
out="$("$R/current/bin/tool")"
check "bin: wrapper sets env" 'case "$out" in "hi there|"*) true ;; *) false ;; esac'
check "bin: LD_LIBRARY_PATH is pinned store paths only" 'case "$out" in *"|$R/store/"*-tool-libs:"$R/store/"*-plugins) true ;; *) false ;; esac'
check "lib: script lib reachable via current" '[ -f "$R/current/lib/util.sh" ]'
check "lib: fetch with matching sha256" 'grep -q "fetched payload" "$R/current/lib/payload"'
check "store: objects are read-only" '[ ! -w "$R/current/etc/.claude/agents/review.md" ] || [ "$(id -u)" = 0 ]'
check "activate: render = base * termux, arrays replaced, @HOME@ substituted" \
    '[ "$(jq -cS . "$HOME/.claude/settings.json")" = "$(jq -ncS --arg h "$HOME" "{a:1,b:2,arr:[3],env:{X:(\$h+\"/x\")}}")" ]'
check "activate: settings.json is a real file" '[ -f "$HOME/.claude/settings.json" ] && [ ! -L "$HOME/.claude/settings.json" ]'
check "activate: keys patched, runtime state kept" '[ "$(jq -c . "$HOME/.claude.json")" = "{\"auth\":\"secret\",\"remoteControlAtStartup\":true}" ]'
check "env.sh and env.fish written" '[ -f "$R/env.sh" ] && [ -f "$R/env.fish" ]'

section "idempotence"
n1="$(objs)"; ls_ switch
check "re-apply makes termux-2" '[ "$(live)" = termux-2 ]'
check "re-apply adds no store objects" '[ "$(objs)" = "$n1" ]'

section "change, diff, rollback"
echo 'review agent v2' > "$C/agents/review.md"; ls_ switch
check "changed source -> new generation, new content" '[ "$(live)" = termux-3 ] && grep -q v2 "$HOME/.claude/agents/review.md"'
ls_ diff termux-2 termux-3
check "diff names the changed entry" 'grep -q "^+etc/.claude/agents" "$T/out" && ! grep -q "^+bin/hello" "$T/out"'
ls_ rollback
check "rollback -> termux-2, old content, verified" '[ "$(live)" = termux-2 ] && grep -q v1 "$HOME/.claude/agents/review.md" && grep -q "ok — termux-2" "$T/out"'
ls_ switch-generation 3
check "switch-generation 3 -> termux-3" '[ "$(live)" = termux-3 ] && grep -q v2 "$HOME/.claude/agents/review.md"'

section "atomicity (fault injection)"
echo 'review agent v3' > "$C/agents/review.md"
for stage in populate seal switch; do
    before="$(live)"
    LINUX_STORE_FAULT=$stage ls_ switch; rc=$?
    check "fault at $stage: run stops (90)" '[ $rc -eq 90 ]'
    check "fault at $stage: current unchanged ($before)" '[ "$(live)" = "$before" ]'
    ls_ check; check "fault at $stage: live generation still verifies" '[ $? -eq 0 ]'
done
echo '{"a":9,"env":{"X":"@HOME@/x"},"arr":[1,2]}' > "$C/base.json"
LINUX_STORE_FAULT=activate ls_ switch
ls_ check; check "fault at activate: verify names the unrendered file" '[ $? -ne 0 ] && grep -q "settings.json differs" "$T/out"'
ls_ repair; check "repair renders it" '[ $? -eq 0 ] && [ "$(jq .a "$HOME/.claude/settings.json")" = 9 ]'

section "integrity"
obj="$(readlink -f "$R/current/etc/.claude/rgignore")"
chmod u+w "$obj"; echo tampered >> "$obj"
ls_ check; check "edited store object is caught" '[ $? -ne 0 ] && grep -q "does not match its hash" "$T/out"'
ls_ repair; check "repair replaces it" '[ $? -eq 0 ] && ! grep -q tampered "$HOME/.claude/rgignore"'
echo '{"hand":"edited"}' > "$HOME/.claude/settings.json"
ls_ check; check "drifted settings.json is caught" '[ $? -ne 0 ]'
ls_ repair; check "repair rewrites it" '[ "$(jq .a "$HOME/.claude/settings.json")" = 9 ]'

section "ownership of \$HOME paths"
jq '.common.etc[".conf/x"] = {"path": "c:util.sh"}' "$T/store.json" > "$T/s" && mv "$T/s" "$T/store.json"
mkdir -p "$HOME/.conf"; echo mine > "$HOME/.conf/x"; before="$(live)"
ls_ switch; check "foreign file blocks apply, nothing switched" '[ $? -ne 0 ] && [ "$(live)" = "$before" ] && grep -q "not managed by linux-store" "$T/out"'
ls_ switch --backup; check "--backup moves it aside and applies" '[ $? -eq 0 ] && ls "$HOME/.conf/" | grep -q "x.linux-store-backup"'
rm -f "$HOME/.conf/x"; ln -s /nix/store/0000-home-manager-files/x "$HOME/.conf/x"; before="$(live)"
ls_ switch --backup; check "a nix-owned link is refused even with --backup" '[ $? -ne 0 ] && [ "$(live)" = "$before" ] && grep -q "belongs to nix" "$T/out"'
rm -f "$HOME/.conf/x"; jq 'del(.common.etc[".conf/x"])' "$T/store.json" > "$T/s" && mv "$T/s" "$T/store.json"
ls_ switch

section "profiles"
ls_ build --profile desktop; check "build --profile desktop works on a termux box" '[ $? -eq 0 ] && [ -d "$R/generations/desktop-1" ]'
check "desktop generation drops hello, keeps .desktop-only" '[ ! -e "$R/generations/desktop-1/bin/hello" ] && [ -L "$R/generations/desktop-1/etc/.desktop-only" ]'
ls_ switch-generation desktop-1; check "switching to the other profile is refused" '[ $? -ne 0 ] && grep -q "refused" "$T/out"'

section "fetch"
jq --arg s "$(printf 0%.0s $(seq 64))" '.common.lib.payload.sha256 = $s' "$T/store.json" > "$T/bad.json"
LINUX_STORE_DECLARATION="$T/bad.json" ls_ switch; check "fetch with the wrong sha256 is refused" '[ $? -ne 0 ] && grep -q "does not match the declared sha256" "$T/out"'

section "dev mode"
ls_ dev .claude/rgignore; check "dev links to the repo source" '[ "$(readlink "$HOME/.claude/rgignore")" = "$C/rgignore" ]'
echo live-edit >> "$C/rgignore"
check "dev: repo edits are visible immediately" 'grep -q live-edit "$HOME/.claude/rgignore"'
ls_ check; check "dev: verify accepts and reports it" '[ $? -eq 0 ] && grep -q "dev mode" "$T/out"'
ls_ switch; check "dev: apply leaves the dev link alone" '[ "$(readlink "$HOME/.claude/rgignore")" = "$C/rgignore" ]'
ls_ dev --off .claude/rgignore; check "dev --off returns it to the store" '[ "$(readlink "$HOME/.claude/rgignore")" = "$R/current/etc/.claude/rgignore" ]'

section "removal, gc, lock"
jq 'del(.common.etc[".claude/rgignore"])' "$T/store.json" > "$T/s" && mv "$T/s" "$T/store.json"
ls_ switch; check "undeclared etc entry is unlinked from \$HOME" '[ ! -e "$HOME/.claude/rgignore" ] && [ ! -L "$HOME/.claude/rgignore" ]'
LINUX_STORE_KEEP=1 ls_ switch; n1="$(objs)"
ls_ gc; check "gc removes unreferenced objects" '[ "$(objs)" -lt "$n1" ] && grep -q "removed" "$T/out"'
ls_ check; check "after gc the live generation still verifies" '[ $? -eq 0 ]'
flock "$R/lock" sleep 3 & sleep 1
ls_ switch; check "a held lock makes a second apply fail fast" '[ $? -ne 0 ] && grep -q "holds" "$T/out"'
wait

section "activate copy"
printf 'extensions:\n  cmd: @HOME@/.node_modules/x.mjs\n' > "$C/goose.yaml"
jq '.common.activate[".config/goose/config.yaml"] = {"copy": "c:goose.yaml"}' "$T/store.json" > "$T/s" && mv "$T/s" "$T/store.json"
ls_ switch; check "copy writes a real file with @HOME@ filled" \
    '[ -f "$HOME/.config/goose/config.yaml" ] && [ ! -L "$HOME/.config/goose/config.yaml" ] && grep -qx "  cmd: $HOME/.node_modules/x.mjs" "$HOME/.config/goose/config.yaml"'

section "secrets (sops, throwaway age key)"
# Everything here is generated for the test: a fresh age key and fake values.
# No real key or secret is read.
age-keygen -o "$T/age.key" 2>/dev/null
APUB="$(age-keygen -y "$T/age.key")"
printf 'ssh:\n  id_test: |\n    -----BEGIN OPENSSH PRIVATE KEY-----\n    FAKEKEYMATERIAL\n    -----END OPENSSH PRIVATE KEY-----\ngithub:\n  token: ghp_FAKE_TEST_TOKEN_123\n' > "$T/plain.yaml"
sops -e --age "$APUB" --input-type yaml --output-type yaml "$T/plain.yaml" > "$C/keys.sops.yaml" 2>"$T/sops.err" || cat "$T/sops.err"
rm -f "$T/plain.yaml"
printf 'github.com:\n    oauth_token: @GH_TOKEN@\n    git_protocol: https\n' > "$C/gh-hosts.yml.tpl"
jq '.common.secret = {
      ".ssh/id_test":         {"sops": "c:keys.sops.yaml", "extract": "[\"ssh\"][\"id_test\"]"},
      ".config/gh/hosts.yml": {"template": "c:gh-hosts.yml.tpl",
                               "values": {"GH_TOKEN": {"sops": "c:keys.sops.yaml", "extract": "[\"github\"][\"token\"]"}}}
    }' "$T/store.json" > "$T/s" && mv "$T/s" "$T/store.json"

before="$(live)"
( unset SOPS_AGE_KEY_FILE; ls_ switch ); check "no age key: apply refused before switching, file named" \
    '[ "$(live)" = "$before" ] && grep -q "cannot decrypt .*keys.sops.yaml" "$T/out"'
export SOPS_AGE_KEY_FILE="$T/age.key"
ls_ switch; rc=$?
check "with the key: apply succeeds and verifies" '[ $rc -eq 0 ] && grep -q "ok — " "$T/out"'
[ $rc -eq 0 ] || cat "$T/out"
check "ssh key written, mode 600, ends in newline" \
    '[ "$(stat -c %a "$HOME/.ssh/id_test")" = 600 ] && grep -q FAKEKEYMATERIAL "$HOME/.ssh/id_test" && [ -z "$(tail -c1 "$HOME/.ssh/id_test")" ]'
check "~/.ssh is 700" '[ "$(stat -c %a "$HOME/.ssh")" = 700 ]'
check "token rendered into gh hosts.yml, mode 600" \
    'grep -qx "    oauth_token: ghp_FAKE_TEST_TOKEN_123" "$HOME/.config/gh/hosts.yml" && [ "$(stat -c %a "$HOME/.config/gh/hosts.yml")" = 600 ]'
check "no secret value anywhere under the store root" '! grep -rqs -e ghp_FAKE_TEST_TOKEN -e FAKEKEYMATERIAL "$R"'
check "store root is 700" '[ "$(stat -c %a "$R")" = 700 ]'
echo tampered >> "$HOME/.config/gh/hosts.yml"
ls_ check; check "edited secret is caught (without printing it)" '[ $? -ne 0 ] && grep -q "hosts.yml differs" "$T/out" && ! grep -q ghp_FAKE "$T/out"'
chmod 644 "$HOME/.ssh/id_test"
ls_ check; check "loosened mode is caught" '[ $? -ne 0 ] && grep -q "has mode 644" "$T/out"'
ls_ repair; check "repair re-decrypts both" '[ $? -eq 0 ] && [ "$(stat -c %a "$HOME/.ssh/id_test")" = 600 ] && ! grep -q tampered "$HOME/.config/gh/hosts.yml"'

section "secret file kind + settings.include"
mkdir -p "$C/vault/gh" "$C/vault/ssh"
printf 'ghp_PLAIN_TEST_TOKEN\n' > "$C/vault/gh/token"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nPLAINKEY\n-----END OPENSSH PRIVATE KEY-----' > "$C/vault/ssh/id_rsa"
cat > "$C/account.json" <<EOF
{ "common": { "secret": {
    ".ssh/id_rsa":          { "file": "c:vault/ssh/id_rsa" },
    ".config/gh/hosts.yml": { "template": "c:gh-hosts.yml.tpl", "values": { "GH_TOKEN": { "file": "c:vault/gh/token" } } },
    ".ssh/id_test": null
} } }
EOF
jq '.settings.include = ["c:account.json"]' "$T/store.json" > "$T/s" && mv "$T/s" "$T/store.json"
ls_ switch; rc=$?
check "include: switch succeeds" '[ $rc -eq 0 ]'
[ $rc -eq 0 ] || cat "$T/out"
check "file secret: ssh key copied, 600, newline-terminated" \
    '[ "$(stat -c %a "$HOME/.ssh/id_rsa")" = 600 ] && grep -q PLAINKEY "$HOME/.ssh/id_rsa" && [ -z "$(tail -c1 "$HOME/.ssh/id_rsa")" ]'
check "file value in template: token rendered without its trailing newline" \
    'grep -qx "    oauth_token: ghp_PLAIN_TEST_TOKEN" "$HOME/.config/gh/hosts.yml"'
check "include: null in a fragment removes an entry" '! jq -e ".entries[] | select(.name == \".ssh/id_test\")" "$(readlink "$R/current")/manifest.json" >/dev/null'
check "no plaintext secret under the store root" '! grep -rqs -e ghp_PLAIN_TEST_TOKEN -e PLAINKEY "$R"'
ls_ check; check "check passes with file secrets" '[ $? -eq 0 ]'
: > "$C/vault/gh/token"; ls_ build; check "empty secret file is refused at build" '[ $? -ne 0 ] && grep -q "is empty" "$T/out"'
printf 'ghp_PLAIN_TEST_TOKEN\n' > "$C/vault/gh/token"

section "declaration from cloud-me_configs"
CM="$GIT_BASE/cloud-me_configs"; UD="$CM/A_CONFIGS-USER/a0-diego-admin/deb-user-configs"
mkdir -p "$UD"
echo '{"kind":"cloud-me.configs","configs_users":[{"id":"diego-admin","path":"A_CONFIGS-USER/a0-diego-admin"}]}' > "$CM/configs.json"
cp "$T/store.json" "$UD/linux-store.json"
( unset LINUX_STORE_DECLARATION; ls_ build ); check "found via configs.json for diego-admin" \
    '[ "$(jq -r .declaration "$(ls -1d "$R"/generations/termux-* | sort -t- -k2,2n | tail -1)/manifest.json")" = "$UD/linux-store.json" ]'
( unset LINUX_STORE_DECLARATION; LINUX_STORE_USER=nobody ls_ build ); check "unknown configs-user is named in the error" \
    'grep -q "declares no configs-user .nobody." "$T/out"'
( unset LINUX_STORE_DECLARATION; ls_ switch; mv "$CM" "$CM.away"; ls_ check; rc=$?; mv "$CM.away" "$CM"; exit $rc ); check "verify falls back to the recorded declaration when the checkout is gone" '[ $? -eq 0 ]'

printf '\n%d passed, %d failed\n' "$pass" "$failn"
[ "$failn" -eq 0 ]
