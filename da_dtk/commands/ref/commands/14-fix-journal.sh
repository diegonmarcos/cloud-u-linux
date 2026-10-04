#!/bin/sh
# Full journal spam fix (persistent)
set -eu
sudo sh -c 'echo 0 > /proc/sys/kernel/printk' 2>/dev/null || true
sudo dmesg -n 1 2>/dev/null || true
sudo systemctl stop systemd-journald-audit.socket 2>/dev/null || true
sudo mkdir -p /etc/sysctl.d
sudo sh -c 'echo "kernel.printk = 0 0 0 0" > /etc/sysctl.d/99-silence-console.conf' 2>/dev/null || true
echo "journal spam silenced"
