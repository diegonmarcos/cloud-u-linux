# ---------------------------------------------------------------------------
# Dependency resolver — install claude + shells if not found
# ---------------------------------------------------------------------------

# Detect package manager
_detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        printf 'apt'
    elif command -v dnf >/dev/null 2>&1; then
        printf 'dnf'
    elif command -v yum >/dev/null 2>&1; then
        printf 'yum'
    elif command -v pacman >/dev/null 2>&1; then
        printf 'pacman'
    elif command -v apk >/dev/null 2>&1; then
        printf 'apk'
    elif command -v zypper >/dev/null 2>&1; then
        printf 'zypper'
    else
        printf 'none'
    fi
}

# Install a system package by name (tries sudo, skips on failure)
_pkg_install() {
    _pi_pkg="$1"
    _pi_mgr=$(_detect_pkg_manager)

    case "$_pi_mgr" in
        apt)    sudo -n apt-get install -y "$_pi_pkg" >/dev/null 2>&1 ;;
        dnf)    sudo -n dnf install -y "$_pi_pkg" >/dev/null 2>&1 ;;
        yum)    sudo -n yum install -y "$_pi_pkg" >/dev/null 2>&1 ;;
        pacman) sudo -n pacman -S --noconfirm "$_pi_pkg" >/dev/null 2>&1 ;;
        apk)    sudo -n apk add "$_pi_pkg" >/dev/null 2>&1 ;;
        zypper) sudo -n zypper install -y "$_pi_pkg" >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

# Ensure bash and fish shells are available — Claude needs a working shell
shell_solve() {
    # --- bash ---
    if ! command -v bash >/dev/null 2>&1; then
        log "shell_solve: bash not found, installing..."
        if _pkg_install bash; then
            log "shell_solve: bash installed via package manager"
        elif command -v nix-shell >/dev/null 2>&1; then
            log "shell_solve: bash available via nix (not persistent)"
        else
            log "WARNING: bash not found and cannot install"
        fi
    else
        log_only "shell_solve: bash OK ($(command -v bash))"
    fi

    # --- fish ---
    if ! command -v fish >/dev/null 2>&1; then
        log "shell_solve: fish not found, installing..."
        if _pkg_install fish; then
            log "shell_solve: fish installed via package manager"
        elif command -v nix-shell >/dev/null 2>&1; then
            log "shell_solve: fish available via nix (not persistent)"
        else
            log "WARNING: fish not found and cannot install"
        fi
    else
        log_only "shell_solve: fish OK ($(command -v fish))"
    fi
}

# Install claude if not found
deps_solve() {
    log "deps_solve: claude not found natively, attempting install..."

    _ds_npm=$(find_bin npm) || _ds_npm=""
    _ds_node=$(find_bin node) || _ds_node=""

    if [ -z "$_ds_node" ]; then
        log "deps_solve: node not found anywhere"
        return 1
    fi

    _ds_major=$(node_major "$_ds_node") || _ds_major=0
    if [ "$_ds_major" -lt 18 ]; then
        log "deps_solve: node $("$_ds_node" --version) < 18.0.0 required"
        return 1
    fi

    if [ -z "$_ds_npm" ]; then
        log "deps_solve: npm not found anywhere"
        return 1
    fi

    log "deps_solve: found npm=$_ds_npm node=$_ds_node"
    ensure_npm_prefix

    # Try user-level install
    if "$_ds_npm" install -g "$PKG" >/dev/null 2>&1; then
        log "deps_solve: npm install -g succeeded"
        return 0
    fi

    # Try sudo
    log "deps_solve: npm install -g failed (permissions?), trying sudo..."
    if sudo -n "$_ds_npm" install -g "$PKG" >/dev/null 2>&1; then
        log "deps_solve: sudo npm install -g succeeded"
        return 0
    fi

    # Manual fallback
    printf '\n'
    log "deps_solve: automatic install failed"
    printf '  Run manually:  sudo %s install -g %s\n\n' "$_ds_npm" "$PKG"
    printf '  Continue with npx instead? [y/N] '
    read -r _ds_answer </dev/tty
    case "$_ds_answer" in
        [yY]|[yY][eE][sS]) return 1 ;;
        *) log "deps_solve: user declined npx fallback"; exit 1 ;;
    esac
}
