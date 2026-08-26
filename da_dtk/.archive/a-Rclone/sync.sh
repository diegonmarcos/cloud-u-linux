#!/bin/bash
# Rclone Sync Manager - Unified sync manager for cloud and local folders
# Author: Diego Nepomuceno Marcos
# Version: 1.0

set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================

SYNC_DIR="/home/diego/mnt_syncs"
CONFIG_DIR="$HOME/.config/rclone_manager"
RULES_FILE="$SYNC_DIR/sync.json"      # Local rules file (user-editable)
JOBS_FILE="$CONFIG_DIR/sync_jobs.json"       # Jobs tracking (auto-managed)
LOG_DIR="$CONFIG_DIR/logs"
LOG_FILE="$SYNC_DIR/.sync.log"

# Google Drive accounts reference
# Gdrive_dnm = diegonmarcos1@gmail.com
# Gdrive_me  = me@diegonmarcos.com

# Default paths
DEFAULT_BISYNC_BASE="$HOME/Documents/Gdrive_Syncs"
DEFAULT_REMOTE="Gdrive_dnm"

# Rclone options
RCLONE_OPTS="--tpslimit 10 --drive-skip-gdocs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# Unicode symbols
SYM_CHECK="✓"
SYM_CROSS="✗"
SYM_DOT="●"
SYM_CIRCLE="○"
SYM_ARROW="→"
SYM_ARROW_BI="↔"
SYM_ARROW_LEFT="←"
SYM_WARN="⚠"
SYM_PLAY="▶"
SYM_STOP="■"

# ==============================================================================
# INITIALIZATION
# ==============================================================================

init() {
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"
    [ ! -f "$JOBS_FILE" ] && echo "[]" > "$JOBS_FILE"

    # Create sample rules file if not exists
    if [ ! -f "$RULES_FILE" ]; then
        cat > "$RULES_FILE" << 'SAMPLE'
[
  {
    "_comment": "Sample sync rules - edit this file to add your own rules",
    "_schema": {
      "name": "Unique rule name",
      "local_path": "Source path (local folder)",
      "remote": "Destination (Gdrive_dnm:path or local path)",
      "sync_type": "bisync | sync_to_remote | sync_to_local | local_to_local | local_bisync",
      "conflict_resolve": "newer | larger | path1 | path2",
      "delete_extra": "true | false (delete files in dest not in source)",
      "enabled": "true | false"
    }
  },
  {
    "name": "Example_Docs",
    "local_path": "/home/diego/Documents/Example",
    "remote": "Gdrive_dnm:Backups/Example",
    "sync_type": "bisync",
    "conflict_resolve": "newer",
    "delete_extra": true,
    "enabled": false,
    "last_run": null,
    "created": "2024-01-01T00:00:00"
  }
]
SAMPLE
        log_debug "Created sample rules file: $RULES_FILE"
    fi

    # Rotate log if > 1MB
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
    fi
    touch "$LOG_FILE"
}

# ==============================================================================
# LOGGING
# ==============================================================================

log_debug() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

