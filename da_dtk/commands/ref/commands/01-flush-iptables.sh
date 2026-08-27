#!/bin/sh
# Flush iptables INPUT chain and accept all
set -eu
sudo iptables -F INPUT
sudo iptables -P INPUT ACCEPT
echo "iptables flushed"
