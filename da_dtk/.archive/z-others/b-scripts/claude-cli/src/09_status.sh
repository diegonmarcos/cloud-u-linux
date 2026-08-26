# ---------------------------------------------------------------------------
# Status — diagnostics and version drift detection
# ---------------------------------------------------------------------------

_status_bin() {
    _sb_label="$1"
    _sb_name="$2"
    printf '\n%s\n' "--- ${_sb_label} ---"
    _sb_bin=$(find_bin "$_sb_name") || _sb_bin=""
    if [ -n "$_sb_bin" ]; then
        printf 'Active:      %s  (%s)\n' "$("$_sb_bin" --version 2>/dev/null || printf 'unknown')" "$_sb_bin"
    else
        printf 'Active:      NOT FOUND\n'
    fi
}

cmd_status() {
    printf '=== claude-launcher v%s ===\n\n' "$CLAUDE_LAUNCHER_VERSION"

    # OS
    if [ -f /etc/os-release ]; then
        _cs_os=$(. /etc/os-release && printf '%s' "$PRETTY_NAME")
        printf 'OS:          %s\n' "$_cs_os"
    else
        printf 'OS:          %s %s\n' "$(uname -s)" "$(uname -r)"
    fi
    printf 'Arch:        %s\n' "$(uname -m)"
    printf 'User:        %s\n' "$(id -un)"

    # Display
    printf '\n%s\n' '--- Display ---'
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        printf 'Server:      Wayland (%s)\n' "$WAYLAND_DISPLAY"
    elif [ -n "${DISPLAY:-}" ]; then
        printf 'Server:      X11 (%s)\n' "$DISPLAY"
    else
        printf 'Server:      TTY (headless)\n'
    fi

    # Node
    printf '\n%s\n' '--- Node.js ---'
    _cs_node=$(find_bin node) || _cs_node=""
    if [ -n "$_cs_node" ]; then
        printf 'Active:      %s  (%s)\n' "$("$_cs_node" --version 2>/dev/null)" "$_cs_node"
        _cs_major=$(node_major "$_cs_node") || _cs_major=0
        if [ "$_cs_major" -lt 18 ]; then
            printf '  WARNING:   node >=18 required (found v%s)\n' "$_cs_major"
        fi
    else
        printf 'Active:      NOT FOUND\n'
    fi
    printf 'All paths:\n'
    find_all_bins node | sort -u | while read -r _cs_p; do
        printf '  %s  (%s)\n' "$("$_cs_p" --version 2>/dev/null)" "$_cs_p"
    done

    # npm
    _status_bin "npm" "npm"
    printf 'All paths:\n'
    find_all_bins npm | sort -u | while read -r _cs_p; do
        printf '  %s  (%s)\n' "$("$_cs_p" --version 2>/dev/null)" "$_cs_p"
    done

    # npx
    _status_bin "npx" "npx"

    # Claude
    printf '\n%s\n' '--- Claude Code ---'
    _cs_claude=$(find_bin claude) || _cs_claude=""
    if [ -n "$_cs_claude" ]; then
        printf 'Active:      %s  (%s)\n' "$("$_cs_claude" --version 2>/dev/null)" "$_cs_claude"
    else
        printf 'Active:      NOT FOUND\n'
    fi
    printf 'All installs:\n'
    find_all_bins claude | sort -u | while read -r _cs_p; do
        _cs_v=$("$_cs_p" --version 2>/dev/null) || _cs_v="unknown"
        printf '  %s  (%s)\n' "$_cs_v" "$_cs_p"
    done

    # Version drift
    _cs_v_npm=""
    _cs_v_nix=""
    if [ -x "${HOME}/.npm-global/bin/claude" ]; then
        _cs_v_npm=$("${HOME}/.npm-global/bin/claude" --version 2>/dev/null) || true
    fi
    if [ -x "${HOME}/.nix-profile/bin/claude" ]; then
        _cs_v_nix=$("${HOME}/.nix-profile/bin/claude" --version 2>/dev/null) || true
    fi
    if [ -n "$_cs_v_npm" ] && [ -n "$_cs_v_nix" ] && [ "$_cs_v_npm" != "$_cs_v_nix" ]; then
        printf '\n  DRIFT:     npm-global=%s  nix-profile=%s\n' "$_cs_v_npm" "$_cs_v_nix"
    fi

    # Bubblewrap
    printf '\n%s\n' '--- Bubblewrap (sandbox) ---'
    _cs_bwrap=$(find_bin bwrap) || _cs_bwrap=""
    if [ -n "$_cs_bwrap" ]; then
        printf 'Available:   yes  (%s)\n' "$_cs_bwrap"
        printf 'Version:     %s\n' "$("$_cs_bwrap" --version 2>/dev/null || printf 'unknown')"
    else
        printf 'Available:   no'
        if command -v nix-shell >/dev/null 2>&1; then
            printf '  (available via nix-shell -p bubblewrap)'
        fi
        printf '\n'
    fi

    # Carbonyl
    printf '\n%s\n' '--- Carbonyl (TTY browser) ---'
    _cs_carbonyl=$(find_bin carbonyl) || _cs_carbonyl=""
    if [ -n "$_cs_carbonyl" ]; then
        printf 'Available:   yes  (%s)\n' "$_cs_carbonyl"
    else
        printf 'Available:   no  (install: npm i -g carbonyl | docker run -it %s)\n' "$CARBONYL_IMAGE"
    fi

    # Container engines
    printf '\n%s\n' '--- Container Engines ---'
    _cs_docker=$(find_bin docker) || _cs_docker=""
    _cs_podman=$(find_bin podman) || _cs_podman=""
    if [ -n "$_cs_docker" ]; then
        printf 'Docker:      %s  (%s)\n' "$("$_cs_docker" --version 2>/dev/null)" "$_cs_docker"
    else
        printf 'Docker:      NOT FOUND'
        if command -v nix-shell >/dev/null 2>&1; then
            printf '  (available via nix-shell)'
        fi
        printf '\n'
    fi
    if [ -n "$_cs_podman" ]; then
        printf 'Podman:      %s  (%s)\n' "$("$_cs_podman" --version 2>/dev/null)" "$_cs_podman"
    else
        printf 'Podman:      NOT FOUND'
        if command -v nix-shell >/dev/null 2>&1; then
            printf '  (available via nix-shell)'
        fi
        printf '\n'
    fi

    # nix-shell
    printf '\n%s\n' '--- nix-shell ---'
    if command -v nix-shell >/dev/null 2>&1; then
        printf 'Available:   yes  (%s)\n' "$(command -v nix-shell)"
    else
        printf 'Available:   no\n'
    fi

    printf '\n'
}
