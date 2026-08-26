#!/bin/sh
#=====================================
# LANDPAGE BUILD SCRIPT
#=====================================
# POSIX-compliant build script
# Usage: ./1.ops/build.sh [action]

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Project paths
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="Landpage"
PORT="8000"
DIST_DIR="$PROJECT_DIR/dist"
SRC_STATIC="$PROJECT_DIR/src_static"

# Logging
log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }
log_warning() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }

# Help menu
print_usage() {
    printf "${BLUE}===========================================================================${NC}\n"
    printf "${CYAN}  ${PROJECT_NAME} Build Script${NC}\n"
    printf "${BLUE}===========================================================================${NC}\n"
    printf "\n"
    printf "${YELLOW}USAGE:${NC}  ./1.ops/build.sh [action]\n"
    printf "\n"
    printf "${YELLOW}BUILD:${NC}\n"
    printf "  ${GREEN}build${NC}        # Build Sass and TypeScript (production)\n"
    printf "\n"
    printf "${YELLOW}DEV SERVER:${NC}\n"
    printf "  ${GREEN}dev${NC}          # Watch Sass and TypeScript + live-server\n"
    printf "\n"
    printf "${YELLOW}UTILITY:${NC}\n"
    printf "  ${GREEN}clean${NC}        # Clean build artifacts\n"
    printf "  ${GREEN}help${NC}         # Show this help\n"
    printf "\n"
    printf "${YELLOW}PROJECT INFO:${NC}\n"
    printf "${BLUE}---------------------------------------------------------------------------${NC}\n"
    printf "  ${MAGENTA}%-12s  %-10s  %-10s  %-10s  %-14s  %s${NC}\n" "Project" "Framework" "CSS" "JavaScript" "Dev Server" "Watch"
    printf "${BLUE}---------------------------------------------------------------------------${NC}\n"
    printf "  ${CYAN}%-12s${NC}  %-10s  %-10s  %-10s  ${GREEN}%-14s${NC}  ${YELLOW}%s${NC}\n" "Landpage" "Vanilla" "Sass" "TypeScript" "npm-live :${PORT}" "Sass, TS"
    printf "${BLUE}---------------------------------------------------------------------------${NC}\n"
    printf "\n"
}

# Check and install dependencies for scss
check_scss_deps() {
    if [ -d "$SRC_STATIC/scss/node_modules" ]; then
        return 0
    fi
    log_info "Installing SCSS dependencies..."
    cd "$SRC_STATIC/scss"
    npm install
}

# Check and install dependencies for typescript
check_ts_deps() {
    if [ -d "$SRC_STATIC/typescript/node_modules" ]; then
        return 0
    fi
    log_info "Installing TypeScript dependencies..."
    cd "$SRC_STATIC/typescript"
    npm install
}

# Build SCSS to CSS
build_scss() {
    log_info "Building SCSS..."
    check_scss_deps
    cd "$SRC_STATIC/scss"

    if [ "$1" = "dev" ]; then
        npx sass style.scss:../style.css --style=expanded --source-map
    else
        npx sass style.scss:../style.css --style=compressed --no-source-map
    fi

    log_success "SCSS compiled successfully"
}

# Build TypeScript to JavaScript
build_typescript() {
    log_info "Building TypeScript..."
    check_ts_deps
    cd "$SRC_STATIC/typescript"

    if [ "$1" = "dev" ]; then
        npx tsc --sourceMap
    else
        npx tsc
    fi

    # Move output to src_static
    if [ -f "script.js" ]; then
        mv script.js ../script.js
    fi
    if [ -f "script.js.map" ]; then
        mv script.js.map ../script.js.map
    fi

    log_success "TypeScript compiled successfully"
}

