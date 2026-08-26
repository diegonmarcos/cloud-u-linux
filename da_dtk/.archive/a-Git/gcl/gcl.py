#!/usr/bin/env python3

"""
gcl.py - Git Clone/Pull/Push Manager (Python version)
A TUI-based git repository manager with CLI support
Matches the gcl.sh TUI layout and functionality
"""

import os
import sys
import subprocess
import curses
import json
from pathlib import Path
from typing import List, Tuple, Optional, Dict
import argparse
from dataclasses import dataclass
import threading
import queue
import time

# --- Configuration: Load from JSON ---
SCRIPT_DIR = Path(__file__).parent.parent  # Go up from gcl/ to Git/
CONFIG_FILE = SCRIPT_DIR / "gcl.json"

def load_config() -> dict:
    """Load configuration from gcl.json"""
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, 'r') as f:
                config = json.load(f)
                return config
        except (json.JSONDecodeError, IOError) as e:
            print(f"Warning: Failed to load config from {CONFIG_FILE}: {e}")
    # Fallback defaults if config file missing
    return {
        "workdir": "/home/diego/Documents/Git",
        "public_repos": {},
        "private_repos": {}
    }

# Load config on module import
_config = load_config()
PUBLIC_REPOS = _config.get("public_repos", {})
PRIVATE_REPOS = _config.get("private_repos", {})
DEFAULT_WORKDIR = _config.get("workdir", "/home/diego/Documents/Git")
ALL_REPOS = {**PUBLIC_REPOS, **PRIVATE_REPOS}

# --- Color Codes (for non-curses output) ---
class Colors:
    RESET = "\033[0m"
    BOLD = "\033[1m"
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"
    CYAN = "\033[36m"

# --- Helper Functions ---
def log(msg: str):
    """Print log message"""
    print(f"{Colors.CYAN}===>{Colors.RESET} {Colors.BOLD}{msg}{Colors.RESET}")

def success(msg: str):
    """Print success message"""
    print(f"{Colors.GREEN}  ✓ {msg}{Colors.RESET}")

def error(msg: str):
    """Print error message"""
    print(f"{Colors.RED}  ✗ {msg}{Colors.RESET}")

def warn(msg: str):
    """Print warning message"""
    print(f"{Colors.YELLOW}  ⚠ {msg}{Colors.RESET}")

# --- Git Helper Functions ---
def run_git(repo_dir: str, *args, timeout=300) -> Tuple[int, str]:
    """Run git command and return (returncode, output)"""
    try:
        result = subprocess.run(
            ['git', '-C', repo_dir] + list(args),
            capture_output=True, text=True, timeout=timeout
        )
        return result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return 1, "Git command timed out"
    except Exception as e:
        return 1, str(e)

def get_repo_local_status(repo_dir: str) -> str:
    """Get local repository status (uncommitted changes, unpushed commits, and untracked files)"""
    if not Path(repo_dir).is_dir():
        return "Not Cloned"

    # Check for uncommitted changes (staged and unstaged) and untracked files
    _, porcelain_output = run_git(repo_dir, 'status', '--porcelain')
    if porcelain_output.strip():
        return "Uncommitted"

    # Check if branch tracks a remote
    ret, _ = run_git(repo_dir, 'rev-parse', '@{u}')
    if ret != 0:
        return "No Remote"

    # Check for unpushed commits
    ret, unpushed_out = run_git(repo_dir, 'log', '@{u}..', '--oneline')
    unpushed = len(unpushed_out.strip().split('\n')) if unpushed_out.strip() else 0
    if unpushed > 0:
        return f"{unpushed} Unpushed"

    return "OK"

def get_repo_remote_status(repo_dir: str, do_fetch: bool = True) -> str:
    """Get remote repository status (unpulled commits after fetch)"""
    if not Path(repo_dir).is_dir():
        return "Not Cloned"

    # Check if branch tracks a remote
    ret, _ = run_git(repo_dir, 'rev-parse', '@{u}')
    if ret != 0:
        return "No Remote"

    # Fetch from remote only if requested
    if do_fetch:
        ret, _ = run_git(repo_dir, 'fetch', '--quiet')
        if ret != 0:
            return "Fetch Failed"

    # Check for unpulled commits
    ret, unpulled_out = run_git(repo_dir, 'log', 'HEAD..@{u}', '--oneline')
    unpulled = len(unpulled_out.strip().split('\n')) if unpulled_out.strip() else 0
    if unpulled > 0:
        return f"{unpulled} To Pull"

    return "Up to Date"

def format_age(updated_at: str) -> str:
    """Format the age of a workflow run in human-readable format"""
    try:
        from datetime import datetime, timezone
        # Parse ISO 8601 format
        run_time = datetime.fromisoformat(updated_at.replace('Z', '+00:00'))
        now = datetime.now(timezone.utc)
        delta = now - run_time

        total_seconds = int(delta.total_seconds())
        if total_seconds < 60:
            return f"{total_seconds}s"
        elif total_seconds < 3600:
            minutes = total_seconds // 60
            return f"{minutes}m"
        elif total_seconds < 86400:
            hours = total_seconds // 3600
            return f"{hours}h"
        else:
            days = total_seconds // 86400
            return f"{days}d"
    except Exception:
        return ""

def get_repo_ci_status(repo_name: str) -> str:
    """Get the CI/CD status from GitHub Actions for a repository"""
    try:
        # Extract the GitHub repo path from the URL
        repo_url = ALL_REPOS.get(repo_name, '')
        if not repo_url:
            return "?"

        # Parse git@github.com:user/repo.git format
        # Use rstrip to only remove .git from the end, not from middle (e.g., github.io)
        if repo_url.startswith('git@github.com:'):
            gh_repo = repo_url.replace('git@github.com:', '')
            if gh_repo.endswith('.git'):
                gh_repo = gh_repo[:-4]
        elif 'github.com/' in repo_url:
            gh_repo = repo_url.split('github.com/')[-1]
            if gh_repo.endswith('.git'):
                gh_repo = gh_repo[:-4]
        else:
            return "?"

        import json

        # Run gh run list to get the latest workflow run
        result = subprocess.run(
            ['gh', 'run', 'list', '-R', gh_repo, '--limit', '1', '--json', 'conclusion,status,updatedAt'],
            capture_output=True, text=True, timeout=30
        )

        if result.returncode != 0:
            return "?"

        runs = json.loads(result.stdout)
        if not runs:
            return "-"  # No runs

        run = runs[0]
        status = run.get('status', '')
        conclusion = run.get('conclusion', '')
        updated_at = run.get('updatedAt', '')

        ci_age = format_age(updated_at) if updated_at else ""
        age_str = f"({ci_age})" if ci_age else ""

        if status == 'in_progress' or status == 'queued':
            return f"⟳{age_str}"  # Running
        elif conclusion == 'success':
            return f"✓{age_str}"  # Success
        elif conclusion == 'failure':
            return f"✗{age_str}"  # Failed
        elif conclusion == 'cancelled':
            return f"○{age_str}"  # Cancelled
        else:
            return "?"
    except subprocess.TimeoutExpired:
        return "?"
    except Exception:
        return "?"