log_error() {
    printf "[%s] ERROR: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

# ==============================================================================
# HELPERS
# ==============================================================================

print_header() {
    printf "\n${CYAN}${BOLD}%s${NC}\n" "$1"
    printf "%s\n" "$(echo "$1" | sed 's/./-/g')"
}

log() { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error() { printf "${RED}[-]${NC} %s\n" "$1"; }
info() { printf "${CYAN}[i]${NC} %s\n" "$1"; }

confirm() {
    printf "${YELLOW}%s [y/N]:${NC} " "$1"
    read -r answer
    case "$answer" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# Check if jq is available
check_jq() {
    if ! command -v jq &>/dev/null; then
        error "jq is required but not installed"
        echo "Install with: sudo pacman -S jq"
        exit 1
    fi
}

# Check if rclone is available
check_rclone() {
    if ! command -v rclone &>/dev/null; then
        error "rclone is required but not installed"
        exit 1
    fi
}

# Get list of rclone remotes
get_remotes() {
    rclone listremotes 2>/dev/null | sed 's/:$//'
}

# Check if remote exists
remote_exists() {
    rclone listremotes 2>/dev/null | grep -q "^${1}:$"
}

# Generate unique job ID
generate_job_id() {
    echo "job_$(date '+%Y%m%d_%H%M%S')_$$"
}

# ==============================================================================
# SYNC RULES MANAGEMENT
# ==============================================================================

# List all rules (filter out schema/comment entries)
list_rules() {
    check_jq
    if [ ! -s "$RULES_FILE" ] || [ "$(cat "$RULES_FILE")" = "[]" ]; then
        echo "[]"
        return
    fi
    # Filter out entries that have _comment or _schema (documentation entries)
    cat "$RULES_FILE" | jq '[.[] | select(has("name") and (.name | startswith("_") | not))]'
}

# Get schema/documentation entries from rules file
get_schema_entries() {
    check_jq
    if [ ! -s "$RULES_FILE" ]; then
        echo "[]"
        return
    fi
    cat "$RULES_FILE" | jq '[.[] | select(has("_comment") or has("_schema"))]'
}

# Save rules while preserving schema entries
save_rules() {
    local rules="$1"
    check_jq

    local schema=$(get_schema_entries)
    # Merge schema entries with rules
    echo "$schema $rules" | jq -s 'add' > "$RULES_FILE"
}

# Get rule count
rule_count() {
    list_rules | jq 'length'
}

# Get enabled rule count
enabled_rule_count() {
    list_rules | jq '[.[] | select(.enabled == true)] | length'
}

# Get rule by name
get_rule() {
    local name="$1"
    list_rules | jq -r ".[] | select(.name == \"$name\")"
}

# Add a new rule
add_rule() {
    local name="$1"
    local local_path="$2"
    local remote="$3"
    local sync_type="$4"
    local conflict_resolve="${5:-newer}"
    local delete_extra="${6:-true}"

    check_jq

    # Check for duplicate
    if [ -n "$(get_rule "$name")" ]; then
        error "Rule '$name' already exists"
        return 1
    fi

    local now=$(date -Iseconds)
    local new_rule=$(cat <<EOF
{
  "name": "$name",
  "local_path": "$local_path",
  "remote": "$remote",
  "sync_type": "$sync_type",
  "conflict_resolve": "$conflict_resolve",
  "delete_extra": $delete_extra,
  "enabled": true,
  "last_run": null,
  "created": "$now"
}
EOF
)

    local rules=$(list_rules)
    local updated=$(echo "$rules" | jq ". + [$new_rule]")
    save_rules "$updated"
    log_debug "Added rule: $name"
    return 0
}

# Delete a rule
delete_rule() {
    local name="$1"
    check_jq

    local rules=$(list_rules)
    local updated=$(echo "$rules" | jq "del(.[] | select(.name == \"$name\"))")
    save_rules "$updated"
    log_debug "Deleted rule: $name"
}

# Toggle rule enabled/disabled
toggle_rule() {
    local name="$1"
    check_jq

    local rules=$(list_rules)
    local current=$(echo "$rules" | jq -r ".[] | select(.name == \"$name\") | .enabled")
    local new_state="true"
    [ "$current" = "true" ] && new_state="false"

    local updated=$(echo "$rules" | jq "(.[] | select(.name == \"$name\") | .enabled) = $new_state")
    save_rules "$updated"
    log_debug "Toggled rule $name: enabled=$new_state"
}

# Update last_run for a rule
update_last_run() {
    local name="$1"
    check_jq

    local now=$(date -Iseconds)
    local rules=$(list_rules)
    local updated=$(echo "$rules" | jq "(.[] | select(.name == \"$name\") | .last_run) = \"$now\"")
    save_rules "$updated"
}

# ==============================================================================
# SYNC JOBS MANAGEMENT
# ==============================================================================

# List all jobs
list_jobs() {
    check_jq
    if [ ! -s "$JOBS_FILE" ] || [ "$(cat "$JOBS_FILE")" = "[]" ]; then
        echo "[]"
        return
    fi
    cat "$JOBS_FILE"
}

# Add a job
add_job() {
    local job_id="$1"
    local name="$2"
    local source="$3"
    local dest="$4"
    local sync_type="$5"
    local pid="$6"
    local log_file="$7"

    check_jq

    local now=$(date -Iseconds)
    local new_job=$(cat <<EOF
{
  "job_id": "$job_id",
  "name": "$name",
  "source": "$source",
  "dest": "$dest",
  "sync_type": "$sync_type",
  "status": "running",
  "started": "$now",
  "ended": null,
  "pid": $pid,
  "log_file": "$log_file"
}
EOF
)

    local jobs=$(list_jobs)
    # Keep only last 20 jobs
    jobs=$(echo "$jobs" | jq '. | if length > 19 then .[-19:] else . end')
    echo "$jobs" | jq ". + [$new_job]" > "$JOBS_FILE"
}

# Update job status
update_job() {
    local job_id="$1"
    local status="$2"

    check_jq

    local now=$(date -Iseconds)
    local jobs=$(list_jobs)
    echo "$jobs" | jq "(.[] | select(.job_id == \"$job_id\") | .status) = \"$status\" | (.[] | select(.job_id == \"$job_id\") | .ended) = \"$now\"" > "$JOBS_FILE"
}

# Get running jobs (verify PIDs are still alive)
get_running_jobs() {
    check_jq

    local jobs=$(list_jobs)
    local updated=false
    local result="[]"

    while IFS= read -r job; do
        [ -z "$job" ] && continue

        local job_id=$(echo "$job" | jq -r '.job_id')
        local status=$(echo "$job" | jq -r '.status')
        local pid=$(echo "$job" | jq -r '.pid')

        if [ "$status" = "running" ]; then
            if kill -0 "$pid" 2>/dev/null; then
                result=$(echo "$result" | jq ". + [$job]")
            else
                # Process died, update status
                local log_file=$(echo "$job" | jq -r '.log_file')
                local new_status="completed"
                if [ -f "$log_file" ] && grep -qE "ERROR|FAILED" "$log_file" 2>/dev/null; then
                    new_status="failed"
                fi
                update_job "$job_id" "$new_status"
            fi
        fi
    done < <(echo "$jobs" | jq -c '.[]')

    echo "$result"
}

# Cancel a running job
cancel_job() {
    local job_id="$1"
    check_jq

    local jobs=$(list_jobs)
    local pid=$(echo "$jobs" | jq -r ".[] | select(.job_id == \"$job_id\") | .pid")

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null
        update_job "$job_id" "cancelled"
        return 0
    fi
    return 1
}

# Clear completed jobs
clear_completed_jobs() {
    check_jq

    local jobs=$(list_jobs)
    local running=$(echo "$jobs" | jq '[.[] | select(.status == "running")]')
    local removed=$(($(echo "$jobs" | jq 'length') - $(echo "$running" | jq 'length')))

    echo "$running" > "$JOBS_FILE"
    echo "$removed"
}

# Get job progress from log file
get_job_progress() {
    local log_file="$1"

    if [ ! -f "$log_file" ]; then
        echo "Starting..."
        return
    fi

    # Parse rclone stats from log
    local percent=$(grep -oP '\d+%' "$log_file" 2>/dev/null | tail -1)
    local transferred=$(grep -oP 'Transferred:\s+\K[^,]+' "$log_file" 2>/dev/null | tail -1)
    local speed=$(grep -oP '\d+\.?\d*\s*[KMG]?i?B/s' "$log_file" 2>/dev/null | tail -1)
    local eta=$(grep -oP 'ETA\s+\K\S+' "$log_file" 2>/dev/null | tail -1)
    local errors=$(grep -c "ERROR" "$log_file" 2>/dev/null || echo 0)

    local result=""
    [ -n "$percent" ] && result="$percent"
    [ -n "$transferred" ] && result="$result | $transferred"
    [ -n "$speed" ] && result="$result | $speed"
    [ -n "$eta" ] && [ "$eta" != "-" ] && result="$result | ETA: $eta"
    [ "$errors" -gt 0 ] && result="$result | ${RED}Errors: $errors${NC}"

    if [ -n "$result" ]; then
        echo "$result"
    else
        local lines=$(wc -l < "$log_file" 2>/dev/null || echo 0)
        echo "Processing... ($lines log lines)"
    fi
}

# ==============================================================================
# SYNC OPERATIONS
# ==============================================================================

# One-way sync
sync_one_way() {
    local source="$1"
    local dest="$2"
    local dry_run="${3:-false}"
    local delete="${4:-true}"

    local cmd="rclone"
    if [ "$delete" = "true" ]; then
        cmd="$cmd sync"
    else
        cmd="$cmd copy"
    fi

    cmd="$cmd \"$source\" \"$dest\" $RCLONE_OPTS --verbose --progress"

    [ "$dry_run" = "true" ] && cmd="$cmd --dry-run"

    printf "\n${CYAN}${BOLD}Sync: %s ${SYM_ARROW} %s${NC}\n" "$source" "$dest"
    [ "$dry_run" = "true" ] && warn "DRY RUN - No changes will be made"

    log_debug "Running: $cmd"

    if eval $cmd; then
        log "Sync completed successfully"
        return 0
    else
        error "Sync failed"
        return 1
    fi
}

# Bidirectional sync
sync_bisync() {
    local path1="$1"
    local path2="$2"
    local dry_run="${3:-false}"
    local resync="${4:-false}"
    local conflict_resolve="${5:-newer}"

    # Check if bisync state exists
    local bisync_cache="$HOME/.cache/rclone/bisync"
    [ ! -d "$bisync_cache" ] && resync="true"

    local cmd="rclone bisync \"$path1\" \"$path2\" $RCLONE_OPTS --verbose"

    [ "$resync" = "true" ] && cmd="$cmd --resync"
    [ "$dry_run" = "true" ] && cmd="$cmd --dry-run"

    if [ "$conflict_resolve" = "path1" ] || [ "$conflict_resolve" = "path2" ]; then
        cmd="$cmd --conflict-resolve $conflict_resolve"
    fi

    printf "\n${CYAN}${BOLD}Bisync: %s ${SYM_ARROW_BI} %s${NC}\n" "$path1" "$path2"
    [ "$resync" = "true" ] && warn "Using --resync (first time or forced)"
    [ "$dry_run" = "true" ] && warn "DRY RUN - No changes will be made"

    log_debug "Running: $cmd"

    if eval $cmd; then
        log "Bisync completed successfully"
        return 0
    else
        error "Bisync failed"
        return 1
    fi
}

# Run a sync rule
run_rule() {
    local name="$1"
    local dry_run="${2:-false}"

    check_jq

    local rule=$(get_rule "$name")
    if [ -z "$rule" ]; then
        error "Rule '$name' not found"
        return 1
    fi

    local local_path=$(echo "$rule" | jq -r '.local_path')
    local remote=$(echo "$rule" | jq -r '.remote')
    local sync_type=$(echo "$rule" | jq -r '.sync_type')
    local conflict_resolve=$(echo "$rule" | jq -r '.conflict_resolve')
    local delete_extra=$(echo "$rule" | jq -r '.delete_extra')

    print_header "Running rule: $name"
    info "Type: $sync_type"
    info "Source: $local_path"
    info "Destination: $remote"

    # Ensure paths exist
    mkdir -p "$local_path" 2>/dev/null || true

    local success=false

    case "$sync_type" in
        bisync)
            sync_bisync "$remote" "$local_path" "$dry_run" "false" "$conflict_resolve" && success=true
            ;;
        sync_to_remote)
            sync_one_way "$local_path" "$remote" "$dry_run" "$delete_extra" && success=true
            ;;
        sync_to_local)
            sync_one_way "$remote" "$local_path" "$dry_run" "$delete_extra" && success=true
            ;;
        local_to_local|local_bisync)
            mkdir -p "$remote" 2>/dev/null || true
            if [ "$sync_type" = "local_bisync" ]; then
                sync_bisync "$local_path" "$remote" "$dry_run" "false" "$conflict_resolve" && success=true
            else
                sync_one_way "$local_path" "$remote" "$dry_run" "$delete_extra" && success=true
            fi
            ;;
    esac

    if [ "$success" = "true" ] && [ "$dry_run" = "false" ]; then
        update_last_run "$name"
    fi

    return $([ "$success" = "true" ] && echo 0 || echo 1)
}

