"""
Simple TUI (Terminal User Interface) for sync-app
Uses simple terminal output instead of curses (more compatible)
"""

import os
import time
import sys
from .config import ConfigManager
from .git_manager import GitManager
from .rclone_manager import RcloneManager
from .job_manager import JobManager


class SimpleTUI:
    """Simple Terminal User Interface without curses"""

    def __init__(self):
        """Initialize SimpleTUI"""
        self.config = ConfigManager()
        self.git = GitManager(self.config.git_workdir)
        self.rclone = RcloneManager()
        self.jobs = JobManager()

    def clear_screen(self):
        """Clear the terminal screen"""
        os.system('clear' if os.name != 'nt' else 'cls')

    def run(self):
        """Run the TUI"""
        try:
            while True:
                self.clear_screen()
                self.draw_screen()

                print("\n" + "=" * 80)
                print("Commands: [r]efresh  [s]tatus  [g]it  [rc]lone  [j]obs  [q]uit  [?]help")
                print("=" * 80)
                print("Enter command: ", end='', flush=True)

                # Simple blocking input
                cmd = input().strip().lower()

                if cmd == 'q':
                    break
                elif cmd == 'r' or cmd == '':
                    continue  # Just refresh
                elif cmd == '?':
                    self.show_help()
                elif cmd == 's':
                    self.show_full_status()
                elif cmd == 'g':
                    self.show_git_menu()
                elif cmd == 'rc':
                    self.show_rclone_menu()
                elif cmd == 'j':
                    self.show_jobs()

        except KeyboardInterrupt:
            print("\nExiting...")
        except EOFError:
            print("\nExiting...")

    def draw_screen(self):
        """Draw the main screen"""
        # Header
        header = "SYNC-APP - Unified Git & Rclone Sync Manager"
        print("=" * 80)
        print(header.center(80))
        print("=" * 80)
        print()

        # Git Repositories
        print("📁 GIT REPOSITORIES")
        print("-" * 80)
        print(f"{'Name':<30} | {'Local':<15} | {'Remote':<15} | {'CI':<10}")
        print("-" * 80)

        git_repos = self.config.get_git_repos()
        for repo in git_repos[:10]:  # Show first 10 to fit on screen
            try:
                status = self.git.get_sync_status(repo)

                # Color based on status
                if "Uncommitted" in status.local or "Unpushed" in status.local:
                    status_symbol = "🟡"
                elif "To Pull" in status.remote:
                    status_symbol = "🟡"
                else:
                    status_symbol = "🟢"

                print(f"{status_symbol} {repo.name:<28} | {status.local:<15} | {status.remote:<15} | {status.ci_status:<10}")
            except Exception as e:
                print(f"❌ {repo.name:<28} | Error: {str(e)[:50]}")

        if len(git_repos) > 10:
            print(f"... and {len(git_repos) - 10} more repos (use 's' to see all)")

        print()

        # Rclone Sync Rules
        print("🔄 RCLONE SYNC RULES")
        print("-" * 80)

        rclone_repos = self.config.get_rclone_repos()
        if not rclone_repos:
            print("  No sync rules configured")
        else:
            for repo in rclone_repos:
                enabled = "✓" if repo.enabled else "✗"
                symbol = "🟢" if repo.enabled else "⚪"
                print(f"{symbol} [{enabled}] {repo.name:<25} | {repo.source} → {repo.destination}")

        print()

        # Active Mounts
        print("💾 ACTIVE MOUNTS")
        print("-" * 80)

        mounts = self.rclone.get_all_mounts()
        if not mounts:
            print("  No active mounts")
        else:
            for remote, mountpoint in mounts:
                print(f"🟢 {remote:<20} → {mountpoint}")

        print()

        # Running Jobs
        running_jobs = self.jobs.get_running_jobs()
        if running_jobs:
            print("⚙️  RUNNING JOBS")
            print("-" * 80)
            for job in running_jobs:
                print(f"  [{job.id}] {job.repo_name} - {job.action} ({job.progress:.0f}%) - PID: {job.pid}")
            print()

    def show_help(self):
        """Show help screen"""
        self.clear_screen()
        print("=" * 80)
        print("SYNC-APP HELP".center(80))
        print("=" * 80)
        print()
        print("Interactive Commands:")
        print("  r         - Refresh display")
        print("  s         - Show full status")
        print("  g         - Git operations menu")
        print("  rc        - Rclone operations menu")
        print("  j         - View jobs")
        print("  q         - Quit")
        print("  ?         - Show this help")
        print()
        print("Command Line Usage:")
        print("  ./sync-app.py status            - Show all status")
        print("  ./sync-app.py git status        - Git repos only")
        print("  ./sync-app.py git sync          - Sync all Git repos")
        print("  ./sync-app.py rclone status     - Rclone status")
        print("  ./sync-app.py rclone mount      - Mount default remote")
        print("  ./sync-app.py --help            - Full help")
        print()
        input("Press Enter to return...")

    def show_full_status(self):
        """Show full status (all repos)"""
        self.clear_screen()
        print("=" * 80)
        print("FULL STATUS".center(80))
        print("=" * 80)
        print()

        print("GIT REPOSITORIES")
        print("-" * 80)

        git_repos = self.config.get_git_repos()
        for repo in git_repos:
            status = self.git.get_sync_status(repo)
            print(f"{repo.name:<30} | {status.local:<15} | {status.remote:<15} | {status.ci_status:<10}")

        print()
        input("Press Enter to return...")

    def show_git_menu(self):
        """Show Git operations menu"""
        self.clear_screen()
        print("=" * 80)
        print("GIT OPERATIONS".center(80))
        print("=" * 80)
        print()
        print("1. Show status")
        print("2. Sync all repos")
        print("3. Push all repos")
        print("4. Pull all repos")
        print("5. Fetch all repos")
        print("0. Back")
        print()
        choice = input("Choose option: ").strip()

        if choice == '1':
            os.system('./sync-app.py git status | less')
        elif choice == '2':
            os.system('./sync-app.py git sync')
        elif choice == '3':
            os.system('./sync-app.py git push')
        elif choice == '4':
            os.system('./sync-app.py git pull')
        elif choice == '5':
            os.system('./sync-app.py git fetch')

    def show_rclone_menu(self):
        """Show Rclone operations menu"""
        self.clear_screen()
        print("=" * 80)
        print("RCLONE OPERATIONS".center(80))
        print("=" * 80)
        print()
        print("1. Show status")
        print("2. Run sync rules")
        print("3. Mount Gdrive")
        print("4. Unmount")
        print("0. Back")
        print()
        choice = input("Choose option: ").strip()

        if choice == '1':
            os.system('./sync-app.py rclone status')
            input("\nPress Enter to continue...")
        elif choice == '2':
            os.system('./sync-app.py rclone sync')
            input("\nPress Enter to continue...")
        elif choice == '3':
            os.system('./sync-app.py rclone mount')
            input("\nPress Enter to continue...")
        elif choice == '4':
            os.system('./sync-app.py rclone umount')
            input("\nPress Enter to continue...")

    def show_jobs(self):
        """Show jobs"""
        self.clear_screen()
        os.system('./sync-app.py jobs')
        input("\nPress Enter to return...")