def get_repo_push_status(repo_name: str) -> str:
    """Get the last push time for a repository"""
    try:
        repo_url = ALL_REPOS.get(repo_name, '')
        if not repo_url:
            return "?"

        # Parse git@github.com:user/repo.git format
        if repo_url.startswith('git@github.com:'):
            gh_repo = repo_url.replace('git@github.com:', '')
            if gh_repo.endswith('.git'):
                gh_repo = gh_repo[:-4]
        elif 'github.com/' in repo_url:
            gh_repo = repo_url.split('github.com/')[-1]
            if gh_repo.endswith('.git'):
                gh_repo = gh_repo[:-4]
        else:
            return "?"

        # Get last push time
        push_result = subprocess.run(
            ['gh', 'api', f'repos/{gh_repo}/commits/main', '--jq', '.commit.committer.date'],
            capture_output=True, text=True, timeout=15
        )
        if push_result.returncode == 0 and push_result.stdout.strip():
            return format_age(push_result.stdout.strip())
        return "?"
    except Exception:
        return "?"

def process_repo(repo_dir: str, repo_url: str, strategy: str, action: str, work_dir: str) -> List[str]:
    """Process a repository with given action, return list of log messages"""
    logs = []
    logs.append(f"==> Processing '{repo_dir}'")

    repo_path = str(Path(work_dir) / repo_dir)

    # NEVER auto-clone. Only clone with explicit 'clone' action.
    if not Path(repo_path).is_dir():
        if action == 'clone':
            logs.append(f"  Cloning '{repo_dir}'...")
            ret, output = run_git(work_dir, 'clone', repo_url, repo_dir)
            if output.strip():
                for line in output.strip().split('\n'):
                    logs.append(f"    {line}")
            if ret == 0:
                logs.append(f"  ✓ Clone complete.")
            else:
                logs.append(f"  ✗ Clone failed.")
        else:
            logs.append(f"  ⚠ Skipped - not cloned (use 'clone' action first)")
        return logs

    if action == 'sync':
        # Commit uncommitted changes
        ret, _ = run_git(repo_path, 'diff-index', '--quiet', 'HEAD', '--')
        if ret != 0:
            logs.append("  Found uncommitted changes, committing before sync...")
            run_git(repo_path, 'add', '.')
            ret, output = run_git(repo_path, 'commit', '-m', 'Auto-commit before sync')
            if output.strip():
                for line in output.strip().split('\n'):
                    logs.append(f"    {line}")
            if ret == 0:
                logs.append("  ✓ Changes committed.")
            else:
                logs.append("  ✗ Commit failed.")
                return logs

        # Fetch from remote
        logs.append("  Fetching latest changes from remote...")
        ret, output = run_git(repo_path, 'fetch')
        if output.strip():
            for line in output.strip().split('\n'):
                logs.append(f"    {line}")
        if ret == 0:
            logs.append("  ✓ Fetch complete.")
        else:
            logs.append("  ✗ Fetch failed.")
            return logs

        # Pull
        logs.append(f"  Pulling with strategy: {strategy}")
        ret, output = run_git(repo_path, 'pull', '--no-rebase', f'--strategy-option={strategy}')
        if output.strip():
            for line in output.strip().split('\n'):
                logs.append(f"    {line}")
        if ret == 0:
            logs.append("  ✓ Pull complete.")

            # Add and commit any changes
            run_git(repo_path, 'add', '.')
            ret, _ = run_git(repo_path, 'diff-index', '--quiet', '--cached', 'HEAD', '--')
            if ret != 0:
                logs.append("  Found changes, committing with default message 'fixes'...")
                ret, output = run_git(repo_path, 'commit', '-m', 'fixes')
                if output.strip():
                    for line in output.strip().split('\n'):
                        logs.append(f"    {line}")
                if ret == 0:
                    logs.append("  ✓ Commit complete.")

            # Push
            logs.append("  Pushing changes...")
            ret, output = run_git(repo_path, 'push')
            if output.strip():
                for line in output.strip().split('\n'):
                    logs.append(f"    {line}")
            if ret == 0:
                logs.append("  ✓ Push complete.")
            else:
                logs.append("  ✗ Push failed.")
        else:
            logs.append(f"  ✗ Pull failed.")

    elif action == 'push':
        run_git(repo_path, 'add', '.')
        ret, _ = run_git(repo_path, 'diff-index', '--quiet', '--cached', 'HEAD', '--')
        if ret != 0:
            logs.append("  Found changes, committing with default message 'fixes'...")
            ret, output = run_git(repo_path, 'commit', '-m', 'fixes')
            if output.strip():
                for line in output.strip().split('\n'):
                    logs.append(f"    {line}")
            if ret == 0:
                logs.append("  ✓ Commit complete.")

        logs.append("  Pushing changes...")
        ret, output = run_git(repo_path, 'push')
        if output.strip():
            for line in output.strip().split('\n'):
                logs.append(f"    {line}")
        if ret == 0:
            logs.append("  ✓ Push complete.")
        else:
            logs.append("  ✗ Push failed.")

    elif action == 'pull':
        # Commit uncommitted changes
        ret, _ = run_git(repo_path, 'diff-index', '--quiet', 'HEAD', '--')
        if ret != 0:
            logs.append("  Found uncommitted changes, committing before pull...")
            run_git(repo_path, 'add', '.')
            ret, output = run_git(repo_path, 'commit', '-m', 'Auto-commit before pull')
            if output.strip():
                for line in output.strip().split('\n'):
                    logs.append(f"    {line}")
            if ret == 0:
                logs.append("  ✓ Changes committed.")

        logs.append(f"  Pulling with strategy: {strategy}")
        ret, output = run_git(repo_path, 'pull', '--no-rebase', f'--strategy-option={strategy}')
        if output.strip():
            for line in output.strip().split('\n'):
                logs.append(f"    {line}")
        if ret == 0:
            logs.append("  ✓ Pull complete.")
        else:
            logs.append(f"  ✗ Pull failed.")

    elif action == 'status':
        logs.append(f"  Checking '{repo_dir}'")

        # Check for uncommitted changes and untracked files
        _, status_output = run_git(repo_path, 'status', '--short')
        if status_output.strip():
            logs.append("  ⚠ Has uncommitted changes or untracked files")
            for line in status_output.strip().split('\n')[:5]:
                logs.append(f"    {line}")
        else:
            logs.append("  ✓ Working tree clean")

        # Check for unpushed commits
        ret, unpushed_out = run_git(repo_path, 'log', '@{u}..', '--oneline')
        unpushed = len(unpushed_out.strip().split('\n')) if unpushed_out.strip() else 0
        if unpushed > 0:
            logs.append(f"  ⚠ Has {unpushed} unpushed commit(s)")
        else:
            ret, _ = run_git(repo_path, 'rev-parse', '@{u}')
            if ret == 0:
                logs.append("  ✓ All commits pushed")
            else:
                logs.append("  ⚠ Branch does not track a remote")

    elif action == 'fetch':
        logs.append(f"  Fetching in '{repo_dir}'...")
        ret, output = run_git(repo_path, 'fetch')
        if output.strip():
            for line in output.strip().split('\n'):
                logs.append(f"    {line}")
        if ret == 0:
            logs.append("  ✓ Fetch complete.")
        else:
            logs.append("  ✗ Fetch failed.")

    elif action == 'untracked':
        logs.append(f"  Checking '{repo_dir}'")
        _, untracked_output = run_git(repo_path, 'ls-files', '--others', '--exclude-standard')
        if untracked_output.strip():
            untracked_files = untracked_output.strip().split('\n')
            logs.append(f"  ⚠ Has {len(untracked_files)} untracked file(s)")
            for f in untracked_files[:10]:
                logs.append(f"    {f}")
        else:
            logs.append("  ✓ No untracked files")

    elif action == 'ignored':
        logs.append(f"  Checking '{repo_dir}'")
        _, ignored_output = run_git(repo_path, 'ls-files', '--others', '--ignored', '--exclude-standard')
        if ignored_output.strip():
            ignored_files = ignored_output.strip().split('\n')
            logs.append(f"  ⚠ Has {len(ignored_files)} ignored file(s)")
            for f in ignored_files[:10]:
                logs.append(f"    {f}")
        else:
            logs.append("  ✓ No ignored files")

    elif action == 'clone':
        logs.append(f"  ✓ Already cloned")

    elif action == 'deploys':
        logs.append(f"  Checking GitHub Actions for '{repo_dir}'")
        # Extract the GitHub repo path from the URL
        # Only remove .git from end, not from middle (e.g., github.io)
        if repo_url.startswith('git@github.com:'):
            gh_repo = repo_url.replace('git@github.com:', '')
            if gh_repo.endswith('.git'):
                gh_repo = gh_repo[:-4]
        elif 'github.com/' in repo_url:
            gh_repo = repo_url.split('github.com/')[-1]
            if gh_repo.endswith('.git'):
                gh_repo = gh_repo[:-4]
        else:
            logs.append("  ✗ Could not determine GitHub repository")
            return logs

        try:
            result = subprocess.run(
                ['gh', 'run', 'list', '-R', gh_repo, '--limit', '10'],
                capture_output=True, text=True, timeout=30
            )
            if result.returncode == 0 and result.stdout.strip():
                logs.append(f"  Recent workflow runs for {gh_repo}:")
                for line in result.stdout.strip().split('\n')[:10]:
                    logs.append(f"    {line}")
            elif result.returncode == 0:
                logs.append("  ✓ No workflow runs found")
            else:
                logs.append(f"  ✗ Failed to get workflow runs: {result.stderr.strip()}")
        except subprocess.TimeoutExpired:
            logs.append("  ✗ Command timed out")
        except Exception as e:
            logs.append(f"  ✗ Error: {str(e)}")

    return logs

