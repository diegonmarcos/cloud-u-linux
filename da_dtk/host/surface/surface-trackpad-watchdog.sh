#!/bin/bash
# Auto-detect trackpad click loss and capture diagnostic state
# Run: sudo bash surface-trackpad-watchdog.sh &
# It watches libinput — if motion events happen but NO clicks for 60s, it snapshots.

LOG="/tmp/trackpad-watchdog.log"
SNAPSHOT_DIR="/tmp/trackpad-snapshots"
mkdir -p "$SNAPSHOT_DIR"

echo "=== Trackpad Watchdog started $(date -Iseconds) ===" | tee "$LOG"
echo "Snapshots: $SNAPSHOT_DIR/" | tee -a "$LOG"

LAST_CLICK=$(date +%s)
LAST_MOTION=$(date +%s)
SNAPPED=0

# Feed libinput events into a named pipe
FIFO="/tmp/trackpad-libinput-fifo"
rm -f "$FIFO"
mkfifo "$FIFO"

libinput debug-events 2>/dev/null > "$FIFO" &
LI_PID=$!

cleanup() {
    kill $LI_PID 2>/dev/null
    rm -f "$FIFO"
    echo "Watchdog stopped" | tee -a "$LOG"
}
trap cleanup EXIT INT TERM

# Process events
while IFS= read -r line < "$FIFO"; do
    NOW=$(date +%s)

    case "$line" in
        *POINTER_BUTTON*pressed*)
            LAST_CLICK=$NOW
            SNAPPED=0
            ;;
        *POINTER_MOTION*)
            LAST_MOTION=$NOW

            # If we have motion but no clicks for 60s, something is wrong
            CLICK_GAP=$((NOW - LAST_CLICK))
            if [ "$CLICK_GAP" -gt 60 ] && [ "$SNAPPED" -eq 0 ]; then
                SNAPPED=1
                SNAP="$SNAPSHOT_DIR/snap-$(date +%H%M%S).txt"

                echo "[$(date +%H:%M:%S)] CLICK LOSS DETECTED — no clicks for ${CLICK_GAP}s but motion works" | tee -a "$LOG"

                {
                    echo "=== CLICK LOSS SNAPSHOT $(date -Iseconds) ==="
                    echo "Click gap: ${CLICK_GAP}s"
                    echo ""

                    echo "--- KWin state ---"
                    echo "PID: $(pgrep -x kwin_wayland)"
                    echo "CPU: $(ps -p $(pgrep -x kwin_wayland) -o %cpu= 2>/dev/null)"
                    echo "MEM: $(ps -p $(pgrep -x kwin_wayland) -o rss= 2>/dev/null)KB"
                    echo "Threads: $(ls /proc/$(pgrep -x kwin_wayland)/task 2>/dev/null | wc -l)"
                    echo ""

                    echo "--- Input devices ---"
                    ls -la /proc/$(pgrep -x kwin_wayland)/fd 2>/dev/null | grep input
                    echo ""

                    echo "--- /dev/input touchpad ---"
                    for f in /sys/class/input/event*/device/name; do
                        name=$(cat "$f" 2>/dev/null)
                        case "$name" in *Touchpad*|*045E:09AF*|*04F3:3195*)
                            dev=$(echo "$f" | grep -oP 'event\d+')
                            echo "$dev: $name"
                            cat "$(dirname "$f")/uevent" 2>/dev/null
                            echo ""
                        ;; esac
                    done

                    echo "--- dmesg last 20 ---"
                    dmesg 2>/dev/null | tail -20
                    echo ""

                    echo "--- KWin journal last 20 ---"
                    journalctl --user -t kwin_wayland --no-pager -n 20 2>/dev/null
                    echo ""

                    echo "--- All user journal last 10 ---"
                    journalctl --user --no-pager -n 10 2>/dev/null

                } > "$SNAP" 2>&1

                echo "[$(date +%H:%M:%S)] Snapshot saved: $SNAP" | tee -a "$LOG"
            fi
            ;;
        *DEVICE_REMOVED*)
            echo "[$(date +%H:%M:%S)] [!] DEVICE REMOVED: $line" | tee -a "$LOG"
            ;;
        *DEVICE_ADDED*)
            echo "[$(date +%H:%M:%S)] [+] DEVICE ADDED: $line" | tee -a "$LOG"
            ;;
    esac
done
