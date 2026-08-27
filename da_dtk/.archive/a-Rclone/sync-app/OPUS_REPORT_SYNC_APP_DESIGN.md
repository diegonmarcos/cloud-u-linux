# Opus Senior Agent Report: sync-app.py Architecture & Implementation Status

**Date:** 2025-12-05
**Task:** Task2 - Unified Git & Rclone Sync Manager
**Role:** Senior Architect (Opus)
**Status:** IMPLEMENTATION IN PROGRESS - 62.5% Complete (5/8 Tasks Done)

---

## Executive Summary

Designed a unified Python application (`sync-app.py`) that merges two existing tools:
- **gcl.py** - Git repository management TUI
- **rclone.py** - Rclone cloud sync manager

The resulting application provides:
- **TUI Dashboard** - Real-time status for Git repos + Rclone syncs
- **CLI Interface** - Scriptable commands for automation
- **Flask API** - Remote control via HTTP endpoints

**Estimated Implementation Time:** ~10 hours

---

## Source Code Analysis

### gcl.sh / gcl.py (Git Manager)
**Location:** `/home/diego/Documents/Git/ops-Tooling/Git/`

**Key Features Extracted:**
- 14 hardcoded Git repositories with GitHub URLs
- Curses-based TUI with status columns
- GitHub API integration (CI status, last push)
- Git operations: fetch, pull, push, sync
- Status detection: uncommitted, unpushed, behind remote

**Data Model:**
```python
# From gcl.py
repos = {
    'front-Github_io': 'git@github.com:DiegoNMarcos/front-Github_io.git',
    'back-System': 'git@github.com:DiegoNMarcos/back-System.git',
    'ops-Tooling': 'git@github.com:DiegoNMarcos/ops-Tooling.git',
    # ... 11 more repos
}
```

**Status Columns:**
- Local: OK | Uncommitted | Unpushed
- Remote: Up to Date | X To Pull
- CI: ✓ | ✗ | ⟳ | -
- Last Push: Time ago format

### rclone.py (Rclone Manager)
**Location:** `/home/diego/Documents/Git/ops-Tooling/Rclone/`

**Key Features Extracted:**
- Mount/unmount operations
- Bidirectional sync (bisync)
- One-way sync with delete option
- Progress parsing from rclone logs
- Background job management
- SQLite storage for sync rules

**Operations:**
- `mount_remote(remote, local, mode)` - Mount rclone remote
- `umount_remote(local, force)` - Unmount with fusermount
- `bisync(path1, path2, dry_run, resync)` - Bidirectional sync
- `sync_one_direction(src, dest, delete)` - One-way sync

---

## Architecture Design

### Unified Data Model

```python
from dataclasses import dataclass
from enum import Enum
from typing import Optional, List

class RepoType(Enum):
    GIT = "git"
    RCLONE_BISYNC = "rclone_bisync"
    RCLONE_SYNC = "rclone_sync"
    RCLONE_MOUNT = "rclone_mount"

class SyncState(Enum):
    SYNCED = "synced"
    AHEAD = "ahead"
    BEHIND = "behind"
    DIVERGED = "diverged"
    MODIFIED = "modified"
    UNKNOWN = "unknown"

@dataclass
class SyncStatus:
    local: str           # Git: "OK"|"Uncommitted" | Rclone: "In Sync"
    remote: str          # Git: "Up to Date"|"X To Pull" | Rclone: N/A
    sync_state: SyncState
    ci_status: str       # Git only: "✓"|"✗"|"⟳"|"-"
    last_sync: str       # Time ago format
    progress: float      # 0-100 for active syncs
    message: str         # Error message or details

@dataclass
class SyncRepo:
    id: str
    name: str
    type: RepoType
    source: str          # Git: repo URL | Rclone: source path
    destination: str     # Git: local path | Rclone: dest path
    enabled: bool = True
    status: Optional[SyncStatus] = None

@dataclass
class SyncJob:
    id: str
    repo_id: str
    action: str          # "sync"|"push"|"pull"|"mount"|"umount"
    status: str          # "running"|"completed"|"failed"|"cancelled"
    progress: float
    started_at: str
    completed_at: Optional[str]
    output: List[str]
```