# --- TUI Implementation ---

class TUI:
    def __init__(self, stdscr):
        self.stdscr = stdscr
        self.running = True

        # State variables
        self.repos = sorted(ALL_REPOS.keys())
        self.repo_selection = [True] * len(self.repos)
        self.repo_local_status = ["Not Checked"] * len(self.repos)
        self.repo_remote_status = ["Not Checked"] * len(self.repos)
        self.repo_ci_status = ["?"] * len(self.repos)
        self.repo_push_status = ["?"] * len(self.repos)

        self.workdir_selected = 1  # 0=current dir, 1=custom path
        self.workdir_path = DEFAULT_WORKDIR
        self.strategy_selected = 1  # 0=local (ours), 1=remote (theirs)
        self.action_selected = 0  # 0=sync, 1=push, 2=pull, 3=status, 4=fetch, 5=untracked, 6=ignored, 7=deploys
        self.repo_cursor = 0
        self.repo_scroll_offset = 0  # For scrolling through repos
        self.current_field = 0  # 0=workdir, 1=strategy, 2=action, 3=repos, 4=run
        self.total_fields = 5
        self.status_message = ""  # For showing refresh status

        # Initialize curses
        curses.curs_set(0)
        if curses.has_colors():
            curses.start_color()
            curses.init_pair(1, curses.COLOR_CYAN, curses.COLOR_BLACK)
            curses.init_pair(2, curses.COLOR_BLUE, curses.COLOR_BLACK)
            curses.init_pair(3, curses.COLOR_GREEN, curses.COLOR_BLACK)
            curses.init_pair(4, curses.COLOR_RED, curses.COLOR_BLACK)
            curses.init_pair(5, curses.COLOR_YELLOW, curses.COLOR_BLACK)
            curses.init_pair(6, curses.COLOR_BLACK, curses.COLOR_CYAN)  # Highlight
            curses.init_pair(7, curses.COLOR_BLACK, curses.COLOR_GREEN)  # Run button

        # Do a quick local status scan on startup
        self.status_message = "Loading repository statuses..."
        self.draw()  # Show loading message
        self.refresh_local_status()
        self.refresh_ci_status(repos=['front-Github_io'])  # Only check front-Github_io by default

    def refresh_local_status(self):
        """Refresh local repository status (fast, no remote fetch)"""
        work_dir = "." if self.workdir_selected == 0 else self.workdir_path
        if not Path(work_dir).is_dir():
            return

        for i, repo in enumerate(self.repos):
            self.status_message = f"Refreshing local status... ({i+1}/{len(self.repos)})"
            self.draw()  # Update display during refresh
            repo_path = str(Path(work_dir) / repo)
            self.repo_local_status[i] = get_repo_local_status(repo_path)

        self.status_message = ""

    def refresh_remote_status(self):
        """Refresh remote repository status (slow, does fetch)"""
        work_dir = "." if self.workdir_selected == 0 else self.workdir_path
        if not Path(work_dir).is_dir():
            return

        for i, repo in enumerate(self.repos):
            self.status_message = f"Fetching remote status... ({i+1}/{len(self.repos)})"
            self.draw()  # Update display during refresh
            repo_path = str(Path(work_dir) / repo)
            self.repo_remote_status[i] = get_repo_remote_status(repo_path)

        self.status_message = ""

    def refresh_ci_status(self, repos: Optional[List[str]] = None):
        """Refresh CI/CD status from GitHub Actions

        Args:
            repos: Optional list of repo names to refresh. If None, refreshes all.
        """
        repos_to_check = repos if repos else self.repos
        for i, repo in enumerate(self.repos):
            if repo in repos_to_check:
                self.status_message = f"Fetching CI status for {repo}..."
                self.draw()  # Update display during refresh
                self.repo_ci_status[i] = get_repo_ci_status(repo)

        self.status_message = ""

    def refresh_push_status(self):
        """Refresh last push time from GitHub for all repos"""
        for i, repo in enumerate(self.repos):
            self.status_message = f"Fetching push status... ({i+1}/{len(self.repos)})"
            self.draw()  # Update display during refresh
            self.repo_push_status[i] = get_repo_push_status(repo)

        self.status_message = ""

    def draw(self):
        """Draw the entire interface"""
        self.stdscr.clear()
        h, w = self.stdscr.getmaxyx()

        row = 0

        # Title
        title = "╔══════════════════════════════════════════╗"
        self.stdscr.addstr(row, 2, title, curses.color_pair(1) | curses.A_BOLD)
        row += 1
        self.stdscr.addstr(row, 2, "║ gcl.py - Git Sync Manager               ║", curses.color_pair(1) | curses.A_BOLD)
        row += 1
        self.stdscr.addstr(row, 2, "╚══════════════════════════════════════════╝", curses.color_pair(1) | curses.A_BOLD)
        row += 2

        # Working Directory
        self.stdscr.addstr(row, 2, "WORKING DIRECTORY:", curses.color_pair(2) | curses.A_BOLD)
        row += 1
        self.stdscr.addstr(row, 2, "══════════════════", curses.color_pair(2))
        row += 1

        opt0 = f"[{'●' if self.workdir_selected == 0 else ' '}] Current Directory (.)"
        attr0 = curses.color_pair(6) if self.current_field == 0 and self.workdir_selected == 0 else curses.A_NORMAL
        self.stdscr.addstr(row, 4, opt0, attr0)
        row += 1

        opt1 = f"[{'●' if self.workdir_selected == 1 else ' '}] Custom Path: {self.workdir_path}"
        attr1 = curses.color_pair(6) if self.current_field == 0 and self.workdir_selected == 1 else curses.A_NORMAL
        self.stdscr.addstr(row, 4, opt1, attr1)
        row += 3

        # Merge Strategy
        self.stdscr.addstr(row, 2, "MERGE STRATEGY (On Conflict):", curses.color_pair(2) | curses.A_BOLD)
        row += 1
        self.stdscr.addstr(row, 2, "══════════════════════════════", curses.color_pair(2))
        row += 1

        # Strategy 0: LOCAL with 'O' highlighted
        marker0 = '●' if self.strategy_selected == 0 else ' '
        attr_s0 = curses.color_pair(6) if self.current_field == 1 and self.strategy_selected == 0 else curses.A_NORMAL
        if self.current_field == 1 and self.strategy_selected == 0:
            self.stdscr.addstr(row, 4, f"[{marker0}] LOCAL  (Keep local changes)", attr_s0)
        else:
            self.stdscr.addstr(row, 4, f"[{marker0}] L")
            self.stdscr.addstr(row, 9, "O", curses.color_pair(5) | curses.A_BOLD)
            self.stdscr.addstr(row, 10, "CAL  (Keep local changes)")
        row += 1

        # Strategy 1: REMOTE with 'E' highlighted
        marker1 = '●' if self.strategy_selected == 1 else ' '
        attr_s1 = curses.color_pair(6) if self.current_field == 1 and self.strategy_selected == 1 else curses.A_NORMAL
        if self.current_field == 1 and self.strategy_selected == 1:
            self.stdscr.addstr(row, 4, f"[{marker1}] REMOTE (Overwrite with remote)", attr_s1)
        else:
            self.stdscr.addstr(row, 4, f"[{marker1}] R")
            self.stdscr.addstr(row, 9, "E", curses.color_pair(5) | curses.A_BOLD)
            self.stdscr.addstr(row, 10, "MOTE (Overwrite with remote)")
        row += 3

        # Action
        self.stdscr.addstr(row, 2, "ACTION:", curses.color_pair(2) | curses.A_BOLD)
        row += 1
        self.stdscr.addstr(row, 2, "══════", curses.color_pair(2))
        row += 1

        # Actions with new layout and order
        actions_data = [
            (0, "SYNC", "S", "(Add/Commit, Fetch, Pull, Add/Commit, Push)"),
            (1, "FETCH", "F", "(Get from Remote)"),
            (2, "PULL", "L", "(Merge from Remote)"),
            (3, "PUSH", "P", "(Merge from Local)"),
            (None, None, None, None),  # blank line
            (4, "STATUS", "T", "(Check Local Untracked and Uncommitted)"),
            (5, "UNTRACKED", "N", "(List untracked files)"),
            (6, "IGNORED", "I", "(List ignored files)"),
            (None, None, None, None),  # blank line
            (7, "DEPLOYS", "D", "(Show GitHub Actions runs)"),
        ]

        for action_info in actions_data:
            if action_info[0] is None:  # blank line
                row += 1
                continue

            action_idx = action_info[0]
            action_name = action_info[1]
            shortcut = action_info[2]
            description = action_info[3]

            marker = '●' if self.action_selected == action_idx else ' '
            attr = curses.color_pair(6) if self.current_field == 2 and self.action_selected == action_idx else curses.A_NORMAL

            # If this action is currently selected, use solid highlight
            if self.current_field == 2 and self.action_selected == action_idx:
                self.stdscr.addstr(row, 4, f"[{marker}] {action_name:<10} {description}", attr)
            else:
                # Draw with highlighted shortcut letter
                self.stdscr.addstr(row, 4, f"[{marker}] ")

                # Find position of shortcut letter in action name
                shortcut_pos = action_name.find(shortcut)
                if shortcut_pos >= 0:
                    # Draw text before shortcut
                    if shortcut_pos > 0:
                        self.stdscr.addstr(row, 8, action_name[:shortcut_pos])
                    # Draw shortcut in bold yellow
                    self.stdscr.addstr(row, 8 + shortcut_pos, shortcut, curses.color_pair(5) | curses.A_BOLD)
                    # Draw text after shortcut
                    if shortcut_pos + 1 < len(action_name):
                        self.stdscr.addstr(row, 8 + shortcut_pos + 1, action_name[shortcut_pos + 1:])
                    # Draw description
                    self.stdscr.addstr(row, 8 + len(action_name) + 1, description)
                else:
                    self.stdscr.addstr(row, 8, f"{action_name} {description}")
            row += 1

        row += 2

        # Repositories
        repo_start_row = row
        self.stdscr.addstr(row, 2, "REPOSITORIES:", curses.color_pair(2) | curses.A_BOLD)
        self.stdscr.addstr(row, 38, "LOCAL:", curses.color_pair(2) | curses.A_BOLD)
        self.stdscr.addstr(row, 52, "REMOTE:", curses.color_pair(2) | curses.A_BOLD)
        self.stdscr.addstr(row, 66, "CI:", curses.color_pair(2) | curses.A_BOLD)
        self.stdscr.addstr(row, 76, "LAST PUSH:", curses.color_pair(2) | curses.A_BOLD)
        row += 1
        self.stdscr.addstr(row, 2, "═══════════════════════════════", curses.color_pair(2))
        self.stdscr.addstr(row, 38, "═══════════", curses.color_pair(2))
        self.stdscr.addstr(row, 52, "════════════", curses.color_pair(2))
        self.stdscr.addstr(row, 66, "════════", curses.color_pair(2))
        self.stdscr.addstr(row, 76, "══════════", curses.color_pair(2))
        row += 1

        max_visible_repos = min(14, h - row - 10)  # Show up to 14 repos

        # Display repos with scrolling support
        for i in range(max_visible_repos):
            repo_idx = self.repo_scroll_offset + i
            if repo_idx >= len(self.repos):
                break

            marker = "✓" if self.repo_selection[repo_idx] else " "
            repo_line = f"[{marker}] {self.repos[repo_idx]:<28}"

            local_status = self.repo_local_status[repo_idx]
            remote_status = self.repo_remote_status[repo_idx]
            ci_status = self.repo_ci_status[repo_idx]
            push_status = self.repo_push_status[repo_idx]

            # Determine color for local status
            local_color = curses.A_NORMAL
            if "OK" in local_status:
                local_color = curses.color_pair(3)
            elif "Not Cloned" in local_status or "Uncommitted" in local_status or "Unpushed" in local_status:
                local_color = curses.color_pair(4)
            elif "No Remote" in local_status:
                local_color = curses.color_pair(4)

            # Determine color for remote status
            remote_color = curses.A_NORMAL
            if "Up to Date" in remote_status:
                remote_color = curses.color_pair(3)
            elif "Not Cloned" in remote_status or "To Pull" in remote_status or "Fetch Failed" in remote_status:
                remote_color = curses.color_pair(4)
            elif "Not Checked" in remote_status:
                remote_color = curses.color_pair(5)

            # Determine color for CI status (check first character)
            ci_color = curses.A_NORMAL
            if ci_status.startswith("✓"):
                ci_color = curses.color_pair(3)  # Green for success
            elif ci_status.startswith("✗"):
                ci_color = curses.color_pair(4)  # Red for failure
            elif ci_status.startswith("⟳"):
                ci_color = curses.color_pair(5)  # Yellow for running
            elif ci_status.startswith("○"):
                ci_color = curses.color_pair(5)  # Yellow for cancelled

            # Push status color (green if recent, yellow if older)
            push_color = curses.A_NORMAL
            if push_status != "?":
                push_color = curses.color_pair(3)  # Green

            if self.current_field == 3 and repo_idx == self.repo_cursor:
                self.stdscr.addstr(row, 4, repo_line, curses.color_pair(6))
                self.stdscr.addstr(row, 38, f"{local_status:<12}", curses.color_pair(6))
                self.stdscr.addstr(row, 52, f"{remote_status:<12}", curses.color_pair(6))
                self.stdscr.addstr(row, 66, f"{ci_status:<8}", curses.color_pair(6))
                self.stdscr.addstr(row, 76, push_status, curses.color_pair(6))
            else:
                self.stdscr.addstr(row, 4, repo_line)
                self.stdscr.addstr(row, 38, f"{local_status:<12}", local_color)
                self.stdscr.addstr(row, 52, f"{remote_status:<12}", remote_color)
                self.stdscr.addstr(row, 66, f"{ci_status:<8}", ci_color)
                self.stdscr.addstr(row, 76, push_status, push_color)
            row += 1

        row += 1

        # RUN button
        run_text = "   [ RUN ]   "
        run_attr = curses.color_pair(7) | curses.A_BOLD if self.current_field == 4 else curses.A_BOLD
        self.stdscr.addstr(row, 2, run_text, run_attr)
        row += 3

        # Status message (if refreshing)
        if self.status_message:
            row += 1
            self.stdscr.addstr(row, 2, self.status_message, curses.color_pair(5) | curses.A_BOLD)
            row += 1

        # Help text
        row = h - 9
        self.stdscr.addstr(row, 2, "KEYBOARD SHORTCUTS", curses.color_pair(2) | curses.A_BOLD)
        row += 1
        self.stdscr.addstr(row, 2, "═══════════════════", curses.color_pair(2))
        row += 1

        # Navigate line
        col = 2
        self.stdscr.addstr(row, col, "Navigate: (", curses.A_BOLD)
        col += 11
        self.stdscr.addstr(row, col, "TAB", curses.color_pair(5) | curses.A_BOLD)
        col += 3
        self.stdscr.addstr(row, col, ") Section | (")
        col += 13
        self.stdscr.addstr(row, col, "↑", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, "/", curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, "↓", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") Options | (")
        col += 13
        self.stdscr.addstr(row, col, "SPACE", curses.color_pair(5) | curses.A_BOLD)
        col += 5
        self.stdscr.addstr(row, col, ") Select | (")
        col += 12
        self.stdscr.addstr(row, col, "ENTER", curses.color_pair(5) | curses.A_BOLD)
        col += 5
        self.stdscr.addstr(row, col, ") Run | (")
        col += 9
        self.stdscr.addstr(row, col, "q", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") Quit")
        row += 1

        # Select line
        col = 2
        self.stdscr.addstr(row, col, "Select:   (", curses.A_BOLD)
        col += 11
        self.stdscr.addstr(row, col, "a", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") All | (")
        col += 9
        self.stdscr.addstr(row, col, "u", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") None | (")
        col += 10
        self.stdscr.addstr(row, col, "k", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") Smart Select")
        row += 1

        # Strategy line
        col = 2
        self.stdscr.addstr(row, col, "Strategy: (", curses.A_BOLD)
        col += 11
        self.stdscr.addstr(row, col, "o", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") Local | (")
        col += 11
        self.stdscr.addstr(row, col, "e", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") Remote")
        row += 1

        # Actions line
        col = 2
        self.stdscr.addstr(row, col, "Actions:  (", curses.A_BOLD)
        col += 11
        self.stdscr.addstr(row, col, "s", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") Sync | (")
        col += 10
        self.stdscr.addstr(row, col, "f", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") Fetch | (")
        col += 11
        self.stdscr.addstr(row, col, "l", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") Pull | (")
        col += 10
        self.stdscr.addstr(row, col, "p", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") Push")
        row += 1

        # Actions continued line
        col = 12
        self.stdscr.addstr(row, col, "(")
        col += 1
        self.stdscr.addstr(row, col, "t", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") Status | (")
        col += 12
        self.stdscr.addstr(row, col, "n", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") Untracked")
        row += 1

        # Refresh line
        col = 2
        self.stdscr.addstr(row, col, "Refresh:  (", curses.A_BOLD)
        col += 11
        self.stdscr.addstr(row, col, "t", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") Status Local | (")
        col += 18
        self.stdscr.addstr(row, col, "f", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") Fetch | (")
        col += 11
        self.stdscr.addstr(row, col, "h", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") Last Push | (")
        col += 15
        self.stdscr.addstr(row, col, "d", curses.color_pair(5) | curses.A_BOLD)
        col += 1
        self.stdscr.addstr(row, col, ") Deploys")

        self.stdscr.refresh()

    def handle_input(self, key):
        """Handle keyboard input"""
        if key == ord('q'):
            self.running = False

        elif key == curses.KEY_UP:
            # Arrow UP moves within current section options
            if self.current_field == 0:  # Workdir section
                self.workdir_selected = max(0, self.workdir_selected - 1)
            elif self.current_field == 1:  # Strategy section
                self.strategy_selected = max(0, self.strategy_selected - 1)
            elif self.current_field == 2:  # Action section
                self.action_selected = max(0, self.action_selected - 1)
            elif self.current_field == 3:  # Repo list
                self.repo_cursor = max(0, self.repo_cursor - 1)
                if self.repo_cursor < self.repo_scroll_offset:
                    self.repo_scroll_offset = self.repo_cursor

        elif key == curses.KEY_DOWN:
            # Arrow DOWN moves within current section options
            if self.current_field == 0:  # Workdir section
                self.workdir_selected = min(1, self.workdir_selected + 1)
            elif self.current_field == 1:  # Strategy section
                self.strategy_selected = min(1, self.strategy_selected + 1)
            elif self.current_field == 2:  # Action section
                self.action_selected = min(7, self.action_selected + 1)
            elif self.current_field == 3:  # Repo list
                self.repo_cursor = min(len(self.repos) - 1, self.repo_cursor + 1)
                h, w = self.stdscr.getmaxyx()
                max_visible = min(14, h - 30)
                if self.repo_cursor >= self.repo_scroll_offset + max_visible:
                    self.repo_scroll_offset = self.repo_cursor - max_visible + 1

        elif key == ord('\t') or key == 9:  # TAB - change sections/tables
            self.current_field = (self.current_field + 1) % self.total_fields

        elif key == curses.KEY_BTAB:  # Shift+TAB - go back to previous section
            self.current_field = (self.current_field - 1) % self.total_fields

        elif key == ord(' '):  # SPACE - select/toggle current option
            if self.current_field == 3:  # Toggle repo selection
                self.repo_selection[self.repo_cursor] = not self.repo_selection[self.repo_cursor]
            # For other fields, space just confirms current selection (already selected by arrows)

        elif key == ord('\n') or key == ord('\r') or key == 10 or key == 13:  # ENTER
            self.execute_action()

        # Shortcuts
        elif key == ord('a'):  # Select all
            self.repo_selection = [True] * len(self.repos)

        elif key == ord('u'):  # Unselect all
            self.repo_selection = [False] * len(self.repos)

        elif key == ord('k'):  # Select repos that need updates (smart selection)
            has_remote_updates = False
            for i in range(len(self.repos)):
                local_needs_update = self.repo_local_status[i] not in ["OK"]
                remote_needs_update = self.repo_remote_status[i] not in ["Up to Date", "Not Checked"]
                if local_needs_update or remote_needs_update:
                    self.repo_selection[i] = True
                    # Track if any selected repo has remote updates
                    if remote_needs_update:
                        has_remote_updates = True
                else:
                    self.repo_selection[i] = False

            # Smart action selection: sync if remote updates exist, otherwise push
            if has_remote_updates:
                self.action_selected = 0  # Sync
            else:
                self.action_selected = 3  # Push

        elif key == ord('o'):  # Local strategy
            self.strategy_selected = 0

        elif key == ord('e'):  # Remote strategy
            self.strategy_selected = 1

        elif key == ord('s'):  # Sync action
            self.action_selected = 0

        elif key == ord('f'):  # Fetch action
            self.action_selected = 1
            self.refresh_remote_status()
            self.draw()

        elif key == ord('l'):  # Pull action
            self.action_selected = 2

        elif key == ord('p'):  # Push action
            self.action_selected = 3

        elif key == ord('t'):  # Status action
            self.action_selected = 4
            self.refresh_local_status()
            self.draw()
            # Auto-trigger smart select (k) after 2 seconds
            time.sleep(2)
            self.handle_input(ord('k'))

        elif key == ord('n'):  # Untracked action
            self.action_selected = 5

        elif key == ord('i'):  # Ignored action
            self.action_selected = 6

        elif key == ord('d'):  # Deploys action + refresh CI for front-Github_io
            self.action_selected = 7
            self.refresh_ci_status(repos=['front-Github_io'])

        elif key == ord('h'):  # Refresh push status for all repos
            self.refresh_push_status()

    def execute_action(self):
        """Execute the selected action on selected repos"""
        # Properly end curses mode
        curses.endwin()

        # Clear screen and show header
        os.system('clear')
        print(f"{Colors.BOLD}{Colors.CYAN}{'═' * 63}{Colors.RESET}")
        print(f"{Colors.BOLD}{Colors.CYAN}                    Executing Actions...                       {Colors.RESET}")
        print(f"{Colors.BOLD}{Colors.CYAN}{'═' * 63}{Colors.RESET}")
        print()

        work_dir = "." if self.workdir_selected == 0 else self.workdir_path

        if not Path(work_dir).is_dir():
            error(f"Working directory does not exist: {work_dir}")
            print(f"\n{Colors.YELLOW}Press 'q' to quit or any other key to return to menu.{Colors.RESET}")

            choice = input()
            if choice.lower() == 'q':
                self.running = False
                return

            # Reinitialize curses and return
            self.stdscr = curses.initscr()
            curses.curs_set(0)
            if curses.has_colors():
                curses.start_color()
                curses.init_pair(1, curses.COLOR_CYAN, curses.COLOR_BLACK)
                curses.init_pair(2, curses.COLOR_BLUE, curses.COLOR_BLACK)
                curses.init_pair(3, curses.COLOR_GREEN, curses.COLOR_BLACK)
                curses.init_pair(4, curses.COLOR_RED, curses.COLOR_BLACK)
                curses.init_pair(5, curses.COLOR_YELLOW, curses.COLOR_BLACK)
                curses.init_pair(6, curses.COLOR_BLACK, curses.COLOR_CYAN)
                curses.init_pair(7, curses.COLOR_BLACK, curses.COLOR_GREEN)

            # Refresh status when returning to menu
            self.status_message = "Refreshing repository statuses..."
            self.draw()
            self.refresh_local_status()
            self.draw()  # Redraw without status message
            return

        strategy = 'ours' if self.strategy_selected == 0 else 'theirs'
        action_names = ['sync', 'fetch', 'pull', 'push', 'status', 'untracked', 'ignored', 'deploys']
        action = action_names[self.action_selected]

        selected_repos = [self.repos[i] for i in range(len(self.repos)) if self.repo_selection[i]]

        if not selected_repos:
            warn("No repositories selected. Nothing to do.")
        else:
            for repo_name in selected_repos:
                repo_url = ALL_REPOS.get(repo_name, '')
                logs = process_repo(repo_name, repo_url, strategy, action, work_dir)
                for log_msg in logs:
                    print(log_msg)
                print()

        print(f"\n{Colors.BOLD}{Colors.CYAN}{'═' * 63}{Colors.RESET}")
        print(f"{Colors.GREEN}{Colors.BOLD}                  All tasks complete!                          {Colors.RESET}")
        print(f"{Colors.BOLD}{Colors.CYAN}{'═' * 63}{Colors.RESET}")
        print(f"\n{Colors.YELLOW}Press 'q' to quit or any other key to return to menu.{Colors.RESET}")

        # Wait for user input (requires pressing Enter, just like gcl.sh)
        choice = input()

        if choice.lower() == 'q':
            self.running = False
        else:
            # Reinitialize curses
            self.stdscr = curses.initscr()
            curses.curs_set(0)
            if curses.has_colors():
                curses.start_color()
                curses.init_pair(1, curses.COLOR_CYAN, curses.COLOR_BLACK)
                curses.init_pair(2, curses.COLOR_BLUE, curses.COLOR_BLACK)
                curses.init_pair(3, curses.COLOR_GREEN, curses.COLOR_BLACK)
                curses.init_pair(4, curses.COLOR_RED, curses.COLOR_BLACK)
                curses.init_pair(5, curses.COLOR_YELLOW, curses.COLOR_BLACK)
                curses.init_pair(6, curses.COLOR_BLACK, curses.COLOR_CYAN)
                curses.init_pair(7, curses.COLOR_BLACK, curses.COLOR_GREEN)

            # Refresh status when returning to menu
            self.status_message = "Refreshing repository statuses..."
            self.draw()
            self.refresh_local_status()
            self.draw()  # Redraw without status message

    def run(self):
        """Main TUI loop"""
        while self.running:
            self.draw()
            key = self.stdscr.getch()
            if key != -1:
                self.handle_input(key)

