# ---------------------------------------------------------------------------
# Container execution — docker or podman
# ---------------------------------------------------------------------------

run_container() {
    _rc_engine="$1"
    shift

    _rc_bin=$(find_bin "$_rc_engine") || _rc_bin=""

    # Fallback: try nix-shell for the engine
    if [ -z "$_rc_bin" ]; then
        if command -v nix-shell >/dev/null 2>&1; then
            log "container: $_rc_engine not found, trying nix-shell -p $_rc_engine"
            _rc_bin="nix-shell -p $_rc_engine --run $_rc_engine"
        else
            log "FATAL: $_rc_engine not found and nix-shell unavailable"
            printf '%s not found. Install it or use native mode.\n' "$_rc_engine"
            exit 1
        fi
    fi

    log "container: using $_rc_bin"

    # Resolve real paths for mounts
    _rc_claude_dir=""
    if [ -d "${HOME}/.claude" ]; then
        _rc_claude_dir=$(cd "${HOME}/.claude" && pwd -P)
    fi

    _rc_claude_json="${HOME}/.claude.json"
    _rc_workdir=$(pwd -P)

    if [ -z "$_rc_claude_dir" ]; then
        log "WARNING: ~/.claude not found, creating it"
        mkdir -p "${HOME}/.claude"
        _rc_claude_dir="${HOME}/.claude"
    fi

    log "container: mounts: claude=$_rc_claude_dir workdir=$_rc_workdir"

    # Build run command
    _rc_vol_args="-v ${_rc_claude_dir}:/home/node/.claude -v ${_rc_workdir}:/workspace"

    if [ -f "$_rc_claude_json" ]; then
        _rc_vol_args="$_rc_vol_args -v ${_rc_claude_json}:/home/node/.claude.json:ro"
    else
        log "WARNING: ~/.claude.json not found, container may prompt for login"
    fi

    log_only "container: exec $_rc_engine run -it --rm"
    # shellcheck disable=SC2086
    exec $_rc_bin run -it --rm \
        $_rc_vol_args \
        -w /workspace \
        -e "CLAUDE_CONFIG_DIR=/home/node/.claude" \
        "$CLAUDE_IMAGE" \
        sh -c "npm install -g ${PKG} >/dev/null 2>&1 && claude $*"
}
