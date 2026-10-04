#!/bin/sh
# Restart Docker daemon
set -eu
sudo systemctl restart docker
echo "docker restarted"