def run_tui(stdscr):
    TUI(stdscr).run()

# --- CLI Actions ---
def run_cli_sync(strategy: str = 'remote', repos: Optional[List[str]] = None, work_dir: str = "."):
    git_strategy = 'ours' if strategy == 'local' else 'theirs'
    log(f"Starting Bidirectional Sync (Strategy: {git_strategy})")
    repos_to_process = repos if repos else list(ALL_REPOS.keys())
    for repo_name in repos_to_process:
        repo_url = ALL_REPOS.get(repo_name, '')
        if repo_url:
            logs = process_repo(repo_name, repo_url, git_strategy, 'sync', work_dir)
            for log_msg in logs:
                print(log_msg)
            print()

def run_cli_push(repos: Optional[List[str]] = None, work_dir: str = "."):
    log("Starting Push")
    repos_to_process = repos if repos else list(ALL_REPOS.keys())
    for repo_name in repos_to_process:
        repo_url = ALL_REPOS.get(repo_name, '')
        if repo_url:
            logs = process_repo(repo_name, repo_url, 'theirs', 'push', work_dir)
            for log_msg in logs:
                print(log_msg)
            print()

def run_cli_pull(repos: Optional[List[str]] = None, work_dir: str = "."):
    log("Starting Pull")
    repos_to_process = repos if repos else list(ALL_REPOS.keys())
    for repo_name in repos_to_process:
        repo_url = ALL_REPOS.get(repo_name, '')
        if repo_url:
            logs = process_repo(repo_name, repo_url, 'theirs', 'pull', work_dir)
            for log_msg in logs:
                print(log_msg)
            print()