# Run rule in background
run_rule_background() {
    local name="$1"
    local resync="${2:-false}"

    check_jq

    local rule=$(get_rule "$name")
    if [ -z "$rule" ]; then
        error "Rule '$name' not found"
        return 1
    fi

    local local_path=$(echo "$rule" | jq -r '.local_path')
    local remote=$(echo "$rule" | jq -r '.remote')
    local sync_type=$(echo "$rule" | jq -r '.sync_type')
    local conflict_resolve=$(echo "$rule" | jq -r '.conflict_resolve')
    local delete_extra=$(echo "$rule" | jq -r '.delete_extra')

    # Ensure paths exist
    mkdir -p "$local_path" 2>/dev/null || true
    [ "$sync_type" = "local_to_local" ] || [ "$sync_type" = "local_bisync" ] && mkdir -p "$remote" 2>/dev/null || true

    local job_id=$(generate_job_id)
    local job_log="$LOG_DIR/${job_id}.log"

    # Determine source/dest based on type
    local source dest
    case "$sync_type" in
        bisync) source="$remote"; dest="$local_path" ;;
        sync_to_remote) source="$local_path"; dest="$remote" ;;
        sync_to_local) source="$remote"; dest="$local_path" ;;
        *) source="$local_path"; dest="$remote" ;;
    esac

    # Build command
    local cmd
    case "$sync_type" in
        bisync|local_bisync)
            cmd="rclone bisync '$source' '$dest' $RCLONE_OPTS -v --stats 3s --stats-log-level NOTICE"
            [ "$resync" = "true" ] && cmd="$cmd --resync"
            [ "$conflict_resolve" = "path1" ] || [ "$conflict_resolve" = "path2" ] && cmd="$cmd --conflict-resolve $conflict_resolve"
            ;;
        *)
            if [ "$delete_extra" = "true" ]; then
                cmd="rclone sync '$source' '$dest' $RCLONE_OPTS -v --stats 3s --stats-log-level NOTICE"
            else
                cmd="rclone copy '$source' '$dest' $RCLONE_OPTS -v --stats 3s --stats-log-level NOTICE"
            fi
            ;;
    esac

    # Start background process
    log_debug "Starting background job: $cmd"
    eval "$cmd" > "$job_log" 2>&1 &
    local pid=$!

    # Record job
    add_job "$job_id" "$name" "$source" "$dest" "$sync_type" "$pid" "$job_log"

    log "Started background sync: $name (PID: $pid)"
    info "Job ID: $job_id"
    info "Log: $job_log"

    echo "$job_id"
}

