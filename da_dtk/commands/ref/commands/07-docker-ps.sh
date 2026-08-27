#!/bin/sh
# Show running containers
set -eu
docker ps --format '{{.Names}}: {{.Status}}' | sort
