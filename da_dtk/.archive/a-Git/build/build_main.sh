#!/bin/sh

#=====================================
# MAIN BUILD ORCHESTRATOR
#=====================================
# This script orchestrates builds for all sub-projects
# and replicates the GitHub Actions workflow locally.
#
# Usage: ./1.ops/build_main.sh <action> [options]
#
# POSIX-compliant shell script

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Project root directory (resolve to absolute path of front-Github_io)
# Handle both direct execution and sourced execution
if [ -n "$BASH_SOURCE" ]; then
    SCRIPT_PATH="$BASH_SOURCE"
elif [ -n "$0" ]; then
    SCRIPT_PATH="$0"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Verify PROJECT_ROOT contains expected structure
if [ ! -d "$PROJECT_ROOT/cloud" ] || [ ! -d "$PROJECT_ROOT/linktree" ]; then
    # Fallback: try to find front-Github_io in common locations
    for _try_root in "$HOME/Documents/Git/front-Github_io" "$HOME/front-Github_io" "$(pwd)"; do
        if [ -d "$_try_root/cloud" ] && [ -d "$_try_root/linktree" ]; then
            PROJECT_ROOT="$_try_root"
            break
        fi
    done
fi

# PID file for tracking background processes
PID_FILE="${PROJECT_ROOT}/1.ops/.dev-servers.pid"

# Server URLs mapping (sequential ports starting at 8000)
URL_LANDPAGE="http://localhost:8000/"
URL_LINKTREE="http://localhost:8001/"
URL_CV_WEB="http://localhost:8002/"
URL_MYFEED="http://localhost:8003/"
URL_MYGAMES="http://localhost:8004/"
URL_NEXUS="http://localhost:8005/"
URL_CLOUD="http://localhost:8006/"
URL_FEED="http://localhost:8007/"
URL_OTHERS="http://localhost:8008/"
URL_HEALTH="http://localhost:8009/"
URL_MARKET="http://localhost:8010/"
URL_CENTRALBANK="http://localhost:8011/"
URL_MYMAPS="http://localhost:8012/"
URL_MYPROFILE="http://localhost:8013/"

# Banner function
print_banner() {
    printf "${CYAN}\n"
    printf "=====================================\n"
    printf "  MAIN BUILD ORCHESTRATOR\n"
    printf "=====================================\n"
    printf "${NC}\n"
}

# Get running servers status
get_running_servers() {
    _servers=""
    _count=0

    # Check live-server processes by port
    if pgrep -f "live-server.*8000" >/dev/null 2>&1; then
        _servers="${_servers}  ${GREEN}*${NC} Landpage           ${BLUE}${URL_LANDPAGE}${NC}\n"
        _count=$((_count + 1))
    fi
    if pgrep -f "live-server.*8001" >/dev/null 2>&1; then
        _servers="${_servers}  ${GREEN}*${NC} Linktree           ${BLUE}${URL_LINKTREE}${NC}\n"
        _count=$((_count + 1))
    fi
    if pgrep -f "live-server.*8002" >/dev/null 2>&1; then
        _servers="${_servers}  ${GREEN}*${NC} CV Web             ${BLUE}${URL_CV_WEB}${NC}\n"
        _count=$((_count + 1))
    fi
    if pgrep -f "live-server.*8003" >/dev/null 2>&1; then
        _servers="${_servers}  ${GREEN}*${NC} MyFeed             ${BLUE}${URL_MYFEED}${NC}\n"
        _count=$((_count + 1))
    fi
    if pgrep -f "live-server.*8004" >/dev/null 2>&1; then
        _servers="${_servers}  ${GREEN}*${NC} MyGames          ${BLUE}${URL_MYGAMES}${NC}\n"
        _count=$((_count + 1))
    fi
    if pgrep -f "live-server.*8005" >/dev/null 2>&1; then
        _servers="${_servers}  ${GREEN}*${NC} Nexus              ${BLUE}${URL_NEXUS}${NC}\n"
        _count=$((_count + 1))
    fi
    if pgrep -f "live-server.*8006" >/dev/null 2>&1; then
        _servers="${_servers}  ${GREEN}*${NC} Cloud              ${BLUE}${URL_CLOUD}${NC}\n"
        _count=$((_count + 1))
    fi
    if pgrep -f "live-server.*8007" >/dev/null 2>&1; then
        _servers="${_servers}  ${GREEN}*${NC} Feed Yourself      ${BLUE}${URL_FEED}${NC}\n"
        _count=$((_count + 1))
    fi
    if pgrep -f "live-server.*8008" >/dev/null 2>&1; then
        _servers="${_servers}  ${GREEN}*${NC} Others             ${BLUE}${URL_OTHERS}${NC}\n"
        _count=$((_count + 1))
    fi
    if pgrep -f "live-server.*8009" >/dev/null 2>&1; then
        _servers="${_servers}  ${GREEN}*${NC} Health Tracker     ${BLUE}${URL_HEALTH}${NC}\n"
        _count=$((_count + 1))
    fi
    if pgrep -f "live-server.*8010" >/dev/null 2>&1; then
        _servers="${_servers}  ${GREEN}*${NC} Market Watch       ${BLUE}${URL_MARKET}${NC}\n"
        _count=$((_count + 1))
    fi
    if pgrep -f "live-server.*8011" >/dev/null 2>&1; then
        _servers="${_servers}  ${GREEN}*${NC} Central Bank       ${BLUE}${URL_CENTRALBANK}${NC}\n"
        _count=$((_count + 1))
    fi
    if pgrep -f "next.*dev.*8012" >/dev/null 2>&1 || pgrep -f "mymaps.*next" >/dev/null 2>&1; then
        _servers="${_servers}  ${CYAN}*${NC} MyMaps (Next.js)   ${BLUE}${URL_MYMAPS}${NC}\n"
        _count=$((_count + 1))
    fi
    if pgrep -f "nuxt.*dev.*8013" >/dev/null 2>&1 || pgrep -f "myprofile.*nuxt" >/dev/null 2>&1; then
        _servers="${_servers}  ${CYAN}*${NC} MyProfile (Nuxt)   ${BLUE}${URL_MYPROFILE}${NC}\n"
        _count=$((_count + 1))
    fi
    # Generic live-server check (fallback for other ports)
    if pgrep -f "live-server" >/dev/null 2>&1; then
        _other_live=$(pgrep -f "live-server" 2>/dev/null | while read pid; do
            ps -p "$pid" -o args= 2>/dev/null | grep -vE "80(0[0-9]|1[0-1])" || true
        done)
        if [ -n "$_other_live" ]; then
            _servers="${_servers}  ${GREEN}*${NC} live-server        ${BLUE}(check terminal)${NC}\n"
            _count=$((_count + 1))
        fi
    fi

    # Check Vite dev servers by checking running processes
    # MyFeed - Vite on port 8003
    if pgrep -f "myfeed.*vite" >/dev/null 2>&1 || pgrep -f "vite.*myfeed" >/dev/null 2>&1; then
        _servers="${_servers}  ${CYAN}*${NC} MyFeed (Vite)      ${BLUE}${URL_MYFEED}${NC}\n"
        _count=$((_count + 1))
    fi
    # MyGames - Vite on port 8004
    if pgrep -f "mygames.*vite" >/dev/null 2>&1 || pgrep -f "vite.*mygames" >/dev/null 2>&1; then
        _servers="${_servers}  ${CYAN}*${NC} MyGames (Vite)   ${BLUE}${URL_MYGAMES}${NC}\n"
        _count=$((_count + 1))
    fi
    # Central Bank - Vite on port 8011
    if pgrep -f "central_bank.*vite" >/dev/null 2>&1 || pgrep -f "vite.*central_bank" >/dev/null 2>&1; then
        _servers="${_servers}  ${CYAN}*${NC} Central Bank (Vite) ${BLUE}${URL_CENTRALBANK}${NC}\n"
        _count=$((_count + 1))
    fi
    # Generic Vite check (fallback - only if no specific vite detected above)
    _vite_count=0
    if pgrep -f "node.*/vite" >/dev/null 2>&1; then
        # Count vite processes not from known projects
        for _pid in $(pgrep -f "node.*/vite" 2>/dev/null); do
            _cmd=$(ps -p "$_pid" -o args= 2>/dev/null)
            if ! echo "$_cmd" | grep -qiE "myfeed|mygames|central_bank"; then
                _vite_count=$((_vite_count + 1))
            fi
        done
        if [ "$_vite_count" -gt 0 ]; then
            _servers="${_servers}  ${CYAN}*${NC} Vite Server        ${BLUE}(check terminal)${NC}\n"
            _count=$((_count + 1))
        fi
    fi

    # Check Python http.server
    if pgrep -f "python.*http.server" >/dev/null 2>&1; then
        _servers="${_servers}  ${GREEN}*${NC} Python HTTP        ${BLUE}(check terminal)${NC}\n"
        _count=$((_count + 1))
    fi

    # Check watch processes (Sass/TypeScript)
    if pgrep -f "sass.*--watch" >/dev/null 2>&1; then
        _servers="${_servers}  ${YELLOW}~${NC} Sass Watch         ${YELLOW}(file watcher)${NC}\n"
        _count=$((_count + 1))
    fi
    if pgrep -f "tsc.*--watch" >/dev/null 2>&1 || pgrep -f "esbuild.*--watch" >/dev/null 2>&1; then
        _servers="${_servers}  ${YELLOW}~${NC} TypeScript Watch   ${YELLOW}(file watcher)${NC}\n"
        _count=$((_count + 1))
    fi

    # Check tmux sessions
    if command -v tmux >/dev/null 2>&1; then
        for session in build-landpage-sass build-landpage-ts build-linktree build-cv-web build-myfeed build-mygames build-nexus build-cloud build-feed build-others build-health build-market build-centralbank build-mymaps build-myprofile; do
            if tmux has-session -t "$session" 2>/dev/null; then
                case "$session" in
                    build-landpage-sass)  _servers="${_servers}  ${GREEN}*${NC} Landpage (tmux)    ${BLUE}${URL_LANDPAGE}${NC}\n" ;;
                    build-landpage-ts)    _servers="${_servers}  ${YELLOW}~${NC} Landpage TS (tmux) ${YELLOW}(watcher)${NC}\n" ;;
                    build-linktree)   _servers="${_servers}  ${GREEN}*${NC} Linktree (tmux)    ${BLUE}${URL_LINKTREE}${NC}\n" ;;
                    build-cv-web)     _servers="${_servers}  ${GREEN}*${NC} CV Web (tmux)      ${BLUE}${URL_CV_WEB}${NC}\n" ;;
                    build-myfeed)     _servers="${_servers}  ${GREEN}*${NC} MyFeed (tmux)      ${BLUE}${URL_MYFEED}${NC}\n" ;;
                    build-mygames)  _servers="${_servers}  ${GREEN}*${NC} MyGames (tmux)   ${BLUE}${URL_MYGAMES}${NC}\n" ;;
                    build-nexus)      _servers="${_servers}  ${GREEN}*${NC} Nexus (tmux)       ${BLUE}${URL_NEXUS}${NC}\n" ;;
                    build-cloud)      _servers="${_servers}  ${GREEN}*${NC} Cloud (tmux)       ${BLUE}${URL_CLOUD}${NC}\n" ;;
                    build-feed)       _servers="${_servers}  ${GREEN}*${NC} Feed (tmux)        ${BLUE}${URL_FEED}${NC}\n" ;;
                    build-others)     _servers="${_servers}  ${GREEN}*${NC} Others (tmux)      ${BLUE}${URL_OTHERS}${NC}\n" ;;
                    build-health)     _servers="${_servers}  ${GREEN}*${NC} Health (tmux)      ${BLUE}${URL_HEALTH}${NC}\n" ;;
                    build-market)     _servers="${_servers}  ${GREEN}*${NC} Market (tmux)      ${BLUE}${URL_MARKET}${NC}\n" ;;
                    build-centralbank) _servers="${_servers}  ${GREEN}*${NC} Central Bank (tmux) ${BLUE}${URL_CENTRALBANK}${NC}\n" ;;
                    build-mymaps) _servers="${_servers}  ${GREEN}*${NC} MyMaps (tmux)      ${BLUE}${URL_MYMAPS}${NC}\n" ;;
                    build-myprofile) _servers="${_servers}  ${GREEN}*${NC} MyProfile (tmux)   ${BLUE}${URL_MYPROFILE}${NC}\n" ;;
                esac
                _count=$((_count + 1))
            fi
        done
    fi

    RUNNING_SERVERS="$_servers"
    RUNNING_COUNT="$_count"
}