# Run all enabled rules
run_all_enabled() {
    local dry_run="${1:-false}"
    local background="${2:-false}"

    check_jq

    local rules=$(list_rules)
    local enabled=$(echo "$rules" | jq -c '[.[] | select(.enabled == true)]')
    local count=$(echo "$enabled" | jq 'length')

    if [ "$count" -eq 0 ]; then
        warn "No enabled rules found"
        return 1
    fi

    print_header "Running $count enabled rule(s)"

    local success=0
    local failed=0

    while IFS= read -r rule; do
        [ -z "$rule" ] && continue
        local name=$(echo "$rule" | jq -r '.name')

        if [ "$background" = "true" ]; then
            run_rule_background "$name" && ((success++)) || ((failed++))
        else
            run_rule "$name" "$dry_run" && ((success++)) || ((failed++))
        fi
    done < <(echo "$enabled" | jq -c '.[]')

    echo ""
    print_header "SYNC SUMMARY"
    log "Successful: $success"
    [ "$failed" -gt 0 ] && error "Failed: $failed"

    return $([ "$failed" -eq 0 ] && echo 0 || echo 1)
}

# ==============================================================================
# TUI - STATUS DISPLAY
# ==============================================================================

show_status() {
    check_jq

    printf "\n${CYAN}${BOLD}╔════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}${BOLD}║              Rclone Sync Manager Status                ║${NC}\n"
    printf "${CYAN}${BOLD}╚════════════════════════════════════════════════════════╝${NC}\n\n"

    # Remotes
    printf "${BLUE}${BOLD}Configured Remotes${NC}\n"
    printf "${DIM}────────────────────────────────────────────────────────${NC}\n"
    local remotes=$(get_remotes)
    if [ -n "$remotes" ]; then
        echo "$remotes" | while read -r remote; do
            case "$remote" in
                Gdrive_dnm) printf "  ${GREEN}${SYM_CHECK}${NC} %-20s ${DIM}(diegonmarcos1@gmail.com)${NC}\n" "$remote" ;;
                Gdrive_me)  printf "  ${GREEN}${SYM_CHECK}${NC} %-20s ${DIM}(me@diegonmarcos.com)${NC}\n" "$remote" ;;
                *)          printf "  ${GREEN}${SYM_CHECK}${NC} %s\n" "$remote" ;;
            esac
        done
    else
        printf "  ${DIM}No remotes configured${NC}\n"
    fi

    # Sync Rules
    printf "\n${BLUE}${BOLD}Sync Rules${NC}\n"
    printf "${DIM}────────────────────────────────────────────────────────${NC}\n"

    local rules=$(list_rules)
    local total=$(echo "$rules" | jq 'length')
    local enabled=$(echo "$rules" | jq '[.[] | select(.enabled == true)] | length')

    printf "  Total: %s | Enabled: ${GREEN}%s${NC} | Disabled: ${DIM}%s${NC}\n" "$total" "$enabled" "$((total - enabled))"

    if [ "$total" -gt 0 ]; then
        printf "\n"
        echo "$rules" | jq -c '.[]' | while read -r rule; do
            local name=$(echo "$rule" | jq -r '.name')
            local sync_type=$(echo "$rule" | jq -r '.sync_type')
            local is_enabled=$(echo "$rule" | jq -r '.enabled')
            local last_run=$(echo "$rule" | jq -r '.last_run // "never"')
            [ "$last_run" != "never" ] && last_run="${last_run:0:16}"

            local icon
            case "$sync_type" in
                bisync) icon="${SYM_ARROW_BI}" ;;
                sync_to_remote) icon="${SYM_ARROW}" ;;
                sync_to_local) icon="${SYM_ARROW_LEFT}" ;;
                local_bisync) icon="${SYM_ARROW_BI}" ;;
                local_to_local) icon="${SYM_ARROW}" ;;
                *) icon="?" ;;
            esac

            if [ "$is_enabled" = "true" ]; then
                printf "  ${GREEN}${SYM_DOT}${NC} %-20s [%s] ${DIM}last: %s${NC}\n" "$name" "$icon" "$last_run"
            else
                printf "  ${DIM}${SYM_CIRCLE} %-20s [%s] last: %s${NC}\n" "$name" "$icon" "$last_run"
            fi
        done
    fi

    # Running Jobs
    printf "\n${BLUE}${BOLD}Background Jobs${NC}\n"
    printf "${DIM}────────────────────────────────────────────────────────${NC}\n"

    local running=$(get_running_jobs)
    local running_count=$(echo "$running" | jq 'length')

    if [ "$running_count" -gt 0 ]; then
        printf "  ${GREEN}Running: %s${NC}\n\n" "$running_count"
        echo "$running" | jq -c '.[]' | while read -r job; do
            local name=$(echo "$job" | jq -r '.name')
            local job_id=$(echo "$job" | jq -r '.job_id')
            local pid=$(echo "$job" | jq -r '.pid')
            local log_file=$(echo "$job" | jq -r '.log_file')
            local started=$(echo "$job" | jq -r '.started')

            # Calculate elapsed time
            local start_epoch=$(date -d "$started" +%s 2>/dev/null || echo 0)
            local now_epoch=$(date +%s)
            local elapsed=$((now_epoch - start_epoch))
            local mins=$((elapsed / 60))
            local secs=$((elapsed % 60))

            printf "  ${GREEN}${SYM_PLAY}${NC} %s ${DIM}(%dm%ds)${NC}\n" "$name" "$mins" "$secs"
            printf "    ${DIM}PID: %s | ID: %s${NC}\n" "$pid" "$job_id"

            local progress=$(get_job_progress "$log_file")
            printf "    ${CYAN}%s${NC}\n" "$progress"
        done
    else
        printf "  ${DIM}No running jobs${NC}\n"
    fi

    # Recent completed jobs
    local all_jobs=$(list_jobs)
    local completed=$(echo "$all_jobs" | jq -c '[.[] | select(.status != "running")] | .[-5:]')
    local completed_count=$(echo "$completed" | jq 'length')

    if [ "$completed_count" -gt 0 ]; then
        printf "\n  ${DIM}Recent:${NC}\n"
        echo "$completed" | jq -c '.[]' | while read -r job; do
            local name=$(echo "$job" | jq -r '.name')
            local status=$(echo "$job" | jq -r '.status')
            local ended=$(echo "$job" | jq -r '.ended // ""')
            [ -n "$ended" ] && ended="${ended:0:16}"

            case "$status" in
                completed) printf "  ${GREEN}${SYM_CHECK}${NC} %s ${DIM}(%s)${NC}\n" "$name" "$ended" ;;
                failed)    printf "  ${RED}${SYM_CROSS}${NC} %s ${DIM}(%s)${NC}\n" "$name" "$ended" ;;
                cancelled) printf "  ${YELLOW}${SYM_STOP}${NC} %s ${DIM}(%s)${NC}\n" "$name" "$ended" ;;
            esac
        done
    fi

    # Log info
    printf "\n${BLUE}${BOLD}Debug Log${NC}\n"
    printf "${DIM}────────────────────────────────────────────────────────${NC}\n"
    if [ -f "$LOG_FILE" ]; then
        local log_lines=$(wc -l < "$LOG_FILE" | tr -d ' ')
        local log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
        local log_errors=$(grep -c "ERROR" "$LOG_FILE" 2>/dev/null || true)
        log_errors="${log_errors:-0}"
        printf "  ${DIM}Path:${NC}   %s\n" "$LOG_FILE"
        printf "  ${DIM}Lines:${NC}  %s  ${DIM}Size:${NC} %s  " "$log_lines" "$log_size"
        if [ "$log_errors" != "0" ] && [ -n "$log_errors" ]; then
            printf "${RED}Errors: %s${NC}\n" "$log_errors"
        else
            printf "${GREEN}No errors${NC}\n"
        fi
    else
        printf "  ${DIM}(No log file)${NC}\n"
    fi

    printf "\n"
}

