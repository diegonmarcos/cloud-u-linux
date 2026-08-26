# ---------------------------------------------------------------------------
# Utilities — binary discovery, version checks, npm setup
# ---------------------------------------------------------------------------

# Find first matching binary across home-local + system + PATH
find_bin() {
    _fb_name="$1"
    for _fb_p in \
        "${HOME}/.npm-global/bin/${_fb_name}" \
        "${HOME}/node_modules/.bin/${_fb_name}" \
        "${HOME}/.local/bin/${_fb_name}" \
        "${HOME}/.nix-profile/bin/${_fb_name}" \
        "/usr/local/bin/${_fb_name}" \
        "/usr/bin/${_fb_name}" \
        "/bin/${_fb_name}"; do
        if [ -x "$_fb_p" ] 2>/dev/null; then
            printf '%s' "$_fb_p"
            return 0
        fi
    done
    if command -v "$_fb_name" >/dev/null 2>&1; then
        command -v "$_fb_name"
        return 0
    fi
    return 1
}

# Return all found paths for a binary (for status/drift reporting)
find_all_bins() {
    _fab_name="$1"
    for _fab_p in \
        "${HOME}/.npm-global/bin/${_fab_name}" \
        "${HOME}/node_modules/.bin/${_fab_name}" \
        "${HOME}/.local/bin/${_fab_name}" \
        "${HOME}/.nix-profile/bin/${_fab_name}" \
        "/usr/local/bin/${_fab_name}" \
        "/usr/bin/${_fab_name}" \
        "/bin/${_fab_name}"; do
        if [ -x "$_fab_p" ] 2>/dev/null; then
            printf '%s\n' "$_fab_p"
        fi
    done
    if command -v "$_fab_name" >/dev/null 2>&1; then
        _fab_cmd=$(command -v "$_fab_name")
        printf '%s\n' "$_fab_cmd"
    fi
}

# Get major version number from node's "vX.Y.Z" output
node_major() {
    _nm_ver=$("$1" --version 2>/dev/null) || return 1
    _nm_ver=${_nm_ver#v}
    _nm_ver=${_nm_ver%%.*}
    printf '%s' "$_nm_ver"
}

# Ensure NPM_CONFIG_PREFIX is set for --global installs
ensure_npm_prefix() {
    NPM_CONFIG_PREFIX="${HOME}/.npm-global"
    export NPM_CONFIG_PREFIX
    mkdir -p "$NPM_CONFIG_PREFIX"

    # Add to PATH if not already present
    case ":${PATH}:" in
        *":${NPM_CONFIG_PREFIX}/bin:"*) ;;
        *) PATH="${NPM_CONFIG_PREFIX}/bin:${PATH}"; export PATH ;;
    esac
}

# Detect if running in a TTY without graphical display
is_headless_tty() {
    [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]
}

# Find the SSL cert file for this distro
find_ssl_cert() {
    _fsc_old_ifs="$IFS"
    IFS='
'
    for _fsc_p in $SSL_CERT_PATHS; do
        _fsc_p=$(printf '%s' "$_fsc_p" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        [ -z "$_fsc_p" ] && continue
        if [ -f "$_fsc_p" ]; then
            IFS="$_fsc_old_ifs"
            printf '%s' "$_fsc_p"
            return 0
        fi
    done
    IFS="$_fsc_old_ifs"
    return 1
}
