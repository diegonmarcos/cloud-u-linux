"""
Data models for sync-app
Unified abstraction for Git and Rclone sync operations
Enhanced with full feature support
"""

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Any, Callable
from datetime import datetime
from enum import Enum
import json


class RepoType(Enum):
    """Type of sync repository"""
    GIT = "git"
    RCLONE_BISYNC = "rclone_bisync"
    RCLONE_SYNC_TO_REMOTE = "rclone_sync_to_remote"
    RCLONE_SYNC_TO_LOCAL = "rclone_sync_to_local"
    RCLONE_LOCAL_SYNC = "rclone_local_sync"
    RCLONE_LOCAL_BISYNC = "rclone_local_bisync"
    RCLONE_MOUNT = "rclone_mount"


class SyncState(Enum):
    """Synchronization state"""
    SYNCED = "synced"           # Everything up to date
    AHEAD = "ahead"             # Local ahead of remote (unpushed commits)
    BEHIND = "behind"           # Remote ahead of local (need to pull)
    DIVERGED = "diverged"       # Both have changes (conflict)
    MODIFIED = "modified"       # Local changes (uncommitted)
    SYNCING = "syncing"         # Currently syncing
    ERROR = "error"             # Sync failed
    UNKNOWN = "unknown"         # Cannot determine state
    NOT_CLONED = "not_cloned"   # Repo not yet cloned


class JobStatus(Enum):
    """Background job status"""
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"
    QUEUED = "queued"