# Compact status for TUI header
compact_status() {
    check_jq

    # Rules status
    local rules=$(list_rules)
    local total=$(echo "$rules" | jq 'length')
    local enabled=$(echo "$rules" | jq '[.[] | select(.enabled == true)] | length')
    printf "  ${BLUE}Rules:${NC}   ${GREEN}%s${NC}/%s enabled" "$enabled" "$total"

    # Jobs status
    local running=$(get_running_jobs)
    local running_count=$(echo "$running" | jq 'length')
    if [ "$running_count" -gt 0 ]; then
        printf "   ${BLUE}Jobs:${NC} ${GREEN}${SYM_PLAY}%s running${NC}" "$running_count"
    fi
    printf "\n"

    # Show running job names
    if [ "$running_count" -gt 0 ]; then
        echo "$running" | jq -r '.[].name' | head -3 | while read -r name; do
            printf "             ${DIM}${SYM_PLAY} %s${NC}\n" "$name"
        done
    fi
}

# ==============================================================================
# TUI - MENUS
# ==============================================================================

show_main_menu() {
    clear
    printf "${CYAN}${BOLD}"
    printf "╔══════════════════════════════════════════════════════════╗\n"
    printf "║            Rclone Sync Manager v1.0                      ║\n"
    printf "╚══════════════════════════════════════════════════════════╝${NC}\n\n"

    # Status bar
    printf "${DIM}───────────────────────── Status ─────────────────────────${NC}\n"
    compact_status
    printf "${DIM}───────────────────────────────────────────────────────────${NC}\n\n"

    # Quick Actions
    printf "${GREEN}${BOLD}▸ Quick Actions${NC}\n"
    printf "  ${GREEN}1${NC}  Run all enabled rules       ${GREEN}2${NC}  Quick sync (one-time)\n"
    printf "\n"

    # Rules Management
    printf "${BLUE}${BOLD}▸ Rules Management${NC}\n"
    printf "  ${BLUE}3${NC}  List rules                   ${BLUE}4${NC}  Add new rule\n"
    printf "  ${BLUE}5${NC}  Delete rule                  ${BLUE}6${NC}  Toggle rule (on/off)\n"
    printf "  ${BLUE}7${NC}  Run single rule\n"
    printf "\n"

    # Jobs & Status
    printf "${MAGENTA}${BOLD}▸ Jobs & Status${NC}\n"
    printf "  ${MAGENTA}j${NC}  View running jobs            ${MAGENTA}c${NC}  Cancel a job\n"
    printf "  ${MAGENTA}x${NC}  Clear completed jobs         ${MAGENTA}s${NC}  Full status\n"
    printf "\n"

    # Utils
    printf "${CYAN}${BOLD}▸ Utils${NC}\n"
    printf "  ${CYAN}r${NC}  Rclone config                ${CYAN}l${NC}  View log\n"
    printf "  ${CYAN}L${NC}  Clear log                    ${CYAN}q${NC}  Quit\n"
    printf "\n"

    printf "${BOLD}Choice:${NC} "
}

select_remote_menu() {
    local remotes=$(get_remotes)
    if [ -z "$remotes" ]; then
        error "No remotes configured. Run 'rclone config' first."
        return 1
    fi

    printf "\n${BOLD}Select Remote:${NC}\n"
    local i=1
    echo "$remotes" | while read -r remote; do
        case "$remote" in
            Gdrive_dnm) printf "  %d) %s ${DIM}(diegonmarcos1@gmail.com)${NC}\n" "$i" "$remote" ;;
            Gdrive_me)  printf "  %d) %s ${DIM}(me@diegonmarcos.com)${NC}\n" "$i" "$remote" ;;
            *)          printf "  %d) %s\n" "$i" "$remote" ;;
        esac
        i=$((i + 1))
    done
    printf "  0) Cancel\n"
    printf "Choice: "
    read -r choice

    [ "$choice" = "0" ] && return 1

    echo "$remotes" | sed -n "${choice}p"
}

select_sync_type_menu() {
    local include_local="${1:-false}"

    printf "\n${BOLD}Select Sync Type:${NC}\n"
    printf "  1) ${GREEN}Bisync${NC} (${SYM_ARROW_BI}) - Two-way sync\n"
    printf "  2) ${BLUE}Sync to Remote${NC} (${SYM_ARROW}) - Local overwrites remote\n"
    printf "  3) ${YELLOW}Sync to Local${NC} (${SYM_ARROW_LEFT}) - Remote overwrites local\n"
    [ "$include_local" = "true" ] && printf "  4) ${CYAN}Local to Local${NC} - Sync between local folders\n"
    printf "  0) Cancel\n"
    printf "Choice [1]: "
    read -r choice
    choice="${choice:-1}"

    case "$choice" in
        1) echo "bisync" ;;
        2) echo "sync_to_remote" ;;
        3) echo "sync_to_local" ;;
        4) [ "$include_local" = "true" ] && echo "local_to_local" || return 1 ;;
        0) return 1 ;;
        *) return 1 ;;
    esac
}