def run_cli_status(repos: Optional[List[str]] = None, work_dir: str = "."):
    log("Checking Status")
    repos_to_process = repos if repos else list(ALL_REPOS.keys())
    for repo_name in repos_to_process:
        repo_url = ALL_REPOS.get(repo_name, '')
        if repo_url:
            logs = process_repo(repo_name, repo_url, 'theirs', 'status', work_dir)
            for log_msg in logs:
                print(log_msg)
            print()

def run_cli_untracked(repos: Optional[List[str]] = None, work_dir: str = "."):
    log("Listing Untracked Files")
    repos_to_process = repos if repos else list(ALL_REPOS.keys())
    for repo_name in repos_to_process:
        repo_url = ALL_REPOS.get(repo_name, '')
        if repo_url:
            logs = process_repo(repo_name, repo_url, 'theirs', 'untracked', work_dir)
            for log_msg in logs:
                print(log_msg)
            print()

def run_cli_ignored(repos: Optional[List[str]] = None, work_dir: str = "."):
    log("Listing Ignored Files")
    repos_to_process = repos if repos else list(ALL_REPOS.keys())
    for repo_name in repos_to_process:
        repo_url = ALL_REPOS.get(repo_name, '')
        if repo_url:
            logs = process_repo(repo_name, repo_url, 'theirs', 'ignored', work_dir)
            for log_msg in logs:
                print(log_msg)
            print()

