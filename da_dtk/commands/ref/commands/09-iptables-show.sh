#!/bin/sh
# Show iptables INPUT rules
set -eu
sudo iptables -L INPUT -n --line-numbers