add_rule_wizard() {
    printf "\n${CYAN}${BOLD}━━━ Add New Sync Rule ━━━${NC}\n\n"

    # Rule name
    printf "Rule name: "
    read -r name
    [ -z "$name" ] && { error "Name is required"; return 1; }

    # Check duplicate
    if [ -n "$(get_rule "$name")" ]; then
        error "Rule '$name' already exists"
        return 1
    fi

    # Rule type
    printf "\n${BOLD}Rule type:${NC}\n"
    printf "  1) Remote sync (local ${SYM_ARROW_BI} cloud)\n"
    printf "  2) Local sync (local ${SYM_ARROW_BI} local)\n"
    printf "Choice [1]: "
    read -r rule_type
    rule_type="${rule_type:-1}"

    local local_path remote sync_type conflict_resolve delete_extra

    if [ "$rule_type" = "2" ]; then
        # Local to local
        printf "\nSource folder path: "
        read -r local_path
        [ -z "$local_path" ] && { error "Source path required"; return 1; }

        printf "Destination folder path: "
        read -r remote
        [ -z "$remote" ] && { error "Destination path required"; return 1; }

        printf "\n${BOLD}Sync direction:${NC}\n"
        printf "  1) One-way (source ${SYM_ARROW} dest, with deletions)\n"
        printf "  2) One-way copy (no deletions)\n"
        printf "  3) Bisync (${SYM_ARROW_BI} two-way)\n"
        printf "Choice [1]: "
        read -r dir_choice
        dir_choice="${dir_choice:-1}"

        case "$dir_choice" in
            1) sync_type="local_to_local"; delete_extra="true" ;;
            2) sync_type="local_to_local"; delete_extra="false" ;;
            3) sync_type="local_bisync"; delete_extra="true" ;;
            *) sync_type="local_to_local"; delete_extra="true" ;;
        esac

        conflict_resolve="newer"
        if [ "$sync_type" = "local_bisync" ]; then
            printf "\n${BOLD}Conflict resolution:${NC}\n"
            printf "  1) newer (default)\n"
            printf "  2) larger\n"
            printf "  3) path1 (source wins)\n"
            printf "  4) path2 (dest wins)\n"
            printf "Choice [1]: "
            read -r cr_choice
            case "$cr_choice" in
                2) conflict_resolve="larger" ;;
                3) conflict_resolve="path1" ;;
                4) conflict_resolve="path2" ;;
                *) conflict_resolve="newer" ;;
            esac
        fi
    else
        # Remote sync
        local remote_name=$(select_remote_menu)
        [ -z "$remote_name" ] && return 1

        printf "\nRemote path (empty for root): "
        read -r remote_path
        remote="${remote_name}:${remote_path}"

        printf "Local path [${DEFAULT_BISYNC_BASE}]: "
        read -r local_path
        local_path="${local_path:-$DEFAULT_BISYNC_BASE}"

        sync_type=$(select_sync_type_menu)
        [ -z "$sync_type" ] && return 1

        delete_extra="true"
        conflict_resolve="newer"

        if [ "$sync_type" = "bisync" ]; then
            printf "\n${BOLD}Conflict resolution:${NC}\n"
            printf "  1) newer (default)\n"
            printf "  2) larger\n"
            printf "  3) path1 (remote wins)\n"
            printf "  4) path2 (local wins)\n"
            printf "Choice [1]: "
            read -r cr_choice
            case "$cr_choice" in
                2) conflict_resolve="larger" ;;
                3) conflict_resolve="path1" ;;
                4) conflict_resolve="path2" ;;
                *) conflict_resolve="newer" ;;
            esac
        fi
    fi

    # Create rule
    if add_rule "$name" "$local_path" "$remote" "$sync_type" "$conflict_resolve" "$delete_extra"; then
        log "Rule '$name' created successfully!"
    else
        error "Failed to create rule"
        return 1
    fi
}

list_rules_menu() {
    check_jq

    printf "\n${CYAN}${BOLD}━━━ Sync Rules ━━━${NC}\n\n"

    local rules=$(list_rules)
    local count=$(echo "$rules" | jq 'length')

    if [ "$count" -eq 0 ]; then
        printf "${DIM}No rules configured${NC}\n"
        return
    fi

    local i=1
    echo "$rules" | jq -c '.[]' | while read -r rule; do
        local name=$(echo "$rule" | jq -r '.name')
        local local_path=$(echo "$rule" | jq -r '.local_path')
        local remote=$(echo "$rule" | jq -r '.remote')
        local sync_type=$(echo "$rule" | jq -r '.sync_type')
        local is_enabled=$(echo "$rule" | jq -r '.enabled')
        local last_run=$(echo "$rule" | jq -r '.last_run // "never"')
        [ "$last_run" != "never" ] && last_run="${last_run:0:16}"

        local icon status_icon
        case "$sync_type" in
            bisync|local_bisync) icon="${SYM_ARROW_BI}" ;;
            sync_to_remote|local_to_local) icon="${SYM_ARROW}" ;;
            sync_to_local) icon="${SYM_ARROW_LEFT}" ;;
            *) icon="?" ;;
        esac

        if [ "$is_enabled" = "true" ]; then
            status_icon="${GREEN}${SYM_DOT}${NC}"
        else
            status_icon="${DIM}${SYM_CIRCLE}${NC}"
        fi

        printf "%2d. %b %s\n" "$i" "$status_icon" "$name"
        printf "    ${DIM}%s %s %s${NC}\n" "$local_path" "$icon" "$remote"
        printf "    ${DIM}Type: %s | Last: %s${NC}\n\n" "$sync_type" "$last_run"

        i=$((i + 1))
    done
}

select_rule_menu() {
    local action="$1"

    check_jq

    local rules=$(list_rules)
    local count=$(echo "$rules" | jq 'length')

    if [ "$count" -eq 0 ]; then
        warn "No rules configured"
        return 1
    fi

    list_rules_menu

    printf "Select rule number (0 to cancel): "
    read -r choice

    [ "$choice" = "0" ] && return 1

    local name=$(echo "$rules" | jq -r ".[$((choice - 1))].name // empty")
    [ -z "$name" ] && { error "Invalid selection"; return 1; }

    echo "$name"
}

