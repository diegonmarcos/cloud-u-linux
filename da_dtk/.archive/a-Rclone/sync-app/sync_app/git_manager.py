"""
Git Manager for sync-app
Enhanced Git repository operations with full feature support
Ported and improved from gcl.py
"""

import subprocess
import json
from pathlib import Path
from typing import Tuple, Optional, List, Callable
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor, as_completed
from .models import SyncStatus, SyncState, SyncRepo, Colors


class GitManager:
    """Manager for Git repository operations"""

    def __init__(self, workdir: Optional[Path] = None, merge_strategy: str = "theirs",
                 commit_message: str = "fixes"):
        """Initialize GitManager

        Args:
            workdir: Working directory for Git repos (defaults to ~/Documents/Git)
            merge_strategy: Default merge strategy (theirs, ours, etc.)
            commit_message: Default commit message for auto-commits
        """
        self.workdir = workdir or Path.home() / "Documents" / "Git"
        self.merge_strategy = merge_strategy
        self.commit_message = commit_message

    # ==================== Core Git Operations ====================

    def run_git(self, repo_dir: str, *args, timeout: int = 300) -> Tuple[int, str]:
        """Run git command and return (returncode, output)

        Args:
            repo_dir: Repository directory path
            *args: Git command arguments
            timeout: Command timeout in seconds

        Returns:
            Tuple of (return_code, combined_output)
        """
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

    def is_git_repo(self, path: str) -> bool:
        """Check if path is a Git repository"""
        repo_path = Path(path)
        return repo_path.is_dir() and (repo_path / '.git').exists()

    # ==================== Status Functions ====================

    def get_repo_local_status(self, repo_dir: str) -> str:
        """Get local repository status

        Returns:
            Status string: "OK", "Uncommitted", "N Unpushed", "No Remote", "Not Cloned"
        """
        repo_path = Path(repo_dir)
        if not self.is_git_repo(repo_dir):
            return "Not Cloned"

        # Check for uncommitted changes (staged, unstaged, untracked)
        _, porcelain_output = self.run_git(repo_dir, 'status', '--porcelain')
        if porcelain_output.strip():
            return "Uncommitted"

        # Check if branch tracks a remote
        ret, _ = self.run_git(repo_dir, 'rev-parse', '@{u}')
        if ret != 0:
            return "No Remote"

        # Check for unpushed commits
        ret, unpushed_out = self.run_git(repo_dir, 'log', '@{u}..', '--oneline')
        unpushed = len(unpushed_out.strip().split('\n')) if unpushed_out.strip() else 0
        if unpushed > 0:
            return f"{unpushed} Unpushed"

        return "OK"

    def get_repo_remote_status(self, repo_dir: str, do_fetch: bool = True) -> str:
        """Get remote repository status

        Returns:
            Status string: "Up to Date", "N To Pull", "No Remote", "Fetch Failed", "Not Cloned"
        """
        if not self.is_git_repo(repo_dir):
            return "Not Cloned"

        # Check if branch tracks a remote
        ret, _ = self.run_git(repo_dir, 'rev-parse', '@{u}')
        if ret != 0:
            return "No Remote"

        # Fetch from remote only if requested
        if do_fetch:
            ret, _ = self.run_git(repo_dir, 'fetch', '--quiet')
            if ret != 0:
                return "Fetch Failed"

        # Check for unpulled commits
        ret, unpulled_out = self.run_git(repo_dir, 'log', 'HEAD..@{u}', '--oneline')
        unpulled = len(unpulled_out.strip().split('\n')) if unpulled_out.strip() else 0
        if unpulled > 0:
            return f"{unpulled} To Pull"

        return "Up to Date"

    def format_age(self, updated_at: str) -> str:
        """Format timestamp age in human-readable format

        Returns:
            Age string like "5m", "2h", "3d"
        """
        try:
            run_time = datetime.fromisoformat(updated_at.replace('Z', '+00:00'))
            now = datetime.now(timezone.utc)
            delta = now - run_time

            total_seconds = int(delta.total_seconds())
            if total_seconds < 60:
                return f"{total_seconds}s"
            elif total_seconds < 3600:
                return f"{total_seconds // 60}m"
            elif total_seconds < 86400:
                return f"{total_seconds // 3600}h"
            else:
                return f"{total_seconds // 86400}d"
        except Exception:
            return ""

    def get_repo_ci_status(self, repo_url: str) -> str:
        """Get CI/CD status from GitHub Actions

        Returns:
            Status string: "✓(5m)" (success), "✗(2h)" (failed), "⟳(1m)" (running), "-" (no runs)
        """
        try:
            # Parse GitHub URL
            if repo_url.startswith('git@github.com:'):
                gh_repo = repo_url.replace('git@github.com:', '').rstrip('.git')
            elif 'github.com/' in repo_url:
                gh_repo = repo_url.split('github.com/')[-1].rstrip('.git')
            else:
                return "?"

            # Get latest workflow run
            result = subprocess.run(
                ['gh', 'run', 'list', '-R', gh_repo, '--limit', '1',
                 '--json', 'conclusion,status,updatedAt'],
                capture_output=True, text=True, timeout=15
            )

            if result.returncode != 0:
                return "?"

            runs = json.loads(result.stdout)
            if not runs:
                return "-"

            run = runs[0]
            status = run.get('status', '')
            conclusion = run.get('conclusion', '')
            updated_at = run.get('updatedAt', '')

            age_str = f"({self.format_age(updated_at)})" if updated_at else ""

            if status in ('in_progress', 'queued'):
                return f"⟳{age_str}"
            elif conclusion == 'success':
                return f"✓{age_str}"
            elif conclusion == 'failure':
                return f"✗{age_str}"
            elif conclusion == 'cancelled':
                return f"○{age_str}"
            else:
                return "?"

        except subprocess.TimeoutExpired:
            return "?"
        except Exception:
            return "?"

    def get_repo_push_status(self, repo_url: str) -> str:
        """Get last push time for repository

        Returns:
            Time ago string like "5m", "2h", "3d", or "?" if unknown
        """
        try:
            if repo_url.startswith('git@github.com:'):
                gh_repo = repo_url.replace('git@github.com:', '').rstrip('.git')
            elif 'github.com/' in repo_url:
                gh_repo = repo_url.split('github.com/')[-1].rstrip('.git')
            else:
                return "?"

            # Try main branch first, then master
            for branch in ['main', 'master']:
                result = subprocess.run(
                    ['gh', 'api', f'repos/{gh_repo}/commits/{branch}',
                     '--jq', '.commit.committer.date'],
                    capture_output=True, text=True, timeout=15
                )
                if result.returncode == 0 and result.stdout.strip():
                    return self.format_age(result.stdout.strip())

            return "?"
        except Exception:
            return "?"

    def get_sync_status(self, repo: SyncRepo, do_fetch: bool = False) -> SyncStatus:
        """Get complete sync status for a repository"""
        local_status = self.get_repo_local_status(repo.source)
        remote_status = self.get_repo_remote_status(repo.source, do_fetch=do_fetch)
        ci_status = self.get_repo_ci_status(repo.destination)
        last_push = self.get_repo_push_status(repo.destination)

        # Determine sync state
        if local_status == "Not Cloned":
            sync_state = SyncState.NOT_CLONED
        elif local_status == "Uncommitted":
            sync_state = SyncState.MODIFIED
        elif "Unpushed" in local_status:
            if "To Pull" in remote_status:
                sync_state = SyncState.DIVERGED
            else:
                sync_state = SyncState.AHEAD
        elif "To Pull" in remote_status:
            sync_state = SyncState.BEHIND
        elif local_status == "OK" and remote_status == "Up to Date":
            sync_state = SyncState.SYNCED
        elif "No Remote" in local_status or "No Remote" in remote_status:
            sync_state = SyncState.UNKNOWN
        else:
            sync_state = SyncState.UNKNOWN

        return SyncStatus(
            local=local_status,
            remote=remote_status,
            sync_state=sync_state,
            last_activity=last_push,
            ci_status=ci_status
        )

    def get_status_batch(self, repos: List[SyncRepo], do_fetch: bool = False,
                        max_workers: int = 5) -> List[Tuple[SyncRepo, SyncStatus]]:
        """Get status for multiple repos in parallel"""
        results = []

        def get_status_for_repo(repo: SyncRepo) -> Tuple[SyncRepo, SyncStatus]:
            status = self.get_sync_status(repo, do_fetch=do_fetch)
            return (repo, status)

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = {executor.submit(get_status_for_repo, repo): repo for repo in repos}
            for future in as_completed(futures):
                try:
                    results.append(future.result())
                except Exception as e:
                    repo = futures[future]
                    results.append((repo, SyncStatus(
                        local="Error",
                        remote="Error",
                        sync_state=SyncState.ERROR,
                        details=str(e)
                    )))

        return results

    # ==================== Action Functions ====================

    def clone_repo(self, url: str, target_dir: str) -> Tuple[bool, List[str]]:
        """Clone a repository

        Args:
            url: Git repository URL
            target_dir: Target directory name (relative to workdir)

        Returns:
            Tuple of (success, log_messages)
        """
        logs = []
        target_path = self.workdir / target_dir

        if target_path.exists():
            logs.append(f"Directory already exists at {target_path}")
            return False, logs

        logs.append(f"Cloning {url} to {target_path}...")
        ret, output = self.run_git(str(self.workdir), 'clone', url, target_dir)

        if output.strip():
            logs.extend([f"  {line}" for line in output.strip().split('\n')])

        if ret == 0:
            logs.append("✓ Clone complete")
            return True, logs
        else:
            logs.append("✗ Clone failed")
            return False, logs

    def fetch_repo(self, repo) -> Tuple[bool, List[str]]:
        """Fetch from remote

        Args:
            repo: Either a SyncRepo object or a string path
        """
        # Handle both SyncRepo and string
        repo_dir = repo.source if hasattr(repo, 'source') else repo

        logs = []
        repo_name = Path(repo_dir).name
        logs.append(f"Fetching {repo_name}...")

        ret, output = self.run_git(repo_dir, 'fetch', '--all')
        if output.strip():
            logs.extend([f"  {line}" for line in output.strip().split('\n')])

        if ret == 0:
            logs.append("✓ Fetch complete")
            return True, logs
        else:
            logs.append("✗ Fetch failed")
            return False, logs

    def pull_repo(self, repo, strategy: Optional[str] = None) -> Tuple[bool, List[str]]:
        """Pull from remote with merge strategy

        Args:
            repo: Either a SyncRepo object or a string path
        """
        # Handle both SyncRepo and string
        repo_dir = repo.source if hasattr(repo, 'source') else repo

        logs = []
        strategy = strategy or self.merge_strategy

        # Auto-commit uncommitted changes first
        ret, _ = self.run_git(repo_dir, 'diff-index', '--quiet', 'HEAD', '--')
        if ret != 0:
            logs.append("Found uncommitted changes, committing before pull...")
            self.run_git(repo_dir, 'add', '.')
            ret, output = self.run_git(repo_dir, 'commit', '-m', 'Auto-commit before pull')
            if output.strip():
                logs.extend([f"  {line}" for line in output.strip().split('\n')[:3]])
            if ret == 0:
                logs.append("✓ Changes committed")

        # Pull with strategy
        logs.append(f"Pulling with strategy: {strategy}...")
        ret, output = self.run_git(repo_dir, 'pull', '--no-rebase', f'--strategy-option={strategy}')
        if output.strip():
            logs.extend([f"  {line}" for line in output.strip().split('\n')[:5]])

        if ret == 0:
            logs.append("✓ Pull complete")
            return True, logs
        else:
            logs.append("✗ Pull failed")
            return False, logs

    def push_repo(self, repo) -> Tuple[bool, List[str]]:
        """Push to remote (commits changes first if any)

        Args:
            repo: Either a SyncRepo object or a string path
        """
        # Handle both SyncRepo and string
        repo_dir = repo.source if hasattr(repo, 'source') else repo

        logs = []

        # Add and check for staged changes
        self.run_git(repo_dir, 'add', '.')
        ret, _ = self.run_git(repo_dir, 'diff-index', '--quiet', '--cached', 'HEAD', '--')
        if ret != 0:
            logs.append(f"Committing with message '{self.commit_message}'...")
            ret, output = self.run_git(repo_dir, 'commit', '-m', self.commit_message)
            if output.strip():
                logs.extend([f"  {line}" for line in output.strip().split('\n')[:3]])
            if ret == 0:
                logs.append("✓ Commit complete")

        # Push
        logs.append("Pushing changes...")
        ret, output = self.run_git(repo_dir, 'push')
        if output.strip():
            logs.extend([f"  {line}" for line in output.strip().split('\n')[:3]])

        if ret == 0:
            logs.append("✓ Push complete")
            return True, logs
        else:
            logs.append("✗ Push failed")
            return False, logs

    def sync_repo(self, repo, strategy: Optional[str] = None,
                 progress_callback: Optional[Callable[[str, float], None]] = None) -> Tuple[bool, List[str]]:
        """Full sync: commit -> fetch -> pull -> commit merge -> push

        Args:
            repo: Either a SyncRepo object or a string path
            strategy: Merge strategy for pull
            progress_callback: Optional callback for progress updates (message, percent)

        Returns:
            Tuple of (success, log_messages)
        """
        # Handle both SyncRepo and string
        repo_dir = repo.source if hasattr(repo, 'source') else repo

        logs = []
        strategy = strategy or self.merge_strategy
        repo_name = Path(repo_dir).name

        def update_progress(msg: str, pct: float):
            logs.append(msg)
            if progress_callback:
                progress_callback(msg, pct)

        update_progress(f"Syncing {repo_name}...", 0)

        # Step 1: Commit uncommitted changes (20%)
        ret, _ = self.run_git(repo_dir, 'diff-index', '--quiet', 'HEAD', '--')
        if ret != 0:
            update_progress("Committing local changes...", 10)
            self.run_git(repo_dir, 'add', '.')
            ret, output = self.run_git(repo_dir, 'commit', '-m', 'Auto-commit before sync')
            if ret == 0:
                update_progress("✓ Changes committed", 20)
            else:
                update_progress("✗ Commit failed", 20)
                logs.extend([f"  {line}" for line in output.strip().split('\n')[:3]])
                return False, logs

        # Step 2: Fetch (40%)
        update_progress("Fetching from remote...", 30)
        ret, output = self.run_git(repo_dir, 'fetch')
        if ret != 0:
            update_progress("✗ Fetch failed", 40)
            return False, logs
        update_progress("✓ Fetch complete", 40)

        # Step 3: Pull (60%)
        update_progress(f"Pulling (strategy: {strategy})...", 50)
        ret, output = self.run_git(repo_dir, 'pull', '--no-rebase', f'--strategy-option={strategy}')
        if ret != 0:
            update_progress("✗ Pull failed", 60)
            logs.extend([f"  {line}" for line in output.strip().split('\n')[:5]])
            return False, logs
        update_progress("✓ Pull complete", 60)

        # Step 4: Commit merge changes (80%)
        self.run_git(repo_dir, 'add', '.')
        ret, _ = self.run_git(repo_dir, 'diff-index', '--quiet', '--cached', 'HEAD', '--')
        if ret != 0:
            update_progress("Committing merge changes...", 70)
            ret, output = self.run_git(repo_dir, 'commit', '-m', self.commit_message)
            if ret == 0:
                update_progress("✓ Merge committed", 80)

        # Step 5: Push (100%)
        update_progress("Pushing changes...", 90)
        ret, output = self.run_git(repo_dir, 'push')
        if ret != 0:
            update_progress("✗ Push failed", 100)
            logs.extend([f"  {line}" for line in output.strip().split('\n')[:3]])
            return False, logs

        update_progress("✓ Sync complete", 100)
        return True, logs

    # ==================== Utility Functions ====================

    def get_untracked_files(self, repo) -> List[str]:
        """Get list of untracked files

        Args:
            repo: Either a SyncRepo object or a string path
        """
        repo_dir = repo.source if hasattr(repo, 'source') else repo
        ret, output = self.run_git(repo_dir, 'ls-files', '--others', '--exclude-standard')
        if ret == 0 and output.strip():
            return output.strip().split('\n')
        return []

    def get_ignored_files(self, repo_dir: str) -> List[str]:
        """Get list of ignored files"""
        ret, output = self.run_git(repo_dir, 'ls-files', '--ignored', '--exclude-standard', '-o')
        if ret == 0 and output.strip():
            return output.strip().split('\n')
        return []

    def get_branch(self, repo_dir: str) -> str:
        """Get current branch name"""
        ret, output = self.run_git(repo_dir, 'rev-parse', '--abbrev-ref', 'HEAD')
        if ret == 0:
            return output.strip()
        return "unknown"

    def get_remote_url(self, repo_dir: str) -> str:
        """Get remote origin URL"""
        ret, output = self.run_git(repo_dir, 'remote', 'get-url', 'origin')
        if ret == 0:
            return output.strip()
        return ""

    def get_last_commit(self, repo_dir: str) -> Tuple[str, str, str]:
        """Get last commit info (hash, author, message)"""
        ret, output = self.run_git(repo_dir, 'log', '-1', '--format=%h|%an|%s')
        if ret == 0 and output.strip():
            parts = output.strip().split('|', 2)
            if len(parts) == 3:
                return parts[0], parts[1], parts[2]
        return ("", "", "")

    def stash_changes(self, repo_dir: str) -> Tuple[bool, str]:
        """Stash current changes"""
        ret, output = self.run_git(repo_dir, 'stash', 'push', '-m', 'sync-app auto-stash')
        return ret == 0, output.strip()

    def unstash_changes(self, repo_dir: str) -> Tuple[bool, str]:
        """Pop stashed changes"""
        ret, output = self.run_git(repo_dir, 'stash', 'pop')
        return ret == 0, output.strip()

    def reset_hard(self, repo_dir: str) -> Tuple[bool, str]:
        """Hard reset to HEAD (use with caution!)"""
        ret, output = self.run_git(repo_dir, 'reset', '--hard', 'HEAD')
        return ret == 0, output.strip()

    def clean_untracked(self, repo_dir: str, dry_run: bool = True) -> Tuple[bool, List[str]]:
        """Clean untracked files"""
        args = ['clean', '-fd']
        if dry_run:
            args.append('-n')

        ret, output = self.run_git(repo_dir, *args)
        files = output.strip().split('\n') if output.strip() else []
        return ret == 0, files

    # ==================== Batch Operations ====================

    def sync_all(self, repos: List[SyncRepo], strategy: Optional[str] = None,
                progress_callback: Optional[Callable[[str, str, float], None]] = None,
                max_workers: int = 3) -> List[Tuple[SyncRepo, bool, List[str]]]:
        """Sync multiple repositories

        Args:
            repos: List of SyncRepo objects to sync
            strategy: Merge strategy
            progress_callback: Callback (repo_name, message, percent)
            max_workers: Max parallel operations

        Returns:
            List of (repo, success, logs) tuples
        """
        results = []

        def sync_single(repo: SyncRepo) -> Tuple[SyncRepo, bool, List[str]]:
            def repo_progress(msg: str, pct: float):
                if progress_callback:
                    progress_callback(repo.name, msg, pct)

            success, logs = self.sync_repo(repo.source, strategy, repo_progress)
            return (repo, success, logs)

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = {executor.submit(sync_single, repo): repo for repo in repos}
            for future in as_completed(futures):
                try:
                    results.append(future.result())
                except Exception as e:
                    repo = futures[future]
                    results.append((repo, False, [f"Exception: {e}"]))

        return results

    def fetch_all(self, repos: List[SyncRepo], max_workers: int = 5) -> List[Tuple[SyncRepo, bool, List[str]]]:
        """Fetch from all repositories in parallel"""
        results = []

        def fetch_single(repo: SyncRepo) -> Tuple[SyncRepo, bool, List[str]]:
            success, logs = self.fetch_repo(repo.source)
            return (repo, success, logs)

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = {executor.submit(fetch_single, repo): repo for repo in repos}
            for future in as_completed(futures):
                try:
                    results.append(future.result())
                except Exception as e:
                    repo = futures[future]
                    results.append((repo, False, [f"Exception: {e}"]))

        return results

    def push_all(self, repos: List[SyncRepo], max_workers: int = 3) -> List[Tuple[SyncRepo, bool, List[str]]]:
        """Push all repositories in parallel"""
        results = []

        def push_single(repo: SyncRepo) -> Tuple[SyncRepo, bool, List[str]]:
            success, logs = self.push_repo(repo.source)
            return (repo, success, logs)

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = {executor.submit(push_single, repo): repo for repo in repos}
            for future in as_completed(futures):
                try:
                    results.append(future.result())
                except Exception as e:
                    repo = futures[future]
                    results.append((repo, False, [f"Exception: {e}"]))

        return results

    def pull_all(self, repos: List[SyncRepo], strategy: Optional[str] = None,
                max_workers: int = 3) -> List[Tuple[SyncRepo, bool, List[str]]]:
        """Pull all repositories in parallel"""
        results = []

        def pull_single(repo: SyncRepo) -> Tuple[SyncRepo, bool, List[str]]:
            success, logs = self.pull_repo(repo.source, strategy)
            return (repo, success, logs)

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = {executor.submit(pull_single, repo): repo for repo in repos}
            for future in as_completed(futures):
                try:
                    results.append(future.result())
                except Exception as e:
                    repo = futures[future]
                    results.append((repo, False, [f"Exception: {e}"]))

        return results
