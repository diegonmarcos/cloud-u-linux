#!/bin/sh
# ESM doesn't support NODE_PATH — ensure node_modules symlink exists
DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED="${NODE_PATH:-/home/diego/.node_modules/node_modules}"
[ ! -d "$DIR/node_modules" ] && [ -d "$SHARED" ] && ln -sf "$SHARED" "$DIR/node_modules"
exec npx tsx "$DIR/index.ts" "$@"
