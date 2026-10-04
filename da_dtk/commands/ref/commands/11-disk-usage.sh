#!/bin/sh
# Show disk usage for key mountpoints
set -eu
df -h / /var /opt 2>/dev/null