### Module Structure

```
sync-app/
├── sync-app.py              # Entry point
├── requirements.txt         # Dependencies
├── config/
│   └── default.json         # Default configuration
└── sync_app/
    ├── __init__.py
    ├── models.py            # Data classes
    ├── config_manager.py    # Configuration handling
    ├── git_manager.py       # Git operations (from gcl.py)
    ├── rclone_manager.py    # Rclone operations (from rclone.py)
    ├── job_manager.py       # Background job management
    ├── tui/
    │   ├── __init__.py
    │   ├── dashboard.py     # Main TUI screen
    │   ├── jobs_panel.py    # Jobs view
    │   └── config_menu.py   # Settings menu
    ├── cli.py               # CLI commands
    └── api.py               # Flask API
```

### TUI Layout Design (80x24)

```
╔═══════════════════════════════════ sync-app ══════════════════════════════════╗
║ [1] Git Repos          [2] Rclone Syncs          [3] Mounts         Refreshing ⟳ ║
╠════════════════════════════════════════════════════════════════════════════════╣
║ Git Repositories (14)                                                          ║
║ ─────────────────────────────────────────────────────────────────────────────── ║
║   NAME                  │ LOCAL      │ REMOTE        │ CI │ LAST PUSH          ║
║ ► front-Github_io       │ OK         │ Up to Date    │ ✓  │ 2h ago             ║
║   back-System           │ Uncommitted│ 3 To Pull     │ ✗  │ 1d ago             ║
║   ops-Tooling           │ Unpushed   │ Up to Date    │ ⟳  │ 30m ago            ║
║   ...                   │            │               │    │                    ║
╠════════════════════════════════════════════════════════════════════════════════╣
║ Rclone Syncs (3)                                                               ║
║ ─────────────────────────────────────────────────────────────────────────────── ║
║   NAME              │ SOURCE → DEST                    │ STATUS    │ LAST SYNC ║
║   Documents         │ ~/Documents ↔ gdrive:Documents   │ Synced    │ 1h ago    ║
║   Photos            │ ~/Photos → gdrive:Backup/Photos  │ 45% ████░░│ Syncing...║
╠════════════════════════════════════════════════════════════════════════════════╣
║ Mounts (2)                                                                     ║
║   gdrive:/          │ ~/mnt/gdrive                     │ ✓ Mounted │           ║
╠════════════════════════════════════════════════════════════════════════════════╣
║ [S]ync [P]ush [L]ull [F]etch [m]ount [J]obs [C]onfig [?]Help [q]uit           ║
╚════════════════════════════════════════════════════════════════════════════════╝
```

### Keyboard Shortcuts

| Key | Action | Context |
|-----|--------|---------|
| j/↓ | Move cursor down | All sections |
| k/↑ | Move cursor up | All sections |
| Tab | Next section | All |
| 1/2/3 | Jump to section | All |
| Space | Toggle selection | All sections |
| a | Select all | All sections |
| n | Select none | All sections |
| S | Sync selected | Git/Rclone |
| P | Push selected | Git only |
| L | Pull selected | Git only |
| F | Fetch/refresh | Git only |
| m | Mount toggle | Mounts |
| M | Mount menu | Mounts |
| J | Jobs panel | Global |
| C | Config menu | Global |
| ? | Help screen | Global |
| q | Quit | Global |

### CLI Commands

```bash
# No args - launch TUI
./sync-app.py

# Status commands
./sync-app.py status              # All status
./sync-app.py git status          # Git repos only
./sync-app.py rclone status       # Rclone rules only

# Git operations
./sync-app.py git sync [repo]     # Full sync (fetch+pull+push)
./sync-app.py git push [repo]     # Commit and push
./sync-app.py git pull [repo]     # Pull only
./sync-app.py git fetch           # Fetch all

# Rclone operations
./sync-app.py rclone sync [rule]  # Run sync rule
./sync-app.py rclone mount        # Mount default remote
./sync-app.py rclone umount       # Unmount

# Job management
./sync-app.py jobs                # List jobs
./sync-app.py jobs cancel <id>    # Cancel job

# Server mode
./sync-app.py serve               # Start API (port 5050)
./sync-app.py serve --port 8080   # Custom port
```

