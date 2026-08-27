#!/bin/bash
# Simple htop ANSI export with colors
# Usage: ./htop_export.sh [output_file]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/htop_layout.txt}"

python3 "$SCRIPT_DIR/htop_export.py" "$OUTPUT"
