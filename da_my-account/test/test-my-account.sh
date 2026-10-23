#!/bin/sh
# test-my-account.sh — manifests are complete and my-account's copy has not
# drifted from the flake-sourced content (redundant phase), plus a sandboxed
# deploy round trip. Roots for drift:
#   lin: = this repo (cloud-u-linux), always available
#   cmc: = cloud-me_configs checkout: $MY_ACCOUNT_CMC, else a sibling dir;
#          absent -> SKIP with notice, or FAIL when MY_ACCOUNT_STRICT=1.
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"; REPO="$(cd "$D/.." && pwd)"
CMC="${MY_ACCOUNT_CMC:-}"
for c in "$REPO/../cloud-me_configs" "$REPO/../../cloud-me_configs" "${GIT_BASE:-/nonexistent}/cloud-me_configs" "$HOME/cloud-me_configs"; do
  [ -n "$CMC" ] && break; [ -d "$c/A_CONFIGS-USER" ] && CMC="$c"
done
T="$(mktemp -d "${TMPDIR:-/tmp}/my-account-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 1\n' > "$T/bin/gh"; chmod +x "$T/bin/gh"   # no ambient gh token
PATH="$T/bin:$PATH"; export PATH; unset GITHUB_TOKEN MY_ACCOUNT_ME_TOKEN MY_ACCOUNT_ME_DIR MY_ACCOUNT_ME_API GIT_BASE
TAB="$(printf '\t')"; pass=0; failn=0
ok() { pass=$((pass + 1)); }
no() { failn=$((failn + 1)); printf '  FAIL %s\n' "$1"; }
same() { if [ -d "$1" ]; then diff -r -x manifest "$1" "$2" >/dev/null 2>&1; else cmp -s "$1" "$2"; fi; }
skipped=0

echo "-- manifests"
n=0
for m in "$D"/*/manifest; do
  app="$(basename "$(dirname "$m")")"; n=$((n + 1))
  while IFS="$TAB" read -r kind variants source target flake; do
    case "$kind" in ''|'#'*) continue ;; esac
    [ -n "$flake" ] || { no "$app: entry '$source' has fewer than 5 fields"; continue; }
    case "$kind" in file|dir|inline|sops|canon|secret) ;; *) no "$app: bad kind '$kind'"; continue ;; esac
    case "$variants" in desktop|termux|desktop,termux|termux,desktop) ;; *) no "$app: bad variants '$variants'" ;; esac
    case "$kind" in
      secret) [ "$source" = - ] && case "$flake" in me:*) ok ;; *) no "$app: secret entry without me: ref" ;; esac \
              || no "$app: secret entry must not carry a source"; continue ;;
      sops) [ "$source" = - ] && case "$flake" in sops:*) ok ;; *) no "$app: sops entry without sops: ref" ;; esac \
              || no "$app: sops entry must not carry a source (never copy secrets)"; continue ;;
    esac
    [ -e "$D/$app/$source" ] && ok || no "$app: source '$source' missing"
    case "$kind" in file|dir)
      case "$target" in /*|../*|*/../*|-|'') no "$app: target '$target' must be relative to \$HOME" ;; *) ok ;; esac ;;
    esac
  done < "$m"
done
[ "$n" -gt 10 ] && ok || no "expected many app manifests, found $n"

echo "-- every held file is declared (no orphans), no secret files"
for app in "$D"/*/; do
  app="$(basename "$app")"; [ -f "$D/$app/manifest" ] || continue
  # canon source "." covers the whole app folder
  if awk -F'\t' '$1=="canon" && $3=="."{f=1} END{exit !f}' "$D/$app/manifest"; then continue; fi
  find "$D/$app" -type f ! -name manifest | while read -r f; do
    rel="${f#"$D/$app/"}"
    awk -F'\t' -v r="$rel" '$3==r || (index(r, $3 "/")==1){f=1} END{exit !f}' "$D/$app/manifest" || echo "orphan $app/$rel"
  done