### Flask API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/status` | GET | All status |
| `/api/status/git` | GET | Git repos status |
| `/api/status/rclone` | GET | Rclone status |
| `/api/git/repos` | GET | List repos |
| `/api/git/sync` | POST | Sync repos (body: {repos: []}) |
| `/api/git/push` | POST | Push repos |
| `/api/git/pull` | POST | Pull repos |
| `/api/rclone/rules` | GET | List sync rules |
| `/api/rclone/sync` | POST | Run sync |
| `/api/rclone/mount` | POST | Mount remote |
| `/api/rclone/umount` | POST | Unmount |
| `/api/mounts` | GET | List mounts |
| `/api/jobs` | GET | List jobs |
| `/api/jobs/<id>` | GET | Job details |
| `/api/jobs/<id>/cancel` | POST | Cancel job |

---

## Configuration Design

### Default Configuration

```json
{
  "version": "1.0.0",
  "git": {
    "workdir": "~/Documents/Git",
    "repos": {
      "front-Github_io": "git@github.com:DiegoNMarcos/front-Github_io.git",
      "back-System": "git@github.com:DiegoNMarcos/back-System.git",
      "ops-Tooling": "git@github.com:DiegoNMarcos/ops-Tooling.git",
      "obs-AIagent": "git@github.com:DiegoNMarcos/obs-AIagent.git",
      "obs-C": "git@github.com:DiegoNMarcos/obs-C.git",
      "obs-CC": "git@github.com:DiegoNMarcos/obs-CC.git",
      "obs-Webdev": "git@github.com:DiegoNMarcos/obs-Webdev.git",
      "mymovies": "git@github.com:DiegoNMarcos/mymovies.git",
      "feed_yourself": "git@github.com:DiegoNMarcos/feed_yourself.git",
      "gcp_vm_scheduler": "git@github.com:DiegoNMarcos/gcp_vm_scheduler.git",
      "llm-workflow-engine": "git@github.com:DiegoNMarcos/llm-workflow-engine.git",
      "cv-ai-profiles": "git@github.com:DiegoNMarcos/cv-ai-profiles.git",
      "hf-gguf-manager": "git@github.com:DiegoNMarcos/hf-gguf-manager.git",
      "LOCAL_KEYS": "git@github.com:DiegoNMarcos/LOCAL_KEYS.git"
    }
  },
  "rclone": {
    "rules": [
      {
        "name": "Documents Bisync",
        "type": "bisync",
        "source": "~/Documents",
        "destination": "gdrive:Documents",
        "enabled": true
      }
    ],
    "mounts": [
      {
        "name": "Google Drive",
        "remote": "gdrive:/",
        "local": "~/mnt/gdrive",
        "mode": "read_write"
      }
    ]
  },
  "api": {
    "port": 5050,
    "host": "0.0.0.0"
  },
  "jobs": {
    "max_history": 50,
    "auto_cleanup": true
  }
}
```

### Config Location

```
~/.config/sync-app/
├── config.json      # Main configuration
├── jobs.json        # Job history
└── logs/
    └── sync-app.log # Application log
```

---

## Implementation Status

| Task | Description | Estimated | Status |
|------|-------------|-----------|--------|
| Task 1 | Project Setup & Data Models | 30 min | ✅ COMPLETE |
| Task 2 | Configuration Manager | 45 min | ✅ COMPLETE |
| Task 3 | Git Manager (port from gcl.py) | 90 min | ✅ COMPLETE |
| Task 4 | Rclone Manager (port from rclone.py) | 90 min | ✅ COMPLETE |
| Task 5 | Job Manager | 60 min | ✅ COMPLETE |
| Task 6 | TUI Implementation | 120 min | ⏳ IN PROGRESS |
| Task 7 | CLI Implementation | 45 min | ⏳ PARTIAL |
| Task 8 | Flask API | 60 min | ⏳ PENDING |
| **TOTAL** | | **~10 hours** | **62.5%** |

### Completed Work Details

