# ---------------------------------------------------------------------------
# Native execution — tiered fallback chain
# ---------------------------------------------------------------------------

run_native() {
    # Always ensure shells are available first
    shell_solve

    # --- Tier 1: native claude binary ---
    _rn_bin=$(find_bin claude) || _rn_bin=""

    if [ -n "$_rn_bin" ]; then
        log_only "tier1: exec $_rn_bin"
        exec "$_rn_bin" "$@"
    fi

    # --- Tier 1.5: install deps, then retry ---
    if deps_solve; then
        _rn_bin=$(find_bin claude) || _rn_bin=""
        if [ -n "$_rn_bin" ]; then
            log_only "tier1.5: exec $_rn_bin (after deps_solve)"
            exec "$_rn_bin" "$@"
        fi
    fi

    # --- Tier 2: npx ---
    _rn_npx=$(find_bin npx) || _rn_npx=""

    if [ -n "$_rn_npx" ]; then
        log_only "tier2: exec $_rn_npx --yes $PKG"
        exec "$_rn_npx" --yes "$PKG" "$@"
    fi

    # --- Tier 3: nix-shell fallback ---
    if command -v nix-shell >/dev/null 2>&1; then
        log "tier3: nix-shell -p nodejs (npx fallback)"
        exec nix-shell -p nodejs --run "npx --yes $PKG $*"
    fi

    log "FATAL: no way to run claude — install node >=18 and npm"
    exit 1
}

# Mirror mode — direct exec with full home access
run_mirror() {
    shell_solve

    _rm_bin=$(find_bin claude) || _rm_bin=""

    if [ -n "$_rm_bin" ]; then
        log_only "mirror: exec $_rm_bin"
        exec "$_rm_bin" "$@"
    fi

    # Fall through to native tiers if not found directly
    run_native "$@"
}
