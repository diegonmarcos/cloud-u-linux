#!/usr/bin/env python3
"""
Rclone Sync Manager
A comprehensive tool for managing rclone mount, sync, and bisync operations
with persistent sync rules management and background sync support.
"""

import os
import sys
import subprocess
import argparse
import json
import signal
import threading
import re
from pathlib import Path
from typing import List, Dict, Optional, Tuple
from dataclasses import dataclass, asdict, field
from datetime import datetime


@dataclass
class SyncJob:
    """Represents a running or completed background sync job"""
    job_id: str
    name: str  # Rule name or "Quick Sync"
    source: str
    dest: str
    sync_type: str
    status: str  # 'running', 'completed', 'failed', 'cancelled'
    started: str
    ended: Optional[str] = None
    pid: Optional[int] = None
    log_file: Optional[str] = None
    progress: str = ""
    error: Optional[str] = None


class Colors:
    """ANSI color codes for terminal output"""
    HEADER = '\033[95m'
    OKBLUE = '\033[94m'
    OKCYAN = '\033[96m'
    OKGREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'
    DIM = '\033[2m'


@dataclass
class SyncRule:
    """Represents a sync rule configuration"""
    name: str
    local_path: str
    remote: str  # e.g., "Gdrive:folder" or local path for local_to_local
    sync_type: str  # 'bisync', 'sync_to_remote', 'sync_to_local', 'local_to_local', 'local_bisync'
    conflict_resolve: str  # 'newer', 'larger', 'path1', 'path2'
    enabled: bool = True
    last_run: Optional[str] = None
    created: Optional[str] = None
    delete_extra: bool = True  # For one-way sync, whether to delete extra files in dest

    def __post_init__(self):
        if not self.created:
            self.created = datetime.now().isoformat()