# Print status box
print_status_box() {
    get_running_servers

    printf "\n"
    printf "${MAGENTA}┌────────────────────────────────────────────────────────────────────────────┐${NC}\n"
    printf "${MAGENTA}│${NC}  ${CYAN}SERVER STATUS${NC}                                                               ${MAGENTA}│${NC}\n"
    printf "${MAGENTA}├────────────────────────────────────────────────────────────────────────────┤${NC}\n"

    if [ "$RUNNING_COUNT" -eq 0 ]; then
        printf "${MAGENTA}│${NC}  ${YELLOW}No servers currently running${NC}                                                ${MAGENTA}│${NC}\n"
    else
        # Calculate padding for the running count line. Assumes RUNNING_COUNT is max 2 digits.
        _len_running_count_text=$(( 2 + ${#RUNNING_COUNT} + 33 )) # "  " + count + " server(s)/watcher(s) running:"
        _padding_running_count=$(( 76 - _len_running_count_text ))
        printf "${MAGENTA}│${NC}  ${GREEN}%d server(s)/watcher(s) running:${NC}%${_padding_running_count}s${MAGENTA}│${NC}\n" "$RUNNING_COUNT" ""
        printf "%b" "$RUNNING_SERVERS" | while IFS= read -r line; do
            printf "${MAGENTA}│${NC} %-74b${MAGENTA}│${NC}\n" "$line"
        done
    fi

    printf "${MAGENTA}└────────────────────────────────────────────────────────────────────────────┘${NC}\n"
}

# Usage information
print_usage() {
    printf "${BLUE}===============================================================================${NC}\n"
    printf "${CYAN}                        MAIN BUILD ORCHESTRATOR                                ${NC}\n"
    printf "${BLUE}===============================================================================${NC}\n"
    printf "\n"
    printf "${YELLOW}USAGE:${NC}  ./1.ops/build_main.sh <action> [options]\n"
    printf "\n"
    printf "${YELLOW}BUILD:${NC}\n"
    printf "  ${GREEN}build${NC}              # All projects\n"
    printf "  ${GREEN}build-landpage${NC}     # Landpage - Vanilla + Sass + TypeScript\n"
    printf "  ${GREEN}build-linktree${NC}     # Linktree - Vanilla + Sass\n"
    printf "  ${GREEN}build-cv-web${NC}       # CV Web - Vanilla + Sass\n"
    printf "  ${GREEN}build-myfeed${NC}       # MyFeed - Vue 3 + Sass + TypeScript\n"
    printf "  ${GREEN}build-mygames${NC}    # MyGames - SvelteKit + Sass + TypeScript\n"
    printf "  ${GREEN}build-nexus${NC}        # Nexus - Vanilla + Sass+TW + TypeScript\n"
    printf "  ${GREEN}build-cloud${NC}        # Cloud - Vanilla + Sass + TypeScript\n"
    printf "  ${GREEN}build-feed${NC}         # Feed Yourself - Vanilla + Sass\n"
    printf "  ${GREEN}build-others${NC}       # Others - Python\n"
    printf "  ${GREEN}build-health${NC}       # Health Tracker - Vanilla + Tailwind\n"
    printf "  ${GREEN}build-market${NC}       # Market Watch - Vanilla + Sass + TypeScript\n"
    printf "  ${GREEN}build-centralbank${NC}  # Central Bank - Vanilla + Tailwind + TypeScript\n"
    printf "  ${GREEN}build-mymaps${NC}       # MyMaps - Next.js + Sass + TypeScript\n"
    printf "  ${GREEN}build-myprofile${NC}    # MyProfile - Nuxt 4 + Sass + TypeScript\n"
    printf "\n"
    printf "${YELLOW}DEV SERVER:${NC}\n"
    printf "  ${GREEN}dev${NC}                # All - Start all servers\n"
    printf "  ${GREEN}dev-landpage${NC}       # Landpage - npm-live :8000\n"
    printf "  ${GREEN}dev-linktree${NC}       # Linktree - npm-live :8001\n"
    printf "  ${GREEN}dev-cv-web${NC}         # CV Web - npm-live :8002\n"
    printf "  ${GREEN}dev-myfeed${NC}         # MyFeed - Vite :8003\n"
    printf "  ${GREEN}dev-mygames${NC}      # MyGames - Vite :8004\n"
    printf "  ${GREEN}dev-nexus${NC}          # Nexus - Vite :8005\n"
    printf "  ${GREEN}dev-cloud${NC}          # Cloud - npm-live :8006\n"
    printf "  ${GREEN}dev-feed${NC}           # Feed Yourself - npm-live :8007\n"
    printf "  ${GREEN}dev-others${NC}         # Others - npm-live :8008\n"
    printf "  ${GREEN}dev-health${NC}         # Health Tracker - npm-live :8009\n"
    printf "  ${GREEN}dev-market${NC}         # Market Watch - npm-live :8010\n"
    printf "  ${GREEN}dev-centralbank${NC}    # Central Bank - npm-live :8011\n"
    printf "  ${GREEN}dev-mymaps${NC}         # MyMaps - Next.js :8012\n"
    printf "  ${GREEN}dev-myprofile${NC}      # MyProfile - Nuxt :8013\n"
    printf "\n"
    printf "${YELLOW}UTILITY:${NC}\n"
    printf "  ${GREEN}list${NC}               # List running servers/watchers\n"
    printf "  ${GREEN}kill${NC}               # Kill all dev servers\n"
    printf "  ${GREEN}clean${NC}              # Clean build artifacts\n"
    printf "  ${GREEN}clean-all${NC}          # Clean artifacts + node_modules\n"
    printf "  ${GREEN}test${NC}               # Run all tests\n"
    printf "  ${GREEN}help${NC}               # Show this help\n"
    printf "\n"
    printf "${YELLOW}OPTIONS:${NC}  ${GREEN}-v, --verbose${NC}  |  ${GREEN}-f, --force${NC}\n"
    printf "\n"
    printf "${YELLOW}PROJECT STRUCTURE:${NC}\n"
    printf "${BLUE}------------------------------------------------------------------------------------------------------${NC}\n"
    printf "  ${MAGENTA}%-13s  %-10s  %-10s  %-10s  %-15s  %s${NC}\n" "Project" "Framework" "CSS" "JavaScript" "Dev Server" "Watch"
    printf "${BLUE}------------------------------------------------------------------------------------------------------${NC}\n"
    printf "  ${CYAN}%-13s${NC}  %-10s  %-10s  %-10s  ${GREEN}%-15s${NC}  ${YELLOW}%s${NC}\n" "Landpage" "Vanilla" "Sass" "TypeScript" "npm-live :8000" "Sass, TS"
    printf "  ${CYAN}%-13s${NC}  %-10s  %-10s  %-10s  ${GREEN}%-15s${NC}  ${YELLOW}%s${NC}\n" "Linktree" "Vanilla" "Sass" "Vanilla" "npm-live :8001" "Sass"
    printf "  ${CYAN}%-13s${NC}  %-10s  %-10s  %-10s  ${GREEN}%-15s${NC}  ${YELLOW}%s${NC}\n" "CV Web" "Vanilla" "Sass" "Vanilla" "npm-live :8002" "Sass"
    printf "  ${CYAN}%-13s${NC}  ${GREEN}%-10s${NC}  %-10s  %-10s  ${CYAN}%-15s${NC}  ${YELLOW}%s${NC}\n" "MyFeed" "Vue 3" "Sass" "TypeScript" "Vite :8003" "HMR"
    printf "  ${CYAN}%-13s${NC}  ${GREEN}%-10s${NC}  %-10s  %-10s  ${CYAN}%-15s${NC}  ${YELLOW}%s${NC}\n" "MyGames" "SvelteKit" "Sass" "TypeScript" "Vite :8004" "HMR"
    printf "  ${CYAN}%-13s${NC}  %-10s  %-10s  %-10s  ${GREEN}%-15s${NC}  ${YELLOW}%s${NC}\n" "Nexus" "Vanilla" "Sass+TW" "TypeScript" "npm-live :8005" "Sass, TS"
    printf "  ${CYAN}%-13s${NC}  %-10s  %-10s  %-10s  ${GREEN}%-15s${NC}  ${YELLOW}%s${NC}\n" "Cloud" "Vanilla" "Sass" "TypeScript" "npm-live :8006" "Sass, TS"
    printf "  ${CYAN}%-13s${NC}  %-10s  %-10s  %-10s  ${GREEN}%-15s${NC}  ${YELLOW}%s${NC}\n" "Feed Yourself" "Vanilla" "Sass" "Vanilla" "npm-live :8007" "Sass"
    printf "  ${CYAN}%-13s${NC}  %-10s  %-10s  %-10s  ${GREEN}%-15s${NC}  ${YELLOW}%s${NC}\n" "Others" "Python" "-" "-" "npm-live :8008" "-"
    printf "  ${CYAN}%-13s${NC}  %-10s  %-10s  %-10s  ${GREEN}%-15s${NC}  ${YELLOW}%s${NC}\n" "HealthTracker" "Vanilla" "Tailwind" "Vanilla" "npm-live :8009" "-"
    printf "  ${CYAN}%-13s${NC}  %-10s  %-10s  %-10s  ${GREEN}%-15s${NC}  ${YELLOW}%s${NC}\n" "MarketWatch" "Vanilla" "Sass" "TypeScript" "npm-live :8010" "Sass, TS"
    printf "  ${CYAN}%-13s${NC}  %-10s  %-10s  %-10s  ${GREEN}%-15s${NC}  ${YELLOW}%s${NC}\n" "CentralBank" "Vanilla" "Tailwind" "TypeScript" "npm-live :8011" "-"
    printf "  ${CYAN}%-13s${NC}  ${GREEN}%-10s${NC}  %-10s  %-10s  ${CYAN}%-15s${NC}  ${YELLOW}%s${NC}\n" "MyMaps" "Next.js" "Sass" "TypeScript" "Next.js :8012" "HMR"
    printf "  ${CYAN}%-13s${NC}  ${GREEN}%-10s${NC}  %-10s  %-10s  ${CYAN}%-15s${NC}  ${YELLOW}%s${NC}\n" "MyProfile" "Nuxt 4" "Sass" "TypeScript" "Vite :8013" "HMR"
    printf "${BLUE}------------------------------------------------------------------------------------------------------${NC}\n"

    # Show status box in help
    print_status_box
}

# Logging functions
log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

log_success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
}

log_warning() {
    printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

log_section() {
    printf "\n${MAGENTA}========================================${NC}\n"
    printf "${MAGENTA}  %s${NC}\n" "$1"
    printf "${MAGENTA}========================================${NC}\n\n"
}

# Print server started message with URL
print_server_started() {
    _name="$1"
    _url="$2"
    _type="${3:-server}"

    printf "\n"
    printf "${GREEN}+----------------------------------------------------------+${NC}\n"
    printf "${GREEN}|${NC}  ${CYAN}%s STARTED${NC}\n" "$_name"
    printf "${GREEN}+----------------------------------------------------------+${NC}\n"
    if [ "$_type" = "watcher" ]; then
        printf "${GREEN}|${NC}  ${YELLOW}Type:${NC} File Watcher (no HTTP server)\n"
    else
        printf "${GREEN}|${NC}  ${YELLOW}URL:${NC}  ${BLUE}%s${NC}\n" "$_url"
    fi
    printf "${GREEN}|${NC}  ${YELLOW}Stop:${NC} ./1.ops/build_main.sh kill\n"
    printf "${GREEN}+----------------------------------------------------------+${NC}\n"
    printf "\n"
}

# Check if build.sh exists in a directory
check_build_script() {
    _dir="$1"
    _build_script="$PROJECT_ROOT/$_dir/1.ops/build.sh"

    if [ -f "$_build_script" ]; then
        return 0
    else
        return 1
    fi
}

# Execute build script
execute_build() {
    _project="$1"
    _action="$2"
    _build_script="$PROJECT_ROOT/$_project/1.ops/build.sh"

    # mygames now uses standard 1.ops path

    log_section "Building: $_project"

    if [ -f "$_build_script" ]; then
        log_info "Executing: $_build_script $_action"
        if sh "$_build_script" "$_action"; then
            log_success "$_project build completed"
            return 0
        else
            log_error "$_project build failed"
            return 1
        fi
    else
        log_warning "Build script not found: $_build_script"
        return 1
    fi
}

# Build all projects
build_all() {
    _force="${1:-false}"

    log_section "Building All Projects"

    if [ "$_force" = "true" ]; then
        log_info "Force rebuild enabled - cleaning first..."
        clean_all_builds
    fi

    _failed=0

    # Create dist directory for root
    mkdir -p "$PROJECT_ROOT/dist"

    # Build landpage
    log_info "Building Landpage..."
    execute_build "landpage" "build" || _failed=$((_failed + 1))

    # Build each sub-project
    execute_build "linktree" "build" || _failed=$((_failed + 1))
    execute_build "cv_web" "build" || _failed=$((_failed + 1))
    execute_build "myfeed" "build" || _failed=$((_failed + 1))
    execute_build "mygames" "build" || _failed=$((_failed + 1))
    execute_build "cloud" "build" || _failed=$((_failed + 1))
    execute_build "feed_yourself" "build" || _failed=$((_failed + 1))
    execute_build "others" "build" || _failed=$((_failed + 1))
    execute_build "health_tracker" "build" || _failed=$((_failed + 1))
    execute_build "market_watch" "build" || _failed=$((_failed + 1))
    execute_build "central_bank" "build" || _failed=$((_failed + 1))
    execute_build "mymaps" "build" || _failed=$((_failed + 1))
    execute_build "myprofile" "build" || _failed=$((_failed + 1))

    if [ "$_failed" -eq 0 ]; then
        log_success "All builds completed successfully!"
        return 0
    else
        log_error "$_failed build(s) failed"
        return 1
    fi
}

# Clean build artifacts
clean_all_builds() {
    log_section "Cleaning Build Artifacts"

    # Clean landpage
    execute_build "landpage" "clean" || true

    # Clean sub-projects
    execute_build "linktree" "clean" || true
    execute_build "cv_web" "clean" || true
    execute_build "myfeed" "clean" || true
    execute_build "mygames" "clean" || true
    execute_build "cloud" "clean" || true
    execute_build "feed_yourself" "clean" || true
    execute_build "others" "clean" || true
    execute_build "health_tracker" "clean" || true
    execute_build "market_watch" "clean" || true
    execute_build "central_bank" "clean" || true
    execute_build "mymaps" "clean" || true
    execute_build "myprofile" "clean" || true

    log_success "All build artifacts cleaned"
}

# Deep clean (including node_modules)
clean_deep() {
    log_section "Deep Cleaning (including node_modules)"

    clean_all_builds

    log_info "Removing node_modules..."
    find "$PROJECT_ROOT" -name "node_modules" -type d -prune -exec rm -rf {} + 2>/dev/null || true
    find "$PROJECT_ROOT" -name "package-lock.json" -type f -delete 2>/dev/null || true

    log_success "Deep clean completed"
}

# List running servers
list_servers() {
    log_section "Running Servers & Watchers"
    print_status_box

    # Additional details
    printf "${YELLOW}Process Details:${NC}\n"
    printf "${BLUE}-------------------------------------------------------------------------------${NC}\n"

    # live-server processes
    _live_pids=$(pgrep -f "live-server" 2>/dev/null || true)
    if [ -n "$_live_pids" ]; then
        printf "${CYAN}live-server Processes:${NC}\n"
        ps -p $(echo "$_live_pids" | tr '\n' ',') -o pid,args 2>/dev/null | tail -n +2 || true
        printf "\n"
    fi

    # Sass watchers
    _sass_pids=$(pgrep -f "sass.*--watch" 2>/dev/null || true)
    if [ -n "$_sass_pids" ]; then
        printf "${CYAN}Sass Watchers:${NC}\n"
        ps -p $(echo "$_sass_pids" | tr '\n' ',') -o pid,args 2>/dev/null | tail -n +2 || true
        printf "\n"
    fi

    # TypeScript watchers
    _tsc_pids=$(pgrep -f "tsc.*--watch" 2>/dev/null || true)
    if [ -n "$_tsc_pids" ]; then
        printf "${CYAN}TypeScript Watchers:${NC}\n"
        ps -p $(echo "$_tsc_pids" | tr '\n' ',') -o pid,args 2>/dev/null | tail -n +2 || true
        printf "\n"
    fi

    # Tmux sessions
    if command -v tmux >/dev/null 2>&1; then
        _tmux_sessions=$(tmux list-sessions 2>/dev/null | grep "^build-" || true)
        if [ -n "$_tmux_sessions" ]; then
            printf "${CYAN}Tmux Sessions:${NC}\n"
            printf "%s\n" "$_tmux_sessions"
            printf "\n"
        fi
    fi

    printf "${BLUE}-------------------------------------------------------------------------------${NC}\n"
    printf "${YELLOW}To stop all:${NC} ./1.ops/build_main.sh kill\n"
    printf "\n"
}

# Start development servers
dev_all() {
    _verbose="${1:-false}"

    log_section "Starting All Development Servers"

    log_warning "This will start multiple development servers concurrently."
    printf "\n"

    # Use tmux if available
    if command -v tmux >/dev/null 2>&1; then
        log_info "Starting servers in tmux sessions..."

        tmux new-session -d -s build-landpage "cd $PROJECT_ROOT/landpage/1.ops && sh build.sh dev" 2>/dev/null || true
        tmux new-session -d -s build-linktree "cd $PROJECT_ROOT/linktree/1.ops && sh build.sh dev" 2>/dev/null || true
        tmux new-session -d -s build-cv-web "cd $PROJECT_ROOT/cv_web/1.ops && sh build.sh dev" 2>/dev/null || true
        tmux new-session -d -s build-myfeed "cd $PROJECT_ROOT/myfeed/1.ops && sh build.sh dev" 2>/dev/null || true
        tmux new-session -d -s build-mygames "cd $PROJECT_ROOT/mygames/1.ops && sh build.sh dev" 2>/dev/null || true
        tmux new-session -d -s build-nexus "cd $PROJECT_ROOT/nexus/1.ops && sh build.sh dev" 2>/dev/null || true
        tmux new-session -d -s build-cloud "cd $PROJECT_ROOT/cloud/1.ops && sh build.sh dev" 2>/dev/null || true
        tmux new-session -d -s build-feed "cd $PROJECT_ROOT/feed_yourself/1.ops && sh build.sh dev" 2>/dev/null || true
        tmux new-session -d -s build-others "cd $PROJECT_ROOT/others/1.ops && sh build.sh dev" 2>/dev/null || true
        tmux new-session -d -s build-health "cd $PROJECT_ROOT/health_tracker/1.ops && sh build.sh dev" 2>/dev/null || true
        tmux new-session -d -s build-market "cd $PROJECT_ROOT/market_watch/1.ops && sh build.sh dev" 2>/dev/null || true
        tmux new-session -d -s build-centralbank "cd $PROJECT_ROOT/central_bank/1.ops && sh build.sh dev" 2>/dev/null || true
        tmux new-session -d -s build-mymaps "cd $PROJECT_ROOT/mymaps/1.ops && sh build.sh dev" 2>/dev/null || true
        tmux new-session -d -s build-myprofile "cd $PROJECT_ROOT/myprofile/1.ops && sh build.sh dev" 2>/dev/null || true

        log_success "All servers started in tmux sessions!"
        printf "\n"
        printf "${GREEN}============================================================${NC}\n"
        printf "${CYAN}  Development Servers Running (live-server):${NC}\n"
        printf "${GREEN}============================================================${NC}\n"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Landpage" "$URL_LANDPAGE"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Linktree" "$URL_LINKTREE"
        printf "  ${CYAN}%-15s${NC}  %s\n" "CV Web" "$URL_CV_WEB"
        printf "  ${CYAN}%-15s${NC}  %s\n" "MyFeed" "$URL_MYFEED"
        printf "  ${CYAN}%-15s${NC}  %s\n" "MyGames" "$URL_MYGAMES"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Nexus" "$URL_NEXUS"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Cloud" "$URL_CLOUD"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Feed Yourself" "$URL_FEED"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Others" "$URL_OTHERS"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Health Tracker" "$URL_HEALTH"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Market Watch" "$URL_MARKET"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Central Bank" "$URL_CENTRALBANK"
        printf "  ${CYAN}%-15s${NC}  %s\n" "MyMaps" "$URL_MYMAPS"
        printf "  ${CYAN}%-15s${NC}  %s\n" "MyProfile" "$URL_MYPROFILE"
        printf "${GREEN}============================================================${NC}\n"
        printf "\n"
        log_info "Tmux Sessions: build-landpage, build-linktree, etc."
        log_info "To view logs: tmux attach -t <session-name>"
        log_info "To kill all servers: ./1.ops/build_main.sh kill"
        printf "\n"
        log_success "Returning to prompt. Dev servers are running in background."

    else
        log_warning "tmux not found. Starting servers in background..."
        log_info "Install tmux for better session management: sudo apt-get install tmux"
        printf "\n"

        # Create log directory
        mkdir -p "$PROJECT_ROOT/1.ops/logs"

        # Start servers in background
        log_info "Starting landpage..."
        nohup sh "$PROJECT_ROOT/landpage/1.ops/build.sh" dev > "$PROJECT_ROOT/1.ops/logs/landpage-dev.log" 2>&1 &

        log_info "Starting linktree..."
        nohup sh "$PROJECT_ROOT/linktree/1.ops/build.sh" dev > "$PROJECT_ROOT/1.ops/logs/linktree-dev.log" 2>&1 &

        log_info "Starting cv_web..."
        nohup sh "$PROJECT_ROOT/cv_web/1.ops/build.sh" dev > "$PROJECT_ROOT/1.ops/logs/cv-web-dev.log" 2>&1 &

        log_info "Starting myfeed..."
        nohup sh "$PROJECT_ROOT/myfeed/1.ops/build.sh" dev > "$PROJECT_ROOT/1.ops/logs/myfeed-dev.log" 2>&1 &

        log_info "Starting mygames..."
        nohup sh "$PROJECT_ROOT/mygames/1.ops/build.sh" dev > "$PROJECT_ROOT/1.ops/logs/mygames-dev.log" 2>&1 &

        log_info "Starting nexus..."
        nohup sh "$PROJECT_ROOT/nexus/1.ops/build.sh" dev > "$PROJECT_ROOT/1.ops/logs/nexus-dev.log" 2>&1 &

        log_info "Starting cloud..."
        nohup sh "$PROJECT_ROOT/cloud/1.ops/build.sh" dev > "$PROJECT_ROOT/1.ops/logs/cloud-dev.log" 2>&1 &

        log_info "Starting feed_yourself..."
        nohup sh "$PROJECT_ROOT/feed_yourself/1.ops/build.sh" dev > "$PROJECT_ROOT/1.ops/logs/feed-dev.log" 2>&1 &

        log_info "Starting others..."
        nohup sh "$PROJECT_ROOT/others/1.ops/build.sh" dev > "$PROJECT_ROOT/1.ops/logs/others-dev.log" 2>&1 &

        log_info "Starting health_tracker..."
        nohup sh "$PROJECT_ROOT/health_tracker/1.ops/build.sh" dev > "$PROJECT_ROOT/1.ops/logs/health-dev.log" 2>&1 &

        log_info "Starting market_watch..."
        nohup sh "$PROJECT_ROOT/market_watch/1.ops/build.sh" dev > "$PROJECT_ROOT/1.ops/logs/market-dev.log" 2>&1 &

        log_info "Starting central_bank..."
        nohup sh "$PROJECT_ROOT/central_bank/1.ops/build.sh" dev > "$PROJECT_ROOT/1.ops/logs/centralbank-dev.log" 2>&1 &

        log_info "Starting mymaps..."
        nohup sh "$PROJECT_ROOT/mymaps/1.ops/build.sh" dev > "$PROJECT_ROOT/1.ops/logs/mymaps-dev.log" 2>&1 &

        log_info "Starting myprofile..."
        nohup sh "$PROJECT_ROOT/myprofile/1.ops/build.sh" dev > "$PROJECT_ROOT/1.ops/logs/myprofile-dev.log" 2>&1 &

        sleep 3  # Give servers time to start

        log_success "All servers started in background!"
        printf "\n"
        printf "${GREEN}============================================================${NC}\n"
        printf "${CYAN}  Development Servers Running (live-server):${NC}\n"
        printf "${GREEN}============================================================${NC}\n"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Landpage" "$URL_LANDPAGE"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Linktree" "$URL_LINKTREE"
        printf "  ${CYAN}%-15s${NC}  %s\n" "CV Web" "$URL_CV_WEB"
        printf "  ${CYAN}%-15s${NC}  %s\n" "MyFeed" "$URL_MYFEED"
        printf "  ${CYAN}%-15s${NC}  %s\n" "MyGames" "$URL_MYGAMES"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Nexus" "$URL_NEXUS"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Cloud" "$URL_CLOUD"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Feed Yourself" "$URL_FEED"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Others" "$URL_OTHERS"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Health Tracker" "$URL_HEALTH"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Market Watch" "$URL_MARKET"
        printf "  ${CYAN}%-15s${NC}  %s\n" "Central Bank" "$URL_CENTRALBANK"
        printf "  ${CYAN}%-15s${NC}  %s\n" "MyMaps" "$URL_MYMAPS"
        printf "  ${CYAN}%-15s${NC}  %s\n" "MyProfile" "$URL_MYPROFILE"
        printf "${GREEN}============================================================${NC}\n"
        printf "\n"
        log_info "Logs: $PROJECT_ROOT/1.ops/logs/<project>-dev.log"
        log_info "View logs: tail -f $PROJECT_ROOT/1.ops/logs/<project>-dev.log"
        log_info "Kill servers: ./1.ops/build_main.sh kill"
        printf "\n"
        log_success "Returning to prompt. Dev servers are running in background."
    fi
}

# Start single dev server and show URL
dev_single() {
    _project="$1"
    _url="$2"
    _type="${3:-server}"

    log_section "Starting: $_project"

    case "$_project" in
        landpage)
            execute_build "landpage" "dev"
            ;;
        linktree)
            execute_build "linktree" "dev" &
            sleep 2
            print_server_started "Linktree" "$_url"
            wait
            ;;
        cv-web)
            execute_build "cv_web" "dev" &
            sleep 2
            print_server_started "CV Web" "$_url"
            wait
            ;;
        myfeed)
            execute_build "myfeed" "dev" &
            sleep 2
            print_server_started "MyFeed" "$_url"
            wait
            ;;
        mygames)
            execute_build "mygames" "dev" &
            sleep 2
            print_server_started "MyGames" "$_url"
            wait
            ;;
        nexus)
            execute_build "nexus" "dev" &
            sleep 2
            print_server_started "Nexus" "$_url"
            wait
            ;;
        cloud)
            execute_build "cloud" "dev"
            ;;
        feed)
            execute_build "feed_yourself" "dev" &
            sleep 2
            print_server_started "Feed Yourself" "$_url"
            wait
            ;;
        others)
            execute_build "others" "dev" &
            sleep 2
            print_server_started "Others" "$_url"
            wait
            ;;
        health)
            execute_build "health_tracker" "dev" &
            sleep 2
            print_server_started "Health Tracker" "$_url"
            wait
            ;;
        market)
            execute_build "market_watch" "dev"
            ;;
        centralbank)
            execute_build "central_bank" "dev"
            ;;
        mymaps)
            execute_build "mymaps" "dev" &
            sleep 2
            print_server_started "MyMaps" "$_url"
            wait
            ;;
        myprofile)
            execute_build "myprofile" "dev" &
            sleep 2
            print_server_started "MyProfile" "$_url"
            wait
            ;;
    esac
}

