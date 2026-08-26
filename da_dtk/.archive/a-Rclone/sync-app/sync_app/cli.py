"""
CLI handlers for sync-app
Command-line interface implementation
"""

import json
import sys
from typing import Optional
from .config import ConfigManager
from .git_manager import GitManager
from .rclone_manager import RcloneManager
from .job_manager import JobManager


class CLI:
    """Command-line interface handlers"""

    def __init__(self):
        """Initialize CLI with managers"""
        self.config = ConfigManager()
        self.git = GitManager(self.config.git_workdir)
        self.rclone = RcloneManager()
        self.jobs = JobManager()

    # --- Status Commands ---

    def cmd_status(self, args):
        """Show overall status"""
        print("\n=== Sync-App Status ===\n")

        # Git repos status
        print("Git Repositories:")
        print("-" * 80)
        git_repos = self.config.get_git_repos()

        if not git_repos:
            print("  No Git repositories configured")
        else:
            for repo in git_repos:
                status = self.git.get_sync_status(repo)
                print(f"  {repo.name:30} | Local: {status.local:15} | Remote: {status.remote:15} | CI: {status.ci_status}")

        print()

        # Rclone rules status
        print("Rclone Sync Rules:")
        print("-" * 80)
        rclone_repos = self.config.get_rclone_repos()

        if not rclone_repos:
            print("  No Rclone sync rules configured")
        else:
            for repo in rclone_repos:
                enabled = "✓" if repo.enabled else "✗"
                print(f"  [{enabled}] {repo.name:25} | {repo.source} → {repo.destination}")

        print()

        # Mounts status
        print("Rclone Mounts:")
        print("-" * 80)
        mounts = self.rclone.get_all_mounts()

        if not mounts:
            print("  No active mounts")
        else:
            for remote, mountpoint in mounts:
                print(f"  {remote:20} → {mountpoint}")

        print()

        # Running jobs
        running_jobs = self.jobs.get_running_jobs()
        if running_jobs:
            print("Running Jobs:")
            print("-" * 80)
            for job in running_jobs:
                print(f"  [{job.id}] {job.repo_name} - {job.action} ({job.progress:.0f}%)")
            print()

        return 0

    def cmd_status_json(self, args):
        """Show status as JSON"""
        status_data = {
            "git_repos": [],
            "rclone_rules": [],
            "mounts": [],
            "running_jobs": []
        }

        # Git repos
        for repo in self.config.get_git_repos():
            status = self.git.get_sync_status(repo)
            status_data["git_repos"].append({
                "name": repo.name,
                "path": repo.source,
                "url": repo.destination,
                "local": status.local,
                "remote": status.remote,
                "sync_state": status.sync_state.value,
                "ci_status": status.ci_status,
                "last_activity": status.last_activity
            })

        # Rclone rules
        for repo in self.config.get_rclone_repos():
            status_data["rclone_rules"].append({
                "name": repo.name,
                "type": repo.type.value,
                "source": repo.source,
                "destination": repo.destination,
                "enabled": repo.enabled
            })

        # Mounts
        for remote, mountpoint in self.rclone.get_all_mounts():
            status_data["mounts"].append({
                "remote": remote,
                "mountpoint": mountpoint
            })

        # Running jobs
        for job in self.jobs.get_running_jobs():
            status_data["running_jobs"].append({
                "id": job.id,
                "repo_name": job.repo_name,
                "action": job.action,
                "progress": job.progress,
                "start_time": job.start_time
            })

        print(json.dumps(status_data, indent=2))
        return 0

    # --- Git Commands ---

    def cmd_git_status(self, args):
        """Show Git repos status"""
        print("\n=== Git Repositories Status ===\n")
        git_repos = self.config.get_git_repos()

        if not git_repos:
            print("No Git repositories configured")
            return 1

        for repo in git_repos:
            status = self.git.get_sync_status(repo)
            print(f"{repo.name:30} | Local: {status.local:15} | Remote: {status.remote:15} | CI: {status.ci_status:10} | Last: {status.last_activity}")

        return 0

    def cmd_git_sync(self, args):
        """Sync Git repos"""
        git_repos = self.config.get_git_repos()

        if args.repo:
            # Sync specific repo
            git_repos = [r for r in git_repos if r.name == args.repo]
            if not git_repos:
                print(f"Error: Repository '{args.repo}' not found")
                return 1

        print(f"\n=== Syncing {len(git_repos)} Git repositories ===\n")

        for repo in git_repos:
            print(f"\n--- {repo.name} ---")
            success, logs = self.git.sync_repo(repo.source)
            for log in logs:
                print(f"  {log}")

        return 0

    def cmd_git_push(self, args):
        """Push Git repos"""
        git_repos = self.config.get_git_repos()

        if args.repo:
            git_repos = [r for r in git_repos if r.name == args.repo]
            if not git_repos:
                print(f"Error: Repository '{args.repo}' not found")
                return 1

        print(f"\n=== Pushing {len(git_repos)} Git repositories ===\n")

        for repo in git_repos:
            print(f"\n--- {repo.name} ---")
            success, logs = self.git.push_repo(repo.source)
            for log in logs:
                print(f"  {log}")

        return 0

    def cmd_git_pull(self, args):
        """Pull Git repos"""
        git_repos = self.config.get_git_repos()

        if args.repo:
            git_repos = [r for r in git_repos if r.name == args.repo]
            if not git_repos:
                print(f"Error: Repository '{args.repo}' not found")
                return 1

        print(f"\n=== Pulling {len(git_repos)} Git repositories ===\n")

        for repo in git_repos:
            print(f"\n--- {repo.name} ---")
            success, logs = self.git.pull_repo(repo.source)
            for log in logs:
                print(f"  {log}")

        return 0

    def cmd_git_fetch(self, args):
        """Fetch all Git repos"""
        git_repos = self.config.get_git_repos()

        print(f"\n=== Fetching {len(git_repos)} Git repositories ===\n")

        for repo in git_repos:
            print(f"\n--- {repo.name} ---")
            success, logs = self.git.fetch_repo(repo.source)
            for log in logs:
                print(f"  {log}")

        return 0

    # --- Rclone Commands ---

    def cmd_rclone_status(self, args):
        """Show Rclone status"""
        print("\n=== Rclone Sync Rules ===\n")
        rclone_repos = self.config.get_rclone_repos()

        if not rclone_repos:
            print("No Rclone sync rules configured")
            return 1

        for repo in rclone_repos:
            enabled = "✓" if repo.enabled else "✗"
            print(f"[{enabled}] {repo.name:25} | {repo.type.value:20} | {repo.source} → {repo.destination}")

        print("\n=== Active Mounts ===\n")
        mounts = self.rclone.get_all_mounts()

        if not mounts:
            print("No active mounts")
        else:
            for remote, mountpoint in mounts:
                print(f"{remote:20} → {mountpoint}")

        return 0

    def cmd_rclone_sync(self, args):
        """Run Rclone sync rules"""
        rclone_repos = self.config.get_rclone_repos()

        if args.rule:
            rclone_repos = [r for r in rclone_repos if r.name == args.rule]
            if not rclone_repos:
                print(f"Error: Sync rule '{args.rule}' not found")
                return 1

        # Filter to enabled rules only
        rclone_repos = [r for r in rclone_repos if r.enabled]

        print(f"\n=== Running {len(rclone_repos)} Rclone sync rules ===\n")

        for repo in rclone_repos:
            print(f"\n--- {repo.name} ---")
            success, logs = self.rclone.run_sync_rule(repo)
            for log in logs:
                print(f"  {log}")

        return 0

    def cmd_rclone_mount(self, args):
        """Mount Rclone remote"""
        remote = args.remote or 'Gdrive'
        local_path = self.config.rclone_mounts[0]['local'] if self.config.rclone_mounts else str(self.config.git_workdir.parent / 'Gdrive')

        print(f"\n=== Mounting {remote} ===\n")
        success, logs = self.rclone.mount_remote(remote, local_path)
        for log in logs:
            print(f"  {log}")

        return 0 if success else 1

    def cmd_rclone_umount(self, args):
        """Unmount Rclone remote"""
        if args.path:
            local_path = args.path
        else:
            # Use default from config
            local_path = self.config.rclone_mounts[0]['local'] if self.config.rclone_mounts else str(self.config.git_workdir.parent / 'Gdrive')

        print(f"\n=== Unmounting {local_path} ===\n")
        success, logs = self.rclone.umount_remote(local_path)
        for log in logs:
            print(f"  {log}")

        return 0 if success else 1

    # --- Jobs Commands ---

    def cmd_jobs(self, args):
        """View and manage jobs"""
        if args.clear:
            count = self.jobs.clear_completed_jobs()
            print(f"Cleared {count} completed jobs")
            return 0

        all_jobs = self.jobs.get_all_jobs()

        if not all_jobs:
            print("No jobs in history")
            return 0

        print("\n=== Jobs ===\n")

        # Running jobs
        running = [j for j in all_jobs if j.status == "running"]
        if running:
            print("Running:")
            for job in running:
                print(f"  [{job.id}] {job.repo_name} - {job.action} ({job.progress:.0f}%) - PID: {job.pid}")

        # Completed jobs
        completed = [j for j in all_jobs if j.status == "completed"]
        if completed:
            print("\nCompleted:")
            for job in completed[-10:]:  # Show last 10
                print(f"  [{job.id}] {job.repo_name} - {job.action} - {job.end_time}")

        # Failed jobs
        failed = [j for j in all_jobs if j.status == "failed"]
        if failed:
            print("\nFailed:")
            for job in failed[-10:]:  # Show last 10
                print(f"  [{job.id}] {job.repo_name} - {job.action} - Error: {job.error}")

        return 0
