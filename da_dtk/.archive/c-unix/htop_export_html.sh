#!/bin/bash
# Export htop to HTML with CSS styling
# Usage: ./htop_export_html.sh [output_html_file]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMP_TXT="${TEMP_TXT:-$SCRIPT_DIR/htop_layout.txt}"
OUTPUT_HTML="${1:-$SCRIPT_DIR/htop_export.html}"

# Step 1: Capture htop output with ANSI colors
echo "Capturing htop output..."
python3 "$SCRIPT_DIR/htop_export.py" "$TEMP_TXT"

if [ $? -ne 0 ]; then
    echo "Error: Failed to capture htop output"
    exit 1
fi

# Step 2: Convert to HTML
echo "Converting to HTML..."
python3 "$SCRIPT_DIR/htop_to_html.py" "$TEMP_TXT" "$OUTPUT_HTML"

if [ $? -ne 0 ]; then
    echo "Error: Failed to convert to HTML"
    exit 1
fi

echo ""
echo "✓ Successfully exported htop to HTML!"
echo "  Output: $OUTPUT_HTML"
echo "  Open with: xdg-open $OUTPUT_HTML"