# Kill all running dev servers
kill_servers() {
    log_section "Killing All Development Servers"

    _killed=0

    # Kill tmux sessions if they exist
    if command -v tmux >/dev/null 2>&1; then
        for session in build-landpage-sass build-landpage-ts build-linktree build-cv-web build-myfeed build-mygames build-nexus build-cloud build-feed build-others build-health build-market build-centralbank build-mymaps; do
            if tmux has-session -t "$session" 2>/dev/null; then
                log_info "Killing tmux session: $session"
                tmux kill-session -t "$session" 2>/dev/null && _killed=$((_killed + 1)) || true
            fi
        done
    fi

    # Kill Vite dev server processes
    _vite_pids=$(pgrep -f "node.*vite" 2>/dev/null || true)
    if [ -n "$_vite_pids" ]; then
        log_info "Killing Vite dev server processes..."
        echo "$_vite_pids" | xargs kill -15 2>/dev/null || true
        _killed=$((_killed + $(echo "$_vite_pids" | wc -w)))
        sleep 1
        _vite_pids=$(pgrep -f "node.*vite" 2>/dev/null || true)
        if [ -n "$_vite_pids" ]; then
            echo "$_vite_pids" | xargs kill -9 2>/dev/null || true
        fi
    fi

    # Kill Next.js processes
    _next_pids=$(pgrep -f "node.*next" 2>/dev/null || true)
    if [ -n "$_next_pids" ]; then
        log_info "Killing Next.js server processes..."
        echo "$_next_pids" | xargs kill -15 2>/dev/null || true
        _killed=$((_killed + $(echo "$_next_pids" | wc -w)))
        sleep 1
        _next_pids=$(pgrep -f "node.*next" 2>/dev/null || true)
        if [ -n "$_next_pids" ]; then
            echo "$_next_pids" | xargs kill -9 2>/dev/null || true
        fi
    fi

    # Kill Nuxt.js processes
    _nuxt_pids=$(pgrep -f "nuxt" 2>/dev/null || true)
    if [ -n "$_nuxt_pids" ]; then
        log_info "Killing Nuxt.js server processes..."
        echo "$_nuxt_pids" | xargs kill -15 2>/dev/null || true
        _killed=$((_killed + $(echo "$_nuxt_pids" | wc -w)))
        sleep 1
        _nuxt_pids=$(pgrep -f "nuxt" 2>/dev/null || true)
        if [ -n "$_nuxt_pids" ]; then
            echo "$_nuxt_pids" | xargs kill -9 2>/dev/null || true
        fi
    fi

    # Kill live-server processes
    _live_pids=$(pgrep -f "live-server" 2>/dev/null || true)
    if [ -n "$_live_pids" ]; then
        log_info "Killing live-server processes..."
        echo "$_live_pids" | xargs kill -15 2>/dev/null || true
        _killed=$((_killed + $(echo "$_live_pids" | wc -w)))
        sleep 1
        _live_pids=$(pgrep -f "live-server" 2>/dev/null || true)
        if [ -n "$_live_pids" ]; then
            echo "$_live_pids" | xargs kill -9 2>/dev/null || true
        fi
    fi

    # Kill concurrently processes
    _concurrently_pids=$(pgrep -f "node.*concurrently" 2>/dev/null || true)
    if [ -n "$_concurrently_pids" ]; then
        log_info "Killing concurrently processes..."
        echo "$_concurrently_pids" | xargs kill -15 2>/dev/null || true
        _killed=$((_killed + $(echo "$_concurrently_pids" | wc -w)))
        sleep 1
        _concurrently_pids=$(pgrep -f "node.*concurrently" 2>/dev/null || true)
        if [ -n "$_concurrently_pids" ]; then
            echo "$_concurrently_pids" | xargs kill -9 2>/dev/null || true
        fi
    fi

    # Kill npm run processes
    _npm_pids=$(pgrep -f "npm run" 2>/dev/null || true)
    if [ -n "$_npm_pids" ]; then
        log_info "Killing npm processes..."
        echo "$_npm_pids" | xargs kill -15 2>/dev/null || true
        _killed=$((_killed + $(echo "$_npm_pids" | wc -w)))
        sleep 1
        _npm_pids=$(pgrep -f "npm run" 2>/dev/null || true)
        if [ -n "$_npm_pids" ]; then
            echo "$_npm_pids" | xargs kill -9 2>/dev/null || true
        fi
    fi

    # Kill Sass watch processes
    _sass_pids=$(pgrep -f "sass.*--watch" 2>/dev/null || true)
    if [ -n "$_sass_pids" ]; then
        log_info "Killing Sass watch processes..."
        echo "$_sass_pids" | xargs kill -15 2>/dev/null || true
        _killed=$((_killed + $(echo "$_sass_pids" | wc -w)))
        sleep 1
        _sass_pids=$(pgrep -f "sass.*--watch" 2>/dev/null || true)
        if [ -n "$_sass_pids" ]; then
            echo "$_sass_pids" | xargs kill -9 2>/dev/null || true
        fi
    fi

    # Kill TypeScript watch processes
    _tsc_pids=$(pgrep -f "tsc.*--watch" 2>/dev/null || true)
    if [ -n "$_tsc_pids" ]; then
        log_info "Killing TypeScript watch processes..."
        echo "$_tsc_pids" | xargs kill -15 2>/dev/null || true
        _killed=$((_killed + $(echo "$_tsc_pids" | wc -w)))
        sleep 1
        _tsc_pids=$(pgrep -f "tsc.*--watch" 2>/dev/null || true)
        if [ -n "$_tsc_pids" ]; then
            echo "$_tsc_pids" | xargs kill -9 2>/dev/null || true
        fi
    fi

    if [ "$_killed" -gt 0 ]; then
        log_success "Killed $_killed process(es)"
    else
        log_warning "No running dev servers found"
    fi
}

