#!/bin/sh
# Stop and disable watchdog timer
set -eu
sudo systemctl stop watchdog-petter.timer watchdog-petter.service 2>/dev/null
sudo systemctl disable watchdog-petter.timer 2>/dev/null
echo "watchdog killed"