def run_cli_fetch(repos: Optional[List[str]] = None, work_dir: str = "."):
    log("Fetching")
    repos_to_process = repos if repos else list(ALL_REPOS.keys())
    for repo_name in repos_to_process:
        repo_url = ALL_REPOS.get(repo_name, '')
        if repo_url:
            logs = process_repo(repo_name, repo_url, 'theirs', 'fetch', work_dir)
            for log_msg in logs:
                print(log_msg)
            print()

def run_cli_deploys(repos: Optional[List[str]] = None, work_dir: str = "."):
    log("Checking GitHub Actions Deploys")
    repos_to_process = repos if repos else list(ALL_REPOS.keys())
    for repo_name in repos_to_process:
        repo_url = ALL_REPOS.get(repo_name, '')
        if repo_url:
            logs = process_repo(repo_name, repo_url, 'theirs', 'deploys', work_dir)
            for log_msg in logs:
                print(log_msg)
            print()

def run_cli_clone(repos: Optional[List[str]] = None, work_dir: str = "."):
    log("Cloning repositories")
    repos_to_process = repos if repos else list(ALL_REPOS.keys())
    for repo_name in repos_to_process:
        repo_url = ALL_REPOS.get(repo_name, '')
        if repo_url:
            logs = process_repo(repo_name, repo_url, 'theirs', 'clone', work_dir)
            for log_msg in logs:
                print(log_msg)
            print()