# Run tests
run_tests() {
    log_section "Running Tests"

    _failed=0

    execute_build "myfeed" "test" || _failed=$((_failed + 1))
    execute_build "mygames" "test" || _failed=$((_failed + 1))

    if [ "$_failed" -eq 0 ]; then
        log_success "All tests passed!"
        return 0
    else
        log_error "$_failed test suite(s) failed"
        return 1
    fi
}

# TUI Menu System
tui_menu() {
    # Menu items: "label|command"
    _menu_items="
BUILD ALL|build
─────────────────────────────|
Landpage (Vanilla+Sass+TS)|build-landpage
Linktree (Vanilla+Sass)|build-linktree
CV Web (Vanilla+Sass)|build-cv-web
MyFeed (Vue 3)|build-myfeed
MyGames (SvelteKit)|build-mygames
Nexus (Vanilla+Sass+TW)|build-nexus
Cloud (Vanilla+Sass+TS)|build-cloud
Feed Yourself (Vanilla+Sass)|build-feed
Others (Python)|build-others
Health Tracker (Vanilla+TW)|build-health
Market Watch (Vanilla+Sass+TS)|build-market
─────────────────────────────|
DEV ALL|dev
─────────────────────────────|
Landpage :8000|dev-landpage
Linktree :8001|dev-linktree
CV Web :8002|dev-cv-web
MyFeed :8003|dev-myfeed
MyGames :8004|dev-mygames
Nexus :8005|dev-nexus
Cloud :8006|dev-cloud
Feed Yourself :8007|dev-feed
Others :8008|dev-others
Health Tracker :8009|dev-health
Market Watch :8010|dev-market
─────────────────────────────|
List Servers|list
Kill Servers|kill
Clean Builds|clean
Clean All|clean-all
Run Tests|test
─────────────────────────────|
Exit|quit
"

    # Convert to arrays
    _idx=0
    _labels=""
    _commands=""
    _separators=""

    echo "$_menu_items" | while IFS='|' read -r _label _cmd; do
        [ -z "$_label" ] && continue
        if [ -z "$_cmd" ]; then
            _separators="$_separators $_idx"
        fi
        _idx=$((_idx + 1))
    done

    # Current selection
    _selected=0
    _total=0

    # Count items
    _total=$(echo "$_menu_items" | grep -c '|' 2>/dev/null || echo "0")

    # Hide cursor
    printf "\033[?25l"

    # Trap to restore cursor on exit
    trap 'printf "\033[?25h"; clear' EXIT INT TERM

    while true; do
        clear

        # Header
        printf "${CYAN}"
        printf "╔══════════════════════════════════════════════════════════╗\n"
        printf "║            MAIN BUILD ORCHESTRATOR - TUI                 ║\n"
        printf "╚══════════════════════════════════════════════════════════╝${NC}\n"
        printf "\n"

        # Server status (compact)
        get_running_servers
        if [ "$RUNNING_COUNT" -gt 0 ]; then
            printf "${GREEN}● ${RUNNING_COUNT} server(s) running${NC}\n"
        else
            printf "${YELLOW}○ No servers running${NC}\n"
        fi
        printf "\n"

        # Menu
        printf "${BLUE}┌──────────────────────────────────────────────────────────┐${NC}\n"
        printf "${BLUE}│${NC}  ${YELLOW}BUILD${NC}                                                    ${BLUE}│${NC}\n"
        printf "${BLUE}├──────────────────────────────────────────────────────────┤${NC}\n"

        _idx=0
        _section="build"
        echo "$_menu_items" | while IFS='|' read -r _label _cmd; do
            [ -z "$_label" ] && continue

            # Section headers
            if echo "$_label" | grep -q "^─"; then
                if [ "$_section" = "build" ] && [ $_idx -gt 12 ]; then
                    printf "${BLUE}├──────────────────────────────────────────────────────────┤${NC}\n"
                    printf "${BLUE}│${NC}  ${YELLOW}DEV SERVER${NC}                                               ${BLUE}│${NC}\n"
                    printf "${BLUE}├──────────────────────────────────────────────────────────┤${NC}\n"
                    _section="dev"
                elif [ "$_section" = "dev" ] && [ $_idx -gt 25 ]; then
                    printf "${BLUE}├──────────────────────────────────────────────────────────┤${NC}\n"
                    printf "${BLUE}│${NC}  ${YELLOW}UTILITY${NC}                                                  ${BLUE}│${NC}\n"
                    printf "${BLUE}├──────────────────────────────────────────────────────────┤${NC}\n"
                    _section="util"
                fi
                _idx=$((_idx + 1))
                continue
            fi

            # Menu item
            if [ $_idx -eq $_selected ]; then
                printf "${BLUE}│${NC} ${GREEN}▶ %-54s${NC} ${BLUE}│${NC}\n" "$_label"
            else
                printf "${BLUE}│${NC}   %-54s ${BLUE}│${NC}\n" "$_label"
            fi

            _idx=$((_idx + 1))
        done

        printf "${BLUE}└──────────────────────────────────────────────────────────┘${NC}\n"
        printf "\n"
        printf "${CYAN}↑/↓${NC} Navigate  ${CYAN}Enter${NC} Select  ${CYAN}q${NC} Quit  ${CYAN}h${NC} Help\n"

        # Read key
        _key=""
        IFS= read -r -s -n 1 _key

        case "$_key" in
            q|Q)
                printf "\033[?25h"
                clear
                exit 0
                ;;
            h|H)
                printf "\033[?25h"
                clear
                print_usage
                printf "\nPress any key to return to menu..."
                read -r -s -n 1
                ;;
            "")  # Enter
                # Get selected command
                _idx=0
                _selected_cmd=""
                echo "$_menu_items" | while IFS='|' read -r _label _cmd; do
                    [ -z "$_label" ] && continue
                    if [ $_idx -eq $_selected ]; then
                        echo "$_cmd"
                        break
                    fi
                    _idx=$((_idx + 1))
                done > /tmp/tui_cmd.tmp
                _selected_cmd=$(cat /tmp/tui_cmd.tmp 2>/dev/null)
                rm -f /tmp/tui_cmd.tmp

                if [ -n "$_selected_cmd" ] && [ "$_selected_cmd" != "quit" ]; then
                    printf "\033[?25h"
                    clear
                    # Execute command
                    main "$_selected_cmd"
                    printf "\n${CYAN}Press any key to return to menu...${NC}"
                    read -r -s -n 1
                elif [ "$_selected_cmd" = "quit" ]; then
                    printf "\033[?25h"
                    clear
                    exit 0
                fi
                ;;
            $'\x1b')  # Escape sequence (arrow keys)
                read -r -s -n 2 _seq
                case "$_seq" in
                    '[A')  # Up
                        _selected=$((_selected - 1))
                        [ $_selected -lt 0 ] && _selected=$((_total - 1))
                        # Skip separators
                        _check_label=$(echo "$_menu_items" | sed -n "$((_selected + 1))p" | cut -d'|' -f1)
                        while echo "$_check_label" | grep -q "^─"; do
                            _selected=$((_selected - 1))
                            [ $_selected -lt 0 ] && _selected=$((_total - 1))
                            _check_label=$(echo "$_menu_items" | sed -n "$((_selected + 1))p" | cut -d'|' -f1)
                        done
                        ;;
                    '[B')  # Down
                        _selected=$((_selected + 1))
                        [ $_selected -ge $_total ] && _selected=0
                        # Skip separators
                        _check_label=$(echo "$_menu_items" | sed -n "$((_selected + 1))p" | cut -d'|' -f1)
                        while echo "$_check_label" | grep -q "^─"; do
                            _selected=$((_selected + 1))
                            [ $_selected -ge $_total ] && _selected=0
                            _check_label=$(echo "$_menu_items" | sed -n "$((_selected + 1))p" | cut -d'|' -f1)
                        done
                        ;;
                esac
                ;;
        esac
    done
}

