# ---------------------------------------------------------------------------
# Main — CLI parser and dispatch
# ---------------------------------------------------------------------------

# Goose launcher — find and run goose
run_goose() {
    local goose_bin=""

    # Search order: PATH, cargo, pipx
    if command -v goose >/dev/null 2>&1; then
        goose_bin="goose"
    elif [ -x "${HOME}/.cargo/bin/goose" ]; then
        goose_bin="${HOME}/.cargo/bin/goose"
    elif command -v pipx >/dev/null 2>&1 && pipx list 2>/dev/null | grep -q goose; then
        goose_bin="goose"
    fi

    if [ -z "$goose_bin" ]; then
        log_msg "ERROR" "goose not found — install via: cargo install goose-cli / pipx install goose-ai"
        printf 'goose not found.\n\n'
        printf 'Install options:\n'
        printf '  cargo install goose-cli\n'
        printf '  pipx install goose-ai\n'
        printf '  nix-shell -p goose\n'
        exit 1
    fi

    log_msg "INFO" "Launching goose: $goose_bin $*"
    exec "$goose_bin" "$@"
}

case "${1:-}" in
    # ── AI Agents ──
    goose)
        shift
        run_goose "$@"
        ;;

    # ── Commands ──
    -h|--help)
        cmd_help
        ;;
    -V|--version)
        printf 'ai-cli %s\n' "$AI_CLI_VERSION"
        ;;
    status)
        cmd_status
        ;;

    # ── Claude Modes ──
    -s|--sandbox)
        shift
        run_sandbox "$@"
        ;;
    -m|--mirror)
        shift
        run_mirror "$@"
        ;;
    docker)
        shift
        run_container docker "$@"
        ;;
    podman)
        shift
        run_container podman "$@"
        ;;
    browser)
        shift
        run_browser "$@"
        ;;
    --)
        shift
        run_native "$@"
        ;;

    # ── Default: Claude native ──
    *)
        run_native "$@"
        ;;
esac
