#!/bin/sh
# ============================================================================
# unix-mcp — Build Script
# ============================================================================
# MCP server exposing nix/unix tools via bash
#
# Usage:
#   ./build.sh              # Install deps + validate (default)
#   ./build.sh deps         # Install npm dependencies
#   ./build.sh start        # Start MCP server (stdio)
#   ./build.sh check        # TypeScript type check
#   ./build.sh clean        # Remove node_modules
#   ./build.sh --help       # Show help
# ============================================================================

set -eu

# Auto-confirm guardrail prompts
export BUILDSH_GUARDRAIL=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
LOG_FILE="$SCRIPT_DIR/build.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Logging
log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
log_info()    { log "INFO: $*";    printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
log_success() { log "SUCCESS: $*"; printf "${GREEN}[OK]${NC} %s\n" "$*"; }
log_warn()    { log "WARN: $*";    printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
log_error()   { log "ERROR: $*";   printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
log_header()  { log "=== $* ===";  printf "\n${BOLD}${CYAN}=== %s ===${NC}\n\n" "$*"; }

# ============================================================================
# COMMANDS
# ============================================================================

cmd_deps() {
    log_header "Installing Dependencies"

    if ! command -v node >/dev/null 2>&1; then
        log_error "Node.js not found"
        return 1
    fi

    if ! command -v npm >/dev/null 2>&1; then
        log_error "npm not found"
        return 1
    fi

    cd "$SRC_DIR"
    log_info "npm install..."
    npm install --no-audit --no-fund 2>&1 | tee -a "$LOG_FILE"
    log_success "Dependencies installed"
}

cmd_check() {
    log_header "Type Check"
    cd "$SRC_DIR"

    if [ ! -d "node_modules" ]; then
        log_info "No node_modules — installing deps first..."
        cmd_deps
    fi

    log_info "Running tsc --noEmit..."
    npx tsc --noEmit 2>&1 | tee -a "$LOG_FILE"
    log_success "Type check passed"
}

cmd_start() {
    log_header "Starting unix-mcp"
    cd "$SRC_DIR"

    if [ ! -d "node_modules" ]; then
        log_info "No node_modules — installing deps first..."
        cmd_deps
    fi

    log_info "Starting MCP server (stdio)..."
    exec npx tsx index.ts
}

MCP_HTTP_PORT="${MCP_HTTP_PORT:-3200}"
PID_FILE="$SCRIPT_DIR/.unix-mcp.pid"

cmd_serve() {
    log_header "Starting unix-mcp HTTP daemon"
    cd "$SRC_DIR"

    if [ ! -d "node_modules" ]; then
        log_info "No node_modules — installing deps first..."
        cmd_deps
    fi

    # Kill existing if running
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        log_info "Stopping existing daemon (pid $(cat "$PID_FILE"))..."
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        sleep 1
    fi

    log_info "Starting HTTP daemon on 127.0.0.1:${MCP_HTTP_PORT}/mcp..."
    MCP_HTTP=1 MCP_HTTP_PORT="$MCP_HTTP_PORT" nohup npx tsx index.ts \
        >> "$LOG_FILE" 2>&1 &
    echo "$!" > "$PID_FILE"
    log_success "Daemon started (pid $!, port ${MCP_HTTP_PORT})"
}

cmd_stop() {
    log_header "Stopping unix-mcp daemon"
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        kill "$(cat "$PID_FILE")"
        rm -f "$PID_FILE"
        log_success "Daemon stopped"
    else
        log_warn "No running daemon found"
        rm -f "$PID_FILE"
    fi
}

cmd_restart() {
    cmd_stop
    cmd_serve
}

cmd_build() {
    log_header "Build (deps + check)"
    cmd_deps
    cmd_check
    log_success "Build complete"
}

cmd_clean() {
    log_header "Cleaning"
    rm -rf "$SRC_DIR/node_modules" "$SRC_DIR/dist"
    log_success "Cleaned node_modules and dist"
}

cmd_status() {
    log_header "Status"
    printf "${BOLD}Node:${NC} %s\n" "$(node --version 2>/dev/null || echo 'not found')"
    printf "${BOLD}npm:${NC} %s\n" "$(npm --version 2>/dev/null || echo 'not found')"
    printf "${BOLD}tsx:${NC} %s\n" "$(npx tsx --version 2>/dev/null || echo 'not found')"
    printf "${BOLD}Source:${NC} %s\n" "$SRC_DIR"
    if [ -d "$SRC_DIR/node_modules" ]; then
        printf "${BOLD}Deps:${NC} ${GREEN}installed${NC}\n"
    else
        printf "${BOLD}Deps:${NC} ${RED}missing${NC} (run: ./build.sh deps)\n"
    fi
    printf "\n${BOLD}Tools:${NC}\n"
    for f in "$SRC_DIR"/tools/*.ts; do
        name=$(basename "$f" .ts)
        count=$(grep -c 'server.tool(' "$f" 2>/dev/null || echo 0)
        printf "  %-12s %s tools\n" "$name" "$count"
    done
}

# ============================================================================
# HELP
# ============================================================================

show_help() {
    cat << EOF
${BOLD}unix-mcp — MCP server for nix/unix tools${NC}

${YELLOW}USAGE:${NC}
    ./build.sh              Build (deps + check, default)
    ./build.sh <command>    Run command

${YELLOW}COMMANDS:${NC}
    deps        Install npm dependencies
    build       Install deps + type check (default)
    check       TypeScript type check only
    start       Start MCP server (stdio transport)
    serve       Start persistent HTTP daemon (127.0.0.1:3200/mcp)
    stop        Stop HTTP daemon
    restart     Restart HTTP daemon
    status      Show project status
    clean       Remove node_modules

${YELLOW}MCP CONFIG:${NC}
    Add to ~/.mcp.json or .claude/mcp.json:
    {
      "mcpServers": {
        "unix": {
          "command": "npx",
          "args": ["tsx", "${SRC_DIR}/index.ts"]
        }
      }
    }
EOF
}

# ============================================================================
# MAIN
# ============================================================================

log "========== Build script started =========="

case "${1:-build}" in
    -h|--help|help) show_help ;;
    deps)    cmd_deps ;;
    build)   cmd_build ;;
    check)   cmd_check ;;
    start)   cmd_start ;;
    serve)   cmd_serve ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    status)  cmd_status ;;
    clean)   cmd_clean ;;
    *)       log_error "Unknown: $1"; show_help; exit 1 ;;
esac

log "========== Build script finished =========="
