#!/bin/sh
# Reset Surface Type Cover trackpad/keyboard drivers
# Use when trackpad stops clicking or keyboard becomes unresponsive

set -ex

echo "Resetting Surface Type Cover drivers..."

# Reload Surface HID modules
sudo modprobe -r surface_hid_core surface_hid 2>/dev/null || true
sudo modprobe surface_hid_core surface_hid

# Reload HID multitouch
sudo modprobe -r hid_multitouch
sudo modprobe hid_multitouch

# Reload USB HID
sudo modprobe -r usbhid
sudo modprobe usbhid

# Reload full Surface input stack
sudo modprobe -r surface_aggregator_registry surface_aggregator_hub surface_hid surface_hid_core 2>/dev/null || true
sleep 1
sudo modprobe surface_aggregator_registry
sudo modprobe surface_hid

echo "Done. Trackpad should be working now."
