#!/bin/sh
# Start Docker daemon
set -eu
sudo systemctl start docker
echo "docker started"
