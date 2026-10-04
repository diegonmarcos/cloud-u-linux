#!/bin/sh
# Restart WireGuard wg0
set -eu
sudo systemctl restart wg-quick@wg0
echo "wg restarted"
