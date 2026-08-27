"""
Sync-App: Unified Git & Rclone Sync Manager
Package initialization

A masterpiece unification of gcl.sh and rclone.py
Combining the elegance of shell launchers with the power of Python
"""

__version__ = '1.0.0'
__author__ = 'Diego N. Marcos'
__description__ = 'Unified Git & Rclone Sync Manager with TUI, CLI, and API'

# Import main models for convenience
from .models import (
    RepoType,
    SyncState,
    SyncStatus,
    SyncRepo,
    SyncJob,
    MountConfig,
    JobStatus,
    Colors,
    RepoList,
    JobList,
    MountList
)

# Import managers for convenience
from .config import ConfigManager
from .git_manager import GitManager
from .rclone_manager import RcloneManager
from .job_manager import JobManager

# API imports are optional (requires flask)
# Use: from sync_app.api import create_app, run_server

__all__ = [
    # Version info
    '__version__',
    '__author__',
    '__description__',
    # Models
    'RepoType',
    'SyncState',
    'SyncStatus',
    'SyncRepo',
    'SyncJob',
    'MountConfig',
    'JobStatus',
    'Colors',
    'RepoList',
    'JobList',
    'MountList',
    # Managers
    'ConfigManager',
    'GitManager',
    'RcloneManager',
    'JobManager',
]


def get_api():
    """Lazy import for API (requires flask)"""
    from .api import create_app, run_server
    return create_app, run_server
