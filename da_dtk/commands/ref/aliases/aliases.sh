#!/bin/sh
# Generate aliases.md from aliases.json using aliases.md.tpl
# Usage: ./aliases.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JSON="$SCRIPT_DIR/aliases.json"
TPL="$SCRIPT_DIR/aliases.md.tpl"
OUT="$SCRIPT_DIR/aliases.md"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required"; exit 1
fi

DATE=$(date '+%Y-%m-%d %H:%M:%S')

# Build markdown content from JSON
CONTENT=""
for category in $(jq -r 'keys[]' "$JSON"); do
  TITLE=$(echo "$category" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')
  CONTENT="${CONTENT}
## ${TITLE}

| Alias | Description |
|-------|-------------|"

  # Extract all leaf key-value pairs (handles nested objects)
  CONTENT="${CONTENT}
$(jq -r ".[\"$category\"] | [paths(scalars)] as \$paths | \$paths[] as \$p | \"| \`\(\$p[-1])\` | \(getpath(\$p)) |\"" "$JSON")"
  CONTENT="${CONTENT}
"
done

# Apply template
sed "s/{{DATE}}/$DATE/" "$TPL" | awk -v content="$CONTENT" '{gsub(/\{\{CONTENT\}\}/, content); print}' > "$OUT"

echo "Generated: $OUT"
