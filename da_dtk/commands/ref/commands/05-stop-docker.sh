#!/bin/sh
# Stop Docker daemon
set -eu
sudo systemctl stop docker
echo "docker stopped"
