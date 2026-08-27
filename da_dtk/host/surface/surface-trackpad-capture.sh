#!/bin/bash
# Capture raw touchpad events to diagnose click loss
# Runs libinput record in background, watches for click gaps,
# auto-saves the recording when clicks die
#
# Usage: sudo nix-shell -p libinput --run "bash surface-trackpad-capture.sh"

set -euo pipefail

RECORD_FILE="/tmp/trackpad-recording.yml"
STATE_FILE="/tmp/trackpad-capture-state"

# Find touchpad device
TOUCHPAD=""
for dev in /dev/input/event*; do
    name=$(cat "/sys/class/input/$(basename "$dev")/device/name" 2>/dev/null || true)
    if [[ "$name" == *"045E:09AF Touchpad"* ]]; then
        TOUCHPAD="$dev"
        break
    fi
done

if [ -z "$TOUCHPAD" ]; then
    echo "ERROR: Surface touchpad not found"
    exit 1
fi

echo "=== Surface Trackpad Event Capture ==="
echo "Device: $TOUCHPAD"
echo "Recording to: $RECORD_FILE"
echo ""
echo "Use normally. When clicks die, the recording will auto-save."
echo "Press Ctrl+C to stop manually."
echo ""

# Start recording
libinput record "$TOUCHPAD" > "$RECORD_FILE" 2>/dev/null &
RECORD_PID=$!

# Track click state
echo "0" > "$STATE_FILE"
LAST_CLICK=$(date +%s)

cleanup() {
    kill $RECORD_PID 2>/dev/null || true
    echo ""
    echo "Recording saved: $RECORD_FILE"
    echo "Size: $(du -h "$RECORD_FILE" 2>/dev/null | cut -f1)"
    echo ""
    echo "To analyze: libinput replay $RECORD_FILE"
    echo "Or search for stuck slots: grep -n 'BTN_LEFT\|ABS_MT_TRACKING_ID\|SYN_DROPPED' $RECORD_FILE | tail -50"
    rm -f "$STATE_FILE"
}
trap cleanup EXIT INT TERM

# Monitor the recording for click events
tail -f "$RECORD_FILE" 2>/dev/null | while IFS= read -r line; do
    NOW=$(date +%s)

    # Detect button press
    if echo "$line" | grep -q "BTN_LEFT.*1\|BTN_TOOL_FINGER"; then
        LAST_CLICK=$NOW
        echo "$NOW" > "$STATE_FILE"
    fi

    # Detect SYN_DROPPED (kernel dropped events — smoking gun)
    if echo "$line" | grep -q "SYN_DROPPED"; then
        echo "[$(date +%H:%M:%S)] !!! SYN_DROPPED detected — kernel dropped events !!!"
    fi

    # Detect tracking ID changes (touch slot lifecycle)
    if echo "$line" | grep -q "ABS_MT_TRACKING_ID.*-1"; then
        : # touch-up, normal
    elif echo "$line" | grep -q "ABS_MT_TRACKING_ID"; then
        : # touch-down, normal
    fi

done &
TAIL_PID=$!

# Main loop — detect click gaps
while true; do
    sleep 5
    NOW=$(date +%s)
    STORED=$(cat "$STATE_FILE" 2>/dev/null || echo "0")
    if [ "$STORED" != "0" ]; then
        GAP=$((NOW - STORED))
        if [ "$GAP" -gt 60 ]; then
            echo ""
            echo "[$(date +%H:%M:%S)] === CLICK GAP DETECTED (${GAP}s) ==="
            echo "Recording contains the failure. Saving snapshot..."
            cp "$RECORD_FILE" "/tmp/trackpad-failure-$(date +%Y%m%d-%H%M%S).yml"
            echo "Snapshot: /tmp/trackpad-failure-$(date +%Y%m%d-%H%M%S).yml"
            echo "Run: bash ~/git/cloud-mykonsole-dtk/host/surface/surface-trackpad-reset.sh"
            echo "0" > "$STATE_FILE"
        fi
    fi
done