# Print project structure table
print_project_table() {
    printf "${YELLOW}PROJECT STRUCTURE:${NC}\n"
    printf "${BLUE}────────────────────────────────────────────────────────────────────────────────${NC}\n"
    printf "  ${MAGENTA}%-14s %-11s %-11s %-11s %-16s %s${NC}\n" "Project" "Framework" "CSS" "JavaScript" "Dev Server" "Watch"
    printf "${BLUE}────────────────────────────────────────────────────────────────────────────────${NC}\n"
    printf "  ${CYAN}%-14s${NC} %-11s %-11s %-11s ${GREEN}%-16s${NC} ${YELLOW}%s${NC}\n" "Landpage" "Vanilla" "Sass" "TypeScript" "npm-live :8000" "Sass, TS"
    printf "  ${CYAN}%-14s${NC} %-11s %-11s %-11s ${GREEN}%-16s${NC} ${YELLOW}%s${NC}\n" "Linktree" "Vanilla" "Sass" "Vanilla" "npm-live :8001" "Sass"
    printf "  ${CYAN}%-14s${NC} %-11s %-11s %-11s ${GREEN}%-16s${NC} ${YELLOW}%s${NC}\n" "CV Web" "Vanilla" "Sass" "Vanilla" "npm-live :8002" "Sass"
    printf "  ${CYAN}%-14s${NC} ${GREEN}%-11s${NC} %-11s %-11s ${CYAN}%-16s${NC} ${YELLOW}%s${NC}\n" "MyFeed" "Vue 3" "Sass" "TypeScript" "Vite :8003" "HMR"
    printf "  ${CYAN}%-14s${NC} ${GREEN}%-11s${NC} %-11s %-11s ${CYAN}%-16s${NC} ${YELLOW}%s${NC}\n" "MyGames" "SvelteKit" "Sass" "TypeScript" "Vite :8004" "HMR"
    printf "  ${CYAN}%-14s${NC} %-11s %-11s %-11s ${GREEN}%-16s${NC} ${YELLOW}%s${NC}\n" "Nexus" "Vanilla" "Sass+TW" "TypeScript" "npm-live :8005" "Sass, TS"
    printf "  ${CYAN}%-14s${NC} %-11s %-11s %-11s ${GREEN}%-16s${NC} ${YELLOW}%s${NC}\n" "Cloud" "Vanilla" "Sass" "TypeScript" "npm-live :8006" "Sass, TS"
    printf "  ${CYAN}%-14s${NC} %-11s %-11s %-11s ${GREEN}%-16s${NC} ${YELLOW}%s${NC}\n" "Feed Yourself" "Vanilla" "Sass" "Vanilla" "npm-live :8007" "Sass"
    printf "  ${CYAN}%-14s${NC} %-11s %-11s %-11s ${GREEN}%-16s${NC} ${YELLOW}%s${NC}\n" "Others" "Python" "-" "-" "npm-live :8008" "-"
    printf "  ${CYAN}%-14s${NC} %-11s %-11s %-11s ${GREEN}%-16s${NC} ${YELLOW}%s${NC}\n" "HealthTracker" "Vanilla" "Tailwind" "Vanilla" "npm-live :8009" "-"
    printf "  ${CYAN}%-14s${NC} %-11s %-11s %-11s ${GREEN}%-16s${NC} ${YELLOW}%s${NC}\n" "MarketWatch" "Vanilla" "Sass" "TypeScript" "npm-live :8010" "Sass, TS"
    printf "${BLUE}────────────────────────────────────────────────────────────────────────────────${NC}\n"
    printf "\n"
}

