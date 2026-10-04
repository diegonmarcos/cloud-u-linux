"""
Rclone Manager for sync-app
Enhanced Rclone operations with full feature support
Ported and improved from rclone.py with live progress parsing
"""

import subprocess
import os
import re
import signal
import time
import threading
from pathlib import Path
from typing import Tuple, List, Optional, Dict, Callable
from datetime import datetime
from .models import SyncStatus, SyncState, SyncRepo, MountConfig, RepoType, SyncJob, JobStatus


class RcloneManager:
    """Manager for Rclone operations with full feature support"""

    def __init__(self, tpslimit: int = 10, cache_mode: str = "full",
                 cache_max_age: str = "1h", cache_max_size: str = "50G",
                 log_dir: Optional[Path] = None):
        """Initialize RcloneManager

        Args:
            tpslimit: API requests per second limit
            cache_mode: VFS cache mode (off, minimal, writes, full)
            cache_max_age: Maximum age of cached files
            cache_max_size: Maximum cache size
            log_dir: Directory for log files
        """
        self.tpslimit = tpslimit
        self.cache_mode = cache_mode
        self.cache_max_age = cache_max_age
        self.cache_max_size = cache_max_size
        self.log_dir = log_dir or Path.home() / '.config' / 'sync-app' / 'logs'
        self.log_dir.mkdir(parents=True, exist_ok=True)

        # Progress parsing regex patterns
        self._progress_patterns = {
            'transferred': re.compile(r'Transferred:\s*([\d.]+\s*\w+)\s*/\s*([\d.]+\s*\w+)'),
            'speed': re.compile(r'Transferred:.*,\s*([\d.]+\s*\w+/s)'),
            'eta': re.compile(r'ETA\s+(\d+[hms\d]+)'),
            'percent': re.compile(r'(\d+)%'),
            'errors': re.compile(r'Errors:\s*(\d+)'),
            'checks': re.compile(r'Checks:\s*(\d+)\s*/\s*(\d+)'),
            'files': re.compile(r'Transferred:\s*\d+\s*/\s*(\d+)')
        }

    # ==================== Core Operations ====================

    def check_installed(self) -> bool:
        """Check if rclone is installed"""
        try:
            result = subprocess.run(['rclone', 'version'],
                                  capture_output=True, timeout=10)
            return result.returncode == 0
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    def get_version(self) -> str:
        """Get rclone version"""
        try:
            result = subprocess.run(['rclone', 'version'],
                                  capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                return result.stdout.split('\n')[0].replace('rclone ', '')
        except:
            pass
        return "unknown"

    def get_remotes(self) -> List[str]:
        """Get list of configured remotes"""
        try:
            result = subprocess.run(['rclone', 'listremotes'],
                                  capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                return [r.strip().rstrip(':') for r in result.stdout.strip().split('\n') if r.strip()]
        except:
            pass
        return []

    def list_remote_folders(self, remote: str, max_depth: int = 1) -> List[str]:
        """List folders in a remote"""
        try:
            if ':' not in remote:
                remote = f"{remote}:"

            result = subprocess.run(
                ['rclone', 'lsf', remote, '--dirs-only', f'--max-depth={max_depth}'],
                capture_output=True, text=True, timeout=30
            )
            if result.returncode == 0:
                return [f.strip().rstrip('/') for f in result.stdout.strip().split('\n') if f.strip()]
        except:
            pass
        return []

    def get_about(self, remote: str) -> Dict[str, str]:
        """Get space info for a remote (used, free, total)"""
        try:
            if ':' not in remote:
                remote = f"{remote}:"

            result = subprocess.run(
                ['rclone', 'about', remote, '--json'],
                capture_output=True, text=True, timeout=30
            )
            if result.returncode == 0:
                import json
                return json.loads(result.stdout)
        except:
            pass
        return {}

    # ==================== Mount Operations ====================

    def get_mount_status(self, mountpoint: str) -> Tuple[bool, Optional[str]]:
        """Check if a path is mounted

        Returns:
            Tuple of (is_mounted, mount_info_line)
        """
        try:
            result = subprocess.run(['mount'], capture_output=True, text=True, timeout=5)
            for line in result.stdout.split('\n'):
                if mountpoint in line:
                    return True, line
            return False, None
        except:
            return False, None

    def get_all_mounts(self) -> List[Tuple[str, str]]:
        """Get all current rclone mounts

        Returns:
            List of (remote, mountpoint) tuples
        """
        mounts = []
        try:
            result = subprocess.run(['mount'], capture_output=True, text=True, timeout=5)
            for line in result.stdout.split('\n'):
                # Match rclone FUSE mounts
                if 'rclone' in line.lower() or line.startswith('rclone') or ':fuse' in line:
                    parts = line.split()
                    if len(parts) >= 3 and parts[1] == 'on':
                        remote = parts[0]
                        mountpoint = parts[2]
                        mounts.append((remote, mountpoint))
        except:
            pass
        return mounts

    def get_rclone_pids(self) -> List[int]:
        """Get all rclone process IDs"""
        pids = []
        try:
            result = subprocess.run(['pgrep', '-f', 'rclone mount'],
                                  capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                pids = [int(p) for p in result.stdout.strip().split('\n') if p.strip()]
        except:
            pass
        return pids

    def mount_remote(self, remote: str, local_path: str,
                    mode: str = 'daemon',
                    progress_callback: Optional[Callable[[str], None]] = None) -> Tuple[bool, List[str]]:
        """Mount a remote with optimized settings

        Args:
            remote: Remote name (e.g., "Gdrive" or "Gdrive:")
            local_path: Local mount point
            mode: 'daemon' (background), 'verbose' (foreground with logs)
            progress_callback: Callback for status messages

        Returns:
            Tuple of (success, log_messages)
        """
        logs = []

        def log(msg: str):
            logs.append(msg)
            if progress_callback:
                progress_callback(msg)

        # Ensure remote has colon
        if ':' not in remote:
            remote = f"{remote}:"

        # Create mount point
        mount_path = Path(local_path)
        mount_path.mkdir(parents=True, exist_ok=True)

        # Check if already mounted
        is_mounted, _ = self.get_mount_status(local_path)
        if is_mounted:
            log(f"Already mounted at {local_path}")
            return True, logs

        # Build mount command
        log_file = self.log_dir / 'rclone.log'
        mount_cmd = [
            'rclone', 'mount', remote, local_path,
            '--vfs-cache-mode', self.cache_mode,
            '--tpslimit', str(self.tpslimit),
            '--vfs-cache-max-age', self.cache_max_age,
            '--vfs-cache-max-size', self.cache_max_size,
            '--vfs-read-chunk-size', '32M',
            '--vfs-read-chunk-size-limit', 'off',
            '--dir-cache-time', '10000h',
            '--drive-skip-gdocs',
            '--log-level', 'INFO',
            '--log-file', str(log_file)
        ]

        log(f"Mounting {remote} to {local_path}...")
        log(f"Log file: {log_file}")

        try:
            if mode == 'daemon':
                mount_cmd.append('--daemon')
                log("Mode: daemon (background)")

                # Use shell to properly daemonize
                cmd_str = ' '.join([f"'{arg}'" if ' ' in str(arg) else str(arg) for arg in mount_cmd])
                subprocess.Popen(cmd_str + ' &', shell=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

                # Wait and verify
                time.sleep(3)
                is_mounted, _ = self.get_mount_status(local_path)
                if is_mounted:
                    log("✓ Mount successful")
                    return True, logs
                else:
                    # Check log for errors
                    time.sleep(2)
                    is_mounted, _ = self.get_mount_status(local_path)
                    if is_mounted:
                        log("✓ Mount successful (delayed)")
                        return True, logs
                    log("⚠ Mount started but verification pending - check logs")
                    return True, logs

            else:  # verbose
                log("Mode: verbose (foreground)")
                log("Press Ctrl+C to stop")
                subprocess.run(mount_cmd)
                return True, logs

        except Exception as e:
            log(f"✗ Mount failed: {e}")
            return False, logs

    def umount_remote(self, local_path: str, force: bool = False) -> Tuple[bool, List[str]]:
        """Unmount a mounted remote

        Args:
            local_path: Mount point to unmount
            force: Force lazy unmount if busy

        Returns:
            Tuple of (success, log_messages)
        """
        logs = []

        is_mounted, _ = self.get_mount_status(local_path)
        if not is_mounted:
            logs.append(f"Not mounted: {local_path}")
            return True, logs

        try:
            cmd = ['fusermount', '-uz' if force else '-u', local_path]
            logs.append(f"{'Force unmounting' if force else 'Unmounting'} {local_path}...")

            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode == 0:
                logs.append("✓ Unmount successful")
                return True, logs
            else:
                logs.append(f"✗ Unmount failed: {result.stderr}")
                return False, logs
        except Exception as e:
            logs.append(f"✗ Error: {e}")
            return False, logs

    def reset_mount(self, remote: str, local_path: str) -> Tuple[bool, List[str]]:
        """Unmount and remount a remote"""
        logs = []
        logs.append("Resetting mount...")

        success, umount_logs = self.umount_remote(local_path, force=True)
        logs.extend(umount_logs)

        time.sleep(2)

        success, mount_logs = self.mount_remote(remote, local_path)
        logs.extend(mount_logs)

        return success, logs

    # ==================== Sync Operations ====================

    def _parse_progress(self, line: str, job: Optional[SyncJob] = None) -> Dict[str, any]:
        """Parse rclone output for progress info"""
        info = {}

        # Parse transferred bytes
        m = self._progress_patterns['transferred'].search(line)
        if m:
            info['transferred'] = f"{m.group(1)} / {m.group(2)}"

        # Parse speed
        m = self._progress_patterns['speed'].search(line)
        if m:
            info['speed'] = m.group(1)

        # Parse ETA
        m = self._progress_patterns['eta'].search(line)
        if m:
            info['eta'] = m.group(1)

        # Parse percent
        m = self._progress_patterns['percent'].search(line)
        if m:
            info['percent'] = int(m.group(1))

        # Parse errors
        m = self._progress_patterns['errors'].search(line)
        if m:
            info['errors'] = int(m.group(1))

        # Update job if provided
        if job and info:
            if 'percent' in info:
                job.progress = info['percent']
            if 'transferred' in info:
                job.transferred = info['transferred']
            if 'speed' in info:
                job.speed = info['speed']
            if 'eta' in info:
                job.eta = info['eta']
            if 'errors' in info:
                job.errors_count = info['errors']

        return info

    def bisync(self, path1: str, path2: str,
              dry_run: bool = False, resync: bool = False,
              conflict_resolve: str = 'newer',
              progress_callback: Optional[Callable[[str, float], None]] = None) -> Tuple[bool, List[str]]:
        """Bidirectional sync between two paths

        Args:
            path1: First path (local or remote)
            path2: Second path (local or remote)
            dry_run: Only show what would be done
            resync: Force full resync (required on first run)
            conflict_resolve: How to resolve conflicts ('newer', 'larger', 'path1', 'path2')
            progress_callback: Callback (message, percent)

        Returns:
            Tuple of (success, log_messages)
        """
        logs = []

        def log(msg: str, pct: float = 0):
            logs.append(msg)
            if progress_callback:
                progress_callback(msg, pct)

        # Check if bisync state exists (needs resync on first run)
        bisync_cache = Path.home() / '.cache' / 'rclone' / 'bisync'
        needs_resync = resync or not bisync_cache.exists()

        cmd = [
            'rclone', 'bisync',
            path1, path2,
            '--tpslimit', str(self.tpslimit),
            '--drive-skip-gdocs',
            '--verbose',
            '--progress'
        ]

        if needs_resync:
            cmd.append('--resync')
            log("Note: Using --resync (first run or forced)")

        if dry_run:
            cmd.append('--dry-run')
            log("DRY RUN MODE - No changes will be made")

        # Add conflict resolution
        if conflict_resolve in ['path1', 'path2']:
            cmd.extend(['--conflict-resolve', conflict_resolve])

        log(f"Bisync: {path1} <-> {path2}", 0)

        try:
            process = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1
            )

            for line in process.stdout:
                line = line.strip()
                if line:
                    info = self._parse_progress(line)
                    if 'percent' in info:
                        log(f"Progress: {info.get('percent', 0)}% - {info.get('transferred', '')}", info['percent'])
                    elif 'ERROR' in line.upper():
                        log(f"ERROR: {line}", -1)

            process.wait()

            if process.returncode == 0:
                log("✓ Bisync complete", 100)
                return True, logs
            else:
                log(f"✗ Bisync failed (code {process.returncode})", 100)
                return False, logs

        except KeyboardInterrupt:
            log("Bisync cancelled by user")
            return False, logs
        except Exception as e:
            log(f"✗ Error: {e}")
            return False, logs

    def sync_one_direction(self, source: str, dest: str,
                          dry_run: bool = False, delete: bool = True,
                          progress_callback: Optional[Callable[[str, float], None]] = None) -> Tuple[bool, List[str]]:
        """One-direction sync from source to dest

        Args:
            source: Source path (local or remote)
            dest: Destination path (local or remote)
            dry_run: Only show what would be done
            delete: Delete files in dest not in source
            progress_callback: Callback (message, percent)

        Returns:
            Tuple of (success, log_messages)
        """
        logs = []

        def log(msg: str, pct: float = 0):
            logs.append(msg)
            if progress_callback:
                progress_callback(msg, pct)

        cmd = [
            'rclone', 'sync' if delete else 'copy',
            source, dest,
            '--tpslimit', str(self.tpslimit),
            '--drive-skip-gdocs',
            '--verbose',
            '--progress'
        ]

        if dry_run:
            cmd.append('--dry-run')
            log("DRY RUN MODE - No changes will be made")

        log(f"Sync: {source} -> {dest}", 0)

        try:
            process = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1
            )

            for line in process.stdout:
                line = line.strip()
                if line:
                    info = self._parse_progress(line)
                    if 'percent' in info:
                        log(f"Progress: {info.get('percent', 0)}%", info['percent'])

            process.wait()

            if process.returncode == 0:
                log("✓ Sync complete", 100)
                return True, logs
            else:
                log(f"✗ Sync failed (code {process.returncode})", 100)
                return False, logs

        except KeyboardInterrupt:
            log("Sync cancelled by user")
            return False, logs
        except Exception as e:
            log(f"✗ Error: {e}")
            return False, logs

    def run_sync_rule(self, repo: SyncRepo, dry_run: bool = False,
                     progress_callback: Optional[Callable[[str, float], None]] = None) -> Tuple[bool, List[str]]:
        """Execute a sync rule based on repo type

        Args:
            repo: SyncRepo with sync configuration
            dry_run: Only show what would be done
            progress_callback: Callback (message, percent)

        Returns:
            Tuple of (success, log_messages)
        """
        logs = []

        def log(msg: str, pct: float = 0):
            logs.append(msg)
            if progress_callback:
                progress_callback(msg, pct)

        log(f"Running sync rule: {repo.name}")
        log(f"Type: {repo.type.value}")
        log(f"Source: {repo.source}")
        log(f"Destination: {repo.destination}")

        # Ensure local paths exist
        for path in [repo.source, repo.destination]:
            if not path.startswith(('rclone:', 'Gdrive:', 'OneDrive:')) and ':' not in path:
                Path(path).mkdir(parents=True, exist_ok=True)

        if repo.type == RepoType.RCLONE_BISYNC:
            success, sync_logs = self.bisync(
                repo.source, repo.destination,
                dry_run=dry_run,
                conflict_resolve=repo.conflict_resolve,
                progress_callback=progress_callback
            )
            logs.extend(sync_logs)

        elif repo.type == RepoType.RCLONE_SYNC_TO_REMOTE:
            success, sync_logs = self.sync_one_direction(
                repo.source, repo.destination,
                dry_run=dry_run,
                delete=repo.delete_extra,
                progress_callback=progress_callback
            )
            logs.extend(sync_logs)

        elif repo.type == RepoType.RCLONE_SYNC_TO_LOCAL:
            success, sync_logs = self.sync_one_direction(
                repo.destination, repo.source,
                dry_run=dry_run,
                delete=repo.delete_extra,
                progress_callback=progress_callback
            )
            logs.extend(sync_logs)

        elif repo.type in (RepoType.RCLONE_LOCAL_SYNC, RepoType.RCLONE_LOCAL_BISYNC):
            # Local-to-local sync
            if repo.type == RepoType.RCLONE_LOCAL_BISYNC:
                success, sync_logs = self.bisync(
                    repo.source, repo.destination,
                    dry_run=dry_run,
                    progress_callback=progress_callback
                )
            else:
                success, sync_logs = self.sync_one_direction(
                    repo.source, repo.destination,
                    dry_run=dry_run,
                    delete=repo.delete_extra,
                    progress_callback=progress_callback
                )
            logs.extend(sync_logs)

        else:
            log(f"✗ Unknown sync type: {repo.type.value}")
            return False, logs

        return success, logs

    # ==================== Status Operations ====================

    def get_sync_status(self, repo: SyncRepo) -> SyncStatus:
        """Get sync status for a repo (checks for differences)"""
        # Basic status - more detailed checks would require rclone check
        source_exists = True
        dest_exists = True

        if not repo.source.startswith(('rclone:', 'Gdrive:', 'OneDrive:')) and ':' not in repo.source:
            source_exists = Path(repo.source).exists()

        if source_exists and dest_exists:
            return SyncStatus(
                local="OK",
                remote="Connected",
                sync_state=SyncState.UNKNOWN,
                details="Run sync to check"
            )
        else:
            return SyncStatus(
                local="Missing" if not source_exists else "OK",
                remote="Missing" if not dest_exists else "OK",
                sync_state=SyncState.ERROR,
                details="Path does not exist"
            )

    def check_differences(self, path1: str, path2: str) -> Tuple[int, int, List[str]]:
        """Check for differences between two paths

        Returns:
            Tuple of (files_different, files_same, list_of_differences)
        """
        try:
            result = subprocess.run(
                ['rclone', 'check', path1, path2, '--combined', '-'],
                capture_output=True, text=True, timeout=300
            )

            differences = []
            same = 0
            different = 0

            for line in result.stdout.split('\n'):
                if line.startswith('='):
                    same += 1
                elif line.startswith('+') or line.startswith('-') or line.startswith('*'):
                    different += 1
                    differences.append(line)

            return different, same, differences[:50]  # Limit to 50 differences

        except Exception as e:
            return -1, 0, [f"Error checking: {e}"]

    # ==================== Utility Operations ====================

    def dedupe(self, remote: str, mode: str = 'newest') -> Tuple[bool, List[str]]:
        """Remove duplicate files from remote

        Args:
            remote: Remote name
            mode: How to handle duplicates ('newest', 'oldest', 'largest', 'smallest')

        Returns:
            Tuple of (success, log_messages)
        """
        logs = []

        if ':' not in remote:
            remote = f"{remote}:"

        cmd = ['rclone', 'dedupe', '--dedupe-mode', mode, remote, '-v']
        logs.append(f"Deduplicating {remote} (mode: {mode})...")

        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
            logs.extend(result.stdout.strip().split('\n')[-10:])

            if result.returncode == 0:
                logs.append("✓ Dedupe complete")
                return True, logs
            else:
                logs.append(f"✗ Dedupe failed")
                return False, logs
        except Exception as e:
            logs.append(f"✗ Error: {e}")
            return False, logs

    def cleanup(self, remote: str) -> Tuple[bool, List[str]]:
        """Clean up remote (empty dirs, trash, etc.)

        Returns:
            Tuple of (success, log_messages)
        """
        logs = []

        if ':' not in remote:
            remote = f"{remote}:"

        logs.append(f"Cleaning up {remote}...")

        try:
            # Remove empty directories
            result = subprocess.run(
                ['rclone', 'rmdirs', remote, '-v'],
                capture_output=True, text=True, timeout=300
            )
            logs.append("Empty directories removed")

            # Empty trash (if supported)
            result = subprocess.run(
                ['rclone', 'cleanup', remote],
                capture_output=True, text=True, timeout=300
            )
            if result.returncode == 0:
                logs.append("Trash emptied")

            logs.append("✓ Cleanup complete")
            return True, logs
        except Exception as e:
            logs.append(f"✗ Error: {e}")
            return False, logs

    def refresh_cache(self, mountpoint: str) -> bool:
        """Refresh VFS cache for a mount"""
        try:
            # Find rc port from mount process
            result = subprocess.run(
                ['rclone', 'rc', '--rc-addr', '127.0.0.1:5572', 'vfs/refresh'],
                capture_output=True, timeout=30
            )
            return result.returncode == 0
        except:
            return False

    def get_space_info(self, remote: str) -> Dict[str, str]:
        """Get space usage info for remote"""
        about = self.get_about(remote)
        if about:
            def format_size(size_bytes):
                for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
                    if size_bytes < 1024:
                        return f"{size_bytes:.1f} {unit}"
                    size_bytes /= 1024
                return f"{size_bytes:.1f} PB"

            return {
                'used': format_size(about.get('used', 0)),
                'free': format_size(about.get('free', 0)),
                'total': format_size(about.get('total', 0)),
                'trashed': format_size(about.get('trashed', 0))
            }
        return {}