quick_sync_menu() {
    printf "\n${CYAN}${BOLD}━━━ Quick Sync ━━━${NC}\n\n"

    # Sync type first
    local sync_type=$(select_sync_type_menu "true")
    [ -z "$sync_type" ] && return 1

    local source dest

    if [ "$sync_type" = "local_to_local" ]; then
        printf "\nSource folder: "
        read -r source
        [ -z "$source" ] && { error "Source required"; return 1; }

        printf "Destination folder: "
        read -r dest
        [ -z "$dest" ] && { error "Destination required"; return 1; }
    else
        local remote_name=$(select_remote_menu)
        [ -z "$remote_name" ] && return 1

        printf "\nRemote path (empty for root): "
        read -r remote_path
        local remote="${remote_name}:${remote_path}"

        printf "Local path [${DEFAULT_BISYNC_BASE}]: "
        read -r local_path
        local_path="${local_path:-$DEFAULT_BISYNC_BASE}"

        case "$sync_type" in
            bisync) source="$remote"; dest="$local_path" ;;
            sync_to_remote) source="$local_path"; dest="$remote" ;;
            sync_to_local) source="$remote"; dest="$local_path" ;;
        esac
    fi

    # Run mode
    printf "\n${BOLD}Run mode:${NC}\n"
    printf "  1) Background (returns to menu)\n"
    printf "  2) Foreground (wait for completion)\n"
    printf "  3) Dry run (preview only)\n"
    printf "Choice [1]: "
    read -r mode
    mode="${mode:-1}"

    case "$mode" in
        1)
            # Background
            local job_id=$(generate_job_id)
            local job_log="$LOG_DIR/${job_id}.log"
            local cmd

            case "$sync_type" in
                bisync|local_bisync)
                    cmd="rclone bisync '$source' '$dest' $RCLONE_OPTS -v --stats 3s"
                    ;;
                *)
                    cmd="rclone sync '$source' '$dest' $RCLONE_OPTS -v --stats 3s"
                    ;;
            esac

            eval "$cmd" > "$job_log" 2>&1 &
            local pid=$!

            add_job "$job_id" "Quick Sync" "$source" "$dest" "$sync_type" "$pid" "$job_log"

            log "Started background sync (PID: $pid)"
            info "Job ID: $job_id"
            ;;
        2)
            # Foreground
            case "$sync_type" in
                bisync|local_bisync) sync_bisync "$source" "$dest" "false" ;;
                *) sync_one_way "$source" "$dest" "false" ;;
            esac
            ;;
        3)
            # Dry run
            case "$sync_type" in
                bisync|local_bisync) sync_bisync "$source" "$dest" "true" ;;
                *) sync_one_way "$source" "$dest" "true" ;;
            esac
            ;;
    esac
}

jobs_menu() {
    check_jq

    printf "\n${CYAN}${BOLD}━━━ Running Jobs ━━━${NC}\n\n"

    local running=$(get_running_jobs)
    local count=$(echo "$running" | jq 'length')

    if [ "$count" -eq 0 ]; then
        printf "${DIM}No running jobs${NC}\n"
        return
    fi

    local i=1
    echo "$running" | jq -c '.[]' | while read -r job; do
        local name=$(echo "$job" | jq -r '.name')
        local job_id=$(echo "$job" | jq -r '.job_id')
        local pid=$(echo "$job" | jq -r '.pid')
        local source=$(echo "$job" | jq -r '.source')
        local dest=$(echo "$job" | jq -r '.dest')
        local log_file=$(echo "$job" | jq -r '.log_file')
        local started=$(echo "$job" | jq -r '.started')

        # Calculate elapsed
        local start_epoch=$(date -d "$started" +%s 2>/dev/null || echo 0)
        local now_epoch=$(date +%s)
        local elapsed=$((now_epoch - start_epoch))
        local mins=$((elapsed / 60))
        local secs=$((elapsed % 60))

        printf "%d. ${GREEN}${SYM_PLAY}${NC} %s ${DIM}(%dm%ds)${NC}\n" "$i" "$name" "$mins" "$secs"
        printf "   ${DIM}PID: %s | ID: %s${NC}\n" "$pid" "$job_id"
        printf "   ${DIM}%s ${SYM_ARROW} %s${NC}\n" "$source" "$dest"

        local progress=$(get_job_progress "$log_file")
        printf "   ${CYAN}%s${NC}\n\n" "$progress"

        i=$((i + 1))
    done
}

view_log() {
    printf "\n${CYAN}${BOLD}━━━ Sync Log (last 30 lines) ━━━${NC}\n\n"

    if [ -f "$LOG_FILE" ]; then
        tail -30 "$LOG_FILE" | while IFS= read -r line; do
            case "$line" in
                *ERROR*) printf "${RED}%s${NC}\n" "$line" ;;
                *)       printf "${DIM}%s${NC}\n" "$line" ;;
            esac
        done
        printf "\n${DIM}Log path: %s${NC}\n" "$LOG_FILE"
    else
        printf "${DIM}No log file${NC}\n"
    fi
}

clear_log() {
    if [ -f "$LOG_FILE" ]; then
        : > "$LOG_FILE"
        log "Log cleared"
    fi
}

# ==============================================================================
# TUI MAIN LOOP
# ==============================================================================