**Task 1-5: Core Infrastructure ✅**
- `models.py` - Data classes (RepoType, SyncState, SyncStatus, SyncRepo, SyncJob)
- `config.py` - ConfigManager with 14 default Git repos
- `git_manager.py` - Full Git operations (clone, fetch, pull, push, sync, CI status)
- `rclone_manager.py` - Full Rclone operations (mount, umount, bisync, sync)
- `job_manager.py` - Background job tracking with PID management

**Task 6: TUI ⏳**
- `tui.py` - Dashboard layout created
- `simple_tui.py` - Simplified version implemented
- Keyboard navigation needs completion

**Task 7: CLI ⏳**
- `cli.py` - Basic argument parsing implemented
- Full subcommands need implementation

### Files Created

```
sync-app/
├── sync-app.py           # Entry point (executable)
├── requirements.txt      # Dependencies
├── test_tui.py          # TUI testing
├── PROGRESS.md          # Progress tracking
├── README.md            # Documentation
├── config/              # Config templates
└── sync_app/
    ├── __init__.py
    ├── models.py        # ✅ Data models
    ├── config.py        # ✅ Configuration manager
    ├── git_manager.py   # ✅ Git operations
    ├── rclone_manager.py# ✅ Rclone operations
    ├── job_manager.py   # ✅ Job management
    ├── cli.py           # ⏳ CLI interface
    ├── tui.py           # ⏳ Full TUI
    └── simple_tui.py    # ⏳ Simple TUI
```

---

## Dependencies

```
# requirements.txt
flask>=2.0.0
flask-cors>=3.0.0
requests>=2.25.0
```

**System Requirements:**
- Python 3.8+
- Git (for git operations)
- rclone (for cloud sync)
- gh CLI (for GitHub API)

---

## Key Design Decisions

### 1. Unified SyncRepo Abstraction
Both Git repos and Rclone sync rules are treated as "repos" with unified status model. This simplifies the TUI and API design.

### 2. Background Job Management
All sync operations run as background jobs with:
- Progress tracking
- Cancellation support
- History persistence
- Real-time status updates

### 3. Three Interface Modes
- **TUI** - Primary interface for interactive use
- **CLI** - Scriptable for automation/cron
- **API** - Remote control from other apps

### 4. Configuration-Driven
All repos and rules are defined in config, not hardcoded. Users can add/remove repos without code changes.

### 5. Preserve Source Logic
Git operations from gcl.py and rclone operations from rclone.py are preserved with minimal modification. The sync-app acts as a unified wrapper.

---

## Files Created

| File | Size | Description |
|------|------|-------------|
| `SYNC_APP_ARCHITECTURE.md` | 26KB | Full architecture specification |
| `TASKS_SYNC_APP.md` | 15KB | Implementation tasks for Sonnet |
| `CHECKLIST_SYNC_APP.md` | 10KB | 150+ checkbox progress tracker |

All files located at:
`/home/diego/Documents/Git/ops-Tooling/1_GitDriveDb/`

---

## Relationship to Task1

Task1 (Deployment) and Task2 (sync-app) are independent:

- **Task1:** Infrastructure deployment via CLI (GCloud + Oracle)
- **Task2:** Development tool for local machine

Task2 sync-app.py will be useful for managing the Git repos that contain the infrastructure code from Task1.

---

## Recommendations

### For Implementation
1. Start with Task 1-2 (Setup + Config) to establish foundation
2. Port Git operations first (Task 3) - simpler codebase
3. Port Rclone operations (Task 4) - more complex, needs careful testing
4. Build TUI incrementally - dashboard first, then panels
5. Test each component before integration

### For Testing
1. Unit tests for each manager module
2. Integration tests for TUI interaction
3. Manual tests for real Git/Rclone operations
4. API endpoint tests with curl

### Security Considerations
1. Never store credentials in config.json
2. Use system keyring for sensitive data
3. API should only bind to localhost by default
4. Job output may contain sensitive paths - sanitize in logs

---

## Sign-off

| Role | Status | Date |
|------|--------|------|
| Architect (Opus) | ✅ Design Complete | 2025-12-05 |
| Developer (Sonnet) | ⏳ Pending Implementation | - |
| CEO (Diego) | ⏳ Pending Review | - |

---

**Report Generated:** 2025-12-05
**Architecture Version:** 1.0.0
**Ready for Implementation:** YES
