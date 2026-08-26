#!/bin/bash
# Monitor Surface trackpad for click loss events
# Run: bash surface-trackpad-monitor.sh
# Logs to: /tmp/trackpad-monitor.log
# Stop: kill the PID printed at start, or Ctrl+C

set -euo pipefail

LOG="/tmp/trackpad-monitor.log"
POLL_INTERVAL=2

echo "=== Surface Trackpad Monitor ===" | tee "$LOG"
echo "PID: $$" | tee -a "$LOG"
echo "Started: $(date -Iseconds)" | tee -a "$LOG"
echo "Log: $LOG" | tee -a "$LOG"
echo "Press Ctrl+C to stop" | tee -a "$LOG"
echo "" | tee -a "$LOG"

# Snapshot baseline device state
snapshot_devices() {
    ls -la /dev/input/event* 2>/dev/null | wc -l
}

snapshot_hid() {
    ls /sys/bus/hid/devices/ 2>/dev/null | sort
}

get_touchpad_eventdev() {
    grep -l "045E:09AF\|04F3:3195" /sys/class/input/event*/device/modalias 2>/dev/null | head -1 | sed 's|.*/\(event[0-9]*\)/.*|\1|'
}

BASELINE_DEVCOUNT=$(snapshot_devices)
BASELINE_HID=$(snapshot_hid)
BASELINE_TP=$(get_touchpad_eventdev)

echo "[baseline] input devices: $BASELINE_DEVCOUNT" | tee -a "$LOG"
echo "[baseline] touchpad event: $BASELINE_TP" | tee -a "$LOG"
echo "[baseline] HID devices:" | tee -a "$LOG"
echo "$BASELINE_HID" | tee -a "$LOG"
echo "" | tee -a "$LOG"

# Start dmesg watcher in background
sudo dmesg -w 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        *surface_hid*|*hid_multi*|*045E:09AF*|*04F3:3195*|*error*-71*|*probe*fail*|*descriptor*|*EPROTO*)
            echo "[$(date +%H:%M:%S)] [DMESG-HID] $line" >> "$LOG"
            echo "[DMESG-HID] $line"
            ;;
        *input:*Surface*|*input:*ELAN*|*input:*Touchpad*)
            echo "[$(date +%H:%M:%S)] [DMESG-INPUT] $line" >> "$LOG"
            echo "[DMESG-INPUT] $line"
            ;;
    esac
done &
DMESG_PID=$!

# Start libinput monitor for button events (needs root)
sudo timeout 86400 libinput debug-events 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        *POINTER_BUTTON*)
            echo "[$(date +%H:%M:%S)] [CLICK] $line" >> "$LOG"
            ;;
        *POINTER_BUTTON*released*)
            # Track click rate - if we stop seeing these, clicks are dead
            echo "[$(date +%H:%M:%S)] [CLICK-UP] $line" >> "$LOG"
            ;;
    esac
done &
LIBINPUT_PID=$!

# Start KWin focus monitor via dbus
dbus-monitor --session "type='signal',interface='org.kde.KWin'" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        *activeWindow*|*clientActivated*|*windowActivated*)
            echo "[$(date +%H:%M:%S)] [FOCUS] $line" >> "$LOG"
            ;;
    esac
done &
DBUS_PID=$!

cleanup() {
    echo "" | tee -a "$LOG"
    echo "[$(date +%H:%M:%S)] Monitor stopped" | tee -a "$LOG"
    kill $DMESG_PID $LIBINPUT_PID $DBUS_PID 2>/dev/null || true
    wait 2>/dev/null || true

    # Summary
    echo "" | tee -a "$LOG"
    echo "=== SUMMARY ===" | tee -a "$LOG"
    echo "Total clicks logged: $(grep -c '\[CLICK\]' "$LOG" 2>/dev/null || echo 0)" | tee -a "$LOG"
    echo "HID errors: $(grep -c '\[DMESG-HID\]' "$LOG" 2>/dev/null || echo 0)" | tee -a "$LOG"
    echo "Device changes: $(grep -c '\[DEVICE-CHANGE\]' "$LOG" 2>/dev/null || echo 0)" | tee -a "$LOG"
    echo "Focus changes: $(grep -c '\[FOCUS\]' "$LOG" 2>/dev/null || echo 0)" | tee -a "$LOG"
    echo "Gaps detected: $(grep -c '\[GAP\]' "$LOG" 2>/dev/null || echo 0)" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "Full log: $LOG" | tee -a "$LOG"
}
trap cleanup EXIT INT TERM

# Main polling loop — detect state changes
LAST_CLICK_TIME=$(date +%s)

while true; do
    NOW=$(date +%s)

    # Check if input devices changed
    CURRENT_DEVCOUNT=$(snapshot_devices)
    if [ "$CURRENT_DEVCOUNT" != "$BASELINE_DEVCOUNT" ]; then
        echo "[$(date +%H:%M:%S)] [DEVICE-CHANGE] input device count: $BASELINE_DEVCOUNT -> $CURRENT_DEVCOUNT" | tee -a "$LOG"
        BASELINE_DEVCOUNT=$CURRENT_DEVCOUNT
    fi

    # Check if HID devices changed
    CURRENT_HID=$(snapshot_hid)
    if [ "$CURRENT_HID" != "$BASELINE_HID" ]; then
        echo "[$(date +%H:%M:%S)] [DEVICE-CHANGE] HID device list changed:" | tee -a "$LOG"
        diff <(echo "$BASELINE_HID") <(echo "$CURRENT_HID") 2>/dev/null | tee -a "$LOG" || true
        BASELINE_HID=$CURRENT_HID
    fi

    # Check if touchpad event device changed (re-enumerated)
    CURRENT_TP=$(get_touchpad_eventdev)
    if [ "$CURRENT_TP" != "$BASELINE_TP" ]; then
        echo "[$(date +%H:%M:%S)] [DEVICE-CHANGE] touchpad event device: $BASELINE_TP -> $CURRENT_TP" | tee -a "$LOG"
        BASELINE_TP=$CURRENT_TP
    fi

    # Check for click gaps — if no clicks logged in last 30s, flag it
    LAST_CLICK=$(grep '\[CLICK\]' "$LOG" 2>/dev/null | tail -1 | grep -oP '\d{2}:\d{2}:\d{2}' || echo "")
    if [ -n "$LAST_CLICK" ]; then
        LAST_EPOCH=$(date -d "$LAST_CLICK" +%s 2>/dev/null || echo "$NOW")
        GAP=$((NOW - LAST_EPOCH))
        if [ "$GAP" -gt 30 ] && [ "$GAP" -lt 300 ]; then
            # Only alert once per gap
            LAST_GAP=$(grep '\[GAP\]' "$LOG" 2>/dev/null | tail -1 | grep -oP '\d{2}:\d{2}:\d{2}' || echo "")
            if [ "$LAST_GAP" != "$(date +%H:%M:%S)" ]; then
                echo "[$(date +%H:%M:%S)] [GAP] No clicks for ${GAP}s — clicks may be dead!" | tee -a "$LOG"
                # Capture state at gap time
                echo "[$(date +%H:%M:%S)] [GAP-STATE] devices=$(snapshot_devices) tp_event=$CURRENT_TP" >> "$LOG"
                sudo dmesg 2>/dev/null | tail -5 >> "$LOG"
            fi
        fi
    fi

    sleep "$POLL_INTERVAL"
done
