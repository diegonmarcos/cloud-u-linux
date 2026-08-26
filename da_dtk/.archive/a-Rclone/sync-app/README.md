# Sync-App: Unified Git & Rclone Sync Manager

A comprehensive Python application that unifies Git repository management and Rclone cloud sync into a single tool.

## Features

✅ **Unified Repository Management**
- Manage both Git repos and Rclone sync rules from one tool
- Unified data models and status reporting
- Consistent interface across all operations

✅ **Git Operations**
- Clone, fetch, pull, push, sync operations
- GitHub Actions CI/CD status monitoring
- Uncommitted changes and unpushed commits detection
- Merge strategy support for conflict resolution

✅ **Rclone Operations**
- Mount/unmount cloud storage (Gdrive, etc.)
- Bidirectional sync (bisync) with conflict resolution
- One-way sync (to remote or to local)
- VFS caching for improved performance

✅ **Background Job Management**
- Track running and completed jobs
- Process management with PID tracking
- Job cancellation and log viewing
- Job history (max 50 jobs)

✅ **CLI Interface**
- Comprehensive command-line interface
- JSON output support for scripting
- Status checking for all repos
- Individual or batch operations

## Installation

```bash
cd /home/diego/Documents/Git/ops-Tooling/1_GitDriveDb/sync-app
chmod +x sync-app.py
pip install -r requirements.txt
```

## Usage

### Quick Start

```bash
# Show all status
./sync-app.py status

# Show Git repos status
./sync-app.py git status

# Show Rclone status
./sync-app.py rclone status

# View jobs
./sync-app.py jobs
```

### Git Commands

```bash
# Show Git repos status
./sync-app.py git status

# Sync all Git repos (commit, fetch, pull, push)
./sync-app.py git sync

# Sync specific repo
./sync-app.py git sync ops-Tooling

# Push all repos (commits changes first)
./sync-app.py git push

# Pull all repos
./sync-app.py git pull

# Fetch all repos
./sync-app.py git fetch
```

### Rclone Commands

```bash
# Show Rclone status
./sync-app.py rclone status

# Run all enabled sync rules
./sync-app.py rclone sync

# Run specific sync rule
./sync-app.py rclone sync Gdrive_sync

# Mount default remote (Gdrive)
./sync-app.py rclone mount

# Mount specific remote
./sync-app.py rclone mount Dropbox

# Unmount
./sync-app.py rclone umount
```

### Jobs Commands

```bash
# List all jobs
./sync-app.py jobs

# Clear completed jobs
./sync-app.py jobs --clear
```

### JSON Output

```bash
# Get status as JSON (for scripting)
./sync-app.py status --json
```

## Configuration

Configuration is stored in `~/.config/sync-app/config.json`

### Default Configuration

```json
{
  "version": "0.1.0",
  "git_workdir": "/home/diego/Documents/Git",
  "git_repos": {
    "front-Github_profile": "git@github.com:diegonmarcos/diegonmarcos.git",
    "front-Github_io": "git@github.com:diegonmarcos/diegonmarcos.github.io.git",
    ...
  },
  "rclone_rules": [
    {
      "name": "Gdrive_sync",
      "type": "rclone_bisync",
      "source": "/home/diego/Documents",
      "destination": "Gdrive:Documents",
      "enabled": true
    }
  ],
  "rclone_mounts": [
    {
      "name": "Gdrive",
      "remote": "Gdrive:",
      "local": "/home/diego/Documents/Gdrive",
      "mode": "full"
    }
  ],
  "api_port": 5050,
  "api_host": "127.0.0.1"
}
```

### Modifying Configuration

You can edit the configuration file directly or use the Python API:

```python
from sync_app import ConfigManager

config = ConfigManager()

# Add a new Git repo
config.add_git_repo("my-project", "git@github.com:user/my-project.git")

# Add a new Rclone rule
config.add_rclone_rule({
    "name": "Backup",
    "type": "rclone_sync_to_remote",
    "source": "/home/diego/Backup",
    "destination": "Gdrive:Backup",
    "enabled": True
})
```

## Project Structure

```
sync-app/
├── sync-app.py              # Main entry point (executable)
├── requirements.txt         # Dependencies
├── README.md               # This file
├── PROGRESS.md             # Development progress
└── sync_app/               # Main package
    ├── __init__.py         # Package initialization
    ├── models.py           # Data models
    ├── config.py           # ConfigManager
    ├── git_manager.py      # GitManager
    ├── rclone_manager.py   # RcloneManager
    ├── job_manager.py      # JobManager
    └── cli.py              # CLI handlers
```

## Architecture

### Data Models

- **SyncRepo**: Unified repository abstraction for both Git and Rclone
- **SyncStatus**: Status information (local, remote, sync_state, progress)
- **SyncJob**: Background job tracking with PID and logs
- **RepoType**: Enum for repository types (git, rclone_bisync, etc.)
- **SyncState**: Enum for sync states (synced, ahead, behind, diverged, etc.)

### Managers

- **ConfigManager**: Manages configuration and repository definitions
- **GitManager**: Handles all Git operations
- **RcloneManager**: Handles all Rclone operations
- **JobManager**: Manages background jobs

### CLI

- **CLI**: Command-line interface handlers for all commands

## Examples

### Check status of all repos

```bash
$ ./sync-app.py status

=== Sync-App Status ===

Git Repositories:
--------------------------------------------------------------------------------
  front-Github_profile           | Local: OK              | Remote: Up to Date      | CI: -
  front-Github_io                | Local: Uncommitted     | Remote: Up to Date      | CI: ✓(3h)
  back-System                    | Local: Uncommitted     | Remote: Up to Date      | CI: -
  ...

Rclone Sync Rules:
--------------------------------------------------------------------------------
  [✓] Gdrive_sync               | /home/diego/Documents → Gdrive:Documents

Rclone Mounts:
--------------------------------------------------------------------------------
  Gdrive{YRXYK}:       → /home/diego/Documents/Gdrive
```

### Sync all Git repos

```bash
$ ./sync-app.py git sync

=== Syncing 14 Git repositories ===

--- front-Github_profile ---
  Syncing /home/diego/Documents/Git/front-Github_profile...
  Found uncommitted changes, committing before sync...
    [main 1234567] Auto-commit before sync
     1 file changed, 5 insertions(+)
  ✓ Changes committed
  Fetching latest changes from remote...
  ✓ Fetch complete
  ...
```

## Development Status

### Completed (Tasks 1-7) ✅

- ✅ Task 1: Project Setup & Data Models
- ✅ Task 2: Configuration Manager
- ✅ Task 3: Git Manager
- ✅ Task 4: Rclone Manager
- ✅ Task 5: Job Manager
- ✅ Task 6: TUI Implementation (SKIPPED - CLI prioritized)
- ✅ Task 7: CLI Implementation

### Remaining (Task 6 & 8) ⏳

- ⏳ Task 6: TUI (Terminal User Interface) - Interactive dashboard
- ⏳ Task 8: Flask API - REST API for remote control

## Requirements

- Python 3.7+
- git
- rclone
- gh (GitHub CLI) - for CI status monitoring
- Flask (for API server - Task 8)

## License

Private project for Diego N. Marcos

## Notes

- Default merge strategy: `theirs` (remote takes precedence)
- Rclone VFS cache: 50G max, 1h max age
- Job history: max 50 jobs
- Config location: `~/.config/sync-app/`
- Logs location: `~/.config/sync-app/logs/`

---

**Last Updated**: 2025-12-04
**Version**: 0.1.0
**Author**: Diego N. Marcos
