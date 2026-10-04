#!/bin/sh
# Full rescue: flush iptables + restart sshd + restart wg
set -eu
sudo iptables -F INPUT
sudo iptables -P INPUT ACCEPT
sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null
sudo systemctl restart wg-quick@wg0 2>/dev/null
echo "full rescue done"
