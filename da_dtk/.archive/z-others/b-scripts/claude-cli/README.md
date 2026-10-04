# Claude Code Container

Portable sandboxed Claude Code environment using Nix and bubblewrap.

## Quick Start

```bash
# Build
./build.sh

# Run (isolated sandbox by default)
./dist/claude.AppImage

# Show help
./dist/claude.AppImage -h

# Run in mirror mode (full home access)
./dist/claude.AppImage -m
```

## CLI Usage

```
claude [OPTIONS] [CLAUDE_ARGS...]

OPTIONS
    -h, --help       Show help message
    -i, --isolated   Run in isolated sandbox (default)
    -m, --mirror     Run with full home access (no isolation)

EXAMPLES
    claude                     Run in isolated mode (default)
    claude -m                  Run in mirror mode
    claude -- --version        Pass --version to Claude
```

## Distribution Formats

| Format | Size | Description |
|--------|------|-------------|
| **AppImage** | ~65MB | Portable, auto-extracts, works everywhere |
| **Tar.gz** | ~65MB | Extract and run with `./run.sh` |

**No system dependencies required** - both formats bundle nix-portable and work offline.

## Modes

### Isolated Mode (default)

Claude runs inside a bwrap sandbox with restricted access:

| Path | Mode |
|------|------|
| `~/.claude` | read/write |
| `~/.config` | read/write |
| `~/.npm-global` | read/write |
| `~/mnt_git` | read/write |
| `~/.ssh` | read-only |
| `~/.gitconfig` | read-only |

Environment variable `CLAUDE_SANDBOXED=1` is set automatically.

### Mirror Mode

Claude runs with full access to your home directory. No isolation - use for trusted operations.

## Building

```sh
./build.sh    # Builds both tar.gz + AppImage
```

**Outputs:**
- `dist/claude.tar.gz` (~65MB)
- `dist/claude.AppImage` (~65MB)

## Project Structure

```
claude-sandbox/
├── build.sh                    # Build script
├── README.md
├── dist/                       # Build outputs
│   ├── claude.tar.gz
│   └── claude.AppImage
├── libs/                       # Downloaded libs (gitignored)
│   └── nix-portable
├── docs/
│   └── build-spec.md
└── src/
    ├── AppImage/
    │   └── appimagetool-x86_64.AppImage
    └── nix/
        └── flake.nix           # SOURCE OF TRUTH
```

## How It Works

1. AppImage auto-extracts (FUSE not required)
2. Uses bundled nix-portable with `NP_RUNTIME=bwrap`
3. Nix installs Claude Code on first run
4. Creates sandboxed environment with bubblewrap

## System Requirements

- Linux kernel with user namespaces (`/proc/sys/kernel/unprivileged_userns_clone = 1`)
- No root access needed
- No Nix installation needed (bundled)
- No FUSE needed (auto-extracts)
