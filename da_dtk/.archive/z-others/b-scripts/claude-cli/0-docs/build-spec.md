# Claude Code Container - Build Specification

## Source of Truth

**`src/nix/flake.nix`** is the single source of truth for the entire project.

## Build Outputs

### 1. AppImage (`claude.AppImage` ~65MB)

Self-contained portable executable:
- Bundles `flake.nix` + `nix-portable`
- Auto-extracts on run (no FUSE required)
- Uses `NP_RUNTIME=bwrap` for proper isolation

```bash
./dist/claude.AppImage          # Run isolated (default)
./dist/claude.AppImage -h       # Show help
./dist/claude.AppImage -m       # Run in mirror mode
```

### 2. Tar Archive (`claude.tar.gz` ~65MB)

Extractable distribution:
- Contents: `flake.nix`, `nix-portable`, `run.sh`
- Same runtime behavior as AppImage

```bash
tar -xzf dist/claude.tar.gz
cd claude
./run.sh
```

## CLI Interface

```
claude [OPTIONS] [CLAUDE_ARGS...]

OPTIONS
    -h, --help       Show container help (not Claude help)
    -i, --isolated   Run in isolated sandbox (default)
    -m, --mirror     Run with full home access (no isolation)
```

## Runtime Strategy

### nix-portable with bwrap

Both distributions use bundled **nix-portable** with `NP_RUNTIME=bwrap`:
- Uses Linux kernel namespaces for real isolation
- No proot/ptrace overhead
- Requires `unprivileged_userns_clone=1` (most modern distros)

### Sandbox Isolation (Isolated Mode)

bubblewrap creates a restricted environment:

| Mount | Mode | Purpose |
|-------|------|---------|
| `/nix` | ro | Nix store |
| `/usr`, `/lib`, `/bin` | ro | System binaries |
| `/etc/ssl`, `/etc/ca-certificates` | ro | SSL certificates |
| `~/.claude` | rw | Claude config/data |
| `~/.config` | rw | App configs |
| `~/.npm-global` | rw | npm global packages |
| `~/mnt_git` | rw | Git repositories |
| `~/.ssh` | ro | SSH keys |
| `~/.gitconfig` | ro | Git config |

Environment:
- `CLAUDE_SANDBOXED=1` - Indicates sandbox mode
- `SSL_CERT_FILE` - CA certificates path
- `NODE_EXTRA_CA_CERTS` - Node.js CA path

### Mirror Mode

Full home access, no isolation. Use for trusted operations.

## Build Process

```bash
./build.sh
```

1. Downloads nix-portable (cached in `libs/`)
2. Creates tar.gz with `flake.nix` + `nix-portable` + `run.sh`
3. Creates AppImage with `flake.nix` + `nix-portable` + `AppRun`

## System Requirements

**Required:**
- Linux kernel with user namespaces
- `/proc/sys/kernel/unprivileged_userns_clone = 1`

**Not required:**
- Root access
- System Nix installation
- FUSE (AppImage auto-extracts)

## First Run

On first execution, Nix downloads and caches:
- Node.js 22
- Claude Code npm package
- bubblewrap
- git, coreutils

Subsequent runs use cached packages.
