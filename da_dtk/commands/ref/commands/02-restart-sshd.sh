#!/bin/sh
# Restart SSH daemon
set -eu
sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null
echo "sshd restarted"