done > "$T/orphans"
[ -s "$T/orphans" ] && no "undeclared files: $(tr '\n' ' ' < "$T/orphans")" || ok
find "$D" \( -name 'secrets.yaml' -o -name 'secrets.yml' -o -name 'keys.txt' -o -name '*.age' \) -type f | grep . >/dev/null && no "secret-like file present" || ok

echo "-- drift vs flake sources (cmc: ${CMC:-not found})"
for m in "$D"/*/manifest; do
  app="$(basename "$(dirname "$m")")"
  while IFS="$TAB" read -r kind variants source target flake; do
    case "$kind" in ''|'#'*|sops|secret) continue ;; esac
    oldifs="$IFS"; IFS=,; set -- $flake; IFS="$oldifs"
    for ref in "$@"; do
      case "$ref" in
        lin:*) root="$REPO" ;;
        cmc:*) root="$CMC"
          if [ -z "$root" ]; then
            [ "${MY_ACCOUNT_STRICT:-0}" = 1 ] && no "$app: cloud-me_configs not found" || skipped=$((skipped + 1)); continue
          fi ;;
        *) no "$app: bad flake_src '$ref'"; continue ;;
      esac
      p="$root/${ref#*:}"
      if [ ! -e "$p" ]; then no "$app/$source: flake source gone: ${ref#*:}"; continue; fi
      same "$D/$app/$source" "$p" && ok || no "$app/$source drifted from ${ref#*:}"
    done
  done < "$m"
done
[ "$skipped" -gt 0 ] && echo "  SKIP $skipped cmc: comparison(s): cloud-me_configs checkout not found (set MY_ACCOUNT_CMC)"

echo "-- deploy round trip in a sandbox HOME"
H="$T/home"; mkdir -p "$H"
MY_ACCOUNT_HOME="$H" sh "$D/my-account" --profile desktop > "$T/plan" 2>&1
[ -z "$(find "$H" -type f | head -1)" ] && ok || no "dry-run wrote files"
grep -q 'new   fish -> .config/fish/functions' "$T/plan" && ok || no "plan lacks fish functions"
MY_ACCOUNT_HOME="$H" sh "$D/my-account" --profile desktop --apply > "$T/apply" 2>&1
same "$D/git/config" "$H/.config/git/config" && ok || no "apply did not deploy git/config"
same "$D/kde/plasmoids/org.kde.plasma.kstats" "$H/.local/share/plasma/plasmoids/org.kde.plasma.kstats" && ok || no "dir entry not deployed"
[ -e "$H/.config/sops/age/keys.txt" ] && no "sops entry was deployed" || ok
MY_ACCOUNT_HOME="$H" sh "$D/my-account" --profile desktop 2>&1 | grep -q 'new=0 same=[1-9]' && ok || no "second plan not idempotent"
printf 'local edit\n' >> "$H/.vimrc"
MY_ACCOUNT_HOME="$H" sh "$D/my-account" --profile desktop --apply 2>&1 | grep -q 'diff  vim' && ok || no "local edit not reported"
grep -q 'local edit' "$H/.vimrc" && ok || no "differing file overwritten without --force"
rm -f "$H/.config/starship.toml"; ln -s /nix/store/x-starship.toml "$H/.config/starship.toml"
MY_ACCOUNT_HOME="$H" sh "$D/my-account" --profile desktop 2>&1 | grep -q 'skip  starship' && ok || no "nix-managed symlink not skipped"

echo "-- secrets: local cloud-me clone first, mocked API second, values never printed"
ME="$T/cloud-me"; mkdir -p "$ME/my-account/goose" "$T/bin"
printf 'LOCAL-SECRET-VALUE-111\n' > "$ME/my-account/goose/config.yaml"
cat > "$T/bin/curl" <<'SH'
#!/bin/sh
# mock cloud-me-api (infra-api_cloud-me-api): GET <base>/repos/cloud-me/file?path=<p> -> 200 text/plain;
# the bearer must arrive via -K - (stdin), never argv. The mesh host is down; only the c3-pvt base answers.
cfg="$(cat)"; out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; -K) ;; -*) ;; *) url="$1" ;; esac; shift; done
case "$cfg" in *"Bearer TESTTOKEN"*) ;; *) exit 22 ;; esac
case "$cfg" in *"Bearer TESTTOKEN"*"Accept: text/plain"*) ;; *) exit 22 ;; esac
case "$url" in
  https://mock.invalid/api/repos/cloud-me/file?path=*|https://c3-pvt.diegonmarcos.com/cloud-me-api/me/repos/cloud-me/file?path=*)
    printf 'API-SECRET-VALUE-222 %s\n' "${url#*?path=}" > "$out" ;;
  *) exit 22 ;;
esac
SH
chmod +x "$T/bin/curl"
sec() { PATH="$T/bin:$PATH" MY_ACCOUNT_HOME="$H2" MY_ACCOUNT_ME_DIR="${MEDIR:-/nonexistent}" MY_ACCOUNT_ME_API=https://mock.invalid/api \
        MY_ACCOUNT_ME_TOKEN="${TOK-TESTTOKEN}" sh "$D/my-account" --profile desktop --app goose "$@" 2>&1; }
H2="$T/home2"; mkdir -p "$H2"
MEDIR="$ME" sec | grep -q 'source: cloud-me clone' && ok || no "dry-run does not name the local clone"
MEDIR="$ME" sec | grep -q 'LOCAL-SECRET' && no "dry-run printed a secret value" || ok
[ -e "$H2/.config/goose/config.yaml" ] && no "dry-run wrote a secret" || ok
MEDIR="$ME" sec --apply | grep -q 'SECRET-VALUE' && no "apply printed a secret value" || ok
grep -q LOCAL-SECRET-VALUE-111 "$H2/.config/goose/config.yaml" && ok || no "local clone not used"
[ "$(stat -c %a "$H2/.config/goose/config.yaml")" = 600 ] && ok || no "secret not 0600"
rm -f "$H2/.config/goose/config.yaml"
MEDIR="" sec | grep -q 'source: cloud-me api' && ok || no "dry-run does not name the api"
MEDIR="" sec --apply | grep -q 'SECRET-VALUE' && no "api apply printed a secret value" || ok
grep -q 'API-SECRET-VALUE-222 my-account/goose/config.yaml' "$H2/.config/goose/config.yaml" && ok || no "api fallback not used"
rm -f "$H2/.config/goose/config.yaml"
TOK="" MEDIR="" HOME="$T/nohome" sec | grep -q 'UNRESOLVED' && ok || no "unresolved secret not reported"
# default bases (no MY_ACCOUNT_ME_API): mesh is tried first, c3-pvt answers; a GitHub token is never the bearer
rm -f "$H2/.config/goose/config.yaml"
PATH="$T/bin:$PATH" MY_ACCOUNT_HOME="$H2" MY_ACCOUNT_ME_DIR=/nonexistent MY_ACCOUNT_ME_TOKEN=TESTTOKEN env -u MY_ACCOUNT_ME_API \
  sh "$D/my-account" --profile desktop --app goose --apply >/dev/null 2>&1
grep -q 'API-SECRET-VALUE-222 my-account/goose/config.yaml' "$H2/.config/goose/config.yaml" && ok || no "default mesh-then-c3-pvt bases not used"
rm -f "$H2/.config/goose/config.yaml"
GITHUB_TOKEN=TESTTOKEN TOK="" MEDIR="" HOME="$T/nohome" sec | grep -q 'UNRESOLVED' && ok || no "GITHUB_TOKEN was used as the cloud-me-api bearer"
TOK=wrong MEDIR="" sec --apply | grep -q 'fetch failed' && ok || no "bad token not reported"
[ -e "$H2/.config/goose/config.yaml" ] && no "failed fetch left a file" || ok

printf '\nmy-account tests: %s ok, %s failed\n' "$pass" "$failn"
[ "$failn" = 0 ]