class RcloneManager:
    """Main class for managing rclone operations"""

    def __init__(self):
        self.config_file = Path.home() / '.config' / 'rclone' / 'rclone.conf'
        self.config_dir = Path.home() / '.config' / 'rclone_manager'
        self.mount_config = self.config_dir / 'mounts.json'
        self.sync_rules_file = self.config_dir / 'sync_rules.json'
        self.sync_jobs_file = self.config_dir / 'sync_jobs.json'
        self.config_dir.mkdir(parents=True, exist_ok=True)

        # Default paths
        self.user = os.environ.get('USER') or os.environ.get('LOGNAME') or os.getlogin()
        self.default_mount = Path.home() / 'fuses' / 'Gdrive_me'
        self.log_dir = Path.home() / 'fuses' / 'Gdrive_me' / 'system' / '.rclone'
        self.sync_log_dir = self.config_dir / 'logs'
        self.sync_log_dir.mkdir(parents=True, exist_ok=True)
        self.default_remote = 'Gdrive'
        self.default_bisync_base = Path.home() / 'Documents/Gdrive_Syncs'

        # Job counter for unique IDs
        self._job_counter = 0

    # ==================== SYNC RULES MANAGEMENT ====================

    def load_sync_rules(self) -> List[SyncRule]:
        """Load sync rules from config file"""
        if not self.sync_rules_file.exists():
            return []
        try:
            with open(self.sync_rules_file, 'r') as f:
                data = json.load(f)
                return [SyncRule(**rule) for rule in data]
        except (json.JSONDecodeError, TypeError):
            return []

    def save_sync_rules(self, rules: List[SyncRule]) -> None:
        """Save sync rules to config file"""
        with open(self.sync_rules_file, 'w') as f:
            json.dump([asdict(r) for r in rules], f, indent=2)

    def add_sync_rule(self, rule: SyncRule) -> None:
        """Add a new sync rule"""
        rules = self.load_sync_rules()
        # Check for duplicate names
        if any(r.name == rule.name for r in rules):
            raise ValueError(f"Rule with name '{rule.name}' already exists")
        rules.append(rule)
        self.save_sync_rules(rules)

    def delete_sync_rule(self, name: str) -> bool:
        """Delete a sync rule by name"""
        rules = self.load_sync_rules()
        new_rules = [r for r in rules if r.name != name]
        if len(new_rules) == len(rules):
            return False
        self.save_sync_rules(new_rules)
        return True

    def update_rule_last_run(self, name: str) -> None:
        """Update the last run timestamp for a rule"""
        rules = self.load_sync_rules()
        for rule in rules:
            if rule.name == name:
                rule.last_run = datetime.now().isoformat()
                break
        self.save_sync_rules(rules)

    def get_enabled_rules(self) -> List[SyncRule]:
        """Get all enabled sync rules"""
        return [r for r in self.load_sync_rules() if r.enabled]

    # ==================== SYNC JOBS MANAGEMENT ====================

    def load_sync_jobs(self) -> List[SyncJob]:
        """Load sync jobs from config file"""
        if not self.sync_jobs_file.exists():
            return []
        try:
            with open(self.sync_jobs_file, 'r') as f:
                data = json.load(f)
                return [SyncJob(**job) for job in data]
        except (json.JSONDecodeError, TypeError):
            return []

    def save_sync_jobs(self, jobs: List[SyncJob]) -> None:
        """Save sync jobs to config file"""
        with open(self.sync_jobs_file, 'w') as f:
            json.dump([asdict(j) for j in jobs], f, indent=2)

    def add_sync_job(self, job: SyncJob) -> None:
        """Add a new sync job"""
        jobs = self.load_sync_jobs()
        jobs.append(job)
        # Keep only last 20 jobs
        if len(jobs) > 20:
            jobs = jobs[-20:]
        self.save_sync_jobs(jobs)

    def update_sync_job(self, job_id: str, **kwargs) -> None:
        """Update a sync job by ID"""
        jobs = self.load_sync_jobs()
        for job in jobs:
            if job.job_id == job_id:
                for key, value in kwargs.items():
                    if hasattr(job, key):
                        setattr(job, key, value)
                break
        self.save_sync_jobs(jobs)

    def get_running_jobs(self) -> List[SyncJob]:
        """Get all running sync jobs, verifying they're still running"""
        jobs = self.load_sync_jobs()
        running = []
        updated = False

        for job in jobs:
            if job.status == 'running':
                # Check if process is still running
                if job.pid:
                    try:
                        os.kill(job.pid, 0)  # Check if process exists
                        running.append(job)
                    except OSError:
                        # Process no longer running, update status
                        job.status = 'completed'
                        job.ended = datetime.now().isoformat()
                        # Check log for errors
                        if job.log_file and Path(job.log_file).exists():
                            with open(job.log_file, 'r') as f:
                                content = f.read()
                                if 'ERROR' in content or 'FAILED' in content:
                                    job.status = 'failed'
                        updated = True
                else:
                    running.append(job)

        if updated:
            self.save_sync_jobs(jobs)

        return running

    def get_job_progress(self, job: SyncJob) -> Dict[str, str]:
        """Get detailed progress info from job log file"""
        result = {
            'status': 'Starting...',
            'transferred': '',
            'speed': '',
            'eta': '',
            'percent': '',
            'files': '',
            'errors': '',
            'files_done': '',
            'files_total': ''
        }

        if not job.log_file or not Path(job.log_file).exists():
            result['status'] = "No log available"
            return result

        try:
            with open(job.log_file, 'r') as f:
                content = f.read()
                lines = content.split('\n')

                # Count files being processed
                copied_count = content.count('Copied (new)') + content.count('Copied (replaced')
                if copied_count > 0:
                    result['status'] = f'Copying files... ({copied_count} done)'

                # Parse the log for stats - rclone outputs stats periodically
                # Format: "Transferred:   	   1.234 GiB / 5.678 GiB, 22%, 10.5 MiB/s, ETA 5m30s"
                # Or with log level prefix: "<5>NOTICE: Transferred: ..."
                transferred_bytes_line = ''
                transferred_files_line = ''
                errors_line = ''

                for line in reversed(lines[-200:]):
                    line = line.strip()

                    # Match bytes transferred line
                    # Format: "Transferred:   	   1.234 GiB / 5.678 GiB, 22%, 10.5 MiB/s, ETA 5m30s"
                    if 'Transferred:' in line and ('/' in line) and ('B' in line or 'iB' in line):
                        if not transferred_bytes_line:
                            transferred_bytes_line = line

                            # Extract transferred/total bytes
                            # Pattern handles both "1.234 GiB" and "1.234GiB" formats
                            match = re.search(r'Transferred:\s*([\d.]+\s*\w*B)\s*/\s*([\d.]+\s*\w*B)', line, re.IGNORECASE)
                            if match:
                                result['transferred'] = f"{match.group(1).strip()} / {match.group(2).strip()}"

                            # Extract percentage
                            pct_match = re.search(r',\s*(\d+)%', line)
                            if pct_match:
                                result['percent'] = pct_match.group(1)

                            # Extract speed
                            speed_match = re.search(r'(\d+\.?\d*\s*\w*B/s)', line, re.IGNORECASE)
                            if speed_match:
                                result['speed'] = speed_match.group(1).strip()

                            # Extract ETA
                            eta_match = re.search(r'ETA\s+(\S+)', line)
                            if eta_match and eta_match.group(1) != '-':
                                result['eta'] = eta_match.group(1)

                    # Match files transferred line
                    # Format: "Transferred:            1 / 10, 10%"
                    elif 'Transferred:' in line and '/' in line and 'B' not in line.upper():
                        if not transferred_files_line:
                            transferred_files_line = line
                            match = re.search(r'Transferred:\s*(\d+)\s*/\s*(\d+)', line)
                            if match:
                                result['files_done'] = match.group(1)
                                result['files_total'] = match.group(2)
                                result['files'] = f"{match.group(1)}/{match.group(2)} files"

                    # Match errors line
                    if 'Errors:' in line and not errors_line:
                        errors_line = line
                        match = re.search(r'Errors:\s*(\d+)', line)
                        if match and int(match.group(1)) > 0:
                            result['errors'] = match.group(1)

                    # Check for fatal errors
                    if 'ERROR' in line and 'Fatal' in line:
                        result['status'] = 'Fatal error!'

                # Set status based on what we found
                if result['percent']:
                    pct = int(result['percent'])
                    if pct >= 100:
                        result['status'] = 'Finishing...'
                    else:
                        result['status'] = f"{pct}% complete"
                elif result['files']:
                    result['status'] = f"Transferring ({result['files']})"
                elif transferred_bytes_line:
                    result['status'] = 'Syncing...'

        except Exception as e:
            result['status'] = f"Error: {str(e)[:30]}"

        return result

    def get_job_progress_simple(self, job: SyncJob) -> str:
        """Get simple one-line progress string"""
        progress = self.get_job_progress(job)

        parts = []
        if progress['percent']:
            parts.append(f"{progress['percent']}%")
        if progress['transferred']:
            parts.append(progress['transferred'])
        if progress['speed']:
            parts.append(progress['speed'])
        if progress['eta']:
            parts.append(f"ETA: {progress['eta']}")
        if progress['errors']:
            parts.append(f"Errors: {progress['errors']}")

        if parts:
            return ' | '.join(parts)
        return progress['status']

    def cancel_sync_job(self, job_id: str) -> bool:
        """Cancel a running sync job"""
        jobs = self.load_sync_jobs()
        for job in jobs:
            if job.job_id == job_id and job.status == 'running' and job.pid:
                try:
                    os.kill(job.pid, signal.SIGTERM)
                    job.status = 'cancelled'
                    job.ended = datetime.now().isoformat()
                    self.save_sync_jobs(jobs)
                    return True
                except OSError:
                    pass
        return False

    def clear_completed_jobs(self) -> int:
        """Remove completed/failed/cancelled jobs from history"""
        jobs = self.load_sync_jobs()
        running = [j for j in jobs if j.status == 'running']
        removed = len(jobs) - len(running)
        self.save_sync_jobs(running)
        return removed

    def generate_job_id(self) -> str:
        """Generate a unique job ID"""
        self._job_counter += 1
        return f"job_{datetime.now().strftime('%Y%m%d_%H%M%S')}_{self._job_counter}"

    # ==================== RCLONE OPERATIONS ====================

    def check_rclone_installed(self) -> bool:
        """Check if rclone is installed"""
        try:
            subprocess.run(['rclone', 'version'],
                         stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL,
                         check=True)
            return True
        except (subprocess.CalledProcessError, FileNotFoundError):
            return False

    def run_rclone_config(self) -> None:
        """Open rclone configuration menu"""
        print(f"{Colors.HEADER}Opening rclone configuration...{Colors.ENDC}")
        try:
            subprocess.run(['rclone', 'config'], check=True)
        except subprocess.CalledProcessError as e:
            print(f"{Colors.FAIL}Error running rclone config: {e}{Colors.ENDC}")

    def get_mount_status(self, mountpoint: str) -> Tuple[bool, Optional[str]]:
        """Check if a path is mounted and get mount flags"""
        try:
            result = subprocess.run(['mount'],
                                  capture_output=True,
                                  text=True,
                                  check=True)
            for line in result.stdout.split('\n'):
                if mountpoint in line:
                    return True, line
            return False, None
        except subprocess.CalledProcessError:
            return False, None

    def get_all_mounts(self) -> List[Tuple[str, str]]:
        """Get all current rclone mounts and their mountpoints"""
        mounts = []
        try:
            result = subprocess.run(['mount'],
                                  capture_output=True,
                                  text=True,
                                  check=True)
            for line in result.stdout.split('\n'):
                if 'rclone' in line.lower() or line.startswith('rclone') or ':' in line:
                    parts = line.split()
                    if len(parts) >= 3 and parts[1] == 'on':
                        remote = parts[0]
                        mountpoint = parts[2]
                        mounts.append((remote, mountpoint))
            return mounts
        except subprocess.CalledProcessError:
            return []

    def mount_remote(self, remote: str, local_path: str, mode: str = 'daemon') -> bool:
        """Mount a remote with predefined options"""
        self.log_dir.mkdir(parents=True, exist_ok=True)
        log_file = self.log_dir / 'rclone.log'

        mount_path = Path(local_path)
        mount_path.mkdir(parents=True, exist_ok=True)

        if ':' not in remote:
            remote = f"{remote}:"

        mount_cmd = [
            'rclone', 'mount', remote,
            str(local_path),
            '--vfs-cache-mode', 'full',
            '--tpslimit', '10',
            '--vfs-cache-max-age', '1h',
            '--vfs-cache-max-size', '50G',
            '--vfs-read-chunk-size', '32M',
            '--vfs-read-chunk-size-limit', 'off',
            '--dir-cache-time', '10000h',
            '--drive-skip-gdocs',
            '--log-level', 'INFO',
            '--rc',
            '--rc-addr', '127.0.0.1:0',  # Use dynamic port to avoid conflicts
            '--log-file', str(log_file)
        ]

        try:
            print(f"{Colors.OKBLUE}Mounting {remote} to {local_path}...{Colors.ENDC}")
            print(f"{Colors.OKCYAN}Log file: {log_file}{Colors.ENDC}")

            if mode == 'daemon':
                mount_cmd.append('--daemon')
                print(f"{Colors.OKCYAN}Mode: Daemon (Background service){Colors.ENDC}")

                cmd_str = ' '.join([f"'{arg}'" if ' ' in arg else arg for arg in mount_cmd]) + ' &'
                subprocess.Popen(cmd_str, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

                import time
                time.sleep(2)

                is_mounted, _ = self.get_mount_status(str(local_path))
                if is_mounted:
                    print(f"{Colors.OKGREEN}✓ Successfully mounted!{Colors.ENDC}")
                    self.save_mount_config(remote, str(local_path))
                    return True
                else:
                    print(f"{Colors.WARNING}Mount process started, check log for issues{Colors.ENDC}")
                    self.save_mount_config(remote, str(local_path))
                    return True

            elif mode == 'silent':
                print(f"{Colors.OKCYAN}Mode: Silent (Background process){Colors.ENDC}")
                cmd_str = ' '.join([f"'{arg}'" if ' ' in arg else arg for arg in mount_cmd]) + ' &'
                subprocess.Popen(cmd_str, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

                import time
                time.sleep(2)

                is_mounted, _ = self.get_mount_status(str(local_path))
                if is_mounted:
                    print(f"{Colors.OKGREEN}✓ Successfully mounted!{Colors.ENDC}")
                    self.save_mount_config(remote, str(local_path))
                    return True
                else:
                    print(f"{Colors.WARNING}Mount process started in background{Colors.ENDC}")
                    self.save_mount_config(remote, str(local_path))
                    return True

            else:  # verbose
                print(f"{Colors.WARNING}Mode: Verbose (Foreground with logs){Colors.ENDC}")
                print(f"{Colors.WARNING}Press Ctrl+C to stop.{Colors.ENDC}")
                input(f"\n{Colors.OKGREEN}Press Enter to start...{Colors.ENDC}")
                subprocess.run(mount_cmd, check=False)
                return True

        except subprocess.CalledProcessError as e:
            print(f"{Colors.FAIL}Error mounting: {e}{Colors.ENDC}")
            return False
        except KeyboardInterrupt:
            print(f"\n{Colors.WARNING}Mount interrupted{Colors.ENDC}")
            return True

    def umount_remote(self, local_path: str, force: bool = False) -> bool:
        """Unmount a mounted remote"""
        try:
            if force:
                print(f"{Colors.WARNING}Force unmounting {local_path}...{Colors.ENDC}")
                subprocess.run(['fusermount', '-uz', local_path], check=True)
            else:
                print(f"{Colors.OKBLUE}Unmounting {local_path}...{Colors.ENDC}")
                subprocess.run(['fusermount', '-u', local_path], check=True)

            print(f"{Colors.OKGREEN}Successfully unmounted!{Colors.ENDC}")
            return True
        except subprocess.CalledProcessError as e:
            print(f"{Colors.FAIL}Error unmounting: {e}{Colors.ENDC}")
            return False

    def reset_mount(self, remote: str, local_path: str) -> bool:
        """Unmount and remount a remote"""
        print(f"{Colors.HEADER}Resetting mount...{Colors.ENDC}")
        self.umount_remote(local_path, force=True)
        return self.mount_remote(remote, local_path)

    def save_mount_config(self, remote: str, local_path: str) -> None:
        """Save mount configuration to file"""
        config = {}
        if self.mount_config.exists():
            with open(self.mount_config, 'r') as f:
                config = json.load(f)
        config[local_path] = remote
        with open(self.mount_config, 'w') as f:
            json.dump(config, f, indent=2)

    def load_mount_config(self) -> Dict[str, str]:
        """Load saved mount configurations"""
        if self.mount_config.exists():
            with open(self.mount_config, 'r') as f:
                return json.load(f)
        return {}

    def get_rclone_remotes(self) -> List[str]:
        """Get list of configured rclone remotes"""
        try:
            result = subprocess.run(['rclone', 'listremotes'],
                                  capture_output=True,
                                  text=True,
                                  check=True)
            remotes = [r.strip().rstrip(':') for r in result.stdout.strip().split('\n') if r.strip()]
            return remotes
        except subprocess.CalledProcessError:
            return []

    def list_remote_folders(self, remote: str, max_depth: int = 1) -> List[str]:
        """List folders in a remote"""
        try:
            if ':' not in remote:
                remote = f"{remote}:"

            result = subprocess.run(
                ['rclone', 'lsf', remote, '--dirs-only', f'--max-depth={max_depth}'],
                capture_output=True,
                text=True,
                check=True,
                timeout=10
            )
            folders = [f.strip().rstrip('/') for f in result.stdout.strip().split('\n') if f.strip()]
            return folders
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            return []

    # ==================== SYNC OPERATIONS ====================

    def sync_one_direction(self, source: str, dest: str, dry_run: bool = False,
                          delete: bool = True) -> bool:
        """
        One-direction sync from source to dest.

        Args:
            source: Source path (local or remote)
            dest: Destination path (local or remote)
            dry_run: If True, only show what would be done
            delete: If True, delete files in dest not in source
        """
        cmd = [
            'rclone', 'sync',
            source, dest,
            '--tpslimit', '10',
            '--drive-skip-gdocs',
            '--verbose',
            '--progress'
        ]

        if dry_run:
            cmd.append('--dry-run')

        if not delete:
            # Use copy instead of sync to not delete
            cmd[1] = 'copy'

        print(f"\n{Colors.HEADER}Sync: {source} → {dest}{Colors.ENDC}")
        if dry_run:
            print(f"{Colors.WARNING}DRY RUN MODE - No changes will be made{Colors.ENDC}")

        try:
            result = subprocess.run(cmd, check=False)
            if result.returncode == 0:
                print(f"{Colors.OKGREEN}✓ Sync completed successfully{Colors.ENDC}")
                return True
            else:
                print(f"{Colors.FAIL}✗ Sync failed with code {result.returncode}{Colors.ENDC}")
                return False
        except subprocess.CalledProcessError as e:
            print(f"{Colors.FAIL}Error during sync: {e}{Colors.ENDC}")
            return False
        except KeyboardInterrupt:
            print(f"\n{Colors.WARNING}Sync interrupted by user{Colors.ENDC}")
            return False

    def bisync(self, path1: str, path2: str, dry_run: bool = False,
               resync: bool = False, conflict_resolve: str = 'newer') -> bool:
        """
        Bidirectional sync between two paths.

        Args:
            path1: First path (usually remote)
            path2: Second path (usually local)
            dry_run: If True, only show what would be done
            resync: If True, force full resync
            conflict_resolve: How to resolve conflicts ('newer', 'larger', 'path1', 'path2')
        """
        # Check if bisync state exists
        bisync_cache = Path.home() / '.cache' / 'rclone' / 'bisync'
        needs_resync = resync or not bisync_cache.exists()

        cmd = [
            'rclone', 'bisync',
            path1, path2,
            '--tpslimit', '10',
            '--drive-skip-gdocs',
            '--verbose'
        ]

        if needs_resync:
            cmd.append('--resync')
            print(f"{Colors.WARNING}Note: Using --resync (first time or forced){Colors.ENDC}")

        if dry_run:
            cmd.append('--dry-run')

        # Add conflict resolution
        if conflict_resolve in ['path1', 'path2']:
            cmd.extend(['--conflict-resolve', conflict_resolve])

        print(f"\n{Colors.HEADER}Bisync: {path1} ↔ {path2}{Colors.ENDC}")
        if dry_run:
            print(f"{Colors.WARNING}DRY RUN MODE - No changes will be made{Colors.ENDC}")

        try:
            result = subprocess.run(cmd, check=False)
            if result.returncode == 0:
                print(f"{Colors.OKGREEN}✓ Bisync completed successfully{Colors.ENDC}")
                return True
            else:
                print(f"{Colors.FAIL}✗ Bisync failed with code {result.returncode}{Colors.ENDC}")
                return False
        except subprocess.CalledProcessError as e:
            print(f"{Colors.FAIL}Error during bisync: {e}{Colors.ENDC}")
            return False
        except KeyboardInterrupt:
            print(f"\n{Colors.WARNING}Bisync interrupted by user{Colors.ENDC}")
            return False

    def run_sync_rule(self, rule: SyncRule, dry_run: bool = False) -> bool:
        """Execute a sync rule"""
        print(f"\n{Colors.HEADER}{'='*60}{Colors.ENDC}")
        print(f"{Colors.HEADER}Running rule: {rule.name}{Colors.ENDC}")
        print(f"{Colors.HEADER}{'='*60}{Colors.ENDC}")
        print(f"{Colors.OKCYAN}Type: {rule.sync_type}{Colors.ENDC}")
        print(f"{Colors.OKCYAN}Source: {rule.local_path}{Colors.ENDC}")
        print(f"{Colors.OKCYAN}Destination: {rule.remote}{Colors.ENDC}")

        # Ensure local path exists
        local_path = Path(rule.local_path)
        if not local_path.exists():
            print(f"{Colors.WARNING}Source path doesn't exist, creating...{Colors.ENDC}")
            local_path.mkdir(parents=True, exist_ok=True)

        # For local rules, ensure destination also exists
        if rule.sync_type in ['local_to_local', 'local_bisync']:
            dest_path = Path(rule.remote)
            if not dest_path.exists():
                print(f"{Colors.WARNING}Destination path doesn't exist, creating...{Colors.ENDC}")
                dest_path.mkdir(parents=True, exist_ok=True)

        success = False

        if rule.sync_type == 'bisync':
            success = self.bisync(
                rule.remote, rule.local_path,
                dry_run=dry_run,
                conflict_resolve=rule.conflict_resolve
            )
        elif rule.sync_type == 'sync_to_remote':
            success = self.sync_one_direction(
                rule.local_path, rule.remote,
                dry_run=dry_run
            )
        elif rule.sync_type == 'sync_to_local':
            success = self.sync_one_direction(
                rule.remote, rule.local_path,
                dry_run=dry_run
            )
        elif rule.sync_type == 'local_to_local':
            success = self.sync_one_direction(
                rule.local_path, rule.remote,
                dry_run=dry_run,
                delete=rule.delete_extra
            )
        elif rule.sync_type == 'local_bisync':
            success = self.bisync(
                rule.local_path, rule.remote,
                dry_run=dry_run,
                conflict_resolve=rule.conflict_resolve
            )

        if success and not dry_run:
            self.update_rule_last_run(rule.name)

        return success

    # ==================== BACKGROUND SYNC OPERATIONS ====================

    def start_background_sync(self, source: str, dest: str, sync_type: str,
                              name: str = "Quick Sync", delete: bool = True,
                              resync: bool = False, conflict_resolve: str = 'newer',
                              rule_name: Optional[str] = None) -> SyncJob:
        """
        Start a sync operation in the background.

        Returns a SyncJob object that can be used to track progress.
        """
        job_id = self.generate_job_id()
        log_file = str(self.sync_log_dir / f"{job_id}.log")

        # Build the command based on sync type
        # Use --use-json-log for structured output that includes stats
        if sync_type in ['bisync', 'local_bisync']:
            cmd = [
                'rclone', 'bisync',
                source, dest,
                '--tpslimit', '10',
                '--drive-skip-gdocs',
                '-v',
                '--stats', '3s',  # Output stats every 3 seconds
                '--stats-log-level', 'NOTICE',  # Ensure stats are logged
            ]
            # Check if bisync state exists
            bisync_cache = Path.home() / '.cache' / 'rclone' / 'bisync'
            if resync or not bisync_cache.exists():
                cmd.append('--resync')
            if conflict_resolve in ['path1', 'path2']:
                cmd.extend(['--conflict-resolve', conflict_resolve])
        else:
            # One-direction sync
            if delete:
                cmd = ['rclone', 'sync']
            else:
                cmd = ['rclone', 'copy']

            cmd.extend([
                source, dest,
                '--tpslimit', '10',
                '--drive-skip-gdocs',
                '-v',
                '--stats', '3s',  # Output stats every 3 seconds
                '--stats-log-level', 'NOTICE',  # Ensure stats are logged
            ])

        # Start the process - capture all output to log file
        log_handle = open(log_file, 'w')
        process = subprocess.Popen(
            cmd,
            stdout=log_handle,
            stderr=subprocess.STDOUT,  # Redirect stderr to stdout (which goes to log)
            start_new_session=True  # Detach from terminal
        )

        # Create job record
        job = SyncJob(
            job_id=job_id,
            name=name,
            source=source,
            dest=dest,
            sync_type=sync_type,
            status='running',
            started=datetime.now().isoformat(),
            pid=process.pid,
            log_file=log_file
        )

        self.add_sync_job(job)

        return job

    def run_sync_rule_background(self, rule: SyncRule, resync: bool = False) -> SyncJob:
        """Execute a sync rule in the background"""
        # Ensure paths exist
        local_path = Path(rule.local_path)
        if not local_path.exists():
            local_path.mkdir(parents=True, exist_ok=True)

        if rule.sync_type in ['local_to_local', 'local_bisync']:
            dest_path = Path(rule.remote)
            if not dest_path.exists():
                dest_path.mkdir(parents=True, exist_ok=True)

        # Determine source and dest based on sync type
        if rule.sync_type == 'bisync':
            source, dest = rule.remote, rule.local_path
        elif rule.sync_type == 'sync_to_remote':
            source, dest = rule.local_path, rule.remote
        elif rule.sync_type == 'sync_to_local':
            source, dest = rule.remote, rule.local_path
        elif rule.sync_type in ['local_to_local', 'local_bisync']:
            source, dest = rule.local_path, rule.remote
        else:
            source, dest = rule.local_path, rule.remote

        job = self.start_background_sync(
            source=source,
            dest=dest,
            sync_type=rule.sync_type,
            name=rule.name,
            delete=rule.delete_extra,
            resync=resync,
            conflict_resolve=rule.conflict_resolve,
            rule_name=rule.name
        )

        return job

    def run_all_enabled_rules_background(self) -> List[SyncJob]:
        """Run all enabled sync rules in background"""
        rules = self.get_enabled_rules()
        jobs = []

        for rule in rules:
            job = self.run_sync_rule_background(rule)
            jobs.append(job)

        return jobs

    def run_all_enabled_rules(self, dry_run: bool = False) -> Dict[str, bool]:
        """Run all enabled sync rules"""
        rules = self.get_enabled_rules()
        results = {}

        if not rules:
            print(f"{Colors.WARNING}No enabled sync rules found{Colors.ENDC}")
            return results

        print(f"\n{Colors.HEADER}Running {len(rules)} enabled rule(s)...{Colors.ENDC}")

        for rule in rules:
            results[rule.name] = self.run_sync_rule(rule, dry_run)

        # Summary
        print(f"\n{Colors.HEADER}{'='*60}{Colors.ENDC}")
        print(f"{Colors.HEADER}SYNC SUMMARY{Colors.ENDC}")
        print(f"{Colors.HEADER}{'='*60}{Colors.ENDC}")
        for name, success in results.items():
            status = f"{Colors.OKGREEN}✓ SUCCESS{Colors.ENDC}" if success else f"{Colors.FAIL}✗ FAILED{Colors.ENDC}"
            print(f"  {name}: {status}")

        return results


class TUI:
    """Text User Interface for the rclone manager"""

    def __init__(self, manager: RcloneManager):
        self.manager = manager

    def clear_screen(self) -> None:
        """Clear terminal screen"""
        subprocess.run(['clear'], check=False)

    def print_header(self) -> None:
        """Print TUI header with status"""
        self.clear_screen()
        print(f"{Colors.BOLD}{Colors.HEADER}")
        print("╔" + "═" * 58 + "╗")
        print("║" + "RCLONE SYNC MANAGER".center(58) + "║")
        print("╚" + "═" * 58 + "╝")
        print(f"{Colors.ENDC}")

        # Mount Status
        default_mount = str(self.manager.default_mount)
        is_mounted, info = self.manager.get_mount_status(default_mount)

        print(f"{Colors.OKCYAN}┌─ Mount Status ─────────────────────────────────────────┐{Colors.ENDC}")
        print(f"{Colors.OKCYAN}│{Colors.ENDC} Mountpoint: {Colors.BOLD}{default_mount}{Colors.ENDC}")
        if is_mounted:
            print(f"{Colors.OKCYAN}│{Colors.ENDC} Status: {Colors.OKGREEN}● MOUNTED{Colors.ENDC}")
        else:
            print(f"{Colors.OKCYAN}│{Colors.ENDC} Status: {Colors.WARNING}○ NOT MOUNTED{Colors.ENDC}")
        print(f"{Colors.OKCYAN}└────────────────────────────────────────────────────────┘{Colors.ENDC}")

        # Sync Rules Status
        rules = self.manager.load_sync_rules()
        enabled_rules = [r for r in rules if r.enabled]

        print(f"{Colors.OKBLUE}┌─ Sync Rules ───────────────────────────────────────────┐{Colors.ENDC}")
        print(f"{Colors.OKBLUE}│{Colors.ENDC} Total: {len(rules)} | Enabled: {Colors.OKGREEN}{len(enabled_rules)}{Colors.ENDC} | Disabled: {Colors.DIM}{len(rules) - len(enabled_rules)}{Colors.ENDC}")

        if enabled_rules:
            print(f"{Colors.OKBLUE}│{Colors.ENDC}")
            for rule in enabled_rules[:3]:  # Show max 3 rules
                # Determine sync icon based on type
                if rule.sync_type == 'bisync':
                    sync_icon = "↔"
                elif rule.sync_type == 'local_bisync':
                    sync_icon = "⇄"
                elif rule.sync_type == 'sync_to_remote':
                    sync_icon = "→"
                elif rule.sync_type == 'sync_to_local':
                    sync_icon = "←"
                elif rule.sync_type == 'local_to_local':
                    sync_icon = "⟹"
                else:
                    sync_icon = "?"
                last_run = rule.last_run[:10] if rule.last_run else "never"
                print(f"{Colors.OKBLUE}│{Colors.ENDC}  {Colors.OKGREEN}●{Colors.ENDC} {rule.name} [{sync_icon}] (last: {last_run})")
            if len(enabled_rules) > 3:
                print(f"{Colors.OKBLUE}│{Colors.ENDC}  {Colors.DIM}... and {len(enabled_rules) - 3} more{Colors.ENDC}")
        else:
            print(f"{Colors.OKBLUE}│{Colors.ENDC}  {Colors.DIM}No enabled rules{Colors.ENDC}")

        print(f"{Colors.OKBLUE}└────────────────────────────────────────────────────────┘{Colors.ENDC}")

        # Running Jobs Status
        running_jobs = self.manager.get_running_jobs()
        all_jobs = self.manager.load_sync_jobs()
        completed_jobs = [j for j in all_jobs if j.status in ['completed', 'failed', 'cancelled']]

        if running_jobs or completed_jobs:
            print(f"{Colors.WARNING}┌─ Sync Jobs ────────────────────────────────────────────┐{Colors.ENDC}")

            if running_jobs:
                print(f"{Colors.WARNING}│{Colors.ENDC} {Colors.OKGREEN}Running: {len(running_jobs)}{Colors.ENDC}")
                for job in running_jobs[:2]:  # Show max 2 running jobs
                    progress = self.manager.get_job_progress(job)
                    elapsed = ""
                    try:
                        start = datetime.fromisoformat(job.started)
                        elapsed_sec = int((datetime.now() - start).total_seconds())
                        mins, secs = divmod(elapsed_sec, 60)
                        elapsed = f" ({mins}m{secs}s)"
                    except:
                        pass

                    # Build progress bar if we have percentage
                    progress_bar = ""
                    if progress['percent']:
                        pct = int(progress['percent'])
                        bar_width = 20
                        filled = int(bar_width * pct / 100)
                        progress_bar = f"[{'█' * filled}{'░' * (bar_width - filled)}] {pct}%"

                    print(f"{Colors.WARNING}│{Colors.ENDC}  {Colors.OKGREEN}▶{Colors.ENDC} {job.name}{elapsed}")

                    if progress_bar:
                        print(f"{Colors.WARNING}│{Colors.ENDC}    {Colors.OKCYAN}{progress_bar}{Colors.ENDC}")
                        # Show transfer details
                        details = []
                        if progress['transferred']:
                            details.append(progress['transferred'])
                        if progress['speed']:
                            details.append(progress['speed'])
                        if progress['eta']:
                            details.append(f"ETA: {progress['eta']}")
                        if details:
                            print(f"{Colors.WARNING}│{Colors.ENDC}    {Colors.DIM}{' | '.join(details)}{Colors.ENDC}")
                    else:
                        print(f"{Colors.WARNING}│{Colors.ENDC}    {Colors.DIM}{progress['status']}{Colors.ENDC}")

                    if progress['errors']:
                        print(f"{Colors.WARNING}│{Colors.ENDC}    {Colors.FAIL}Errors: {progress['errors']}{Colors.ENDC}")

                if len(running_jobs) > 2:
                    print(f"{Colors.WARNING}│{Colors.ENDC}  {Colors.DIM}... and {len(running_jobs) - 2} more running{Colors.ENDC}")
            else:
                print(f"{Colors.WARNING}│{Colors.ENDC} {Colors.DIM}No running syncs{Colors.ENDC}")

            # Show recent completed
            recent_completed = [j for j in completed_jobs if j.ended][-3:]
            if recent_completed:
                print(f"{Colors.WARNING}│{Colors.ENDC}")
                print(f"{Colors.WARNING}│{Colors.ENDC} Recent:")
                for job in reversed(recent_completed):
                    if job.status == 'completed':
                        icon = f"{Colors.OKGREEN}✓{Colors.ENDC}"
                    elif job.status == 'failed':
                        icon = f"{Colors.FAIL}✗{Colors.ENDC}"
                    else:
                        icon = f"{Colors.DIM}○{Colors.ENDC}"
                    ended = job.ended[:16].replace('T', ' ') if job.ended else ""
                    print(f"{Colors.WARNING}│{Colors.ENDC}  {icon} {job.name} ({ended})")

            print(f"{Colors.WARNING}└────────────────────────────────────────────────────────┘{Colors.ENDC}")

    def print_menu(self) -> None:
        """Print main menu"""
        print(f"\n{Colors.BOLD}━━━ MOUNT ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{Colors.ENDC}")
        print(f"  {Colors.BOLD}1.{Colors.ENDC} Mount Remote")
        print(f"  {Colors.BOLD}2.{Colors.ENDC} Unmount Remote")
        print(f"  {Colors.BOLD}3.{Colors.ENDC} Reset Mount (Unmount + Mount)")

        print(f"\n{Colors.BOLD}━━━ SYNC ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{Colors.ENDC}")
        print(f"  {Colors.BOLD}4.{Colors.ENDC} Quick Sync (One-time)")
        print(f"  {Colors.BOLD}5.{Colors.ENDC} Manage Sync Rules")
        print(f"  {Colors.BOLD}6.{Colors.ENDC} Run All Enabled Rules (Background)")

        print(f"\n{Colors.BOLD}━━━ STATUS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{Colors.ENDC}")
        print(f"  {Colors.BOLD}s.{Colors.ENDC} View Sync Jobs Status")
        print(f"  {Colors.BOLD}r.{Colors.ENDC} Refresh Status")

        print(f"\n{Colors.BOLD}━━━ CONFIG ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{Colors.ENDC}")
        print(f"  {Colors.BOLD}7.{Colors.ENDC} Rclone Configuration")
        print(f"  {Colors.BOLD}8.{Colors.ENDC} Edit Default Paths")
        print(f"  {Colors.BOLD}9.{Colors.ENDC} View Log File")

        print(f"\n  {Colors.BOLD}0.{Colors.ENDC} Exit")
        print()

    def get_input(self, prompt: str) -> str:
        """Get user input with prompt"""
        return input(f"{Colors.OKGREEN}{prompt}{Colors.ENDC}").strip()

    def pause(self) -> None:
        """Pause and wait for user input"""
        input(f"\n{Colors.WARNING}Press Enter to continue...{Colors.ENDC}")

    def select_remote(self) -> Optional[str]:
        """Interactive remote selection"""
        remotes = self.manager.get_rclone_remotes()
        if not remotes:
            print(f"{Colors.FAIL}No remotes configured! Run rclone config first.{Colors.ENDC}")
            return None

        print(f"\n{Colors.OKCYAN}Available remotes:{Colors.ENDC}")
        for i, r in enumerate(remotes, 1):
            marker = " (default)" if r == self.manager.default_remote else ""
            print(f"  {i}. {r}{marker}")

        choice = self.get_input(f"Select remote [1]: ") or '1'
        try:
            return remotes[int(choice) - 1]
        except (ValueError, IndexError):
            print(f"{Colors.FAIL}Invalid selection{Colors.ENDC}")
            return None

    def select_sync_type(self, include_local: bool = False) -> Optional[str]:
        """Interactive sync type selection"""
        print(f"\n{Colors.OKCYAN}Sync types:{Colors.ENDC}")
        print(f"  1. {Colors.OKGREEN}Bisync{Colors.ENDC} (↔) - Two-way sync, keeps both sides updated")
        print(f"  2. {Colors.OKBLUE}Sync to Remote{Colors.ENDC} (→) - Local overwrites remote")
        print(f"  3. {Colors.WARNING}Sync to Local{Colors.ENDC} (←) - Remote overwrites local")
        if include_local:
            print(f"  4. {Colors.OKCYAN}Local to Local{Colors.ENDC} (⇄) - Sync between two local folders")

        choice = self.get_input("Select type [1]: ") or '1'
        type_map = {'1': 'bisync', '2': 'sync_to_remote', '3': 'sync_to_local', '4': 'local_to_local'}
        return type_map.get(choice)

    def sync_jobs_status_menu(self) -> None:
        """View and manage sync jobs"""
        while True:
            self.clear_screen()
            print(f"{Colors.HEADER}━━━ Sync Jobs Status ━━━{Colors.ENDC}")
            print(f"{Colors.DIM}Press 'r' to refresh, 'c' to cancel a job, 'x' to clear history, 'b' to go back{Colors.ENDC}\n")

            running_jobs = self.manager.get_running_jobs()
            all_jobs = self.manager.load_sync_jobs()

            # Show running jobs
            if running_jobs:
                print(f"{Colors.OKGREEN}Running Jobs ({len(running_jobs)}):{Colors.ENDC}")
                print(f"{'─'*60}")
                for i, job in enumerate(running_jobs, 1):
                    progress = self.manager.get_job_progress(job)
                    elapsed = ""
                    try:
                        start = datetime.fromisoformat(job.started)
                        elapsed_sec = int((datetime.now() - start).total_seconds())
                        mins, secs = divmod(elapsed_sec, 60)
                        elapsed = f" ({mins}m {secs}s)"
                    except:
                        pass

                    sync_icon = "↔" if 'bisync' in job.sync_type else "→"
                    print(f"  {i}. {Colors.OKGREEN}▶{Colors.ENDC} {job.name}{elapsed}")
                    print(f"     {Colors.DIM}{job.source} {sync_icon} {job.dest}{Colors.ENDC}")

                    # Progress bar
                    if progress['percent']:
                        pct = int(progress['percent'])
                        bar_width = 30
                        filled = int(bar_width * pct / 100)
                        progress_bar = f"[{'█' * filled}{'░' * (bar_width - filled)}] {pct}%"
                        print(f"     {Colors.OKCYAN}{progress_bar}{Colors.ENDC}")

                        # Details line
                        details = []
                        if progress['transferred']:
                            details.append(progress['transferred'])
                        if progress['speed']:
                            details.append(progress['speed'])
                        if progress['eta']:
                            details.append(f"ETA: {progress['eta']}")
                        if details:
                            print(f"     {Colors.DIM}{' | '.join(details)}{Colors.ENDC}")
                    else:
                        print(f"     {Colors.OKCYAN}{progress['status']}{Colors.ENDC}")
                        if progress['files']:
                            print(f"     {Colors.DIM}{progress['files']}{Colors.ENDC}")

                    if progress['errors']:
                        print(f"     {Colors.FAIL}Errors: {progress['errors']}{Colors.ENDC}")
                    print()
                print(f"{'─'*60}")
            else:
                print(f"{Colors.DIM}No running sync jobs{Colors.ENDC}\n")

            # Show completed jobs
            completed = [j for j in all_jobs if j.status != 'running']
            if completed:
                print(f"\n{Colors.OKBLUE}Recent Jobs:{Colors.ENDC}")
                print(f"{'─'*60}")
                for job in reversed(completed[-10:]):  # Last 10 completed
                    if job.status == 'completed':
                        icon = f"{Colors.OKGREEN}✓{Colors.ENDC}"
                        status_text = "Completed"
                    elif job.status == 'failed':
                        icon = f"{Colors.FAIL}✗{Colors.ENDC}"
                        status_text = "Failed"
                    else:
                        icon = f"{Colors.DIM}○{Colors.ENDC}"
                        status_text = "Cancelled"

                    ended = job.ended[:16].replace('T', ' ') if job.ended else ""
                    duration = ""
                    try:
                        start = datetime.fromisoformat(job.started)
                        end = datetime.fromisoformat(job.ended) if job.ended else datetime.now()
                        dur_sec = int((end - start).total_seconds())
                        mins, secs = divmod(dur_sec, 60)
                        duration = f" (took {mins}m {secs}s)"
                    except:
                        pass

                    print(f"  {icon} {job.name} - {status_text}{duration}")
                    print(f"     {Colors.DIM}{ended}{Colors.ENDC}")
                print(f"{'─'*60}")

            print(f"\n{Colors.OKCYAN}Options:{Colors.ENDC}")
            print(f"  {Colors.BOLD}r{Colors.ENDC} - Refresh status")
            print(f"  {Colors.BOLD}c{Colors.ENDC} - Cancel a running job")
            print(f"  {Colors.BOLD}l{Colors.ENDC} - View job log")
            print(f"  {Colors.BOLD}x{Colors.ENDC} - Clear completed jobs")
            print(f"  {Colors.BOLD}b{Colors.ENDC} - Back to main menu")

            choice = self.get_input("\nSelect option: ").lower()

            if choice == 'r':
                continue  # Refresh by continuing the loop
            elif choice == 'c':
                if running_jobs:
                    idx = self.get_input("Enter job number to cancel: ")
                    try:
                        job = running_jobs[int(idx) - 1]
                        confirm = self.get_input(f"Cancel '{job.name}'? [n]: ") or 'n'
                        if confirm.lower() == 'y':
                            if self.manager.cancel_sync_job(job.job_id):
                                print(f"{Colors.OKGREEN}Job cancelled{Colors.ENDC}")
                            else:
                                print(f"{Colors.FAIL}Failed to cancel job{Colors.ENDC}")
                    except (ValueError, IndexError):
                        print(f"{Colors.FAIL}Invalid selection{Colors.ENDC}")
                    self.pause()
                else:
                    print(f"{Colors.WARNING}No running jobs to cancel{Colors.ENDC}")
                    self.pause()
            elif choice == 'l':
                # View log for a job
                print(f"\n{Colors.OKCYAN}Select job to view log:{Colors.ENDC}")
                all_display = running_jobs + [j for j in all_jobs if j.status != 'running'][-5:]
                for i, job in enumerate(all_display, 1):
                    status = f"{Colors.OKGREEN}▶{Colors.ENDC}" if job.status == 'running' else f"{Colors.DIM}○{Colors.ENDC}"
                    print(f"  {i}. {status} {job.name}")

                idx = self.get_input("Enter job number: ")
                try:
                    job = all_display[int(idx) - 1]
                    if job.log_file and Path(job.log_file).exists():
                        print(f"\n{Colors.HEADER}Log for {job.name}:{Colors.ENDC}")
                        print(f"{'─'*60}")
                        with open(job.log_file, 'r') as f:
                            lines = f.readlines()
                            for line in lines[-30:]:
                                print(line.rstrip())
                        print(f"{'─'*60}")
                    else:
                        print(f"{Colors.WARNING}Log file not found{Colors.ENDC}")
                except (ValueError, IndexError):
                    print(f"{Colors.FAIL}Invalid selection{Colors.ENDC}")
                self.pause()
            elif choice == 'x':
                confirm = self.get_input("Clear all completed jobs? [n]: ") or 'n'
                if confirm.lower() == 'y':
                    removed = self.manager.clear_completed_jobs()
                    print(f"{Colors.OKGREEN}Cleared {removed} completed job(s){Colors.ENDC}")
                self.pause()
            elif choice == 'b':
                break

    def quick_sync_menu(self) -> None:
        """Quick one-time sync menu"""
        print(f"\n{Colors.HEADER}━━━ Quick Sync ━━━{Colors.ENDC}")

        # First ask sync type to know if we need remote or local paths
        sync_type = self.select_sync_type(include_local=True)
        if not sync_type:
            print(f"{Colors.FAIL}Invalid sync type{Colors.ENDC}")
            return

        if sync_type == 'local_to_local':
            # Local to local sync
            print(f"\n{Colors.OKCYAN}Local to Local Sync{Colors.ENDC}")
            source = self.get_input("Source folder path: ")
            if not source:
                print(f"{Colors.FAIL}Source path required{Colors.ENDC}")
                return

            dest = self.get_input("Destination folder path: ")
            if not dest:
                print(f"{Colors.FAIL}Destination path required{Colors.ENDC}")
                return

            # Direction
            print(f"\n{Colors.OKCYAN}Sync direction:{Colors.ENDC}")
            print(f"  1. One-way (source → dest, dest files may be deleted)")
            print(f"  2. One-way copy (source → dest, no deletions)")
            print(f"  3. Bisync (↔ two-way)")

            dir_choice = self.get_input("Select [1]: ") or '1'

            # Ask for mode
            print(f"\n{Colors.OKCYAN}Run mode:{Colors.ENDC}")
            print(f"  1. Background (returns to menu, track via status)")
            print(f"  2. Foreground (wait for completion)")
            print(f"  3. Dry run (preview only)")

            mode_choice = self.get_input("Select [1]: ") or '1'

            if mode_choice == '3':
                # Dry run in foreground
                if dir_choice == '1':
                    self.manager.sync_one_direction(source, dest, dry_run=True, delete=True)
                elif dir_choice == '2':
                    self.manager.sync_one_direction(source, dest, dry_run=True, delete=False)
                elif dir_choice == '3':
                    self.manager.bisync(source, dest, dry_run=True)
                print(f"\n{Colors.WARNING}Dry run complete. Run again without dry-run to apply changes.{Colors.ENDC}")
            elif mode_choice == '2':
                # Foreground
                if dir_choice == '1':
                    self.manager.sync_one_direction(source, dest, dry_run=False, delete=True)
                elif dir_choice == '2':
                    self.manager.sync_one_direction(source, dest, dry_run=False, delete=False)
                elif dir_choice == '3':
                    resync = (self.get_input("Force resync? [n]: ") or 'n').lower() == 'y'
                    self.manager.bisync(source, dest, dry_run=False, resync=resync)
            else:
                # Background
                actual_sync_type = 'local_bisync' if dir_choice == '3' else 'local_to_local'
                delete = dir_choice == '1'
                resync = False
                if dir_choice == '3':
                    resync = (self.get_input("Force resync? [n]: ") or 'n').lower() == 'y'

                job = self.manager.start_background_sync(
                    source=source,
                    dest=dest,
                    sync_type=actual_sync_type,
                    name="Quick Local Sync",
                    delete=delete,
                    resync=resync
                )
                print(f"\n{Colors.OKGREEN}✓ Sync started in background!{Colors.ENDC}")
                print(f"{Colors.OKCYAN}Job ID: {job.job_id}{Colors.ENDC}")
                print(f"{Colors.DIM}Press 's' from main menu to view status{Colors.ENDC}")
        else:
            # Remote sync
            remote_name = self.select_remote()
            if not remote_name:
                return

            # Remote path
            remote_path = self.get_input("Remote path (e.g., folder/subfolder) [root]: ") or ""
            remote = f"{remote_name}:{remote_path}"

            # Local path
            default_local = str(self.manager.default_bisync_base)
            local = self.get_input(f"Local path [{default_local}]: ") or default_local

            # Ask for mode
            print(f"\n{Colors.OKCYAN}Run mode:{Colors.ENDC}")
            print(f"  1. Background (returns to menu, track via status)")
            print(f"  2. Foreground (wait for completion)")
            print(f"  3. Dry run (preview only)")

            mode_choice = self.get_input("Select [1]: ") or '1'

            if mode_choice == '3':
                # Dry run
                if sync_type == 'bisync':
                    self.manager.bisync(remote, local, dry_run=True)
                elif sync_type == 'sync_to_remote':
                    self.manager.sync_one_direction(local, remote, dry_run=True)
                elif sync_type == 'sync_to_local':
                    self.manager.sync_one_direction(remote, local, dry_run=True)
                print(f"\n{Colors.WARNING}Dry run complete. Run again without dry-run to apply changes.{Colors.ENDC}")
            elif mode_choice == '2':
                # Foreground
                if sync_type == 'bisync':
                    resync = (self.get_input("Force resync? [n]: ") or 'n').lower() == 'y'
                    self.manager.bisync(remote, local, dry_run=False, resync=resync)
                elif sync_type == 'sync_to_remote':
                    self.manager.sync_one_direction(local, remote, dry_run=False)
                elif sync_type == 'sync_to_local':
                    self.manager.sync_one_direction(remote, local, dry_run=False)
            else:
                # Background
                resync = False
                if sync_type == 'bisync':
                    resync = (self.get_input("Force resync? [n]: ") or 'n').lower() == 'y'

                # Determine source and dest based on sync type
                if sync_type == 'bisync':
                    src, dst = remote, local
                elif sync_type == 'sync_to_remote':
                    src, dst = local, remote
                else:  # sync_to_local
                    src, dst = remote, local

                job = self.manager.start_background_sync(
                    source=src,
                    dest=dst,
                    sync_type=sync_type,
                    name=f"Quick {sync_type.replace('_', ' ').title()}",
                    resync=resync
                )
                print(f"\n{Colors.OKGREEN}✓ Sync started in background!{Colors.ENDC}")
                print(f"{Colors.OKCYAN}Job ID: {job.job_id}{Colors.ENDC}")
                print(f"{Colors.DIM}Press 's' from main menu to view status{Colors.ENDC}")

    def manage_rules_menu(self) -> None:
        """Sync rules management submenu"""
        while True:
            self.clear_screen()
            rules = self.manager.load_sync_rules()

            print(f"{Colors.HEADER}━━━ Sync Rules Management ━━━{Colors.ENDC}")
            print()

            if rules:
                print(f"{Colors.OKCYAN}Current Rules:{Colors.ENDC}")
                print(f"{'─'*60}")
                for i, rule in enumerate(rules, 1):
                    status = f"{Colors.OKGREEN}●{Colors.ENDC}" if rule.enabled else f"{Colors.DIM}○{Colors.ENDC}"
                    # Determine sync icon based on type
                    if rule.sync_type == 'bisync':
                        sync_icon = "↔"
                    elif rule.sync_type == 'local_bisync':
                        sync_icon = "⇄"
                    elif rule.sync_type == 'sync_to_remote':
                        sync_icon = "→"
                    elif rule.sync_type == 'sync_to_local':
                        sync_icon = "←"
                    elif rule.sync_type == 'local_to_local':
                        sync_icon = "⟹"
                    else:
                        sync_icon = "?"
                    last_run = rule.last_run[:16].replace('T', ' ') if rule.last_run else "never"
                    # Show type label for local rules
                    type_label = " [LOCAL]" if rule.sync_type in ['local_to_local', 'local_bisync'] else ""
                    print(f"  {i}. {status} {rule.name}{type_label}")
                    print(f"     {Colors.DIM}{rule.local_path} {sync_icon} {rule.remote}{Colors.ENDC}")
                    print(f"     {Colors.DIM}Last run: {last_run}{Colors.ENDC}")
                print(f"{'─'*60}")
            else:
                print(f"{Colors.DIM}No sync rules configured{Colors.ENDC}")

            print(f"\n{Colors.OKCYAN}Options:{Colors.ENDC}")
            print(f"  {Colors.BOLD}a.{Colors.ENDC} Add new rule")
            print(f"  {Colors.BOLD}d.{Colors.ENDC} Delete rule")
            print(f"  {Colors.BOLD}t.{Colors.ENDC} Toggle rule (enable/disable)")
            print(f"  {Colors.BOLD}r.{Colors.ENDC} Run single rule")
            print(f"  {Colors.BOLD}b.{Colors.ENDC} Back to main menu")
            print()

            choice = self.get_input("Select option: ").lower()

            if choice == 'a':
                self.add_rule_wizard()
            elif choice == 'd':
                if rules:
                    idx = self.get_input("Enter rule number to delete: ")
                    try:
                        rule_name = rules[int(idx) - 1].name
                        confirm = self.get_input(f"Delete '{rule_name}'? [n]: ") or 'n'
                        if confirm.lower() == 'y':
                            self.manager.delete_sync_rule(rule_name)
                            print(f"{Colors.OKGREEN}Rule deleted{Colors.ENDC}")
                    except (ValueError, IndexError):
                        print(f"{Colors.FAIL}Invalid selection{Colors.ENDC}")
                self.pause()
            elif choice == 't':
                if rules:
                    idx = self.get_input("Enter rule number to toggle: ")
                    try:
                        rule = rules[int(idx) - 1]
                        rule.enabled = not rule.enabled
                        self.manager.save_sync_rules(rules)
                        status = "enabled" if rule.enabled else "disabled"
                        print(f"{Colors.OKGREEN}Rule '{rule.name}' {status}{Colors.ENDC}")
                    except (ValueError, IndexError):
                        print(f"{Colors.FAIL}Invalid selection{Colors.ENDC}")
                self.pause()
            elif choice == 'r':
                if rules:
                    idx = self.get_input("Enter rule number to run: ")
                    try:
                        rule = rules[int(idx) - 1]

                        print(f"\n{Colors.OKCYAN}Run mode:{Colors.ENDC}")
                        print(f"  1. Background (returns to menu, track via status)")
                        print(f"  2. Foreground (wait for completion)")
                        print(f"  3. Dry run (preview only)")

                        mode_choice = self.get_input("Select [1]: ") or '1'

                        if mode_choice == '3':
                            self.manager.run_sync_rule(rule, dry_run=True)
                            print(f"\n{Colors.WARNING}Dry run complete.{Colors.ENDC}")
                        elif mode_choice == '2':
                            self.manager.run_sync_rule(rule, dry_run=False)
                        else:
                            resync = False
                            if rule.sync_type in ['bisync', 'local_bisync']:
                                resync = (self.get_input("Force resync? [n]: ") or 'n').lower() == 'y'
                            job = self.manager.run_sync_rule_background(rule, resync=resync)
                            print(f"\n{Colors.OKGREEN}✓ Sync started in background!{Colors.ENDC}")
                            print(f"{Colors.OKCYAN}Job ID: {job.job_id}{Colors.ENDC}")
                            print(f"{Colors.DIM}Press 's' from main menu to view status{Colors.ENDC}")
                    except (ValueError, IndexError):
                        print(f"{Colors.FAIL}Invalid selection{Colors.ENDC}")
                self.pause()
            elif choice == 'b':
                break
            else:
                print(f"{Colors.FAIL}Invalid option{Colors.ENDC}")
                self.pause()

    def add_rule_wizard(self) -> None:
        """Wizard for adding a new sync rule"""
        print(f"\n{Colors.HEADER}━━━ Add New Sync Rule ━━━{Colors.ENDC}")

        # Rule name
        name = self.get_input("Rule name: ")
        if not name:
            print(f"{Colors.FAIL}Name is required{Colors.ENDC}")
            self.pause()
            return

        # Check for duplicates
        existing = [r.name for r in self.manager.load_sync_rules()]
        if name in existing:
            print(f"{Colors.FAIL}Rule '{name}' already exists{Colors.ENDC}")
            self.pause()
            return

        # Ask for rule type: remote or local
        print(f"\n{Colors.OKCYAN}Rule type:{Colors.ENDC}")
        print(f"  1. Remote sync (local ↔ cloud)")
        print(f"  2. Local sync (local ↔ local)")

        rule_type_choice = self.get_input("Select [1]: ") or '1'
        is_local_rule = rule_type_choice == '2'

        if is_local_rule:
            # Local to local rule
            print(f"\n{Colors.OKCYAN}Local to Local Sync Rule{Colors.ENDC}")

            # Source path
            source = self.get_input("Source folder path: ")
            if not source:
                print(f"{Colors.FAIL}Source path required{Colors.ENDC}")
                self.pause()
                return

            # Destination path
            dest = self.get_input("Destination folder path: ")
            if not dest:
                print(f"{Colors.FAIL}Destination path required{Colors.ENDC}")
                self.pause()
                return

            # Sync direction
            print(f"\n{Colors.OKCYAN}Sync type:{Colors.ENDC}")
            print(f"  1. One-way (source → dest, with deletions)")
            print(f"  2. One-way copy (source → dest, no deletions)")
            print(f"  3. Bisync (↔ two-way)")

            dir_choice = self.get_input("Select [1]: ") or '1'

            if dir_choice == '3':
                sync_type = 'local_bisync'
                delete_extra = True
            else:
                sync_type = 'local_to_local'
                delete_extra = dir_choice == '1'

            # Conflict resolution (for bisync)
            conflict_resolve = 'newer'
            if sync_type == 'local_bisync':
                print(f"\n{Colors.OKCYAN}Conflict resolution:{Colors.ENDC}")
                print(f"  1. newer - Keep newer file (default)")
                print(f"  2. larger - Keep larger file")
                print(f"  3. path1 - Source wins")
                print(f"  4. path2 - Destination wins")

                cr_choice = self.get_input("Select [1]: ") or '1'
                cr_map = {'1': 'newer', '2': 'larger', '3': 'path1', '4': 'path2'}
                conflict_resolve = cr_map.get(cr_choice, 'newer')

            # Create rule
            rule = SyncRule(
                name=name,
                local_path=source,
                remote=dest,  # For local rules, 'remote' stores the destination local path
                sync_type=sync_type,
                conflict_resolve=conflict_resolve,
                enabled=True,
                delete_extra=delete_extra
            )
        else:
            # Remote sync rule (original flow)
            remote_name = self.select_remote()
            if not remote_name:
                self.pause()
                return

            # Remote path
            print(f"\n{Colors.OKCYAN}Listing folders in {remote_name}...{Colors.ENDC}")
            folders = self.manager.list_remote_folders(remote_name)
            if folders:
                print(f"Available folders:")
                for i, f in enumerate(folders, 1):
                    print(f"  {i}. {f}")
                print(f"  0. Enter custom path")

                folder_choice = self.get_input("Select folder [0]: ") or '0'
                try:
                    idx = int(folder_choice)
                    if idx > 0 and idx <= len(folders):
                        remote_path = folders[idx - 1]
                    else:
                        remote_path = self.get_input("Enter remote path: ").strip('/')
                except ValueError:
                    remote_path = self.get_input("Enter remote path: ").strip('/')
            else:
                remote_path = self.get_input("Enter remote path (empty for root): ").strip('/')

            remote = f"{remote_name}:{remote_path}"

            # Local path
            default_local = str(self.manager.default_bisync_base / (remote_path or remote_name))
            local = self.get_input(f"Local path [{default_local}]: ") or default_local

            # Sync type
            sync_type = self.select_sync_type()
            if not sync_type:
                print(f"{Colors.FAIL}Invalid sync type{Colors.ENDC}")
                self.pause()
                return

            # Conflict resolution (for bisync)
            conflict_resolve = 'newer'
            if sync_type == 'bisync':
                print(f"\n{Colors.OKCYAN}Conflict resolution:{Colors.ENDC}")
                print(f"  1. newer - Keep newer file (default)")
                print(f"  2. larger - Keep larger file")
                print(f"  3. path1 - Remote wins")
                print(f"  4. path2 - Local wins")

                cr_choice = self.get_input("Select [1]: ") or '1'
                cr_map = {'1': 'newer', '2': 'larger', '3': 'path1', '4': 'path2'}
                conflict_resolve = cr_map.get(cr_choice, 'newer')

            # Create rule
            rule = SyncRule(
                name=name,
                local_path=local,
                remote=remote,
                sync_type=sync_type,
                conflict_resolve=conflict_resolve,
                enabled=True
            )

        try:
            self.manager.add_sync_rule(rule)
            print(f"\n{Colors.OKGREEN}✓ Rule '{name}' created successfully!{Colors.ENDC}")
        except ValueError as e:
            print(f"{Colors.FAIL}Error: {e}{Colors.ENDC}")

        self.pause()

    def mount_menu(self) -> None:
        """Mount remote menu"""
        remote_name = self.select_remote()
        if not remote_name:
            self.pause()
            return

        # Remote path
        use_root = (self.get_input("Mount root folder? [y]: ") or 'y').lower()
        remote_path = ""

        if use_root != 'y':
            print(f"\n{Colors.OKCYAN}Listing folders in {remote_name}...{Colors.ENDC}")
            folders = self.manager.list_remote_folders(remote_name)
            if folders:
                for i, f in enumerate(folders, 1):
                    print(f"  {i}. {f}")
                print(f"  0. Enter custom path")

                folder_choice = self.get_input("Select folder [0]: ") or '0'
                try:
                    idx = int(folder_choice)
                    if idx > 0 and idx <= len(folders):
                        remote_path = folders[idx - 1]
                    else:
                        remote_path = self.get_input("Enter remote path: ").strip('/')
                except ValueError:
                    remote_path = self.get_input("Enter remote path: ").strip('/')
            else:
                remote_path = self.get_input("Enter remote path: ").strip('/')

        remote = f"{remote_name}:{remote_path}"

        # Local path
        default_local = str(self.manager.default_mount)
        local = self.get_input(f"Local mountpoint [{default_local}]: ") or default_local

        # Mount mode
        print(f"\n{Colors.OKCYAN}Mount modes:{Colors.ENDC}")
        print(f"  1. Daemon (Background service) - Default")
        print(f"  2. Silent (Background process)")
        print(f"  3. Verbose (Foreground with logs)")

        mode_choice = self.get_input("Select mode [1]: ") or '1'
        mode_map = {'1': 'daemon', '2': 'silent', '3': 'verbose'}
        mode = mode_map.get(mode_choice, 'daemon')

        self.manager.mount_remote(remote, local, mode)

        if mode != 'verbose':
            self.pause()

    def umount_menu(self) -> None:
        """Unmount menu"""
        mounts = self.manager.get_all_mounts()
        default_mount = str(self.manager.default_mount)

        if mounts:
            print(f"\n{Colors.OKCYAN}Currently mounted:{Colors.ENDC}")
            for i, (remote, mountpoint) in enumerate(mounts, 1):
                print(f"  {i}. {mountpoint} <- {remote}")
            print(f"  0. Enter custom path")

            choice = self.get_input("Select mount to unmount [0]: ") or '0'
            try:
                idx = int(choice)
                if idx > 0 and idx <= len(mounts):
                    local = mounts[idx - 1][1]
                else:
                    local = self.get_input(f"Enter mountpoint [{default_mount}]: ") or default_mount
            except ValueError:
                local = self.get_input(f"Enter mountpoint [{default_mount}]: ") or default_mount
        else:
            print(f"{Colors.WARNING}No rclone mounts found{Colors.ENDC}")
            local = self.get_input(f"Enter mountpoint [{default_mount}]: ") or default_mount

        force = (self.get_input("Force unmount? [n]: ") or 'n').lower() == 'y'
        self.manager.umount_remote(local, force)

    def run(self) -> None:
        """Run the TUI main loop"""
        if not self.manager.check_rclone_installed():
            print(f"{Colors.FAIL}Error: rclone is not installed!{Colors.ENDC}")
            print("Please install rclone: https://rclone.org/install/")
            sys.exit(1)

        while True:
            self.print_header()
            self.print_menu()

            choice = self.get_input("Select option: ")

            if choice == '1':
                self.mount_menu()
                self.pause()

            elif choice == '2':
                self.umount_menu()
                self.pause()

            elif choice == '3':
                remote_name = self.select_remote()
                if remote_name:
                    remote_path = self.get_input("Remote path [root]: ").strip('/')
                    remote = f"{remote_name}:{remote_path}"
                    default_local = str(self.manager.default_mount)
                    local = self.get_input(f"Local mountpoint [{default_local}]: ") or default_local
                    self.manager.reset_mount(remote, local)
                self.pause()

            elif choice == '4':
                self.quick_sync_menu()
                self.pause()

            elif choice == '5':
                self.manage_rules_menu()

            elif choice == '6':
                # Run all enabled rules
                print(f"\n{Colors.OKCYAN}Run mode:{Colors.ENDC}")
                print(f"  1. Background (returns to menu, track via status)")
                print(f"  2. Foreground (wait for completion)")
                print(f"  3. Dry run (preview only)")

                mode_choice = self.get_input("Select [1]: ") or '1'

                if mode_choice == '3':
                    self.manager.run_all_enabled_rules(dry_run=True)
                    print(f"\n{Colors.WARNING}Dry run complete. Run again without dry-run to apply.{Colors.ENDC}")
                elif mode_choice == '2':
                    self.manager.run_all_enabled_rules(dry_run=False)
                else:
                    jobs = self.manager.run_all_enabled_rules_background()
                    if jobs:
                        print(f"\n{Colors.OKGREEN}✓ Started {len(jobs)} sync job(s) in background!{Colors.ENDC}")
                        for job in jobs:
                            print(f"  {Colors.OKCYAN}▶{Colors.ENDC} {job.name}")
                        print(f"\n{Colors.DIM}Press 's' to view status{Colors.ENDC}")
                    else:
                        print(f"{Colors.WARNING}No enabled rules to run{Colors.ENDC}")
                self.pause()

            elif choice == 's':
                self.sync_jobs_status_menu()

            elif choice == 'r':
                # Refresh - just continue to redraw header
                continue

            elif choice == '7':
                self.manager.run_rclone_config()
                self.pause()

            elif choice == '8':
                print(f"\n{Colors.OKCYAN}Current paths:{Colors.ENDC}")
                print(f"  Default mount: {self.manager.default_mount}")
                print(f"  Default remote: {self.manager.default_remote}")
                print(f"  Bisync base: {self.manager.default_bisync_base}")
                print(f"  Log dir: {self.manager.log_dir}")

                new_mount = self.get_input(f"\nNew default mount path (empty to skip): ")
                if new_mount:
                    self.manager.default_mount = Path(new_mount)
                    self.manager.log_dir = Path(new_mount) / 'system' / '.rclone'
                    print(f"{Colors.OKGREEN}Mount path updated{Colors.ENDC}")

                new_bisync = self.get_input("New bisync base path (empty to skip): ")
                if new_bisync:
                    self.manager.default_bisync_base = Path(new_bisync)
                    print(f"{Colors.OKGREEN}Bisync base updated{Colors.ENDC}")

                self.pause()

            elif choice == '9':
                log_file = self.manager.log_dir / 'rclone.log'
                if log_file.exists():
                    print(f"\n{Colors.HEADER}Last 50 lines of log:{Colors.ENDC}")
                    try:
                        with open(log_file, 'r') as f:
                            lines = f.readlines()
                            for line in lines[-50:]:
                                print(line.rstrip())
                    except Exception as e:
                        print(f"{Colors.FAIL}Error reading log: {e}{Colors.ENDC}")
                else:
                    print(f"{Colors.WARNING}Log file not found: {log_file}{Colors.ENDC}")
                self.pause()

            elif choice == '0':
                print(f"{Colors.OKGREEN}Goodbye!{Colors.ENDC}")
                sys.exit(0)

            else:
                print(f"{Colors.FAIL}Invalid option!{Colors.ENDC}")
                self.pause()


def print_help() -> None:
    """Print help message"""
    help_text = f"""
{Colors.BOLD}Rclone Sync Manager{Colors.ENDC}

{Colors.HEADER}USAGE:{Colors.ENDC}
    rclone.py [OPTIONS]

{Colors.HEADER}OPTIONS:{Colors.ENDC}
    -h, --help              Show this help message
    --config                Open rclone configuration
    --mount REMOTE LOCAL    Mount remote to local path
    --umount LOCAL          Unmount local path
    --sync SRC DEST         One-way sync from SRC to DEST
    --bisync PATH1 PATH2    Two-way sync between paths
    --run-rules             Run all enabled sync rules
    --list-rules            List all sync rules

{Colors.HEADER}EXAMPLES:{Colors.ENDC}
    {Colors.OKGREEN}# Start TUI{Colors.ENDC}
    ./rclone.py

    {Colors.OKGREEN}# Mount a remote{Colors.ENDC}
    ./rclone.py --mount gdrive:folder /mnt/gdrive

    {Colors.OKGREEN}# One-way sync local to remote{Colors.ENDC}
    ./rclone.py --sync /local/folder gdrive:backup

    {Colors.OKGREEN}# Bidirectional sync{Colors.ENDC}
    ./rclone.py --bisync gdrive:docs /local/docs

    {Colors.OKGREEN}# Run all enabled rules{Colors.ENDC}
    ./rclone.py --run-rules

{Colors.HEADER}CONFIGURATION:{Colors.ENDC}
    Config directory: ~/.config/rclone_manager/
    - mounts.json: Mount configurations
    - sync_rules.json: Sync rules
"""
    print(help_text)


def main() -> None:
    """Main entry point"""
    manager = RcloneManager()

    if len(sys.argv) == 1:
        tui = TUI(manager)
        tui.run()
        return

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('-h', '--help', action='store_true')
    parser.add_argument('--config', action='store_true')
    parser.add_argument('--mount', nargs=2, metavar=('REMOTE', 'LOCAL'))
    parser.add_argument('--umount', metavar='LOCAL')
    parser.add_argument('--force', action='store_true')
    parser.add_argument('--sync', nargs=2, metavar=('SRC', 'DEST'))
    parser.add_argument('--bisync', nargs=2, metavar=('PATH1', 'PATH2'))
    parser.add_argument('--run-rules', action='store_true')
    parser.add_argument('--list-rules', action='store_true')
    parser.add_argument('--dry-run', action='store_true')

    try:
        args = parser.parse_args()
    except SystemExit:
        print_help()
        sys.exit(1)

    if args.help:
        print_help()
        sys.exit(0)

    if not manager.check_rclone_installed():
        print(f"{Colors.FAIL}Error: rclone is not installed!{Colors.ENDC}")
        sys.exit(1)

    if args.config:
        manager.run_rclone_config()
    elif args.mount:
        remote, local = args.mount
        manager.mount_remote(remote, local)
    elif args.umount:
        manager.umount_remote(args.umount, args.force)
    elif args.sync:
        src, dest = args.sync
        manager.sync_one_direction(src, dest, dry_run=args.dry_run)
    elif args.bisync:
        path1, path2 = args.bisync
        manager.bisync(path1, path2, dry_run=args.dry_run)
    elif args.run_rules:
        manager.run_all_enabled_rules(dry_run=args.dry_run)
    elif args.list_rules:
        rules = manager.load_sync_rules()
        if rules:
            print(f"{Colors.HEADER}Sync Rules:{Colors.ENDC}")
            for rule in rules:
                status = "●" if rule.enabled else "○"
                print(f"  {status} {rule.name}: {rule.local_path} <-> {rule.remote} ({rule.sync_type})")
        else:
            print(f"{Colors.WARNING}No sync rules configured{Colors.ENDC}")
    else:
        print(f"{Colors.FAIL}Invalid arguments!{Colors.ENDC}")
        print_help()
        sys.exit(1)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print(f"\n{Colors.WARNING}Interrupted by user{Colors.ENDC}")
        sys.exit(0)
    except Exception as e:
        print(f"{Colors.FAIL}Unexpected error: {e}{Colors.ENDC}")
        sys.exit(1)