@dataclass
class SyncStatus:
    """Status information for a sync repository"""
    local: str = "unknown"           # Local status: "OK", "Uncommitted", "N Unpushed"
    remote: str = "unknown"          # Remote status: "Up to Date", "N To Pull", "No Remote"
    sync_state: SyncState = SyncState.UNKNOWN
    last_activity: str = "-"         # Time since last activity (e.g., "2h")
    ci_status: str = "-"             # CI status: "✓", "✗", "⟳", "-"
    progress: float = 0.0            # Progress percentage (0-100)
    details: str = ""                # Additional details or error message

    def to_dict(self) -> Dict[str, Any]:
        return {
            "local": self.local,
            "remote": self.remote,
            "sync_state": self.sync_state.value,
            "last_activity": self.last_activity,
            "ci_status": self.ci_status,
            "progress": self.progress,
            "details": self.details
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "SyncStatus":
        return cls(
            local=data.get("local", "unknown"),
            remote=data.get("remote", "unknown"),
            sync_state=SyncState(data.get("sync_state", "unknown")),
            last_activity=data.get("last_activity", "-"),
            ci_status=data.get("ci_status", "-"),
            progress=data.get("progress", 0.0),
            details=data.get("details", "")
        )


@dataclass
class SyncRepo:
    """Unified repository model for both Git and Rclone"""
    id: str                          # Unique identifier (repo name or rule name)
    name: str                        # Display name
    type: RepoType                   # Type of repository
    source: str                      # Source path/URL (local dir for Git, rclone path)
    destination: str = ""            # Destination (remote URL for Git, rclone path)
    enabled: bool = True             # Whether this repo is enabled for sync
    status: Optional[SyncStatus] = None  # Current status
    last_sync: Optional[str] = None  # Last sync timestamp (ISO format)
    category: str = "default"        # Category for grouping
    conflict_resolve: str = "newer"  # Conflict resolution strategy
    delete_extra: bool = True        # For one-way sync, delete extra files
    metadata: Dict[str, Any] = field(default_factory=dict)

    def __post_init__(self):
        if self.status is None:
            self.status = SyncStatus()

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "type": self.type.value,
            "source": self.source,
            "destination": self.destination,
            "enabled": self.enabled,
            "status": self.status.to_dict() if self.status else None,
            "last_sync": self.last_sync,
            "category": self.category,
            "conflict_resolve": self.conflict_resolve,
            "delete_extra": self.delete_extra,
            "metadata": self.metadata
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "SyncRepo":
        status = SyncStatus.from_dict(data["status"]) if data.get("status") else None
        return cls(
            id=data["id"],
            name=data["name"],
            type=RepoType(data["type"]),
            source=data["source"],
            destination=data.get("destination", ""),
            enabled=data.get("enabled", True),
            status=status,
            last_sync=data.get("last_sync"),
            category=data.get("category", "default"),
            conflict_resolve=data.get("conflict_resolve", "newer"),
            delete_extra=data.get("delete_extra", True),
            metadata=data.get("metadata", {})
        )


@dataclass
class SyncJob:
    """Background job tracking with full progress support"""
    id: str                          # Unique job ID (timestamp-based)
    repo_id: str                     # ID of repository being synced
    repo_name: str                   # Name of repository
    action: str                      # Action: "sync", "push", "pull", "fetch", "mount", etc.
    status: JobStatus = JobStatus.RUNNING
    progress: float = 0.0            # Progress percentage (0-100)
    start_time: str = ""             # Start timestamp (ISO format)
    end_time: Optional[str] = None   # End timestamp (ISO format)
    pid: Optional[int] = None        # Process ID
    log_file: Optional[str] = None   # Path to log file
    log: List[str] = field(default_factory=list)  # In-memory log messages
    error: Optional[str] = None      # Error message if failed

    # Progress details (for rclone)
    transferred: str = ""            # "1.2 GB / 5.0 GB"
    speed: str = ""                  # "15 MB/s"
    eta: str = ""                    # "5m30s"
    files_done: int = 0
    files_total: int = 0
    errors_count: int = 0

    def __post_init__(self):
        if not self.start_time:
            self.start_time = datetime.now().isoformat()

    def add_log(self, message: str):
        """Add a timestamped log message"""
        timestamp = datetime.now().strftime("%H:%M:%S")
        self.log.append(f"[{timestamp}] {message}")
        # Keep log size manageable
        if len(self.log) > 1000:
            self.log = self.log[-500:]

    def complete(self, success: bool = True, error: Optional[str] = None):
        """Mark job as completed"""
        self.status = JobStatus.COMPLETED if success else JobStatus.FAILED
        self.end_time = datetime.now().isoformat()
        self.progress = 100.0 if success else self.progress
        if error:
            self.error = error
            self.add_log(f"ERROR: {error}")

    def cancel(self):
        """Mark job as cancelled"""
        self.status = JobStatus.CANCELLED
        self.end_time = datetime.now().isoformat()
        self.add_log("Job cancelled by user")

    def get_duration(self) -> str:
        """Get human-readable duration"""
        try:
            start = datetime.fromisoformat(self.start_time)
            end = datetime.fromisoformat(self.end_time) if self.end_time else datetime.now()
            delta = int((end - start).total_seconds())

            if delta < 60:
                return f"{delta}s"
            elif delta < 3600:
                mins, secs = divmod(delta, 60)
                return f"{mins}m{secs}s"
            else:
                hours, remainder = divmod(delta, 3600)
                mins = remainder // 60
                return f"{hours}h{mins}m"
        except:
            return "-"

    def get_progress_bar(self, width: int = 20) -> str:
        """Get visual progress bar"""
        filled = int(width * self.progress / 100)
        return f"[{'█' * filled}{'░' * (width - filled)}]"

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "repo_id": self.repo_id,
            "repo_name": self.repo_name,
            "action": self.action,
            "status": self.status.value,
            "progress": self.progress,
            "start_time": self.start_time,
            "end_time": self.end_time,
            "pid": self.pid,
            "log_file": self.log_file,
            "log": self.log[-50:],  # Only save last 50 log entries
            "error": self.error,
            "transferred": self.transferred,
            "speed": self.speed,
            "eta": self.eta,
            "files_done": self.files_done,
            "files_total": self.files_total,
            "errors_count": self.errors_count
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "SyncJob":
        return cls(
            id=data["id"],
            repo_id=data["repo_id"],
            repo_name=data["repo_name"],
            action=data["action"],
            status=JobStatus(data.get("status", "running")),
            progress=data.get("progress", 0.0),
            start_time=data["start_time"],
            end_time=data.get("end_time"),
            pid=data.get("pid"),
            log_file=data.get("log_file"),
            log=data.get("log", []),
            error=data.get("error"),
            transferred=data.get("transferred", ""),
            speed=data.get("speed", ""),
            eta=data.get("eta", ""),
            files_done=data.get("files_done", 0),
            files_total=data.get("files_total", 0),
            errors_count=data.get("errors_count", 0)
        )


@dataclass
class MountConfig:
    """Configuration for an rclone mount"""
    name: str                        # Mount name (e.g., "Gdrive")
    remote: str                      # Remote name with path (e.g., "Gdrive:")
    local_path: str                  # Local mount point
    cache_mode: str = "full"         # VFS cache mode
    enabled: bool = True
    auto_mount: bool = False         # Mount on startup

    def to_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "remote": self.remote,
            "local_path": self.local_path,
            "cache_mode": self.cache_mode,
            "enabled": self.enabled,
            "auto_mount": self.auto_mount
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "MountConfig":
        return cls(
            name=data["name"],
            remote=data["remote"],
            local_path=data["local_path"],
            cache_mode=data.get("cache_mode", "full"),
            enabled=data.get("enabled", True),
            auto_mount=data.get("auto_mount", False)
        )


# Type aliases
RepoList = List[SyncRepo]
JobList = List[SyncJob]
MountList = List[MountConfig]


class Colors:
    """ANSI color codes for terminal output"""
    RESET = '\033[0m'
    BOLD = '\033[1m'
    DIM = '\033[2m'
    ITALIC = '\033[3m'
    UNDERLINE = '\033[4m'

    BLACK = '\033[30m'
    RED = '\033[31m'
    GREEN = '\033[32m'
    YELLOW = '\033[33m'
    BLUE = '\033[34m'
    MAGENTA = '\033[35m'
    CYAN = '\033[36m'
    WHITE = '\033[37m'
    GRAY = '\033[90m'

    # Bright colors
    BRIGHT_RED = '\033[91m'
    BRIGHT_GREEN = '\033[92m'
    BRIGHT_YELLOW = '\033[93m'
    BRIGHT_BLUE = '\033[94m'
    BRIGHT_MAGENTA = '\033[95m'
    BRIGHT_CYAN = '\033[96m'

    # Background colors
    BG_RED = '\033[41m'
    BG_GREEN = '\033[42m'
    BG_YELLOW = '\033[43m'
    BG_BLUE = '\033[44m'

    @classmethod
    def colorize(cls, text: str, *colors) -> str:
        """Apply multiple colors to text"""
        color_str = ''.join(colors)
        return f"{color_str}{text}{cls.RESET}"

    @classmethod
    def success(cls, text: str) -> str:
        return cls.colorize(text, cls.GREEN)

    @classmethod
    def error(cls, text: str) -> str:
        return cls.colorize(text, cls.RED)

    @classmethod
    def warning(cls, text: str) -> str:
        return cls.colorize(text, cls.YELLOW)

    @classmethod
    def info(cls, text: str) -> str:
        return cls.colorize(text, cls.CYAN)

    @classmethod
    def dim(cls, text: str) -> str:
        return cls.colorize(text, cls.DIM)
