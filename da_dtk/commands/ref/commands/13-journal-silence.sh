#!/bin/sh
# Silence kernel console messages
set -eu
sudo sh -c 'echo 0 > /proc/sys/kernel/printk'
sudo dmesg -n 1
echo "journal silenced"
