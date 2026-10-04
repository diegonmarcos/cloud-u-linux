#!/usr/bin/env bash
# my-browser-qute — build engine
#
# This project ships no compiled artifact — it's a pure NixOS / home-manager
# config layer on top of the qutebrowser source vendored in src/browser/. The "build" is a JSON-schema
# check + a Nix flake check; "install" is a noop (the home-manager module
# does the real work when consumed by the user's home flake).
#
# Usage:
#   ./build.sh check      # validate JSON syntax + Nix flake evaluation
#   ./build.sh lint-json  # JSON syntax only (fast)
#   ./build.sh print-config  # show resolved settings/search/keybindings/quickmarks
#   ./build.sh diff       # compare current vs deployed state in ~/.config/my-browser-qute
#   (default = check)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
LOG="$ROOT/build.log"
CONFIG="$ROOT/build.json"

get() { node -e "const c=require('$CONFIG'); const v='$1'.split('.').reduce((o,k)=>o&&o[k],c); process.stdout.write(String(v||''))"; }
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { printf '\033[0;31m[%s] ERROR: %s\033[0m\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

CONFIGS_DIR="$ROOT/$(get paths.configs)"
[ -d "$CONFIGS_DIR" ] || die "configs dir missing: $CONFIGS_DIR"

cmd="${1:-check}"

case "$cmd" in
  lint-json)
    log "validating JSON files in $CONFIGS_DIR"
    rc=0
    for f in "$CONFIGS_DIR"/*.json; do
      if node -e "JSON.parse(require('fs').readFileSync('$f','utf8'))" 2>/dev/null; then
        log "  ok  $(basename "$f")"
      else
        printf '\033[0;31m  bad %s\033[0m\n' "$(basename "$f")"
        rc=1
      fi
    done
    [ "$rc" -eq 0 ] || die "JSON validation failed"
    ;;

  dashboard)
    # Regenerate the committed start-page dashboard (dist/qute-bookmarks.html) from the
    # bookmark folder SoT + cloud-data (build-flakes_desktop.json). The cloud folders
    # (source:"cloud:*") resolve here — without this step the committed dashboard goes
    # stale and the cloud service URLs (*.diegonmarcos.com + api/app) go missing.
    log "regenerating dashboard (bookmarks + cloud-data services)"
    bash "$SRC/dashboard/gen-dashboard.sh"
    ;;

  check)
    "$0" lint-json
    "$0" dashboard
    log "evaluating flake (--no-build)"
    cd "$SRC"
    nix flake check --no-build --no-write-lock-file 2>&1 | tail -10
    log "ok"
    ;;

  print-config)
    log "resolved settings/search/keybindings/quickmarks (post _description strip)"
    for slot in settings search-engines keybindings bookmarks; do
      f="$CONFIGS_DIR/qute-${slot}.json"
      [ -f "$f" ] || continue
      printf '\n=== %s ===\n' "$(basename "$f")"
      node -e "
        const c=require('$f');
        const strip = v => Array.isArray(v) ? v.map(strip)
          : (v && typeof v === 'object')
            ? Object.fromEntries(Object.entries(v).filter(([k])=>!k.startsWith('_description')&&!k.startsWith('_comment')).map(([k,vv])=>[k,strip(vv)]))
            : v;
        console.log(JSON.stringify(strip(c), null, 2));
      "
    done
    ;;

  diff)
    log "diff: src/2_configs vs ~/.config/my-browser-qute/config.py (rough)"
    if [ -f "$HOME/.config/my-browser-qute/config.py" ]; then
      log "config.py size: $(wc -l < "$HOME/.config/my-browser-qute/config.py") lines"
    else
      log "no ~/.config/my-browser-qute/config.py — has home-manager switched yet?"
    fi
    "$0" print-config | tail -50
    ;;

  fork)
    # Build the package (vendored qutebrowser source + the native chrome bar).
    # Proves the patch series applies + the package builds. This is what
    # packages.x86_64-linux.my-browser-qute evaluates to.
    log "nix build .#my-browser-qute"
    cd "$SRC"
    nix build .#my-browser-qute --no-write-lock-file -o "$ROOT/.result-fork"
    log "→ $(readlink -f "$ROOT/.result-fork")/bin/my-browser-qute"
    ;;

  fork-release)
    # Package the FORK as a PORTABLE single-file binary via `nix bundle`
    # (self-extracting; QtWebEngine included, ~640MB). gzip it into dist/ for
    # upload. This is what "deploy the fork in our releases" produces.
    enabled="$(node -e "const c=require('$CONFIG'); process.stdout.write(String(c.release.fork.enabled))")"
    [ "$enabled" = "true" ] || { log "fork-release: enabled=false — skip"; exit 0; }
    asset="$(node -e "const c=require('$CONFIG'); process.stdout.write(c.release.fork.asset_name)")"
    cd "$SRC"
    log "nix bundle .#my-browser-qute (portable binary)"
    nix bundle .#my-browser-qute --no-write-lock-file -o "$ROOT/.result-fork-bundle"
    mkdir -p "$ROOT/dist"
    log "gzip → dist/$asset"
    gzip -c -n "$(readlink -f "$ROOT/.result-fork-bundle")" > "$ROOT/dist/$asset"
    log "→ $ROOT/dist/$asset ($(du -h "$ROOT/dist/$asset" | cut -f1))"
    ;;

  fork-gh-release)
    # Publish the portable fork binary to its OWN rolling GitHub Release tag.
    enabled="$(node -e "const c=require('$CONFIG'); process.stdout.write(String(c.release.fork.enabled))")"
    [ "$enabled" = "true" ] || { log "fork-gh-release: enabled=false — skip"; exit 0; }
    tag="$(node -e "const c=require('$CONFIG'); process.stdout.write(c.release.fork.rolling_tag)")"
    asset="$(node -e "const c=require('$CONFIG'); process.stdout.write(c.release.fork.asset_name)")"
    dst="$ROOT/dist/$asset"
    [ -f "$dst" ] || die "fork-gh-release: $dst missing — run './build.sh fork-release' first"
    log "fork-gh-release: rolling tag=$tag ← $asset"
    if ! gh release view "$tag" >/dev/null 2>&1; then
      gh release create "$tag" --title "my-browser-qute" --target "${GITHUB_SHA:-main}" \
        --notes "Rolling release of my-browser-qute — vendored, rebranded qutebrowser with a native bookmark + plugin chrome bar. Portable self-extracting binary: gunzip then chmod +x and run." --latest
    fi
    gh release upload "$tag" "$dst" --clobber
    log "✓ published fork binary"
    ;;

  release)
    # Build the standalone config bundle (nix/standalone.nix) — independent
    # of the desktop's 37-module home-manager closure. Tarball -> dist/.
    "$0" dashboard
    log "nix build .#standalone"
    cd "$SRC"
    nix build .#standalone --no-write-lock-file -o "$ROOT/.result-standalone"
    mkdir -p "$ROOT/dist"
    asset="$(node -e "const c=require('$CONFIG'); process.stdout.write(c.release.gh_release.asset_name)")"
    tar -C "$ROOT/.result-standalone" -czf "$ROOT/dist/$asset" .
    log "→ $ROOT/dist/$asset ($(du -h "$ROOT/dist/$asset" | cut -f1))"
    ;;

  gh-release)
    # Publish dist/<asset_name> to a rolling GitHub Release tag (--clobber on
    # every push) — same idiom as aa_cloud-nav/ea_cloud-comms step_gh_release.
    enabled="$(node -e "const c=require('$CONFIG'); process.stdout.write(String(c.release.gh_release.enabled))")"
    [ "$enabled" = "true" ] || { log "gh-release: enabled=false — skip"; exit 0; }
    tag="$(node -e "const c=require('$CONFIG'); process.stdout.write(c.release.gh_release.rolling_tag)")"
    asset="$(node -e "const c=require('$CONFIG'); process.stdout.write(c.release.gh_release.asset_name)")"
    dst="$ROOT/dist/$asset"
    [ -f "$dst" ] || die "gh-release: $dst missing — run './build.sh release' first"
    log "gh-release: rolling tag=$tag ← $asset"
    if ! gh release view "$tag" >/dev/null 2>&1; then
      gh release create "$tag" --title "$tag" --target "${GITHUB_SHA:-main}" \
        --notes "Rolling my-browser-qute standalone config release — overwritten on every push touching db_my-browser-qute/." --latest
    fi
    gh release upload "$tag" "$dst" --clobber
    gh release edit "$tag" --latest >/dev/null 2>&1 || true
    log "✓ published"
    ;;

  ghcr-push)
    # Mirror the standalone bundle to GHCR (oras) — matches the repo's
    # all-services-as-GHCR-images pattern. NOT a consumption path:
    # install-standalone / the desktop flake pull from the GitHub Release
    # only (see release.comment in build.json).
    enabled="$(node -e "const c=require('$CONFIG'); process.stdout.write(String(c.release.ghcr.enabled))")"
    [ "$enabled" = "true" ] || { log "ghcr-push: enabled=false — skip"; exit 0; }
    registry="$(node -e "const c=require('$CONFIG'); process.stdout.write(c.release.ghcr.registry)")"
    namespace="$(node -e "const c=require('$CONFIG'); process.stdout.write(c.release.ghcr.namespace)")"
    image="$(node -e "const c=require('$CONFIG'); process.stdout.write(c.release.ghcr.image)")"
    media_type="$(node -e "const c=require('$CONFIG'); process.stdout.write(c.release.ghcr.media_type)")"
    asset="$(node -e "const c=require('$CONFIG'); process.stdout.write(c.release.gh_release.asset_name)")"
    dst="$ROOT/dist/$asset"
    [ -f "$dst" ] || die "ghcr-push: $dst missing — run './build.sh release' first"

    if [ -n "${GITHUB_TOKEN:-}" ]; then
      echo "$GITHUB_TOKEN" | oras login "$registry" -u "${GITHUB_ACTOR:-diegonmarcos}" --password-stdin
    elif command -v gh >/dev/null 2>&1; then
      gh auth token | oras login "$registry" -u "$(gh api user --jq .login)" --password-stdin
    else
      die "ghcr-push: no GHCR credentials (set GITHUB_TOKEN or install gh CLI)"
    fi

    rev="${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
    while IFS= read -r tag; do
      [ -z "$tag" ] && continue
      ref="$registry/$namespace/$image:$tag"
      log "oras push $ref ← $asset (rev ${rev:0:8})"
      ( cd "$ROOT/dist" && oras push "$ref" "$asset:$media_type" \
          --artifact-type "$media_type" \
          --annotation "org.opencontainers.image.revision=$rev" )
    done < <(node -e "const c=require('$CONFIG'); c.release.ghcr.tags.forEach(t=>console.log(t))")
    log "✓ pushed to GHCR"
    ;;

  install-standalone)
    # Pull the latest release + install to ~/.local/opt + symlink launcher.
    # Never touches ~/.config/my-browser-qute (the HM-managed one) — runs
    # isolated via --basedir.
    tag="$(node -e "const c=require('$CONFIG'); process.stdout.write(c.release.gh_release.rolling_tag)")"
    asset="$(node -e "const c=require('$CONFIG'); process.stdout.write(c.release.gh_release.asset_name)")"
    tmp="$(mktemp -d)"
    log "install-standalone: gh release download $tag -p $asset"
    gh release download "$tag" -p "$asset" -D "$tmp" --clobber
    target="$HOME/.local/opt/my-browser-qute-standalone"
    # Extracted files carry the Nix store's read-only mode (444/555) — `rm`
    # needs write on the CONTAINING dir to unlink, not just the file, so a
    # prior install's read-only tree blocks a plain `rm -rf`. chmod first.
    [ -d "$target" ] && chmod -R u+w "$target" 2>/dev/null
    rm -rf "$target"; mkdir -p "$target"
    tar -xzf "$tmp/$asset" -C "$target"
    rm -rf "$tmp"
    mkdir -p "$HOME/.local/bin"
    ln -sf "$target/my-browser-qute-standalone" "$HOME/.local/bin/my-browser-qute-standalone"
    log "✓ installed → $target"
    log "  run: my-browser-qute-standalone   (PATH must include ~/.local/bin)"
    ;;

  *)
    die "Unknown command: $cmd  (use: lint-json | check | dashboard | print-config | diff | fork | fork-release | fork-gh-release | release | gh-release | ghcr-push | install-standalone)"
    ;;
esac
