#!/bin/bash
# Debug Surface trackpad click loss on KWin Wayland
# Watches libinput + journal + KWin simultaneously
# Run: sudo bash surface-trackpad-debug.sh
# When clicks die, press Enter in THIS terminal to capture state

LOG="/tmp/trackpad-debug-$(date +%Y%m%d-%H%M%S).log"

echo "=== Surface Trackpad Debug ===" | tee "$LOG"
echo "Log: $LOG" | tee -a "$LOG"
echo "When clicks die: press ENTER here to snapshot state" | tee -a "$LOG"
echo "" | tee -a "$LOG"

# Record baseline
echo "[BASELINE] $(date -Iseconds)" >> "$LOG"
echo "[BASELINE] KWin PID: $(pgrep -x kwin_wayland)" >> "$LOG"
echo "[BASELINE] libinput devices:" >> "$LOG"
libinput list-devices 2>/dev/null | grep -A3 "Touchpad" >> "$LOG"
echo "" >> "$LOG"

# Background: watch journal for KWin/input messages
journalctl --user -f -t kwin_wayland -t kwin -t plasmashell 2>/dev/null | while IFS= read -r line; do
    echo "[JOURNAL] $(date +%H:%M:%S) $line" >> "$LOG"
done &
J1=$!

# Background: watch system journal for HID/input
journalctl -k -f 2>/dev/null | grep -i "surface_hid\|hid_multi\|input:\|touchpad\|045E" | while IFS= read -r line; do
    echo "[KERNEL] $(date +%H:%M:%S) $line" >> "$LOG"
done &
J2=$!

# Background: count libinput button events per second
libinput debug-events 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        *POINTER_BUTTON*pressed*)
            echo "[LIBINPUT-CLICK] $(date +%H:%M:%S) $line" >> "$LOG"
            echo "CLICK registered at libinput level"
            ;;
        *POINTER_MOTION*)
            # just track that motion works (don't log every one)
            ;;
        *DEVICE_REMOVED*|*DEVICE_ADDED*)
            echo "[LIBINPUT-DEVICE] $(date +%H:%M:%S) $line" >> "$LOG"
            echo "[!] DEVICE CHANGE: $line"
            ;;
    esac
done &
L1=$!

cleanup() {
    kill $J1 $J2 $L1 2>/dev/null
    echo "" | tee -a "$LOG"
    echo "=== Debug ended $(date -Iseconds) ===" | tee -a "$LOG"
    echo "Log saved: $LOG"
}
trap cleanup EXIT INT TERM

# Main loop: wait for user to press Enter when clicks die
while true; do
    echo ""
    echo ">>> Press ENTER when clicks stop working (or Ctrl+C to quit) <<<"
    read -r

    echo "" | tee -a "$LOG"
    echo "========================================" | tee -a "$LOG"
    echo "[SNAPSHOT] $(date -Iseconds) — USER REPORTS CLICKS DEAD" | tee -a "$LOG"
    echo "========================================" | tee -a "$LOG"

    # Snapshot 1: Is KWin alive?
    echo "[SNAPSHOT] KWin PID: $(pgrep -x kwin_wayland)" >> "$LOG"
    echo "[SNAPSHOT] KWin CPU: $(ps -p $(pgrep -x kwin_wayland) -o %cpu= 2>/dev/null)" >> "$LOG"
    echo "[SNAPSHOT] KWin MEM: $(ps -p $(pgrep -x kwin_wayland) -o rss= 2>/dev/null)KB" >> "$LOG"

    # Snapshot 2: Input devices still present?
    echo "[SNAPSHOT] /dev/input/event* count: $(ls /dev/input/event* 2>/dev/null | wc -l)" >> "$LOG"
    echo "[SNAPSHOT] Touchpad in /sys:" >> "$LOG"
    grep -rl "045E:09AF\|04F3:3195" /sys/class/input/*/device/modalias 2>/dev/null >> "$LOG"

    # Snapshot 3: libinput sees the device?
    echo "[SNAPSHOT] libinput list-devices touchpad:" >> "$LOG"
    libinput list-devices 2>/dev/null | grep -B1 -A5 "Touchpad" >> "$LOG"

    # Snapshot 4: KWin input debug
    echo "[SNAPSHOT] KWin supportInformation (input section):" >> "$LOG"
    dbus-send --print-reply --dest=org.kde.KWin /KWin org.kde.KWin.supportInformation 2>/dev/null | grep -i "input\|device\|pointer\|touch" >> "$LOG"

    # Snapshot 5: Recent journal
    echo "[SNAPSHOT] Last 10 KWin journal entries:" >> "$LOG"
    journalctl --user -t kwin_wayland -t kwin --no-pager -n 10 2>/dev/null >> "$LOG"

    # Snapshot 6: dmesg tail
    echo "[SNAPSHOT] Last 10 dmesg:" >> "$LOG"
    dmesg 2>/dev/null | tail -10 >> "$LOG"

    # Snapshot 7: open file descriptors on input devices
    echo "[SNAPSHOT] KWin FDs on /dev/input:" >> "$LOG"
    ls -la /proc/$(pgrep -x kwin_wayland)/fd 2>/dev/null | grep input >> "$LOG"

    echo "" | tee -a "$LOG"
    echo "Snapshot captured. Check $LOG" | tee -a "$LOG"
    echo "Run reset script if needed: bash ~/git/cloud-mykonsole-dtk/host/surface/surface-trackpad-reset.sh" | tee -a "$LOG"
done
