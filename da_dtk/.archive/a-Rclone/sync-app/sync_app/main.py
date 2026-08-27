#!/usr/bin/env python3
"""
sync-app main entry point
Unified Git & Rclone Sync Manager
"""

import sys
import argparse
import json
from pathlib import Path

from .config import ConfigManager
from .git_manager import GitManager
from .rclone_manager import RcloneManager
from .models import Colors


def create_parser() -> argparse.ArgumentParser:
    """Create argument parser with all commands"""
    parser = argparse.ArgumentParser(
        prog='sync',
        description='Unified Git & Rclone Sync Manager',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  sync                       Launch TUI dashboard
  sync status                Show status of all repos
  sync git sync              Sync all Git repos
  sync rclone mount          Mount default remote
  sync serve --port 5050     Start API server
'''
    )

    parser.add_argument('--json', action='store_true',
                       help='Output in JSON format')
    parser.add_argument('--version', '-v', action='version',
                       version='sync-app 1.0.0')

    subparsers = parser.add_subparsers(dest='command', help='Available commands')

    # Status command
    status_parser = subparsers.add_parser('status', help='Show all status')
    status_parser.add_argument('--fetch', '-f', action='store_true',
                              help='Fetch from remotes (slower but accurate)')

    # Git commands
    git_parser = subparsers.add_parser('git', help='Git operations')
    git_sub = git_parser.add_subparsers(dest='git_cmd')

    git_status = git_sub.add_parser('status', help='Show Git status')
    git_status.add_argument('--fetch', '-f', action='store_true')
    git_status.add_argument('--repo', '-r', help='Specific repo name')

    git_sync = git_sub.add_parser('sync', help='Sync Git repos')
    git_sync.add_argument('--repo', '-r', help='Specific repo name')
    git_sync.add_argument('--strategy', '-s', default='theirs',
                         choices=['theirs', 'ours', 'patience'],
                         help='Merge strategy')

    git_push = git_sub.add_parser('push', help='Push Git repos')
    git_push.add_argument('--repo', '-r', help='Specific repo name')
    git_push.add_argument('--message', '-m', help='Commit message')

    git_pull = git_sub.add_parser('pull', help='Pull Git repos')
    git_pull.add_argument('--repo', '-r', help='Specific repo name')

    git_fetch = git_sub.add_parser('fetch', help='Fetch from remotes')
    git_fetch.add_argument('--repo', '-r', help='Specific repo name')

    git_sub.add_parser('clone', help='Clone missing repos')

    # Rclone commands
    rclone_parser = subparsers.add_parser('rclone', help='Rclone operations')
    rclone_sub = rclone_parser.add_subparsers(dest='rclone_cmd')

    rclone_sub.add_parser('status', help='Show Rclone status')

    rclone_sync = rclone_sub.add_parser('sync', help='Run sync rules')
    rclone_sync.add_argument('--rule', '-r', help='Specific rule name')
    rclone_sync.add_argument('--dry-run', '-n', action='store_true')

    rclone_mount = rclone_sub.add_parser('mount', help='Mount remote')
    rclone_mount.add_argument('--remote', help='Remote name (default: Gdrive)')
    rclone_mount.add_argument('--path', help='Mount path')
    rclone_mount.add_argument('--verbose', '-v', action='store_true',
                             help='Run in foreground with logs')

    rclone_umount = rclone_sub.add_parser('umount', help='Unmount remote')
    rclone_umount.add_argument('--path', help='Mount path')
    rclone_umount.add_argument('--force', '-f', action='store_true')

    rclone_sub.add_parser('reset', help='Reset mount (umount + mount)')

    # Jobs command
    jobs_parser = subparsers.add_parser('jobs', help='View background jobs')
    jobs_parser.add_argument('--clear', '-c', action='store_true',
                            help='Clear completed jobs')

    # Serve command (API server)
    serve_parser = subparsers.add_parser('serve', help='Start API server')
    serve_parser.add_argument('--host', default='127.0.0.1')
    serve_parser.add_argument('--port', '-p', type=int, default=5050)

    # Config command
    config_parser = subparsers.add_parser('config', help='Show/edit config')
    config_parser.add_argument('--show', '-s', action='store_true',
                              help='Show current config')
    config_parser.add_argument('--edit', '-e', action='store_true',
                              help='Open config in editor')

    return parser


class CLI:
    """Command-line interface handler"""

    def __init__(self, json_output: bool = False):
        self.json_output = json_output
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

    def print(self, msg: str):
        """Print message (respecting json mode)"""
        if not self.json_output:
            print(msg)

    def print_json(self, data):
        """Print data as JSON"""
        print(json.dumps(data, indent=2, default=str))

    # ==================== Status Commands ====================

    def cmd_status(self, fetch: bool = False):
        """Show overall status"""
        git_repos = self.config.get_git_repos()
        rclone_repos = self.config.get_rclone_repos()
        mounts = self.rclone.get_all_mounts()

        if self.json_output:
            data = {
                "git_repos": [],
                "rclone_rules": [],
                "mounts": []
            }
            for repo in git_repos:
                status = self.git.get_sync_status(repo, do_fetch=fetch)
                data["git_repos"].append({
                    "name": repo.name,
                    "local": status.local,
                    "remote": status.remote,
                    "ci": status.ci_status,
                    "last": status.last_activity
                })
            for repo in rclone_repos:
                data["rclone_rules"].append({
                    "name": repo.name,
                    "type": repo.type.value,
                    "enabled": repo.enabled,
                    "source": repo.source,
                    "destination": repo.destination
                })
            for remote, mountpoint in mounts:
                data["mounts"].append({"remote": remote, "mountpoint": mountpoint})
            self.print_json(data)
            return 0

        # Pretty print
        self.print(f"\n{Colors.BOLD}=== SYNC-APP STATUS ==={Colors.RESET}\n")

        # Git repos
        self.print(f"{Colors.CYAN}Git Repositories:{Colors.RESET}")
        self.print("-" * 80)
        self.print(f"{'Name':<30} | {'Local':<15} | {'Remote':<15} | {'CI':<10} | {'Last':<8}")
        self.print("-" * 80)

        for repo in git_repos:
            status = self.git.get_sync_status(repo, do_fetch=fetch)

            # Color based on state
            if status.local == "OK" and "Up to Date" in status.remote:
                state_color = Colors.GREEN
            elif "Uncommitted" in status.local or "Unpushed" in status.local:
                state_color = Colors.YELLOW
            elif "To Pull" in status.remote:
                state_color = Colors.CYAN
            else:
                state_color = Colors.RESET

            self.print(f"{state_color}{repo.name:<30}{Colors.RESET} | "
                      f"{status.local:<15} | {status.remote:<15} | "
                      f"{status.ci_status:<10} | {status.last_activity:<8}")

        self.print("")

        # Rclone rules
        if rclone_repos:
            self.print(f"{Colors.CYAN}Rclone Sync Rules:{Colors.RESET}")
            self.print("-" * 80)
            for repo in rclone_repos:
                enabled = Colors.success("✓") if repo.enabled else Colors.dim("✗")
                self.print(f"[{enabled}] {repo.name:<25} | {repo.type.value:<20}")
                self.print(f"    {Colors.DIM}{repo.source} -> {repo.destination}{Colors.RESET}")
            self.print("")

        # Mounts
        self.print(f"{Colors.CYAN}Active Mounts:{Colors.RESET}")
        self.print("-" * 80)
        if mounts:
            for remote, mountpoint in mounts:
                self.print(f"{Colors.GREEN}●{Colors.RESET} {remote:<20} -> {mountpoint}")
        else:
            self.print(f"  {Colors.DIM}No active mounts{Colors.RESET}")
        self.print("")

        return 0

    # ==================== Git Commands ====================

    def cmd_git_status(self, fetch: bool = False, repo_name: str = None):
        """Show Git repos status"""
        repos = self.config.get_git_repos()
        if repo_name:
            repos = [r for r in repos if r.name == repo_name]

        if self.json_output:
            data = []
            for repo in repos:
                status = self.git.get_sync_status(repo, do_fetch=fetch)
                data.append({
                    "name": repo.name,
                    "local": status.local,
                    "remote": status.remote,
                    "sync_state": status.sync_state.value,
                    "ci": status.ci_status,
                    "last": status.last_activity
                })
            self.print_json(data)
            return 0

        self.print(f"\n{Colors.BOLD}=== GIT REPOSITORIES ==={Colors.RESET}\n")
        self.print(f"{'Name':<30} | {'Local':<15} | {'Remote':<15} | {'CI':<10} | {'Last':<8}")
        self.print("-" * 85)

        for repo in repos:
            status = self.git.get_sync_status(repo, do_fetch=fetch)
            self.print(f"{repo.name:<30} | {status.local:<15} | {status.remote:<15} | "
                      f"{status.ci_status:<10} | {status.last_activity:<8}")

        return 0

    def cmd_git_sync(self, repo_name: str = None, strategy: str = None):
        """Sync Git repos"""
        repos = self.config.get_git_repos()
        if repo_name:
            repos = [r for r in repos if r.name == repo_name]
            if not repos:
                self.print(f"{Colors.RED}Error: Repository '{repo_name}' not found{Colors.RESET}")
                return 1

        self.print(f"\n{Colors.BOLD}=== SYNCING {len(repos)} REPOSITORIES ==={Colors.RESET}\n")

        results = []
        for repo in repos:
            self.print(f"{Colors.CYAN}--- {repo.name} ---{Colors.RESET}")
            success, logs = self.git.sync_repo(repo.source, strategy)
            for log in logs:
                self.print(f"  {log}")
            results.append((repo.name, success))
            self.print("")

        # Summary
        succeeded = sum(1 for _, s in results if s)
        self.print(f"\n{Colors.BOLD}Summary:{Colors.RESET} {succeeded}/{len(results)} successful")

        return 0 if succeeded == len(results) else 1

    def cmd_git_push(self, repo_name: str = None, message: str = None):
        """Push Git repos"""
        if message:
            self.git.commit_message = message

        repos = self.config.get_git_repos()
        if repo_name:
            repos = [r for r in repos if r.name == repo_name]

        self.print(f"\n{Colors.BOLD}=== PUSHING {len(repos)} REPOSITORIES ==={Colors.RESET}\n")

        for repo in repos:
            self.print(f"{Colors.CYAN}--- {repo.name} ---{Colors.RESET}")
            success, logs = self.git.push_repo(repo.source)
            for log in logs:
                self.print(f"  {log}")
            self.print("")

        return 0

    def cmd_git_pull(self, repo_name: str = None):
        """Pull Git repos"""
        repos = self.config.get_git_repos()
        if repo_name:
            repos = [r for r in repos if r.name == repo_name]

        self.print(f"\n{Colors.BOLD}=== PULLING {len(repos)} REPOSITORIES ==={Colors.RESET}\n")

        for repo in repos:
            self.print(f"{Colors.CYAN}--- {repo.name} ---{Colors.RESET}")
            success, logs = self.git.pull_repo(repo.source)
            for log in logs:
                self.print(f"  {log}")
            self.print("")

        return 0

    def cmd_git_fetch(self, repo_name: str = None):
        """Fetch from remotes"""
        repos = self.config.get_git_repos()
        if repo_name:
            repos = [r for r in repos if r.name == repo_name]

        self.print(f"\n{Colors.BOLD}=== FETCHING {len(repos)} REPOSITORIES ==={Colors.RESET}\n")

        for repo in repos:
            self.print(f"{Colors.CYAN}--- {repo.name} ---{Colors.RESET}")
            success, logs = self.git.fetch_repo(repo.source)
            for log in logs:
                self.print(f"  {log}")

        return 0

    # ==================== Rclone Commands ====================

    def cmd_rclone_status(self):
        """Show Rclone status"""
        repos = self.config.get_rclone_repos()
        mounts = self.rclone.get_all_mounts()
        remotes = self.rclone.get_remotes()

        if self.json_output:
            data = {
                "remotes": remotes,
                "rules": [{"name": r.name, "type": r.type.value, "enabled": r.enabled}
                         for r in repos],
                "mounts": [{"remote": r, "mountpoint": m} for r, m in mounts]
            }
            self.print_json(data)
            return 0

        self.print(f"\n{Colors.BOLD}=== RCLONE STATUS ==={Colors.RESET}\n")

        self.print(f"{Colors.CYAN}Configured Remotes:{Colors.RESET} {', '.join(remotes) if remotes else 'None'}")
        self.print("")

        self.print(f"{Colors.CYAN}Sync Rules:{Colors.RESET}")
        self.print("-" * 80)
        if repos:
            for repo in repos:
                enabled = Colors.success("✓") if repo.enabled else Colors.dim("✗")
                self.print(f"[{enabled}] {repo.name:<25} | {repo.type.value}")
                self.print(f"    Source: {repo.source}")
                self.print(f"    Dest:   {repo.destination}")
        else:
            self.print(f"  {Colors.DIM}No sync rules configured{Colors.RESET}")
        self.print("")

        self.print(f"{Colors.CYAN}Active Mounts:{Colors.RESET}")
        self.print("-" * 80)
        if mounts:
            for remote, mountpoint in mounts:
                self.print(f"  {Colors.GREEN}●{Colors.RESET} {remote} -> {mountpoint}")
        else:
            self.print(f"  {Colors.DIM}No active mounts{Colors.RESET}")

        return 0

    def cmd_rclone_sync(self, rule_name: str = None, dry_run: bool = False):
        """Run Rclone sync rules"""
        repos = self.config.get_rclone_repos()
        if rule_name:
            repos = [r for r in repos if r.name == rule_name]
            if not repos:
                self.print(f"{Colors.RED}Error: Rule '{rule_name}' not found{Colors.RESET}")
                return 1

        # Filter to enabled only
        repos = [r for r in repos if r.enabled]

        self.print(f"\n{Colors.BOLD}=== RUNNING {len(repos)} SYNC RULES ==={Colors.RESET}\n")

        if dry_run:
            self.print(f"{Colors.YELLOW}DRY RUN MODE - No changes will be made{Colors.RESET}\n")

        for repo in repos:
            self.print(f"{Colors.CYAN}--- {repo.name} ---{Colors.RESET}")

            def progress(msg, pct):
                self.print(f"  {msg}")

            success, logs = self.rclone.run_sync_rule(repo, dry_run=dry_run,
                                                     progress_callback=progress)
            self.print("")

        return 0

    def cmd_rclone_mount(self, remote: str = None, path: str = None, verbose: bool = False):
        """Mount a remote"""
        remote = remote or self.config.rclone_default_remote
        path = path or str(self.config.rclone_default_mount)

        self.print(f"\n{Colors.BOLD}=== MOUNTING {remote} ==={Colors.RESET}\n")

        mode = 'verbose' if verbose else 'daemon'
        success, logs = self.rclone.mount_remote(remote, path, mode=mode)
        for log in logs:
            self.print(f"  {log}")

        return 0 if success else 1

    def cmd_rclone_umount(self, path: str = None, force: bool = False):
        """Unmount a remote"""
        path = path or str(self.config.rclone_default_mount)

        self.print(f"\n{Colors.BOLD}=== UNMOUNTING {path} ==={Colors.RESET}\n")

        success, logs = self.rclone.umount_remote(path, force=force)
        for log in logs:
            self.print(f"  {log}")

        return 0 if success else 1

    # ==================== Other Commands ====================

    def cmd_config_show(self):
        """Show current configuration"""
        self.print_json(json.loads(self.config.export_config()))
        return 0


def main():
    """Main entry point"""
    parser = create_parser()
    args = parser.parse_args()

    cli = CLI(json_output=getattr(args, 'json', False))

    # Route to appropriate command
    if args.command is None:
        # Launch TUI
        try:
            from .tui import TUI
            tui = TUI()
            tui.run()
        except Exception as e:
            # Fallback to simple TUI
            try:
                from .simple_tui import SimpleTUI
                print(f"Note: Falling back to simple TUI ({e})")
                simple = SimpleTUI()
                simple.run()
            except Exception as e2:
                print(f"TUI not available ({e2}), showing status...")
                return cli.cmd_status()
        except KeyboardInterrupt:
            print("\nExiting...")
        return 0

    elif args.command == 'status':
        return cli.cmd_status(fetch=args.fetch)

    elif args.command == 'git':
        if args.git_cmd == 'status':
            return cli.cmd_git_status(fetch=args.fetch, repo_name=args.repo)
        elif args.git_cmd == 'sync':
            return cli.cmd_git_sync(repo_name=args.repo, strategy=args.strategy)
        elif args.git_cmd == 'push':
            return cli.cmd_git_push(repo_name=args.repo, message=getattr(args, 'message', None))
        elif args.git_cmd == 'pull':
            return cli.cmd_git_pull(repo_name=args.repo)
        elif args.git_cmd == 'fetch':
            return cli.cmd_git_fetch(repo_name=args.repo)
        else:
            parser.parse_args(['git', '--help'])

    elif args.command == 'rclone':
        if args.rclone_cmd == 'status':
            return cli.cmd_rclone_status()
        elif args.rclone_cmd == 'sync':
            return cli.cmd_rclone_sync(rule_name=args.rule, dry_run=args.dry_run)
        elif args.rclone_cmd == 'mount':
            return cli.cmd_rclone_mount(remote=args.remote, path=args.path, verbose=args.verbose)
        elif args.rclone_cmd == 'umount':
            return cli.cmd_rclone_umount(path=args.path, force=args.force)
        elif args.rclone_cmd == 'reset':
            cli.cmd_rclone_umount(force=True)
            return cli.cmd_rclone_mount()
        else:
            parser.parse_args(['rclone', '--help'])

    elif args.command == 'serve':
        try:
            from .api import run_server
            run_server(host=args.host, port=args.port)
        except ImportError as e:
            print(f"Error: Flask not installed. Run: pip install flask flask-cors")
            return 1

    elif args.command == 'config':
        if args.show or not args.edit:
            return cli.cmd_config_show()
        elif args.edit:
            import os
            editor = os.environ.get('EDITOR', 'nano')
            os.system(f'{editor} {cli.config.config_file}')

    elif args.command == 'jobs':
        print("Job manager not yet implemented in CLI")
        return 0

    return 0


if __name__ == '__main__':
    sys.exit(main())