# Default project root
DEFAULT_PROJECT_ROOT="$HOME/Documents/Git/front-Github_io"

# Print working directory section
print_workdir_section() {
    printf "${YELLOW}WORKING DIRECTORY:${NC}\n"
    printf "${BLUE}══════════════════${NC}\n"

    # Determine which option is selected
    _current_dir="$(pwd)"

    if [ "$PROJECT_ROOT" = "$DEFAULT_PROJECT_ROOT" ]; then
        printf "  ${GREEN}[●]${NC} Default: %s\n" "$DEFAULT_PROJECT_ROOT"
        printf "  [ ] Current Directory: %s\n" "$_current_dir"
        printf "  [ ] Custom Path\n"
    elif [ "$PROJECT_ROOT" = "$_current_dir" ]; then
        printf "  [ ] Default: %s\n" "$DEFAULT_PROJECT_ROOT"
        printf "  ${GREEN}[●]${NC} Current Directory: %s\n" "$_current_dir"
        printf "  [ ] Custom Path\n"
    else
        printf "  [ ] Default: %s\n" "$DEFAULT_PROJECT_ROOT"
        printf "  [ ] Current Directory: %s\n" "$_current_dir"
        printf "  ${GREEN}[●]${NC} Custom Path: %s\n" "$PROJECT_ROOT"
    fi
    printf "\n"
}

