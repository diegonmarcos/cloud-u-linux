#!/bin/sh
# Build ai-cli — concatenate modules + package distributions
set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
SRC="$BASE/src"
DIST="$BASE/dist"
LIBS="$BASE/libs"

# Read version from build.json
VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$BASE/build.json")
printf 'Building ai-cli v%s\n\n' "$VERSION"

mkdir -p "$DIST" "$LIBS"

# ── Step 1: Concatenate shell modules → dist/ai-cli.sh ─────────────────

printf '1. Concatenating shell modules...\n'

cat "$SRC/00_header.sh" > "$DIST/ai-cli.sh"

for mod in \
    "$SRC/01_config.sh" \
    "$SRC/02_log.sh" \
    "$SRC/03_utils.sh" \
    "$SRC/04_deps.sh" \
    "$SRC/05_native.sh" \
    "$SRC/06_sandbox.sh" \
    "$SRC/07_container.sh" \
    "$SRC/08_browser.sh" \
    "$SRC/09_status.sh" \
    "$SRC/10_help.sh" \
    "$SRC/11_main.sh"; do
    printf '\n' >> "$DIST/ai-cli.sh"
    sed '/^#!\/bin\/sh/d' "$mod" >> "$DIST/ai-cli.sh"
done

sed -i "s/%%VERSION%%/$VERSION/g" "$DIST/ai-cli.sh"
chmod +x "$DIST/ai-cli.sh"
printf '   -> ai-cli.sh\n'

# ── Step 2: Copy container files ─────────────────────────────────────────

printf '2. Copying container files...\n'
cp "$SRC/container/Dockerfile" "$DIST/claude-docker.Dockerfile"
cp "$SRC/container/Containerfile" "$DIST/claude-podman.Containerfile"
cp "$SRC/container/docker-compose.yml" "$DIST/claude-docker.compose.yml"
printf '   -> claude-docker.Dockerfile, claude-podman.Containerfile, claude-docker.compose.yml\n'

# ── Step 3: Download nix-portable (cached) ───────────────────────────────

printf '3. Checking nix-portable...\n'
if [ ! -f "$LIBS/nix-portable" ]; then
    printf '   Downloading nix-portable...\n'
    curl -L -o "$LIBS/nix-portable" \
        "https://github.com/DavHau/nix-portable/releases/download/v012/nix-portable-x86_64"
    chmod +x "$LIBS/nix-portable"
    printf '   -> downloaded\n'
else
    printf '   -> cached\n'
fi

# ── Step 4: Build tar.gz (all files bundle) ──────────────────────────────

printf '4. Building tar.gz...\n'
rm -rf "$LIBS/tar"
mkdir -p "$LIBS/tar/claude"
cp "$DIST/claude-sh.sh" "$LIBS/tar/claude/"
cp "$LIBS/nix-portable" "$LIBS/tar/claude/"

cat > "$LIBS/tar/claude/run.sh" << 'RUNEOF'
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/claude-sh.sh" --sandbox "$@"
RUNEOF
chmod +x "$LIBS/tar/claude/run.sh"

cd "$LIBS/tar"
tar -czf "$DIST/claude-tar.tar.gz" claude/
printf '   -> claude-tar.tar.gz\n'

# ── Step 5: Build AppImage ───────────────────────────────────────────────

printf '5. Building AppImage...\n'
rm -rf "$LIBS/appimage"
APPDIR="$LIBS/appimage/Claude_Launcher.AppDir"
mkdir -p "$APPDIR"

cp "$DIST/claude-sh.sh" "$APPDIR/"
cp "$LIBS/nix-portable" "$APPDIR/"

cat > "$APPDIR/AppRun" << 'APPEOF'
#!/bin/sh
if [ -z "${APPIMAGE_EXTRACT_AND_RUN:-}" ]; then
    export APPIMAGE_EXTRACT_AND_RUN=1
    exec "$APPIMAGE" "$@"
fi

DIR="$(dirname "$(readlink -f "$0")")"
exec "$DIR/claude-sh.sh" --sandbox "$@"
APPEOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/claude.desktop" << 'DSKEOF'
[Desktop Entry]
Name=Claude Launcher
Exec=AppRun
Icon=claude
Type=Application
Categories=Development;
Terminal=true
DSKEOF

cat > "$APPDIR/claude.svg" << 'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
<rect width="100" height="100" rx="20" fill="#1a1a2e"/>
<text x="50" y="65" font-size="50" text-anchor="middle" fill="#d4a574">C</text>
</svg>
SVGEOF

APPIMAGETOOL="$SRC/appimage/appimagetool-x86_64.AppImage"
cd "$LIBS/appimage"

# Try bundled appimagetool, then nix appimagetool, then skip
if ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGETOOL" "$APPDIR" "$DIST/claude-appimage.AppImage" 2>/dev/null; then
    printf '   -> claude-appimage.AppImage\n'
elif command -v appimagetool >/dev/null 2>&1; then
    ARCH=x86_64 appimagetool "$APPDIR" "$DIST/claude-appimage.AppImage"
    printf '   -> claude-appimage.AppImage\n'
elif command -v nix-shell >/dev/null 2>&1; then
    printf '   Using nix appimagetool...\n'
    nix-shell -p appimagekit --run "ARCH=x86_64 appimagetool '$APPDIR' '$DIST/claude-appimage.AppImage'"
    printf '   -> claude-appimage.AppImage\n'
else
    printf '   SKIP: appimagetool not available. Other formats available.\n'
fi

# ── Done ─────────────────────────────────────────────────────────────────

printf '\nDone!\n'
ls -lh "$DIST/"