# Build for production
build() {
    log_info "Building ${PROJECT_NAME} for production..."

    build_scss "prod"
    build_typescript "prod"

    # Clean and create dist directory
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"

    # Create symlinks for media assets
    ln -sf ../public "$DIST_DIR/public"

    # Copy files temporarily for single-file build
    cp "$SRC_STATIC/index.html" "$DIST_DIR/"
    cp "$SRC_STATIC/style.css" "$DIST_DIR/"
    cp "$SRC_STATIC/script.js" "$DIST_DIR/"

    build_single_file

    # Clean up intermediate files, keep only SPA
    rm -f "$DIST_DIR/style.css" "$DIST_DIR/script.js"
    mv "$DIST_DIR/index_spa.html" "$DIST_DIR/index.html"

    log_success "Build completed → $DIST_DIR"
}

# Build single-file HTML (inline CSS + JS)
build_single_file() {
    log_info "Building single-file HTML..."

    _html_file="$DIST_DIR/index.html"
    _css_file="$DIST_DIR/style.css"
    _js_file="$DIST_DIR/script.js"
    _output_file="$DIST_DIR/index_spa.html"

    if [ ! -f "$_html_file" ]; then
        log_warning "index.html not found, skipping single-file build"
        return 0
    fi

    # Strip BOM from CSS if present (Sass outputs UTF-8 BOM which breaks inlined CSS)
    if [ -f "$_css_file" ]; then
        sed -i '1s/^\xEF\xBB\xBF//' "$_css_file"
    fi

    # Create single-file HTML using awk with file reading (avoids backslash escape issues)
    awk '
    /<link[^>]*href="style\.css[^"]*"[^>]*>/ {
        print "<style>"
        while ((getline line < "'"$_css_file"'") > 0) print line
        close("'"$_css_file"'")
        print "</style>"
        next
    }
    /<script[^>]*src="script\.js[^"]*"[^>]*>/ {
        print "<script>"
        while ((getline line < "'"$_js_file"'") > 0) print line
        close("'"$_js_file"'")
        print "</script>"
        next
    }
    { print }
    ' "$_html_file" > "$_output_file"

    log_success "Single-file build → $_output_file"
}

# Development mode with watch
dev() {
    log_info "Starting development mode..."

    # Build once first
    build_scss "dev"
    build_typescript "dev"

    cd "$SRC_STATIC"

    # Start SCSS watcher in background
    cd scss
    nohup npx sass --watch style.scss:../style.css --style=expanded > /dev/null 2>&1 &
    cd ..

    # Start TypeScript watcher in background
    cd typescript
    nohup npx tsc --watch > /dev/null 2>&1 &
    cd ..

    # Start live-server
    nohup npx live-server . --port=${PORT} --no-browser --quiet > /dev/null 2>&1 &

    # Print URL and return control
    printf "\n"
    printf "${GREEN}+----------------------------------------------------------+${NC}\n"
    printf "${GREEN}|${NC}  ${CYAN}${PROJECT_NAME} Dev Server STARTED${NC}\n"
    printf "${GREEN}+----------------------------------------------------------+${NC}\n"
    printf "${GREEN}|${NC}  ${YELLOW}URL:${NC}  ${BLUE}http://localhost:${PORT}/${NC}\n"
    printf "${GREEN}|${NC}  ${YELLOW}Stop:${NC} ./1.ops/build_main.sh kill\n"
    printf "${GREEN}+----------------------------------------------------------+${NC}\n"
    printf "\n"
}

# Clean build artifacts
clean() {
    log_info "Cleaning build artifacts..."

    rm -f "$SRC_STATIC/style.css"
    rm -f "$SRC_STATIC/style.css.map"
    rm -f "$SRC_STATIC/script.js"
    rm -f "$SRC_STATIC/script.js.map"

    if [ -d "$DIST_DIR" ]; then
        rm -rf "$DIST_DIR"
        log_success "Dist directory cleaned"
    fi

    log_success "Build artifacts cleaned"
}

# Main
main() {
    _action="${1:-help}"

    case "$_action" in
        build)      build ;;
        dev)        dev ;;
        clean)      clean ;;
        help|-h|--help) print_usage ;;
        *)          print_usage ;;
    esac
}

main "$@"