# Simple TUI (POSIX-compliant)
tui_simple() {
    _last_msg=""

    # Helper to check status and return colored string
    get_status() {
        if eval "$1" >/dev/null 2>&1; then
            echo "${GREEN}On ${NC}"
        else
            echo "${RED}Off${NC}"
        fi
    }

    while true; do
        clear
        print_banner

        # Check statuses
        _s1=$(get_status 'pgrep -f "live-server.*8000"')
        _s2=$(get_status 'pgrep -f "live-server.*8001"')
        _s3=$(get_status 'pgrep -f "live-server.*8002"')
        _s4=$(get_status 'pgrep -f "myfeed.*vite" || pgrep -f "vite.*myfeed"')
        _s5=$(get_status 'pgrep -f "mygames.*vite" || pgrep -f "vite.*mygames"')
        _s6=$(get_status 'pgrep -f "live-server.*8005"')
        _s7=$(get_status 'pgrep -f "live-server.*8006"')
        _s8=$(get_status 'pgrep -f "live-server.*8007"')
        _s9=$(get_status 'pgrep -f "live-server.*8008"')
        _s10=$(get_status 'pgrep -f "live-server.*8009"')
        _s11=$(get_status 'pgrep -f "live-server.*8010"')
        _s12=$(get_status 'pgrep -f "live-server.*8011"')
        _s13=$(get_status 'pgrep -f "next.*dev.*8012" || pgrep -f "mymaps.*next"')
        _s14=$(get_status 'pgrep -f "nuxt.*dev.*8013" || pgrep -f "myprofile.*nuxt"')

        # Table 1: Full project details
        printf "${BLUE}┌────────────────────────────────────────────────────────────────────────────┐${NC}\n"
        printf "${BLUE}│${NC}  ${YELLOW}PROJECTS${NC}                                                                  ${BLUE}│${NC}\n"
        printf "${BLUE}├─────┬────────────────┬────────────┬──────────┬────────────┬───────┬────────┤${NC}\n"
        printf "${BLUE}│${NC} ${GREEN}#${NC}   ${BLUE}│${NC} ${MAGENTA}Name${NC}           ${BLUE}│${NC} ${MAGENTA}Framework${NC}  ${BLUE}│${NC} ${MAGENTA}CSS${NC}      ${BLUE}│${NC} ${MAGENTA}JavaScript${NC} ${BLUE}│${NC} ${MAGENTA}Port${NC}  ${BLUE}│${NC} ${MAGENTA}Live${NC}   ${BLUE}│${NC}\n"
        printf "${BLUE}├─────┼────────────────┼────────────┼──────────┼────────────┼───────┼────────┤${NC}\n"
        printf "${BLUE}│${NC} ${GREEN}1${NC}   ${BLUE}│${NC} Landpage       ${BLUE}│${NC} Vanilla    ${BLUE}│${NC} Sass     ${BLUE}│${NC} TypeScript ${BLUE}│${NC} :8000 ${BLUE}│${NC} %b    ${BLUE}│${NC}\n" "$_s1"
        printf "${BLUE}│${NC} ${GREEN}2${NC}   ${BLUE}│${NC} Linktree       ${BLUE}│${NC} Vanilla    ${BLUE}│${NC} Sass     ${BLUE}│${NC} TypeScript ${BLUE}│${NC} :8001 ${BLUE}│${NC} %b    ${BLUE}│${NC}\n" "$_s2"
        printf "${BLUE}│${NC} ${GREEN}3${NC}   ${BLUE}│${NC} CV Web         ${BLUE}│${NC} Vanilla    ${BLUE}│${NC} Sass     ${BLUE}│${NC} TypeScript ${BLUE}│${NC} :8002 ${BLUE}│${NC} %b    ${BLUE}│${NC}\n" "$_s3"
        printf "${BLUE}│${NC} ${GREEN}4${NC}   ${BLUE}│${NC} MyFeed         ${BLUE}│${NC} Vue 3      ${BLUE}│${NC} Sass     ${BLUE}│${NC} TypeScript ${BLUE}│${NC} :8003 ${BLUE}│${NC} %b    ${BLUE}│${NC}\n" "$_s4"
        printf "${BLUE}│${NC} ${GREEN}5${NC}   ${BLUE}│${NC} MyGames        ${BLUE}│${NC} SvelteKit  ${BLUE}│${NC} Sass     ${BLUE}│${NC} TypeScript ${BLUE}│${NC} :8004 ${BLUE}│${NC} %b    ${BLUE}│${NC}\n" "$_s5"
        printf "${BLUE}│${NC} ${GREEN}6${NC}   ${BLUE}│${NC} Nexus          ${BLUE}│${NC} Vanilla    ${BLUE}│${NC} Sass+TW  ${BLUE}│${NC} TypeScript ${BLUE}│${NC} :8005 ${BLUE}│${NC} %b    ${BLUE}│${NC}\n" "$_s6"
        printf "${BLUE}│${NC} ${GREEN}7${NC}   ${BLUE}│${NC} Cloud          ${BLUE}│${NC} Vanilla    ${BLUE}│${NC} Sass     ${BLUE}│${NC} TypeScript ${BLUE}│${NC} :8006 ${BLUE}│${NC} %b    ${BLUE}│${NC}\n" "$_s7"
        printf "${BLUE}│${NC} ${GREEN}8${NC}   ${BLUE}│${NC} Feed Yourself  ${BLUE}│${NC} Vanilla    ${BLUE}│${NC} Sass     ${BLUE}│${NC} Vanilla    ${BLUE}│${NC} :8007 ${BLUE}│${NC} %b    ${BLUE}│${NC}\n" "$_s8"
        printf "${BLUE}│${NC} ${GREEN}9${NC}   ${BLUE}│${NC} Others         ${BLUE}│${NC} Python     ${BLUE}│${NC} -        ${BLUE}│${NC} -          ${BLUE}│${NC} :8008 ${BLUE}│${NC} %b    ${BLUE}│${NC}\n" "$_s9"
        printf "${BLUE}│${NC} ${GREEN}10${NC}  ${BLUE}│${NC} Health Tracker ${BLUE}│${NC} Vanilla    ${BLUE}│${NC} Tailwind ${BLUE}│${NC} Vanilla    ${BLUE}│${NC} :8009 ${BLUE}│${NC} %b    ${BLUE}│${NC}\n" "$_s10"
        printf "${BLUE}│${NC} ${GREEN}11${NC}  ${BLUE}│${NC} Market Watch   ${BLUE}│${NC} Vanilla    ${BLUE}│${NC} Sass     ${BLUE}│${NC} TypeScript ${BLUE}│${NC} :8010 ${BLUE}│${NC} %b    ${BLUE}│${NC}\n" "$_s11"
        printf "${BLUE}│${NC} ${GREEN}12${NC}  ${BLUE}│${NC} Central Bank   ${BLUE}│${NC} Vanilla    ${BLUE}│${NC} Tailwind ${BLUE}│${NC} TypeScript ${BLUE}│${NC} :8011 ${BLUE}│${NC} %b    ${BLUE}│${NC}\n" "$_s12"
        printf "${BLUE}│${NC} ${GREEN}13${NC}  ${BLUE}│${NC} MyMaps         ${BLUE}│${NC} Next.js    ${BLUE}│${NC} Sass     ${BLUE}│${NC} TypeScript ${BLUE}│${NC} :8012 ${BLUE}│${NC} %b    ${BLUE}│${NC}\n" "$_s13"
        printf "${BLUE}│${NC} ${GREEN}14${NC}  ${BLUE}│${NC} MyProfile      ${BLUE}│${NC} Nuxt 4     ${BLUE}│${NC} Sass     ${BLUE}│${NC} TypeScript ${BLUE}│${NC} :8013 ${BLUE}│${NC} %b    ${BLUE}│${NC}\n" "$_s14"
        printf "${BLUE}└─────┴────────────────┴────────────┴──────────┴────────────┴───────┴────────┘${NC}\n"

        # Server status
        print_status_box

        # Show last action message if any
        if [ -n "$_last_msg" ]; then
            printf "${GREEN}[OK]${NC} %s\n\n" "$_last_msg"
        fi

        # Legend section
        printf "${BLUE}┌────────────────────────────────────────────────────────────────────────────┐${NC}\n"
        printf "${BLUE}│${NC}  ${YELLOW}COMMANDS${NC}                                                                  ${BLUE}│${NC}\n"
        printf "${BLUE}├────────────────────────────────────────────────────────────────────────────┤${NC}\n"
        printf "${BLUE}│${NC}  ${GREEN}B${NC}[n] Build project    ${GREEN}D${NC}[n] Start dev server    ${GREEN}0${NC} All projects             ${BLUE}│${NC}\n"
        printf "${BLUE}│${NC}  ${GREEN}K${NC}    Kill servers     ${GREEN}H${NC}    Help (full docs)    ${GREEN}Q${NC} Quit                     ${BLUE}│${NC}\n"
        printf "${BLUE}├────────────────────────────────────────────────────────────────────────────┤${NC}\n"
        printf "${BLUE}│${NC}  ${CYAN}Examples:${NC}  D3  D11  B0  K                                                 ${BLUE}│${NC}\n"
        printf "${BLUE}└────────────────────────────────────────────────────────────────────────────┘${NC}\n"

        # Input prompt
        printf "\n${YELLOW}Enter command:${NC} "

        read -r _choice

        # Convert to lowercase for easier matching
        _choice_lower=$(echo "$_choice" | tr '[:upper:]' '[:lower:]')

        case "$_choice_lower" in
            # Build commands
            b|b0)              _cmd="build"; _last_msg="Building all projects..." ;;
            b1)                _cmd="build-landpage"; _last_msg="Building Landpage" ;;
            b2)                _cmd="build-linktree"; _last_msg="Building Linktree" ;;
            b3)                _cmd="build-cv-web"; _last_msg="Building CV Web" ;;
            b4)                _cmd="build-myfeed"; _last_msg="Building MyFeed" ;;
            b5)                _cmd="build-mygames"; _last_msg="Building MyGames" ;;
            b6)                _cmd="build-nexus"; _last_msg="Building Nexus" ;;
            b7)                _cmd="build-cloud"; _last_msg="Building Cloud" ;;
            b8)                _cmd="build-feed"; _last_msg="Building Feed Yourself" ;;
            b9)                _cmd="build-others"; _last_msg="Building Others" ;;
            b10)               _cmd="build-health"; _last_msg="Building Health Tracker" ;;
            b11)               _cmd="build-market"; _last_msg="Building Market Watch" ;;
            b12)               _cmd="build-centralbank"; _last_msg="Building Central Bank" ;;
            b13)               _cmd="build-mymaps"; _last_msg="Building MyMaps" ;;
            b14)               _cmd="build-myprofile"; _last_msg="Building MyProfile" ;;
            # Dev commands
            d|d0)              _cmd="dev"; _last_msg="Starting all dev servers..." ;;
            d1)                _cmd="dev-landpage"; _last_msg="Started Landpage :8000" ;;
            d2)                _cmd="dev-linktree"; _last_msg="Started Linktree :8001" ;;
            d3)                _cmd="dev-cv-web"; _last_msg="Started CV Web :8002" ;;
            d4)                _cmd="dev-myfeed"; _last_msg="Started MyFeed :8003" ;;
            d5)                _cmd="dev-mygames"; _last_msg="Started MyGames :8004" ;;
            d6)                _cmd="dev-nexus"; _last_msg="Started Nexus :8005" ;;
            d7)                _cmd="dev-cloud"; _last_msg="Started Cloud :8006" ;;
            d8)                _cmd="dev-feed"; _last_msg="Started Feed Yourself :8007" ;;
            d9)                _cmd="dev-others"; _last_msg="Started Others :8008" ;;
            d10)               _cmd="dev-health"; _last_msg="Started Health Tracker :8009" ;;
            d11)               _cmd="dev-market"; _last_msg="Started Market Watch :8010" ;;
            d12)               _cmd="dev-centralbank"; _last_msg="Started Central Bank :8011" ;;
            d13)               _cmd="dev-mymaps"; _last_msg="Started MyMaps :8012" ;;
            d14)               _cmd="dev-myprofile"; _last_msg="Started MyProfile :8013" ;;
            # Utility commands
            k|kill)            _cmd="kill"; _last_msg="Killed all servers" ;;
            c|clean)           _cmd="clean"; _last_msg="Cleaned build artifacts" ;;
            h|help)
                clear
                print_usage
                printf "\n${CYAN}Press any key to return to TUI...${NC}"
                _old_tty=$(stty -g 2>/dev/null)
                stty -icanon min 1 time 0 2>/dev/null
                dd bs=1 count=1 >/dev/null 2>&1
                stty "$_old_tty" 2>/dev/null
                continue
                ;;
            q|quit|exit)
                clear
                printf "${GREEN}Goodbye!${NC}\n"
                exit 0
                ;;
            "")
                continue
                ;;
            *)
                _last_msg="Invalid: $_choice"
                continue
                ;;
        esac

        # Run command silently in background
        case "$_cmd" in
            dev-landpage)    sh "$PROJECT_ROOT/landpage/1.ops/build.sh" dev > /dev/null 2>&1 & ;;
            dev-linktree)    sh "$PROJECT_ROOT/linktree/1.ops/build.sh" dev > /dev/null 2>&1 & ;;
            dev-cv-web)      sh "$PROJECT_ROOT/cv_web/1.ops/build.sh" dev > /dev/null 2>&1 & ;;
            dev-myfeed)      sh "$PROJECT_ROOT/myfeed/1.ops/build.sh" dev > /dev/null 2>&1 & ;;
            dev-mygames)     sh "$PROJECT_ROOT/mygames/1.ops/build.sh" dev > /dev/null 2>&1 & ;;
            dev-nexus)       sh "$PROJECT_ROOT/nexus/1.ops/build.sh" dev > /dev/null 2>&1 & ;;
            dev-cloud)       sh "$PROJECT_ROOT/cloud/1.ops/build.sh" dev > /dev/null 2>&1 & ;;
            dev-feed)        sh "$PROJECT_ROOT/feed_yourself/1.ops/build.sh" dev > /dev/null 2>&1 & ;;
            dev-others)      sh "$PROJECT_ROOT/others/1.ops/build.sh" dev > /dev/null 2>&1 & ;;
            dev-health)      sh "$PROJECT_ROOT/health_tracker/1.ops/build.sh" dev > /dev/null 2>&1 & ;;
            dev-market)      sh "$PROJECT_ROOT/market_watch/1.ops/build.sh" dev > /dev/null 2>&1 & ;;
            dev-centralbank) sh "$PROJECT_ROOT/central_bank/1.ops/build.sh" dev > /dev/null 2>&1 & ;;
            dev-mymaps)      sh "$PROJECT_ROOT/mymaps/1.ops/build.sh" dev > /dev/null 2>&1 & ;;
            dev-myprofile)   sh "$PROJECT_ROOT/myprofile/1.ops/build.sh" dev > /dev/null 2>&1 & ;;
            dev)             dev_all > /dev/null 2>&1 & ;;
            kill)            kill_servers > /dev/null 2>&1 ;;
            build-landpage)    sh "$PROJECT_ROOT/landpage/1.ops/build.sh" build > /dev/null 2>&1 & ;;
            build-linktree)    sh "$PROJECT_ROOT/linktree/1.ops/build.sh" build > /dev/null 2>&1 & ;;
            build-cv-web)      sh "$PROJECT_ROOT/cv_web/1.ops/build.sh" build > /dev/null 2>&1 & ;;
            build-myfeed)      sh "$PROJECT_ROOT/myfeed/1.ops/build.sh" build > /dev/null 2>&1 & ;;
            build-mygames)   sh "$PROJECT_ROOT/mygames/1.ops/build.sh" build > /dev/null 2>&1 & ;;
            build-nexus)       sh "$PROJECT_ROOT/nexus/1.ops/build.sh" build > /dev/null 2>&1 & ;;
            build-cloud)       sh "$PROJECT_ROOT/cloud/1.ops/build.sh" build > /dev/null 2>&1 & ;;
            build-feed)        sh "$PROJECT_ROOT/feed_yourself/1.ops/build.sh" build > /dev/null 2>&1 & ;;
            build-others)      sh "$PROJECT_ROOT/others/1.ops/build.sh" build > /dev/null 2>&1 & ;;
            build-health)      sh "$PROJECT_ROOT/health_tracker/1.ops/build.sh" build > /dev/null 2>&1 & ;;
            build-market)      sh "$PROJECT_ROOT/market_watch/1.ops/build.sh" build > /dev/null 2>&1 & ;;
            build-centralbank) sh "$PROJECT_ROOT/central_bank/1.ops/build.sh" build > /dev/null 2>&1 & ;;
            build-mymaps)      sh "$PROJECT_ROOT/mymaps/1.ops/build.sh" build > /dev/null 2>&1 & ;;
            build-myprofile)   sh "$PROJECT_ROOT/myprofile/1.ops/build.sh" build > /dev/null 2>&1 & ;;
            build)           build_all > /dev/null 2>&1 & ;;
            clean)           clean_all > /dev/null 2>&1 ;;
        esac

        # Small delay to let processes start
        sleep 0.5
    done
}