def print_help():
    """Print help message"""
    print(f"{Colors.BOLD}{Colors.CYAN}gcl.py - Git Clone/Pull/Push Manager{Colors.RESET}\n")
    print("Manages multiple git repositories via a TUI or command-line arguments.\n")
    print(f"{Colors.BOLD}{Colors.YELLOW}USAGE:{Colors.RESET}")
    print("  gcl.py [OPTIONS] [COMMAND] [REPOS...]\n")
    print(f"{Colors.BOLD}{Colors.YELLOW}OPTIONS:{Colors.RESET}")
    print(f"  {Colors.GREEN}-w, --workdir PATH{Colors.RESET}\tSet working directory (default: {DEFAULT_WORKDIR})")
    print(f"  {Colors.GREEN}-c, --current{Colors.RESET}\t\tUse current directory as working directory")
    print(f"  {Colors.GREEN}-h, --help{Colors.RESET}\t\tShow this help message\n")
    print(f"{Colors.BOLD}{Colors.YELLOW}COMMANDS:{Colors.RESET}")
    print(f"  (no command)\t\tLaunches the interactive TUI menu.")
    print(f"  {Colors.GREEN}clone{Colors.RESET}\t\t\t{Colors.BOLD}Clone repos that don't exist locally.{Colors.RESET}")
    print(f"  {Colors.GREEN}sync [local|remote]{Colors.RESET}\tBidirectional sync. (Add/Commit, Fetch, Pull, Add/Commit, Push). Default: 'remote'.")
    print(f"  {Colors.GREEN}push{Colors.RESET}\t\t\tPushes committed changes. {Colors.YELLOW}Skips repos not cloned.{Colors.RESET}")
    print(f"  {Colors.GREEN}pull{Colors.RESET}\t\t\tPulls using 'remote' strategy. {Colors.YELLOW}Skips repos not cloned.{Colors.RESET}")
    print(f"  {Colors.GREEN}fetch{Colors.RESET}\t\t\tFetches from remote. {Colors.YELLOW}Skips repos not cloned.{Colors.RESET}")
    print(f"  {Colors.GREEN}status{Colors.RESET}\t\t\tChecks for local untracked and uncommitted changes.")
    print(f"  {Colors.GREEN}untracked{Colors.RESET}\t\tLists untracked files (excluding ignored).")
    print(f"  {Colors.GREEN}ignored{Colors.RESET}\t\t\tLists all ignored files.")
    print(f"  {Colors.GREEN}deploys{Colors.RESET}\t\t\tShows GitHub Actions workflow runs.\n")
    print(f"{Colors.BOLD}{Colors.RED}NOTE:{Colors.RESET} Commands NEVER auto-clone. Use 'clone' explicitly to clone missing repos.\n")
    print(f"{Colors.BOLD}{Colors.YELLOW}REPOS:{Colors.RESET}")
    print(f"  Specify repository names to operate on (space-separated).")
    print(f"  If not specified, operates on all repositories.\n")
    print(f"{Colors.BOLD}{Colors.YELLOW}EXAMPLES:{Colors.RESET}")
    print(f"  gcl.py\t\t\t\t# Launch TUI")
    print(f"  gcl.py status\t\t\t\t# Check status of all repos")
    print(f"  gcl.py -c status\t\t\t# Check status in current directory")
    print(f"  gcl.py push front-Github_profile\t# Push specific repo")
    print(f"  gcl.py sync remote ops-Tooling\t\t# Sync specific repo with remote strategy")
    print(f"\n{Colors.BOLD}{Colors.YELLOW}NOTE:{Colors.RESET}")
    print(f"  Git safe.directory is automatically configured for the working directory.")

