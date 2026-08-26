#!/usr/bin/env python3
"""
SYNC-APP: Unified TUI
FULL CONSOLIDATION of gcl.py (1370 lines) + rclone.py (1944 lines)
ALL FEATURES, NOTHING REMOVED!

Layout:
- RCLONE section first (mount status, sync jobs, sync rules)
- GIT section second (all repos with 5 status columns)
- Menu-based navigation with instant key detection
"""

import os
import sys
import curses
import time
import threading
import subprocess
from typing import List, Dict, Optional, Tuple
from datetime import datetime
from pathlib import Path

from .config import ConfigManager
from .git_manager import GitManager
from .rclone_manager import RcloneManager
from .models import SyncRepo, SyncStatus, SyncState, RepoType


class Colors:
    """ANSI color codes for non-curses output"""
    RESET = '\033[0m'
    BOLD = '\033[1m'
    DIM = '\033[2m'
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    MAGENTA = '\033[95m'
    CYAN = '\033[96m'


class TUI:
    """
    Curses-based TUI with instant key detection.
    FULL consolidation of gcl.py + rclone.py features.
    """

    def __init__(self, stdscr):
        self.stdscr = stdscr
        self.running = True

        # Initialize managers
        self.config = ConfigManager()
        self.git = GitManager(
            workdir=self.config.git_workdir,
            merge_strategy=self.config.git_merge_strategy,
            commit_message=self.config.git_commit_message
        )
        self.rclone = RcloneManager(
            tpslimit=self.config.rclone_tpslimit,
            cache_mode=self.config.rclone_cache_mode,
            log_dir=self.config.rclone_log_dir
        )

        # Git data - ALL repos with 5 status columns
        self.git_repos: List[SyncRepo] = []
        self.repo_selection: List[bool] = []
        self.repo_local_status: List[str] = []      # "OK", "Uncommitted", "N Unpushed"
        self.repo_remote_status: List[str] = []     # "Up to Date", "N To Pull"
        self.repo_ci_status: List[str] = []         # "✓(5m)", "✗(2h)", "⟳"
        self.repo_push_status: List[str] = []       # "5m", "2h", "3d"

        # Rclone data
        self.rclone_repos: List[SyncRepo] = []
        self.mounts: List[Tuple[str, str]] = []
        self.running_jobs: List = []

        # UI State
        self.git_cursor = 0
        self.git_scroll = 0
        self.rclone_cursor = 0
        self.current_section = 0  # 0=rclone, 1=git
        self.merge_strategy = 1   # 0=local (ours), 1=remote (theirs)
        self.status_message = ""

        # Initialize curses colors
        curses.curs_set(0)
        if curses.has_colors():
            curses.start_color()
            curses.use_default_colors()
            curses.init_pair(1, curses.COLOR_CYAN, -1)     # Headers
            curses.init_pair(2, curses.COLOR_GREEN, -1)    # OK/Success
            curses.init_pair(3, curses.COLOR_RED, -1)      # Error/Uncommitted
            curses.init_pair(4, curses.COLOR_YELLOW, -1)   # Warning
            curses.init_pair(5, curses.COLOR_BLUE, -1)     # Info
            curses.init_pair(6, curses.COLOR_BLACK, curses.COLOR_CYAN)   # Highlight
            curses.init_pair(7, curses.COLOR_BLACK, curses.COLOR_GREEN)  # Button

        # Load initial data
        self._load_initial_data()

    def _load_initial_data(self):
        """Load all data on startup - FAST FRAME FIRST, then update status"""
        # PHASE 1: Load config instantly - show frame immediately
        self.git_repos = self.config.get_git_repos()
        self.repo_selection = [False] * len(self.git_repos)
        self.repo_local_status = ["Not Checked"] * len(self.git_repos)
        self.repo_remote_status = ["Not Checked"] * len(self.git_repos)
        self.repo_ci_status = ["?"] * len(self.git_repos)
        self.repo_push_status = ["?"] * len(self.git_repos)

        self.rclone_repos = self.config.get_rclone_repos()
        self.mounts = self.rclone.get_all_mounts()
        self.running_jobs = []

        # Draw frame immediately - user sees UI right away!
        self.status_message = "Loading local status..."
        self.draw()

        # PHASE 2: Update local status one by one with visual feedback
        for i, repo in enumerate(self.git_repos):
            self.status_message = f"Checking {i+1}/{len(self.git_repos)}: {repo.name}..."
            try:
                self.repo_local_status[i] = self.git.get_repo_local_status(repo.source)
            except:
                self.repo_local_status[i] = "Error"
            self.draw()  # Update display after each repo!

        self.status_message = ""

    def _refresh_local_status(self):
        """Refresh local git status with visual feedback"""
        for i, repo in enumerate(self.git_repos):
            self.status_message = f"Refreshing {i+1}/{len(self.git_repos)}: {repo.name}..."
            self.draw()
            try:
                self.repo_local_status[i] = self.git.get_repo_local_status(repo.source)
            except:
                self.repo_local_status[i] = "Error"
        self.status_message = "Local status refreshed"
        self.draw()

    def _refresh_remote_status(self):
        """Refresh remote status with fetch - visual feedback"""
        for i, repo in enumerate(self.git_repos):
            self.status_message = f"Fetching {i+1}/{len(self.git_repos)}: {repo.name}..."
            self.draw()
            try:
                self.repo_remote_status[i] = self.git.get_repo_remote_status(repo.source, do_fetch=True)
            except:
                self.repo_remote_status[i] = "Error"
        self.status_message = "Remote status refreshed"
        self.draw()

    def _refresh_ci_status(self):
        """Refresh CI status from GitHub - visual feedback"""
        for i, repo in enumerate(self.git_repos):
            self.status_message = f"CI: {i+1}/{len(self.git_repos)}: {repo.name}..."
            self.draw()
            try:
                self.repo_ci_status[i] = self.git.get_repo_ci_status(repo.destination)
            except:
                self.repo_ci_status[i] = "?"
        self.status_message = "CI status refreshed"
        self.draw()

    def _refresh_push_status(self):
        """Refresh last push times - visual feedback"""
        for i, repo in enumerate(self.git_repos):
            self.status_message = f"Push: {i+1}/{len(self.git_repos)}: {repo.name}..."
            self.draw()
            try:
                self.repo_push_status[i] = self.git.get_repo_push_status(repo.destination)
            except:
                self.repo_push_status[i] = "?"
        self.status_message = "Push status refreshed"
        self.draw()

    def draw(self):
        """Draw the complete TUI"""
        self.stdscr.clear()
        h, w = self.stdscr.getmaxyx()
        row = 0

        # ═══════════════════════════════════════════════════════════════
        # HEADER
        # ═══════════════════════════════════════════════════════════════
        title = "╔════════════════════════════════════════════════════════════════════════════════╗"
        self.stdscr.addstr(row, 0, title[:w-1], curses.color_pair(1) | curses.A_BOLD)
        row += 1
        subtitle = "║" + "SYNC-APP - Unified Git & Rclone Manager".center(80) + "║"
        self.stdscr.addstr(row, 0, subtitle[:w-1], curses.color_pair(1) | curses.A_BOLD)
        row += 1
        self.stdscr.addstr(row, 0, "╚════════════════════════════════════════════════════════════════════════════════╝"[:w-1], curses.color_pair(1) | curses.A_BOLD)
        row += 2

        # ═══════════════════════════════════════════════════════════════
        # RCLONE SECTION (First!)
        # ═══════════════════════════════════════════════════════════════
        section_style = curses.color_pair(1) | curses.A_BOLD if self.current_section == 0 else curses.color_pair(1)

        # Mount Status Box
        is_mounted = len(self.mounts) > 0
        mount_path = str(self.config.rclone_default_mount)

        self.stdscr.addstr(row, 0, "┌─ RCLONE MOUNT STATUS ─────────────────────────────────────────────────────────┐"[:w-1], section_style)
        row += 1
        self.stdscr.addstr(row, 0, f"│ Mountpoint: {mount_path}"[:w-2], section_style)
        row += 1
        if is_mounted:
            self.stdscr.addstr(row, 0, "│ Status: ", section_style)
            self.stdscr.addstr(row, 10, "● MOUNTED", curses.color_pair(2) | curses.A_BOLD)
            row += 1
            for remote, mp in self.mounts[:2]:
                self.stdscr.addstr(row, 0, f"│   {remote} → {mp}"[:w-2], curses.color_pair(1) | curses.A_DIM)
                row += 1
        else:
            self.stdscr.addstr(row, 0, "│ Status: ", section_style)
            self.stdscr.addstr(row, 10, "○ NOT MOUNTED", curses.color_pair(4))
            row += 1
        self.stdscr.addstr(row, 0, "└──────────────────────────────────────────────────────────────────────────────────┘"[:w-1], section_style)
        row += 1

        # Sync Rules Box
        enabled_count = sum(1 for r in self.rclone_repos if r.enabled)
        self.stdscr.addstr(row, 0, f"┌─ SYNC RULES ({len(self.rclone_repos)}) ────────────────────────────────────────────────────────────┐"[:w-1], section_style)
        row += 1
        self.stdscr.addstr(row, 0, f"│ Enabled: {enabled_count} | Disabled: {len(self.rclone_repos) - enabled_count}"[:w-2], section_style)
        row += 1

        for i, repo in enumerate(self.rclone_repos[:3]):
            is_current = self.current_section == 0 and self.rclone_cursor == i
            if repo.type == RepoType.RCLONE_BISYNC:
                icon = "↔"
            elif repo.type == RepoType.RCLONE_SYNC_TO_REMOTE:
                icon = "→"
            elif repo.type == RepoType.RCLONE_SYNC_TO_LOCAL:
                icon = "←"
            else:
                icon = "⇄"

            enabled = "●" if repo.enabled else "○"
            line = f"│  {enabled} {repo.name:<24} [{icon}]"

            if is_current:
                self.stdscr.addstr(row, 0, line[:w-2], curses.color_pair(6))
            else:
                self.stdscr.addstr(row, 0, line[:w-2], section_style)
            row += 1

        if not self.rclone_repos:
            self.stdscr.addstr(row, 0, "│  No sync rules configured"[:w-2], curses.A_DIM)
            row += 1

        self.stdscr.addstr(row, 0, "└──────────────────────────────────────────────────────────────────────────────────┘"[:w-1], section_style)
        row += 2

        # ═══════════════════════════════════════════════════════════════
        # GIT REPOSITORIES SECTION - FULL TABLE WITH 5 COLUMNS
        # ═══════════════════════════════════════════════════════════════
        section_style = curses.color_pair(2) | curses.A_BOLD if self.current_section == 1 else curses.color_pair(2)

        # Count stats
        ok_count = sum(1 for s in self.repo_local_status if s == "OK")
        uncommitted = sum(1 for s in self.repo_local_status if s == "Uncommitted")
        unpushed = sum(1 for s in self.repo_local_status if "Unpushed" in s)
        to_pull = sum(1 for s in self.repo_remote_status if "To Pull" in s)

        self.stdscr.addstr(row, 0, f"┌─ GIT REPOSITORIES ({len(self.git_repos)}) ──────────────────────────────────────────────────────────┐"[:w-1], section_style)
        row += 1
        self.stdscr.addstr(row, 0, f"│ OK: {ok_count} | Uncommitted: {uncommitted} | Unpushed: {unpushed} | To Pull: {to_pull}"[:w-2], section_style)
        row += 1

        # Table header
        header = "│    REPOSITORY                   LOCAL          REMOTE         CI       PUSH"
        self.stdscr.addstr(row, 0, header[:w-1], curses.A_BOLD)
        row += 1
        self.stdscr.addstr(row, 0, "│" + "─" * 79, curses.A_DIM)
        row += 1

        # Calculate visible repos
        max_visible = min(12, h - row - 10)
        start_idx = self.git_scroll
        end_idx = min(start_idx + max_visible, len(self.git_repos))

        for i in range(start_idx, end_idx):
            repo = self.git_repos[i]
            is_current = self.current_section == 1 and self.git_cursor == i
            is_selected = self.repo_selection[i]

            local = self.repo_local_status[i][:12] if i < len(self.repo_local_status) else "?"
            remote = self.repo_remote_status[i][:12] if i < len(self.repo_remote_status) else "?"
            ci = self.repo_ci_status[i][:6] if i < len(self.repo_ci_status) else "?"
            push = self.repo_push_status[i][:5] if i < len(self.repo_push_status) else "?"

            sel = "✓" if is_selected else " "
            line = f"│ [{sel}] {repo.name:<26} {local:<14} {remote:<14} {ci:<8} {push}"

            if is_current:
                self.stdscr.addstr(row, 0, line[:w-1], curses.color_pair(6))
            else:
                self.stdscr.addstr(row, 0, f"│ [{sel}] {repo.name:<26} "[:w-1])
                col = 32

                # Color local status
                if local == "OK":
                    self.stdscr.addstr(row, col, f"{local:<14}", curses.color_pair(2))
                elif "Uncommitted" in local or "Unpushed" in local:
                    self.stdscr.addstr(row, col, f"{local:<14}", curses.color_pair(3))
                else:
                    self.stdscr.addstr(row, col, f"{local:<14}")
                col += 15

                # Color remote status
                if remote == "Up to Date":
                    self.stdscr.addstr(row, col, f"{remote:<14}", curses.color_pair(2))
                elif "To Pull" in remote:
                    self.stdscr.addstr(row, col, f"{remote:<14}", curses.color_pair(3))
                else:
                    self.stdscr.addstr(row, col, f"{remote:<14}")
                col += 15

                # Color CI status
                if ci.startswith("✓"):
                    self.stdscr.addstr(row, col, f"{ci:<8}", curses.color_pair(2))
                elif ci.startswith("✗"):
                    self.stdscr.addstr(row, col, f"{ci:<8}", curses.color_pair(3))
                else:
                    self.stdscr.addstr(row, col, f"{ci:<8}")
                col += 9

                # Push time
                self.stdscr.addstr(row, col, push)

            row += 1

        if len(self.git_repos) > max_visible:
            remaining = len(self.git_repos) - end_idx
            if remaining > 0:
                self.stdscr.addstr(row, 0, f"│  ... and {remaining} more (scroll with j/k)"[:w-2], curses.A_DIM)
                row += 1

        self.stdscr.addstr(row, 0, "└──────────────────────────────────────────────────────────────────────────────────┘"[:w-1], section_style)
        row += 2

        # ═══════════════════════════════════════════════════════════════
        # KEYBOARD SHORTCUTS (Direct key commands like gcl.py!)
        # ═══════════════════════════════════════════════════════════════
        self.stdscr.addstr(row, 0, "KEYBOARD SHORTCUTS", curses.A_BOLD)
        row += 1
        self.stdscr.addstr(row, 0, "═" * 82, curses.color_pair(1))
        row += 1

        # Navigation row
        self.stdscr.addstr(row, 0, "Navigate: (")
        self.stdscr.addstr("TAB", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Section | (")
        self.stdscr.addstr("↑/↓", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Move | (")
        self.stdscr.addstr("SPACE", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Select | (")
        self.stdscr.addstr("q", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Quit")
        row += 1

        # Selection row
        self.stdscr.addstr(row, 0, "Select:   (")
        self.stdscr.addstr("a", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") All | (")
        self.stdscr.addstr("u", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") None | (")
        self.stdscr.addstr("k", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Smart Select")
        row += 1

        # Strategy row
        strategy_local = "●" if self.merge_strategy == 0 else "○"
        strategy_remote = "●" if self.merge_strategy == 1 else "○"
        self.stdscr.addstr(row, 0, "Strategy: (")
        self.stdscr.addstr("o", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(f") Local [{strategy_local}] | (")
        self.stdscr.addstr("e", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(f") Remote [{strategy_remote}]")
        row += 1

        # Git actions row
        self.stdscr.addstr(row, 0, "Git:      (")
        self.stdscr.addstr("s", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Sync | (")
        self.stdscr.addstr("f", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Fetch | (")
        self.stdscr.addstr("l", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Pull | (")
        self.stdscr.addstr("p", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Push | (")
        self.stdscr.addstr("t", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Status | (")
        self.stdscr.addstr("n", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Untracked")
        row += 1

        # Refresh row
        self.stdscr.addstr(row, 0, "Refresh:  (")
        self.stdscr.addstr("r", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Local | (")
        self.stdscr.addstr("R", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Remote | (")
        self.stdscr.addstr("c", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") CI | (")
        self.stdscr.addstr("h", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Push Times")
        row += 1

        # Rclone row
        self.stdscr.addstr(row, 0, "Rclone:   (")
        self.stdscr.addstr("m", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Mount | (")
        self.stdscr.addstr("M", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Unmount | (")
        self.stdscr.addstr("S", curses.color_pair(4) | curses.A_BOLD)
        self.stdscr.addstr(") Run Sync Rules")
        row += 1

        self.stdscr.addstr(row, 0, "═" * 82, curses.color_pair(1))
        row += 1

        # Status line
        if self.status_message:
            self.stdscr.addstr(row, 0, f"→ {self.status_message}", curses.color_pair(4))
        else:
            selected = sum(self.repo_selection)
            strategy = "ours" if self.merge_strategy == 0 else "theirs"
            self.stdscr.addstr(row, 0, f"Ready | {selected} selected | Strategy: {strategy}", curses.A_DIM)

        self.stdscr.refresh()

    def handle_input(self, key):
        """Handle keyboard input - INSTANT like gcl.py!"""
        if key == ord('q'):
            self.running = False

        # Navigation
        elif key == curses.KEY_UP or key == ord('k'):
            if self.current_section == 1:  # Git
                self.git_cursor = max(0, self.git_cursor - 1)
                if self.git_cursor < self.git_scroll:
                    self.git_scroll = self.git_cursor
            else:  # Rclone
                self.rclone_cursor = max(0, self.rclone_cursor - 1)

        elif key == curses.KEY_DOWN or key == ord('j'):
            if self.current_section == 1:  # Git
                self.git_cursor = min(len(self.git_repos) - 1, self.git_cursor + 1)
                h, _ = self.stdscr.getmaxyx()
                max_visible = min(12, h - 25)
                if self.git_cursor >= self.git_scroll + max_visible:
                    self.git_scroll = self.git_cursor - max_visible + 1
            else:  # Rclone
                self.rclone_cursor = min(len(self.rclone_repos) - 1, self.rclone_cursor + 1)

        elif key == ord('\t') or key == 9:  # TAB
            self.current_section = (self.current_section + 1) % 2

        # Selection
        elif key == ord(' '):  # SPACE
            if self.current_section == 1 and self.git_repos:
                self.repo_selection[self.git_cursor] = not self.repo_selection[self.git_cursor]

        elif key == ord('a'):  # Select all
            if self.current_section == 1:
                self.repo_selection = [True] * len(self.git_repos)
                self.status_message = f"Selected {len(self.git_repos)} repos"

        elif key == ord('u'):  # Unselect all
            self.repo_selection = [False] * len(self.git_repos)
            self.status_message = "Selection cleared"

        elif key == ord('k') and self.current_section == 1:  # Smart select (shift+k or just k when not navigating)
            pass  # k is used for navigation, use K for smart select

        elif key == ord('K'):  # Smart select
            count = 0
            for i, repo in enumerate(self.git_repos):
                local = self.repo_local_status[i]
                remote = self.repo_remote_status[i]
                if local not in ("OK", "Loading...") or "To Pull" in remote:
                    self.repo_selection[i] = True
                    count += 1
                else:
                    self.repo_selection[i] = False
            self.status_message = f"Smart selected {count} repos"

        # Strategy
        elif key == ord('o'):
            self.merge_strategy = 0
            self.status_message = "Strategy: LOCAL wins (ours)"

        elif key == ord('e'):
            self.merge_strategy = 1
            self.status_message = "Strategy: REMOTE wins (theirs)"

        # Git actions
        elif key == ord('s'):
            self._action_sync()

        elif key == ord('f'):
            self._refresh_remote_status()

        elif key == ord('l'):
            self._action_pull()

        elif key == ord('p'):
            self._action_push()

        elif key == ord('t'):
            self._refresh_local_status()

        elif key == ord('n'):
            self._action_untracked()

        # Refresh
        elif key == ord('r'):
            self._refresh_local_status()

        elif key == ord('R'):
            self._refresh_remote_status()

        elif key == ord('c'):
            self._refresh_ci_status()

        elif key == ord('h'):
            self._refresh_push_status()

        # Rclone
        elif key == ord('m'):
            self._action_mount()

        elif key == ord('M'):
            self._action_umount()

        elif key == ord('S'):
            self._action_rclone_sync()

        # Enter - execute based on section
        elif key == ord('\n') or key == curses.KEY_ENTER:
            if self.current_section == 1:
                self._action_sync()
            else:
                self._action_rclone_sync()

    def _get_selected_repos(self) -> List[SyncRepo]:
        """Get selected git repos"""
        return [self.git_repos[i] for i, sel in enumerate(self.repo_selection) if sel]

    def _action_sync(self):
        """Sync selected repos"""
        repos = self._get_selected_repos()
        if not repos:
            self.status_message = "No repos selected"
            return

        # Exit curses temporarily
        curses.endwin()

        print(f"\n{'═'*80}")
        print(f"  SYNCING {len(repos)} REPOSITORIES")
        print(f"  Strategy: {'ours (local)' if self.merge_strategy == 0 else 'theirs (remote)'}")
        print(f"{'═'*80}\n")

        strategy = "ours" if self.merge_strategy == 0 else "theirs"
        for repo in repos:
            print(f"\n=== {repo.name} ===")
            success, logs = self.git.sync_repo(repo, strategy=strategy)
            for log in logs:
                print(log)
            if success:
                print(f"✓ Sync complete")
            else:
                print(f"✗ Sync failed")

        print(f"\n{'═'*80}")
        print("  All tasks complete!")
        print(f"{'═'*80}")
        input("\nPress Enter to continue...")

        # Reinit curses
        self.stdscr = curses.initscr()
        curses.curs_set(0)
        self._refresh_local_status()

    def _action_pull(self):
        """Pull selected repos"""
        repos = self._get_selected_repos()
        if not repos:
            self.status_message = "No repos selected"
            return

        curses.endwin()
        print(f"\n  PULLING {len(repos)} REPOSITORIES\n")

        strategy = "ours" if self.merge_strategy == 0 else "theirs"
        for repo in repos:
            print(f"\n=== {repo.name} ===")
            success, logs = self.git.pull_repo(repo, strategy=strategy)
            for log in logs:
                print(log)

        input("\nPress Enter to continue...")
        self.stdscr = curses.initscr()
        curses.curs_set(0)
        self._refresh_local_status()

    def _action_push(self):
        """Push selected repos"""
        repos = self._get_selected_repos()
        if not repos:
            self.status_message = "No repos selected"
            return

        curses.endwin()
        print(f"\n  PUSHING {len(repos)} REPOSITORIES\n")

        for repo in repos:
            print(f"\n=== {repo.name} ===")
            success, logs = self.git.push_repo(repo)
            for log in logs:
                print(log)

        input("\nPress Enter to continue...")
        self.stdscr = curses.initscr()
        curses.curs_set(0)
        self._refresh_local_status()

    def _action_untracked(self):
        """Show untracked files"""
        repos = self._get_selected_repos()
        if not repos:
            repos = self.git_repos

        curses.endwin()
        print(f"\n  UNTRACKED FILES\n")

        for repo in repos:
            untracked = self.git.get_untracked_files(repo)
            if untracked:
                print(f"\n{repo.name}:")
                for f in untracked[:15]:
                    print(f"  {f}")
                if len(untracked) > 15:
                    print(f"  ... and {len(untracked) - 15} more")

        input("\nPress Enter to continue...")
        self.stdscr = curses.initscr()
        curses.curs_set(0)

    def _action_mount(self):
        """Mount default remote"""
        curses.endwin()
        print(f"\n  MOUNTING {self.config.rclone_default_remote}\n")

        success, msg = self.rclone.mount(
            f"{self.config.rclone_default_remote}:",
            str(self.config.rclone_default_mount)
        )
        if success:
            print("✓ Mounted successfully")
        else:
            print(f"✗ {msg}")

        input("\nPress Enter to continue...")
        self.stdscr = curses.initscr()
        curses.curs_set(0)
        self.mounts = self.rclone.get_all_mounts()

    def _action_umount(self):
        """Unmount"""
        curses.endwin()
        print(f"\n  UNMOUNTING\n")

        success, msg = self.rclone.umount(str(self.config.rclone_default_mount))
        if success:
            print("✓ Unmounted")
        else:
            print(f"✗ {msg}")

        input("\nPress Enter to continue...")
        self.stdscr = curses.initscr()
        curses.curs_set(0)
        self.mounts = self.rclone.get_all_mounts()

    def _action_rclone_sync(self):
        """Run rclone sync rules"""
        repos = [r for r in self.rclone_repos if r.enabled]
        if not repos:
            self.status_message = "No sync rules enabled"
            return

        curses.endwin()
        print(f"\n  RUNNING {len(repos)} SYNC RULES\n")

        for repo in repos:
            print(f"\n=== {repo.name} ===")
            success, msg = self.rclone.run_sync_rule(repo)
            print(f"{'✓' if success else '✗'} {msg}")

        input("\nPress Enter to continue...")
        self.stdscr = curses.initscr()
        curses.curs_set(0)

    def run(self):
        """Main TUI loop"""
        while self.running:
            self.draw()
            key = self.stdscr.getch()
            if key != -1:
                self.handle_input(key)


def run_tui(stdscr):
    """Wrapper for curses"""
    tui = TUI(stdscr)
    tui.run()


def main():
    """Entry point"""
    try:
        curses.wrapper(run_tui)
    except curses.error as e:
        print(f"Curses error: {e}")
        print("Try running in a larger terminal (min 80x24)")


if __name__ == '__main__':
    main()
