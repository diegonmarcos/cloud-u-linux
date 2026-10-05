#!/bin/sh
# test-linux-account.sh — the Account journey end to end, in a throwaway HOME
# with a FAKE bundle, FAKE vault files and a fake cloud-me_configs. No real
# secret is read; nothing outside the sandbox is touched.
set -u
ENGINE="$(cd "$(dirname "$0")/.." && pwd)/linux-account"
LS="$(cd "$(dirname "$0")/../../da_linux-store" && pwd)/linux-store"
T="$(mktemp -d "${TMPDIR:-/tmp}/linux-account-test.XXXXXX")"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
export HOME="$T/home" GIT_BASE="$T/git" LINUX_STORE_PROFILE=termux LINUX_ACCOUNT_API="http://127.0.0.1:9" LINUX_ACCOUNT_SYNC_URL="https://127.0.0.1:9/fleet/profile"
export PATH="$T/bin:$PATH"
unset LINUX_STORE_ROOT LINUX_ACCOUNT_BUNDLE LINUX_ACCOUNT_HOME ANTHROPIC_API_KEY
mkdir -p "$HOME" "$T/bin"; ln -s "$LS" "$T/bin/linux-store"
CFG="$HOME/.config/linux-account"

pass=0; failn=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no()  { failn=$((failn + 1)); printf '  FAIL %s\n' "$1"; [ -z "${2:-}" ] || printf '       %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else no "$1" "$2"; fi; }
la() { sh "$ENGINE" "$@" >"$T/out" 2>&1; }
section() { printf '\n── %s\n' "$1"; }

# ── fixture ────────────────────────────────────────────────────────────────
V="$GIT_BASE/cloud-me_vault"; WG="$V/A_A0-Providers/C_TOOLS-INFRA/c0-wireguard"
mkdir -p "$V/C_A1-configs" "$V/A_A0-Providers/B_SERVICES-CLOUD/b0-github/api-key_opaque" "$V/A_A0-Providers/C_TOOLS-INFRA/c2-system/ssh" "$WG/termux" "$WG/termux-public"
printf 'ghp_FAKE_VAULT_TOKEN\n' > "$V/A_A0-Providers/B_SERVICES-CLOUD/b0-github/api-key_opaque/token"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKEVAULTKEY\n-----END OPENSSH PRIVATE KEY-----\n' > "$V/A_A0-Providers/C_TOOLS-INFRA/c2-system/ssh/id_rsa"
printf 'ssh-ed25519 AAAAFAKE me@example\n' > "$V/A_A0-Providers/C_TOOLS-INFRA/c2-system/ssh/id_rsa.pub"
printf 'FAKEWGPRIVATEKEY=\n' > "$WG/termux/privatekey"
printf '[Interface]\nPrivateKey = <PROVIDED_BY_DEVICE>\nAddress = 10.0.0.9/24\n[Peer]\nPublicKey = FAKEPUB=\nEndpoint = 1.2.3.4:51820\n' > "$WG/termux-public/config-v4-full"
printf '[Interface]\nPrivateKey = FAKEINLINE=\nAddress = 10.0.0.9/24\n' > "$WG/termux-public/config"
printf 'FAKEPUBKEY=\n' > "$WG/termux-public/publickey"; printf 'notes\n' > "$WG/termux-public/README.md"
cat > "$V/C_A1-configs/profile-secrets.json" <<'EOF'
{ "schema_version": 1, "_generated": {"emitter": "test"},
  "about": {"profile": {"name": "Ada Lovelace", "email": "ada@example.com", "company": "LEAFY", "location": "Berlin/DE", "website": "example.com", "titles_v2": ["Engineer", "Analyst"]}},
  "git": {"github_token": "ghp_FAKE_VAULT_TOKEN", "ssh_private_key": "-----BEGIN OPENSSH PRIVATE KEY-----\nFAKEVAULTKEY\n-----END OPENSSH PRIVATE KEY-----", "ssh_public_key": "ssh-ed25519 AAAAFAKE me@example", "repos": ["diegonmarcos/cloud-me_vault", "diegonmarcos/nope"]},
  "mesh": {"profiles": {"config-v4-full": "[Interface]\nPrivateKey = <PROVIDED_BY_DEVICE>\n", "config": "[Interface]\n"}, "public_key": "FAKEPUB="},
  "mail": {"authoritative_store": "stalwart", "endpoints": {"domain": "example.com", "imap": "imaps://imap.example.com:993", "smtp": "smtps://smtp.example.com:465", "jmap": "https://jmap.example.com"},
           "accounts": {"ada": {"name": "ada@example.com", "pass_env": "MAIL_ADA"}, "admin": {"name": "admin@example.com", "pass_env": "MAIL_ADMIN"}},
           "passwords": {"ada": "fake-mail-pass", "admin": "x"}},
  "ai": {"tokens": {"claude": "sk-ant-FAKE", "openrouter_my_ai_api": "sk-or-FAKE"}, "configs": {"claude_folder": {}}},
  "autocomplete": {"default": {"a": 1}, "cloud_keys": {"k": "FAKE"}},
  "electronics": {"fleet": {"surface": {"type": "notebook", "wg_peer": {"name": "desktop-nixos", "wg_ip": "10.0.0.5"}}, "galaxy": {"type": "phone", "wg_peer": {"name": "termux-galaxy", "wg_ip": "10.0.0.9"}}}},
  "settings": {"items": {"termux": {"kind": "pending"}}},
  "mystery": {"x": 1}
}
EOF
# a sops-looking file, to be refused
printf '{"schema_version": 1, "git": {"github_token": "ENC[AES256_GCM,data:xx]"}, "sops": {"age": []}}\n' > "$T/encrypted.json"
# fake cloud-me_configs with a minimal linux-store declaration
D="$GIT_BASE/cloud-me_configs/A_CONFIGS-USER/a0-diego-admin/deb-user-configs"; mkdir -p "$D/src"
echo '{"configs_users":[{"id":"diego-admin","path":"A_CONFIGS-USER/a0-diego-admin"}]}' > "$GIT_BASE/cloud-me_configs/configs.json"
echo 'x' > "$D/src/marker"
cat > "$D/linux-store.json" <<'EOF'
{"settings": {"roots": {"me": "cloud-me_configs/A_CONFIGS-USER/a0-diego-admin/deb-user-configs"}},
 "common": {"etc": {".marker": {"path": "me:src/marker"}}}}
EOF
# fake mesh.json for the fleet ssh hosts
mkdir -p "$GIT_BASE/cloud-u-android/aa_cloud-superapp/data"
echo '{"nodes": [{"name": "oci-apps", "wg_ip": "10.0.0.6", "alias": "apps"}, {"name": "gcp-proxy", "wg_ip": "10.0.0.1"}]}' > "$GIT_BASE/cloud-u-android/aa_cloud-superapp/data/mesh.json"
# a fake cloud-infra registry
mkdir -p "$GIT_BASE/cloud-infra/1_cloud-configs/src/inputs"
echo '{"users": {"diego": {"identities": [{"email": "ada@example.com", "label": "Ada", "primary": true}, {"email": "ada@work.example", "label": "work"}]}}}' > "$GIT_BASE/cloud-infra/1_cloud-configs/src/inputs/superapp-users.json"

# ── journey ────────────────────────────────────────────────────────────────
section "connect (sign in)"
la fleet; check "not connected: fleet refuses with guidance" '[ $? -ne 0 ] && grep -q "not connected" "$T/out"'
la connect --file "$T/encrypted.json"; check "encrypted file is refused, nothing adopted" '[ $? -ne 0 ] && grep -q "refused" "$T/out" && [ -z "$(jq -r ".bundle // empty" "$CFG/state.json" 2>/dev/null)" ]'
jq '.schema_version = 9' "$V/C_A1-configs/profile-secrets.json" > "$T/v9.json"
la connect --file "$T/v9.json"; check "unknown schema_version is refused" '[ $? -ne 0 ] && grep -q "schema_version 9" "$T/out"'
la connect; check "vault checkout adopted" '[ $? -eq 0 ] && grep -q "connected: vault checkout (schema 1)" "$T/out"'
check "state dir is 700" '[ "$(stat -c %a "$CFG")" = 700 ]'
la journey; check "journey: step 1 done, step 2 active" 'grep -q "● 1 Sign in" "$T/out" && grep -q "◍ 2 Who" "$T/out"'

section "who / device"
la who; check "identities come from the registry" 'grep -q "ada@example.com" "$T/out" && grep -q "ada@work.example" "$T/out"'
la who nobody@x; check "unknown identity refused" '[ $? -ne 0 ]'
la who ada@example.com; check "identity picked" '[ "$(jq -r .identity_email "$CFG/state.json")" = ada@example.com ]'
la device; check "devices listed from electronics.fleet, galaxy default on termux" 'grep -q "● galaxy" "$T/out" && grep -q "○ surface" "$T/out"'
la device surface; la device galaxy; check "device pick stored" '[ "$(jq -r .device_id "$CFG/state.json")" = galaxy ]'

section "plan (nothing written)"
la plan; check "plan lists store entries for vault files" 'grep -q "git  *store  *.ssh/id_rsa" "$T/out" && grep -q "store  *.config/gh/hosts.yml" "$T/out"'
check "plan: wg template with PROVIDED_BY_DEVICE gets the private key, inline one is a file" 'grep -q "config-v4-full.conf *template" "$T/out" && grep -q "termux-config.conf *secret file" "$T/out"'
check "plan: unknown section reported, settings pending" 'grep -q "mystery *skip" "$T/out" && grep -q "settings *pending" "$T/out"'
check "plan wrote nothing" '[ ! -f "$HOME/.ssh/id_rsa" ] && [ ! -f "$D/account.json" ]'

section "apply (get everything)"
la apply; rc=$?
check "apply succeeds and switches" '[ $rc -eq 0 ] && grep -q "is live" "$T/out"'
cat "$T/out" | sed "s/^/       > /" | head -40
check "fragment written: paths only, no values" '[ -f "$D/account.json" ] && ! grep -q -e ghp_ -e FAKEVAULTKEY -e FAKEWGPRIVATEKEY "$D/account.json" && jq -e ".common.secret[\".ssh/id_rsa\"].file == \"vault:A_A0-Providers/C_TOOLS-INFRA/c2-system/ssh/id_rsa\"" "$D/account.json" >/dev/null'
check "linux-store.json now includes the fragment" 'jq -e ".settings.include | index(\"me:account.json\")" "$D/linux-store.json" >/dev/null'
check "ssh key realised by linux-store, 600" '[ "$(stat -c %a "$HOME/.ssh/id_rsa")" = 600 ] && grep -q FAKEVAULTKEY "$HOME/.ssh/id_rsa" && [ "$(stat -c %a "$HOME/.ssh/id_rsa.pub")" = 644 ]'
check "gh token rendered from the vault file" 'grep -qx "    oauth_token: ghp_FAKE_VAULT_TOKEN" "$HOME/.config/gh/hosts.yml"'
check "wireguard: private key spliced into the public profile" 'grep -qx "PrivateKey = FAKEWGPRIVATEKEY=" "$HOME/.config/wireguard/termux-config-v4-full.conf" && [ "$(stat -c %a "$HOME/.config/wireguard/termux-config-v4-full.conf")" = 600 ]'
check "wireguard: inline profile copied" 'grep -q FAKEINLINE "$HOME/.config/wireguard/termux-config.conf"'
check "wireguard: publickey lands as ~/.config/wireguard/publickey (644), README is not ours" '[ "$(stat -c %a "$HOME/.config/wireguard/publickey")" = 644 ] && grep -q FAKEPUBKEY "$HOME/.config/wireguard/publickey" && [ ! -e "$HOME/.config/wireguard/termux-README.md.conf" ]'
check "fleet ssh hosts generated" 'grep -q "^Host oci-apps apps" "$HOME/.ssh/config.d/fleet" && grep -q "HostName 10.0.0.1" "$HOME/.ssh/config.d/fleet"'
check "mail: identity account picked, env 600" '[ "$(jq -r .mail_account "$CFG/state.json")" = ada ] && grep -q "^export MAIL_PASS=.fake-mail-pass." "$CFG/secrets/mail.env" && [ "$(stat -c %a "$CFG/secrets/mail.env")" = 600 ]'
check "ai: tokens env with ANTHROPIC_API_KEY" 'grep -q "^export CLAUDE_API_KEY=" "$CFG/secrets/ai.env" && grep -q "^export ANTHROPIC_API_KEY=.sk-ant-FAKE." "$CFG/secrets/ai.env"'
check "autocomplete lists 600" '[ "$(stat -c %a "$CFG/secrets/autocomplete/cloud_keys.json")" = 600 ]'
check "about: contact card seeded (titles joined)" '[ "$(jq -r .titles "$CFG/profile.json")" = "Engineer | Analyst" ] && [ "$(jq -r .email "$CFG/profile.json")" = ada@example.com ]'
check "no secret value leaked into the store or the config repo" '! grep -rqs -e ghp_FAKE -e FAKEVAULTKEY -e FAKEWGPRIVATEKEY -e sk-ant-FAKE "$HOME/.linux-store" "$GIT_BASE/cloud-me_configs"'
la journey; check "journey: all four steps done" '[ "$(grep -c "●" "$T/out")" = 4 ]'

section "fleet (the cockpit)"
la fleet -v; rc=$?
check "fleet draws" '[ $rc -eq 0 ]'
check "Drive: token + key MATCH, repos 1/2 DIFFERS" 'grep -q "MATCH *github token" "$T/out" && grep -q "MATCH *ssh key" "$T/out" && grep -q "DIFFERS *repos *1/2" "$T/out"'
check "Drive light OFF (a DIFFERS row)" 'grep -q "Drive (private repos) *OFF" "$T/out"'
check "Mesh ON, Mail ON, AI light reflects the unsourced env" 'grep -q "Mesh *ON" "$T/out" && grep -q "Mail *ON" "$T/out" && grep -q "ABSENT *ANTHROPIC_API_KEY" "$T/out"'
check "Keyboard & Clipboards UNVERIFIABLE" 'grep -q "Keyboard & Clipboards *UNVERIFIABLE" "$T/out"'
check "no secret value in the cockpit output" '! grep -q -e ghp_FAKE -e FAKEVAULTKEY -e sk-ant "$T/out"'
echo tampered >> "$CFG/secrets/ai.env"; la fleet -v; check "edited ai.env shows DIFFERS" 'grep -q "DIFFERS *tokens" "$T/out"'
rm -f "$HOME/.ssh/id_rsa"; la fleet -v; check "removed ssh key shows ABSENT" 'grep -q "ABSENT *ssh key" "$T/out"'
sh "$LS" repair >/dev/null 2>&1; la fleet -v; check "linux-store repair brings the key back (MATCH)" 'grep -q "MATCH *ssh key" "$T/out"'

section "infos (contact card + sync)"
la infos; check "card shows seeded fields" 'grep -q "name *Ada Lovelace" "$T/out"'
la infos set birth=10-12-1815 phone=+49; check "DOB DD-MM-YYYY -> ISO on set" '[ "$(jq -r .birth "$CFG/profile.json")" = 1815-12-10 ]'
la infos set nope=1; check "unknown field refused" '[ $? -ne 0 ]'
la infos push; check "push to an unreachable sync url is queued, not lost" 'grep -q queued "$T/out" && [ "$(ls "$CFG/queue" | wc -l | tr -d " ")" = 1 ]'
check "install id + secret generated once" '[ -n "$(jq -r .install_id "$CFG/state.json")" ] && [ "$(jq -r .install_secret "$CFG/state.json" | wc -c | tr -d " ")" = 33 ]'
check "queued body has the 8-field allowlist only" 'jq -e ".profile | keys - [\"name\",\"email\",\"phone\",\"birth\",\"location\",\"company\",\"website\",\"titles\"] | length == 0" "$CFG"/queue/*.json >/dev/null'
la infos erase; check "erase clears card, queue and install id" '[ ! -f "$CFG/profile.json" ] && [ -z "$(ls "$CFG/queue")" ] && [ -z "$(jq -r ".install_id // empty" "$CFG/state.json")" ]'

section "apps / wg / ai / tui"
la apps compare; check "apps compare lists linux-store bin entries" 'grep -q "● *linux-store" "$T/out" && grep -q "declared" "$T/out"'
la apps export "$T/inv.json"; check "inventory exported in AppInventory shape" '[ "$(jq -r .kind "$T/inv.json")" = linux-account.app-inventory ] && jq -e ".apps[0] | has(\"name\") and has(\"origin\")" "$T/inv.json" >/dev/null'
la wg; check "wg lists declared profiles" 'grep -q "termux-config-v4-full" "$T/out"'
la ai; check "ai reports tokens" 'grep -q "tokens: " "$T/out"'
printf '1\n\n3\nb\n6\n\nq\n' | LINUX_ACCOUNT_TUI_TEST=1 sh "$ENGINE" tui > "$T/out" 2>&1; check "tui drives Fleet, Infos, Apps and quits" 'grep -q "Drive (private repos)" "$T/out" && grep -q "linux-store" "$T/out"'
la connect --forget; la fleet; check "forget disconnects; picks survive" '[ $? -ne 0 ] && [ "$(jq -r .device_id "$CFG/state.json")" = galaxy ]'

printf '\n%d passed, %d failed\n' "$pass" "$failn"
[ "$failn" -eq 0 ]
