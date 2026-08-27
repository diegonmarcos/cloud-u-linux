# ---------------------------------------------------------------------------
# Sandbox execution — bwrap isolation (converted from flake.nix)
# ---------------------------------------------------------------------------

run_sandbox() {
    # Find bwrap
    _rs_bwrap=$(find_bin bwrap) || _rs_bwrap=""

    if [ -z "$_rs_bwrap" ]; then
        if command -v nix-shell >/dev/null 2>&1; then
            log "sandbox: bwrap not found, using nix-shell -p bubblewrap"
            _rs_bwrap="nix-shell -p bubblewrap --run bwrap"
        else
            log "FATAL: bwrap not found and nix-shell unavailable"
            printf 'bubblewrap (bwrap) is required for sandbox mode.\n'
            printf 'Install it or use --mirror / native mode instead.\n'
            exit 1
        fi
    fi

    # Ensure claude is installed
    ensure_npm_prefix
    _rs_claude=$(find_bin claude) || _rs_claude=""
    if [ -z "$_rs_claude" ]; then
        log "sandbox: claude not installed, running deps_solve first..."
        deps_solve || true
        _rs_claude=$(find_bin claude) || _rs_claude=""
        if [ -z "$_rs_claude" ]; then
            log "FATAL: cannot install claude for sandbox mode"
            exit 1
        fi
    fi

    # Find SSL cert
    _rs_ssl=$(find_ssl_cert) || _rs_ssl=""

    # Create isolated tmp
    _rs_tmp=$(mktemp -d)
    trap 'rm -rf "$_rs_tmp"' EXIT INT TERM

    log_only "sandbox: building bwrap command"

    # Build bwrap args
    set -- \
        "$_rs_bwrap" \
        --die-with-parent \
        --new-session \
        --unshare-pid

    # Read-only system mounts (skip missing paths)
    _rs_old_ifs="$IFS"
    IFS='
'
    for _rs_mount in $SANDBOX_RO_MOUNTS; do
        _rs_mount=$(printf '%s' "$_rs_mount" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        [ -z "$_rs_mount" ] && continue
        if [ -e "$_rs_mount" ]; then
            set -- "$@" --ro-bind "$_rs_mount" "$_rs_mount"
        fi
    done

    # Read-write user mounts (create if missing, skip if parent missing)
    for _rs_mount in $SANDBOX_RW_MOUNTS; do
        _rs_mount=$(printf '%s' "$_rs_mount" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        [ -z "$_rs_mount" ] && continue
        mkdir -p "$_rs_mount" 2>/dev/null || true
        if [ -d "$_rs_mount" ]; then
            set -- "$@" --bind "$_rs_mount" "$_rs_mount"
        fi
    done
    IFS="$_rs_old_ifs"

    # Proc and dev
    set -- "$@" \
        --proc /proc \
        --dev /dev \
        --tmpfs /tmp \
        --bind "$_rs_tmp" /tmp

    # Environment
    set -- "$@" \
        --setenv HOME "$HOME" \
        --setenv USER "${USER:-$(id -un)}" \
        --setenv TERM "${TERM:-xterm-256color}" \
        --setenv LANG "${LANG:-C.UTF-8}" \
        --setenv CLAUDE_SANDBOXED 1 \
        --setenv NPM_CONFIG_PREFIX "${HOME}/.npm-global" \
        --setenv PATH "${HOME}/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:/nix/var/nix/profiles/default/bin"

    if [ -n "$_rs_ssl" ]; then
        set -- "$@" \
            --setenv SSL_CERT_FILE "$_rs_ssl" \
            --setenv NODE_EXTRA_CA_CERTS "$_rs_ssl"
    fi

    # Execute claude inside sandbox
    set -- "$@" -- "$_rs_claude" "$@"

    log_only "sandbox: exec bwrap"
    exec "$@"
}