def configure_safe_directories(work_dir: str):
    """Configure git safe.directory for the working directory and all repos"""
    # Add the working directory itself
    work_dir_abs = str(Path(work_dir).absolute())
    subprocess.run(['git', 'config', '--global', '--add', 'safe.directory', work_dir_abs],
                   check=False, capture_output=True)

    # Add wildcard for all subdirectories (repos)
    safe_pattern = f"{work_dir_abs}/*"
    subprocess.run(['git', 'config', '--global', '--add', 'safe.directory', safe_pattern],
                   check=False, capture_output=True)

    # Also add the universal wildcard as fallback
    subprocess.run(['git', 'config', '--global', '--add', 'safe.directory', '*'],
                   check=False, capture_output=True)

def main():
    """Main entry point for CLI and TUI"""
    parser = argparse.ArgumentParser(
        description='gcl.py - Git Clone/Pull/Push Manager',
        formatter_class=argparse.RawTextHelpFormatter,
        add_help=False,
        exit_on_error=False
    )
    parser.add_argument('-w', '--workdir', type=str, default=DEFAULT_WORKDIR,
                        help='Working directory for repositories')
    parser.add_argument('-c', '--current', action='store_true',
                        help='Use current directory as working directory')
    parser.add_argument('-h', '--help', action='store_true',
                        help='Show help message')
    parser.add_argument('command', nargs='?', default=None, help='Command to execute')
    parser.add_argument('args', nargs='*', help='Additional arguments (strategy and/or repos)')

    try:
        args = parser.parse_args()
    except argparse.ArgumentError as e:
        error(f"Invalid argument: {e}")
        print()
        print_help()
        sys.exit(1)

    # Handle help
    if args.help:
        print_help()
        sys.exit(0)

    # Determine working directory
    work_dir = '.' if args.current else args.workdir

    # Configure safe directories automatically (silently)
    configure_safe_directories(work_dir)

    # If no command, launch TUI
    if args.command is None:
        try:
            curses.wrapper(run_tui)
        except curses.error as e:
            error(f"Curses error: {e}")
        sys.exit(0)

    cmd = args.command.lower()

    # Handle help command
    if cmd in ('help',):
        print_help()
        sys.exit(0)

    # Parse repos from args
    repos = args.args if args.args else None

    # Validate repository names if provided
    if repos:
        # For sync command, skip strategy argument if present
        repos_to_validate = repos.copy()
        if cmd == 'sync' and repos_to_validate and repos_to_validate[0] in ['local', 'remote']:
            repos_to_validate = repos_to_validate[1:]

        # Check if any repo names are invalid
        invalid_repos = [r for r in repos_to_validate if r not in ALL_REPOS]
        if invalid_repos:
            error(f"Invalid repository name(s): {', '.join(invalid_repos)}")
            print()
            print(f"{Colors.BOLD}{Colors.YELLOW}Available repositories:{Colors.RESET}")
            for repo_name in sorted(ALL_REPOS.keys()):
                print(f"  - {repo_name}")
            print()
            print_help()
            sys.exit(1)

    if cmd == 'sync':
        strategy = 'remote'
        if repos and repos[0] in ['local', 'remote']:
            strategy = repos.pop(0)
        run_cli_sync(strategy, repos=repos if repos else None, work_dir=work_dir)
    elif cmd == 'push':
        run_cli_push(repos=repos, work_dir=work_dir)
    elif cmd == 'pull':
        run_cli_pull(repos=repos, work_dir=work_dir)
    elif cmd == 'status':
        run_cli_status(repos=repos, work_dir=work_dir)
    elif cmd == 'untracked':
        run_cli_untracked(repos=repos, work_dir=work_dir)
    elif cmd == 'ignored':
        run_cli_ignored(repos=repos, work_dir=work_dir)
    elif cmd == 'fetch':
        run_cli_fetch(repos=repos, work_dir=work_dir)
    elif cmd == 'deploys':
        run_cli_deploys(repos=repos, work_dir=work_dir)
    elif cmd == 'clone':
        run_cli_clone(repos=repos, work_dir=work_dir)
    else:
        error(f"Invalid command: {cmd}")
        print()
        print_help()
        sys.exit(1)


def is_git_installed():
    """Check if git is installed"""
    try:
        subprocess.run(['git', '--version'], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False

if __name__ == "__main__":
    try:
        if not is_git_installed():
            print(f"{Colors.RED}Error: 'git' command not found. Please install Git and ensure it's in your PATH.{Colors.RESET}")
            sys.exit(1)
        main()
    except KeyboardInterrupt:
        print("\n\nInterrupted by user")
        sys.exit(0)
    except Exception as e:
        print(f"{Colors.RED}Application crashed unexpectedly: {e}{Colors.RESET}")
        import traceback
        traceback.print_exc()