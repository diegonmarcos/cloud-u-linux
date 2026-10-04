# ---------------------------------------------------------------------------
# Browser — Carbonyl TTY browser for OAuth flows
# ---------------------------------------------------------------------------

# Install carbonyl if not found (mirrors deps_solve pattern)
carbonyl_solve() {
    log "carbonyl_solve: carbonyl not found, attempting install..."

    _cs_npm=$(find_bin npm) || _cs_npm=""
    _cs_node=$(find_bin node) || _cs_node=""

    if [ -z "$_cs_node" ]; then
        log "carbonyl_solve: node not found"
        return 1
    fi

    _cs_major=$(node_major "$_cs_node") || _cs_major=0
    if [ "$_cs_major" -lt 18 ]; then
        log "carbonyl_solve: node $("$_cs_node" --version) < 18 required"
        return 1
    fi

    if [ -z "$_cs_npm" ]; then
        log "carbonyl_solve: npm not found"
        return 1
    fi

    log "carbonyl_solve: found npm=$_cs_npm node=$_cs_node"
    ensure_npm_prefix

    if "$_cs_npm" install -g carbonyl >/dev/null 2>&1; then
        log "carbonyl_solve: npm install -g carbonyl succeeded"
        return 0
    fi

    log "carbonyl_solve: npm install -g failed, trying sudo..."
    if sudo -n "$_cs_npm" install -g carbonyl >/dev/null 2>&1; then
        log "carbonyl_solve: sudo npm install -g carbonyl succeeded"
        return 0
    fi

    log "carbonyl_solve: automatic install failed"
    return 1
}

run_browser() {
    _rb_url="${1:-}"

    if [ -z "$_rb_url" ]; then
        printf 'Usage: claude.sh browser <URL>\n'
        exit 1
    fi

    # Tier 1: native carbonyl binary
    _rb_bin=$(find_bin carbonyl) || _rb_bin=""
    if [ -n "$_rb_bin" ]; then
        log_only "browser: exec $_rb_bin $_rb_url"
        exec "$_rb_bin" "$_rb_url"
    fi

    # Tier 1.5: install carbonyl, then retry
    if carbonyl_solve; then
        _rb_bin=$(find_bin carbonyl) || _rb_bin=""
        if [ -n "$_rb_bin" ]; then
            log_only "browser: exec $_rb_bin (after carbonyl_solve)"
            exec "$_rb_bin" "$_rb_url"
        fi
    fi

    # Tier 2: npx carbonyl
    _rb_npx=$(find_bin npx) || _rb_npx=""
    if [ -n "$_rb_npx" ]; then
        log "browser: using npx carbonyl"
        exec "$_rb_npx" --yes carbonyl "$_rb_url"
    fi

    # Tier 3: docker/podman container
    _rb_docker=$(find_bin docker) || _rb_docker=""
    _rb_podman=$(find_bin podman) || _rb_podman=""
    _rb_container=""

    if [ -n "$_rb_docker" ]; then
        _rb_container="$_rb_docker"
    elif [ -n "$_rb_podman" ]; then
        _rb_container="$_rb_podman"
    fi

    if [ -n "$_rb_container" ]; then
        log "browser: using $_rb_container for carbonyl"
        exec "$_rb_container" run -it --rm "$CARBONYL_IMAGE" "$_rb_url"
    fi

    # Tier 4: nix-shell
    if command -v nix-shell >/dev/null 2>&1; then
        log "browser: using nix-shell for carbonyl"
        exec nix-shell -p carbonyl --run "carbonyl '$_rb_url'"
    fi

    log "FATAL: no way to run carbonyl browser"
    printf 'Carbonyl not found. Install via: npm install -g carbonyl\n'
    printf 'Or use: docker run -it --rm %s <URL>\n' "$CARBONYL_IMAGE"
    exit 1
}