run_tui() {
    check_jq
    check_rclone
    init

    while true; do
        show_main_menu
        read -r choice

        case "$choice" in
            # Quick Actions
            1)
                printf "\n${BOLD}Run mode:${NC}\n"
                printf "  1) Background\n"
                printf "  2) Foreground\n"
                printf "  3) Dry run\n"
                printf "Choice [1]: "
                read -r mode
                mode="${mode:-1}"

                case "$mode" in
                    1) run_all_enabled "false" "true" ;;
                    2) run_all_enabled "false" "false" ;;
                    3) run_all_enabled "true" "false" ;;
                esac
                ;;
            2) quick_sync_menu ;;

            # Rules Management
            3) list_rules_menu ;;
            4) add_rule_wizard ;;
            5)
                local rule_name=$(select_rule_menu "delete")
                if [ -n "$rule_name" ]; then
                    if confirm "Delete rule '$rule_name'?"; then
                        delete_rule "$rule_name"
                        log "Rule deleted"
                    fi
                fi
                ;;
            6)
                local rule_name=$(select_rule_menu "toggle")
                if [ -n "$rule_name" ]; then
                    toggle_rule "$rule_name"
                    log "Rule toggled"
                fi
                ;;
            7)
                local rule_name=$(select_rule_menu "run")
                if [ -n "$rule_name" ]; then
                    printf "\n${BOLD}Run mode:${NC}\n"
                    printf "  1) Background\n"
                    printf "  2) Foreground\n"
                    printf "  3) Dry run\n"
                    printf "Choice [1]: "
                    read -r mode
                    mode="${mode:-1}"

                    case "$mode" in
                        1) run_rule_background "$rule_name" ;;
                        2) run_rule "$rule_name" "false" ;;
                        3) run_rule "$rule_name" "true" ;;
                    esac
                fi
                ;;

            # Jobs & Status
            j|J) jobs_menu ;;
            c|C)
                local running=$(get_running_jobs)
                local count=$(echo "$running" | jq 'length')

                if [ "$count" -eq 0 ]; then
                    warn "No running jobs to cancel"
                else
                    jobs_menu
                    printf "Enter job number to cancel (0 to skip): "
                    read -r idx

                    if [ "$idx" != "0" ] && [ -n "$idx" ]; then
                        local job_id=$(echo "$running" | jq -r ".[$((idx - 1))].job_id // empty")
                        if [ -n "$job_id" ]; then
                            if cancel_job "$job_id"; then
                                log "Job cancelled"
                            else
                                error "Failed to cancel job"
                            fi
                        fi
                    fi
                fi
                ;;
            x|X)
                if confirm "Clear all completed jobs?"; then
                    local removed=$(clear_completed_jobs)
                    log "Cleared $removed job(s)"
                fi
                ;;
            s|S) show_status ;;

            # Utils
            r|R) rclone config ;;
            l) view_log ;;
            L) clear_log && log "Log cleared" ;;
            q|Q) printf "${GREEN}Bye!${NC}\n"; exit 0 ;;

            *) error "Invalid choice: $choice" ;;
        esac

        printf "\n${DIM}Press Enter to continue...${NC}"
        read -r _
    done
}

# ==============================================================================
# CLI INTERFACE
# ==============================================================================

show_help() {
    cat << 'EOF'
Rclone Sync Manager v1.0 - Unified sync manager for cloud and local folders

USAGE:
    sync.sh [COMMAND] [OPTIONS]

COMMANDS:
    (none)              Launch interactive TUI menu

    run                 Run all enabled sync rules
    run-bg              Run all enabled rules in background
    run-rule NAME       Run a specific rule

    list                List all sync rules
    add                 Add a new rule (interactive)
    delete NAME         Delete a rule
    toggle NAME         Toggle rule enabled/disabled

    sync SRC DEST       One-way sync (foreground)
    bisync P1 P2        Bidirectional sync (foreground)

    jobs                Show running jobs
    cancel JOB_ID       Cancel a running job
    clear-jobs          Clear completed jobs

    status              Show full status
    log                 View debug log
    log-clear           Clear debug log

    help, -h            Show this help

OPTIONS:
    --dry-run           Preview only, don't make changes
    --resync            Force full resync for bisync
    --background, -bg   Run in background

EXAMPLES:
    sync.sh                         # Launch TUI
    sync.sh run                     # Run all enabled rules
    sync.sh run-rule "My Docs"      # Run specific rule
    sync.sh sync ~/docs Gdrive:docs # One-way sync
    sync.sh bisync Gdrive:docs ~/docs --dry-run
    sync.sh jobs                    # Show running jobs
    sync.sh status                  # Full status

CONFIGURATION:
    Rules file: ~/.config/rclone_manager/sync_rules.json
    Jobs file:  ~/.config/rclone_manager/sync_jobs.json
    Log file:   /home/diego/mnt_syncs/.sync.log
EOF
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    init

    case "${1:-}" in
        "")
            run_tui
            ;;
        run)
            shift
            local dry_run="false"
            [ "$1" = "--dry-run" ] && dry_run="true"
            run_all_enabled "$dry_run" "false"
            ;;
        run-bg)
            run_all_enabled "false" "true"
            ;;
        run-rule)
            shift
            local name="$1"
            [ -z "$name" ] && { error "Usage: $0 run-rule NAME"; exit 1; }
            shift
            local dry_run="false"
            local background="false"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --dry-run) dry_run="true" ;;
                    --background|-bg) background="true" ;;
                esac
                shift
            done
            if [ "$background" = "true" ]; then
                run_rule_background "$name"
            else
                run_rule "$name" "$dry_run"
            fi
            ;;
        list)
            list_rules_menu
            ;;
        add)
            add_rule_wizard
            ;;
        delete)
            shift
            [ -z "$1" ] && { error "Usage: $0 delete NAME"; exit 1; }
            delete_rule "$1"
            log "Rule deleted"
            ;;
        toggle)
            shift
            [ -z "$1" ] && { error "Usage: $0 toggle NAME"; exit 1; }
            toggle_rule "$1"
            log "Rule toggled"
            ;;
        sync)
            shift
            local src="$1"
            local dest="$2"
            [ -z "$src" ] || [ -z "$dest" ] && { error "Usage: $0 sync SRC DEST"; exit 1; }
            shift 2
            local dry_run="false"
            [ "$1" = "--dry-run" ] && dry_run="true"
            sync_one_way "$src" "$dest" "$dry_run"
            ;;
        bisync)
            shift
            local p1="$1"
            local p2="$2"
            [ -z "$p1" ] || [ -z "$p2" ] && { error "Usage: $0 bisync PATH1 PATH2"; exit 1; }
            shift 2
            local dry_run="false"
            local resync="false"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --dry-run) dry_run="true" ;;
                    --resync) resync="true" ;;
                esac
                shift
            done
            sync_bisync "$p1" "$p2" "$dry_run" "$resync"
            ;;
        jobs)
            jobs_menu
            ;;
        cancel)
            shift
            [ -z "$1" ] && { error "Usage: $0 cancel JOB_ID"; exit 1; }
            if cancel_job "$1"; then
                log "Job cancelled"
            else
                error "Failed to cancel job (not running or not found)"
            fi
            ;;
        clear-jobs)
            local removed=$(clear_completed_jobs)
            log "Cleared $removed completed job(s)"
            ;;
        status|s)
            show_status
            ;;
        log)
            view_log
            ;;
        log-clear)
            clear_log
            log "Log cleared"
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            error "Unknown command: $1"
            printf "Run '$0 help' for usage\n"
            exit 1
            ;;
    esac
}

main "$@"