# Main execution
main() {
    # Show TUI if no argument provided
    if [ $# -eq 0 ]; then
        tui_simple
        exit 0
    fi

    # Show help for -h/--help
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        print_banner
        print_usage
        exit 0
    fi

    _action="$1"
    _force="false"
    _verbose="false"

    # Parse options
    shift 2>/dev/null || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --force|-f)
                _force="true"
                shift
                ;;
            --verbose|-v)
                _verbose="true"
                set -x
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done

    print_banner

    case "$_action" in
        build)
            build_all "$_force"
            ;;
        build-landpage)
            execute_build "landpage" "build"
            ;;
        build-linktree)
            execute_build "linktree" "build"
            ;;
        build-cv-web)
            execute_build "cv_web" "build"
            ;;
        build-myfeed)
            execute_build "myfeed" "build"
            ;;
        build-mygames)
            execute_build "mygames" "build"
            ;;
        build-nexus)
            execute_build "nexus" "build"
            ;;
        build-cloud)
            execute_build "cloud" "build"
            ;;
        build-feed)
            execute_build "feed_yourself" "build"
            ;;
        build-others)
            execute_build "others" "build"
            ;;
        build-health)
            execute_build "health_tracker" "build"
            ;;
        build-market)
            execute_build "market_watch" "build"
            ;;
        build-centralbank)
            execute_build "central_bank" "build"
            ;;
        build-mymaps)
            execute_build "mymaps" "build"
            ;;
        build-myprofile)
            execute_build "myprofile" "build"
            ;;
        dev)
            dev_all "$_verbose"
            ;;
        dev-landpage)
            dev_single "landpage" "$URL_LANDPAGE"
            ;;
        dev-linktree)
            dev_single "linktree" "$URL_LINKTREE"
            ;;
        dev-cv-web)
            dev_single "cv-web" "$URL_CV_WEB" "watcher"
            ;;
        dev-myfeed)
            dev_single "myfeed" "$URL_MYFEED"
            ;;
        dev-mygames)
            dev_single "mygames" "$URL_MYGAMES"
            ;;
        dev-nexus)
            dev_single "nexus" "$URL_NEXUS"
            ;;
        dev-cloud)
            dev_single "cloud" "$URL_CLOUD"
            ;;
        dev-feed)
            dev_single "feed" "$URL_FEED"
            ;;
        dev-others)
            dev_single "others" "$URL_OTHERS"
            ;;
        dev-health)
            dev_single "health" "$URL_HEALTH"
            ;;
        dev-market)
            dev_single "market" "$URL_MARKET"
            ;;
        dev-centralbank)
            dev_single "centralbank" "$URL_CENTRALBANK"
            ;;
        dev-mymaps)
            dev_single "mymaps" "$URL_MYMAPS"
            ;;
        dev-myprofile)
            dev_single "myprofile" "$URL_MYPROFILE"
            ;;
        list)
            list_servers
            ;;
        kill)
            kill_servers
            ;;
        clean)
            clean_all_builds
            ;;
        clean-all)
            clean_deep
            ;;
        test)
            run_tests
            ;;
        help)
            print_usage
            ;;
        *)
            log_error "Unknown command: $_action"
            printf "\n"
            print_usage
            ;;
    esac
}

# Run main function
main "$@"
