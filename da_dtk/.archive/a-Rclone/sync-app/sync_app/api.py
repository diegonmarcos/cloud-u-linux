"""
Flask API Server for sync-app
RESTful API for Git and Rclone sync operations
Enables external integrations, web UIs, and automation
"""

from flask import Flask, jsonify, request
from flask_cors import CORS
from typing import Optional
import threading
import json

from .config import ConfigManager
from .git_manager import GitManager
from .rclone_manager import RcloneManager
from .job_manager import JobManager
from .models import RepoType, JobStatus


def create_app(config: Optional[ConfigManager] = None) -> Flask:
    """Create and configure the Flask application"""

    app = Flask(__name__)

    # Initialize config and managers
    config = config or ConfigManager()
    CORS(app, origins=config._config.get("api", {}).get("cors_origins", ["*"]))

    git_mgr = GitManager(config)
    rclone_mgr = RcloneManager(config)
    job_mgr = JobManager(config)

    # Store managers in app context
    app.config['sync_config'] = config
    app.config['git_manager'] = git_mgr
    app.config['rclone_manager'] = rclone_mgr
    app.config['job_manager'] = job_mgr

    # ==================== Health & Info ====================

    @app.route('/')
    def index():
        """API info and available endpoints"""
        return jsonify({
            "name": "sync-app API",
            "version": "1.0.0",
            "endpoints": {
                "health": "/health",
                "repos": {
                    "list": "GET /repos",
                    "get": "GET /repos/<id>",
                    "status": "GET /repos/<id>/status"
                },
                "git": {
                    "status": "GET /git/status",
                    "sync": "POST /git/sync",
                    "sync_one": "POST /git/<name>/sync",
                    "push": "POST /git/<name>/push",
                    "pull": "POST /git/<name>/pull",
                    "fetch": "POST /git/<name>/fetch"
                },
                "rclone": {
                    "status": "GET /rclone/status",
                    "mounts": "GET /rclone/mounts",
                    "mount": "POST /rclone/mount",
                    "umount": "POST /rclone/umount",
                    "sync": "POST /rclone/sync",
                    "space": "GET /rclone/space"
                },
                "jobs": {
                    "list": "GET /jobs",
                    "get": "GET /jobs/<id>",
                    "cancel": "DELETE /jobs/<id>"
                },
                "config": {
                    "get": "GET /config",
                    "update": "PATCH /config"
                }
            }
        })

    @app.route('/health')
    def health():
        """Health check endpoint"""
        return jsonify({
            "status": "healthy",
            "git_repos": len(config.get_git_repos()),
            "rclone_rules": len(config.get_rclone_repos()),
            "active_jobs": len([j for j in job_mgr.get_all_jobs()
                               if j.status == JobStatus.RUNNING])
        })

    # ==================== Repositories ====================

    @app.route('/repos')
    def list_repos():
        """List all repositories (Git + Rclone)"""
        repos = config.get_all_repos()
        return jsonify({
            "count": len(repos),
            "repos": [r.to_dict() for r in repos]
        })

    @app.route('/repos/<repo_id>')
    def get_repo(repo_id: str):
        """Get a specific repository by ID"""
        repo = config.get_repo_by_id(repo_id)
        if not repo:
            return jsonify({"error": f"Repository not found: {repo_id}"}), 404
        return jsonify(repo.to_dict())

    @app.route('/repos/<repo_id>/status')
    def get_repo_status(repo_id: str):
        """Get current status of a repository"""
        repo = config.get_repo_by_id(repo_id)
        if not repo:
            return jsonify({"error": f"Repository not found: {repo_id}"}), 404

        if repo.type == RepoType.GIT:
            status = git_mgr.get_repo_full_status(repo)
            return jsonify(status.to_dict())
        else:
            # For rclone rules, return basic info
            return jsonify({
                "type": repo.type.value,
                "source": repo.source,
                "destination": repo.destination,
                "enabled": repo.enabled
            })

    # ==================== Git Operations ====================

    @app.route('/git/status')
    def git_status():
        """Get status of all Git repositories"""
        repos = config.get_git_repos()
        statuses = []

        for repo in repos:
            status = git_mgr.get_repo_full_status(repo)
            repo.status = status
            statuses.append(repo.to_dict())

        return jsonify({
            "count": len(statuses),
            "repos": statuses
        })

    @app.route('/git/sync', methods=['POST'])
    def git_sync_all():
        """Sync all enabled Git repositories"""
        data = request.get_json() or {}
        strategy = data.get('strategy', config.git_merge_strategy)

        # Run in background
        def do_sync():
            git_mgr.sync_all(strategy=strategy)

        thread = threading.Thread(target=do_sync, daemon=True)
        thread.start()

        return jsonify({
            "message": "Sync started for all repositories",
            "strategy": strategy
        })

    @app.route('/git/<name>/sync', methods=['POST'])
    def git_sync_one(name: str):
        """Sync a specific Git repository"""
        repo = config.get_repo_by_name(name)
        if not repo or repo.type != RepoType.GIT:
            return jsonify({"error": f"Git repository not found: {name}"}), 404

        data = request.get_json() or {}
        strategy = data.get('strategy', config.git_merge_strategy)

        # Create job and run
        job = job_mgr.create_job(repo.id, repo.name, "sync")

        def do_sync():
            try:
                success, message = git_mgr.sync_repo(repo, strategy=strategy)
                job.complete(success=success, error=None if success else message)
            except Exception as e:
                job.complete(success=False, error=str(e))
            job_mgr.save_jobs()

        thread = threading.Thread(target=do_sync, daemon=True)
        thread.start()

        return jsonify({
            "message": f"Sync started for {name}",
            "job_id": job.id
        })

    @app.route('/git/<name>/push', methods=['POST'])
    def git_push(name: str):
        """Push changes for a Git repository"""
        repo = config.get_repo_by_name(name)
        if not repo or repo.type != RepoType.GIT:
            return jsonify({"error": f"Git repository not found: {name}"}), 404

        data = request.get_json() or {}
        commit_msg = data.get('message', config.git_commit_message)

        job = job_mgr.create_job(repo.id, repo.name, "push")

        def do_push():
            try:
                success, message = git_mgr.push_repo(repo, commit_message=commit_msg)
                job.complete(success=success, error=None if success else message)
            except Exception as e:
                job.complete(success=False, error=str(e))
            job_mgr.save_jobs()

        thread = threading.Thread(target=do_push, daemon=True)
        thread.start()

        return jsonify({
            "message": f"Push started for {name}",
            "job_id": job.id
        })

    @app.route('/git/<name>/pull', methods=['POST'])
    def git_pull(name: str):
        """Pull changes for a Git repository"""
        repo = config.get_repo_by_name(name)
        if not repo or repo.type != RepoType.GIT:
            return jsonify({"error": f"Git repository not found: {name}"}), 404

        job = job_mgr.create_job(repo.id, repo.name, "pull")

        def do_pull():
            try:
                success, message = git_mgr.pull_repo(repo)
                job.complete(success=success, error=None if success else message)
            except Exception as e:
                job.complete(success=False, error=str(e))
            job_mgr.save_jobs()

        thread = threading.Thread(target=do_pull, daemon=True)
        thread.start()

        return jsonify({
            "message": f"Pull started for {name}",
            "job_id": job.id
        })

    @app.route('/git/<name>/fetch', methods=['POST'])
    def git_fetch(name: str):
        """Fetch updates for a Git repository"""
        repo = config.get_repo_by_name(name)
        if not repo or repo.type != RepoType.GIT:
            return jsonify({"error": f"Git repository not found: {name}"}), 404

        success, message = git_mgr.fetch_repo(repo)
        return jsonify({
            "success": success,
            "message": message
        })

    # ==================== Rclone Operations ====================

    @app.route('/rclone/status')
    def rclone_status():
        """Get status of Rclone sync rules and mounts"""
        rules = config.get_rclone_repos()
        mounts = config.get_mounts()
        active_mounts = rclone_mgr.get_active_mounts()

        return jsonify({
            "rules": [r.to_dict() for r in rules],
            "mounts": [m.to_dict() for m in mounts],
            "active_mounts": active_mounts
        })

    @app.route('/rclone/mounts')
    def rclone_mounts():
        """Get mount configurations and status"""
        mounts = config.get_mounts()
        active = rclone_mgr.get_active_mounts()

        result = []
        for m in mounts:
            data = m.to_dict()
            data['mounted'] = m.local_path in active
            result.append(data)

        return jsonify({
            "count": len(result),
            "mounts": result
        })

    @app.route('/rclone/mount', methods=['POST'])
    def rclone_mount():
        """Mount an rclone remote"""
        data = request.get_json()
        if not data:
            return jsonify({"error": "Request body required"}), 400

        name = data.get('name')
        if not name:
            return jsonify({"error": "Mount name required"}), 400

        # Find mount config
        mount_config = None
        for m in config.get_mounts():
            if m.name == name:
                mount_config = m
                break

        if not mount_config:
            return jsonify({"error": f"Mount config not found: {name}"}), 404

        success, message = rclone_mgr.mount(
            mount_config.remote,
            mount_config.local_path,
            cache_mode=mount_config.cache_mode
        )

        return jsonify({
            "success": success,
            "message": message
        })

    @app.route('/rclone/umount', methods=['POST'])
    def rclone_umount():
        """Unmount an rclone mount"""
        data = request.get_json()
        if not data:
            return jsonify({"error": "Request body required"}), 400

        path = data.get('path')
        if not path:
            # Try name
            name = data.get('name')
            if name:
                for m in config.get_mounts():
                    if m.name == name:
                        path = m.local_path
                        break

        if not path:
            return jsonify({"error": "Mount path or name required"}), 400

        success, message = rclone_mgr.umount(path)
        return jsonify({
            "success": success,
            "message": message
        })

    @app.route('/rclone/sync', methods=['POST'])
    def rclone_sync():
        """Run an rclone sync rule"""
        data = request.get_json()
        if not data:
            return jsonify({"error": "Request body required"}), 400

        name = data.get('name')
        if not name:
            return jsonify({"error": "Rule name required"}), 400

        # Find rule
        rule = None
        for r in config.get_rclone_repos():
            if r.name == name:
                rule = r
                break

        if not rule:
            return jsonify({"error": f"Sync rule not found: {name}"}), 404

        job = job_mgr.create_job(rule.id, rule.name, "sync")

        def do_sync():
            try:
                def progress_callback(progress: float, transferred: str, speed: str, eta: str):
                    job.progress = progress
                    job.transferred = transferred
                    job.speed = speed
                    job.eta = eta

                success, message = rclone_mgr.run_sync_rule(rule, progress_callback)
                job.complete(success=success, error=None if success else message)
            except Exception as e:
                job.complete(success=False, error=str(e))
            job_mgr.save_jobs()

        thread = threading.Thread(target=do_sync, daemon=True)
        thread.start()

        return jsonify({
            "message": f"Sync started for {name}",
            "job_id": job.id
        })

    @app.route('/rclone/space')
    def rclone_space():
        """Get space information for default remote"""
        data = request.args
        remote = data.get('remote', config.rclone_default_remote)

        info = rclone_mgr.get_space_info(remote)
        return jsonify(info)

    # ==================== Jobs ====================

    @app.route('/jobs')
    def list_jobs():
        """List all jobs"""
        status_filter = request.args.get('status')
        jobs = job_mgr.get_all_jobs()

        if status_filter:
            try:
                filter_status = JobStatus(status_filter)
                jobs = [j for j in jobs if j.status == filter_status]
            except ValueError:
                pass

        return jsonify({
            "count": len(jobs),
            "jobs": [j.to_dict() for j in jobs]
        })

    @app.route('/jobs/<job_id>')
    def get_job(job_id: str):
        """Get a specific job"""
        job = job_mgr.get_job(job_id)
        if not job:
            return jsonify({"error": f"Job not found: {job_id}"}), 404
        return jsonify(job.to_dict())

    @app.route('/jobs/<job_id>', methods=['DELETE'])
    def cancel_job(job_id: str):
        """Cancel a running job"""
        job = job_mgr.get_job(job_id)
        if not job:
            return jsonify({"error": f"Job not found: {job_id}"}), 404

        if job.status != JobStatus.RUNNING:
            return jsonify({"error": "Job is not running"}), 400

        success = job_mgr.cancel_job(job_id)
        return jsonify({
            "success": success,
            "message": "Job cancelled" if success else "Failed to cancel job"
        })

    # ==================== Config ====================

    @app.route('/config')
    def get_config():
        """Get current configuration"""
        return jsonify({
            "git": {
                "workdir": str(config.git_workdir),
                "merge_strategy": config.git_merge_strategy,
                "commit_message": config.git_commit_message,
                "repos_count": len(config.get_git_repos())
            },
            "rclone": {
                "default_remote": config.rclone_default_remote,
                "default_mount": str(config.rclone_default_mount),
                "tpslimit": config.rclone_tpslimit,
                "rules_count": len(config.get_rclone_repos()),
                "mounts_count": len(config.get_mounts())
            },
            "api": {
                "host": config.api_host,
                "port": config.api_port
            }
        })

    @app.route('/config', methods=['PATCH'])
    def update_config():
        """Update configuration"""
        data = request.get_json()
        if not data:
            return jsonify({"error": "Request body required"}), 400

        # Update Git settings
        if 'git' in data:
            git_data = data['git']
            config.update_git_settings(
                workdir=git_data.get('workdir'),
                merge_strategy=git_data.get('merge_strategy'),
                commit_message=git_data.get('commit_message')
            )

        # Update Rclone settings
        if 'rclone' in data:
            rclone_data = data['rclone']
            config.update_rclone_settings(
                default_remote=rclone_data.get('default_remote'),
                default_mount=rclone_data.get('default_mount'),
                tpslimit=rclone_data.get('tpslimit')
            )

        # Update API settings
        if 'api' in data:
            api_data = data['api']
            config.update_api_settings(
                host=api_data.get('host'),
                port=api_data.get('port')
            )

        return jsonify({"message": "Configuration updated"})

    # ==================== Repo Management ====================

    @app.route('/git/repos', methods=['POST'])
    def add_git_repo():
        """Add a new Git repository"""
        data = request.get_json()
        if not data:
            return jsonify({"error": "Request body required"}), 400

        name = data.get('name')
        url = data.get('url')

        if not name or not url:
            return jsonify({"error": "Name and URL required"}), 400

        config.add_git_repo(
            name=name,
            url=url,
            category=data.get('category', 'default'),
            enabled=data.get('enabled', True)
        )

        return jsonify({"message": f"Repository {name} added"})

    @app.route('/git/repos/<name>', methods=['DELETE'])
    def remove_git_repo(name: str):
        """Remove a Git repository"""
        if config.remove_git_repo(name):
            return jsonify({"message": f"Repository {name} removed"})
        return jsonify({"error": f"Repository not found: {name}"}), 404

    @app.route('/git/repos/<name>/toggle', methods=['POST'])
    def toggle_git_repo(name: str):
        """Toggle Git repository enabled state"""
        if config.toggle_git_repo(name):
            return jsonify({"message": f"Repository {name} toggled"})
        return jsonify({"error": f"Repository not found: {name}"}), 404

    @app.route('/rclone/rules', methods=['POST'])
    def add_rclone_rule():
        """Add a new Rclone sync rule"""
        data = request.get_json()
        if not data:
            return jsonify({"error": "Request body required"}), 400

        name = data.get('name')
        source = data.get('source')
        destination = data.get('destination')

        if not name or not source or not destination:
            return jsonify({"error": "Name, source, and destination required"}), 400

        config.add_rclone_rule(
            name=name,
            source=source,
            destination=destination,
            rule_type=data.get('type', 'rclone_bisync'),
            conflict_resolve=data.get('conflict_resolve', 'newer'),
            delete_extra=data.get('delete_extra', True),
            enabled=data.get('enabled', True)
        )

        return jsonify({"message": f"Rule {name} added"})

    @app.route('/rclone/rules/<name>', methods=['DELETE'])
    def remove_rclone_rule(name: str):
        """Remove an Rclone sync rule"""
        if config.remove_rclone_rule(name):
            return jsonify({"message": f"Rule {name} removed"})
        return jsonify({"error": f"Rule not found: {name}"}), 404

    return app


def run_server(config: Optional[ConfigManager] = None,
               host: Optional[str] = None,
               port: Optional[int] = None,
               debug: bool = False):
    """Run the API server"""
    config = config or ConfigManager()
    app = create_app(config)

    # Use provided values or fall back to config
    host = host or config.api_host
    port = port or config.api_port

    print(f"Starting sync-app API server on http://{host}:{port}")
    app.run(host=host, port=port, debug=debug, threaded=True)


if __name__ == '__main__':
    run_server(debug=True)
