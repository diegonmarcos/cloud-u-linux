"""
Job Manager for sync-app
Manages background sync/push/pull jobs with progress tracking
"""

import json
import os
import signal
import subprocess
from pathlib import Path
from typing import List, Optional, Dict
from datetime import datetime
from .models import SyncJob, JobList


class JobManager:
    """Manager for background sync jobs"""

    def __init__(self):
        """Initialize JobManager"""
        self.config_dir = Path.home() / '.config' / 'sync-app'
        self.jobs_file = self.config_dir / 'jobs.json'
        self.log_dir = self.config_dir / 'logs'
        self.config_dir.mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)

        self._job_counter = 0

    # --- Job Storage ---

    def load_jobs(self) -> JobList:
        """Load job history from file

        Returns:
            List of SyncJob objects
        """
        if not self.jobs_file.exists():
            return []

        try:
            with open(self.jobs_file, 'r') as f:
                data = json.load(f)
                jobs = []
                for job_data in data:
                    # Convert dict to SyncJob
                    job = SyncJob(
                        id=job_data['id'],
                        repo_id=job_data['repo_id'],
                        repo_name=job_data['repo_name'],
                        action=job_data['action'],
                        status=job_data['status'],
                        progress=job_data.get('progress', 0.0),
                        start_time=job_data['start_time'],
                        end_time=job_data.get('end_time'),
                        pid=job_data.get('pid'),
                        log=job_data.get('log', []),
                        error=job_data.get('error')
                    )
                    jobs.append(job)
                return jobs
        except (json.JSONDecodeError, KeyError, TypeError):
            return []

    def save_jobs(self, jobs: JobList):
        """Save job history to file

        Args:
            jobs: List of SyncJob objects to save
        """
        # Convert SyncJob objects to dicts
        job_dicts = []
        for job in jobs:
            job_dict = {
                'id': job.id,
                'repo_id': job.repo_id,
                'repo_name': job.repo_name,
                'action': job.action,
                'status': job.status,
                'progress': job.progress,
                'start_time': job.start_time,
                'end_time': job.end_time,
                'pid': job.pid,
                'log': job.log,
                'error': job.error
            }
            job_dicts.append(job_dict)

        # Keep max 50 jobs
        if len(job_dicts) > 50:
            job_dicts = job_dicts[-50:]

        with open(self.jobs_file, 'w') as f:
            json.dump(job_dicts, f, indent=2)

    # --- Job Operations ---

    def generate_job_id(self) -> str:
        """Generate unique job ID

        Returns:
            Unique job ID string
        """
        self._job_counter += 1
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        return f"job_{timestamp}_{self._job_counter}"

    def start_job(self, repo_id: str, repo_name: str, action: str,
                  command: List[str], log_file: Optional[Path] = None) -> SyncJob:
        """Start a background job

        Args:
            repo_id: Repository ID
            repo_name: Repository name
            action: Action being performed (sync, push, pull, etc.)
            command: Command to execute as list
            log_file: Optional log file path

        Returns:
            SyncJob object for the started job
        """
        job_id = self.generate_job_id()

        # Create log file if not provided
        if log_file is None:
            log_file = self.log_dir / f"{job_id}.log"

        # Start process
        with open(log_file, 'w') as log_f:
            process = subprocess.Popen(
                command,
                stdout=log_f,
                stderr=subprocess.STDOUT,
                start_new_session=True  # Detach from parent
            )

        # Create job
        job = SyncJob(
            id=job_id,
            repo_id=repo_id,
            repo_name=repo_name,
            action=action,
            status="running",
            progress=0.0,
            pid=process.pid
        )
        job.add_log(f"Started {action} for {repo_name}")
        job.add_log(f"Command: {' '.join(command)}")
        job.add_log(f"Log file: {log_file}")

        # Save job
        jobs = self.load_jobs()
        jobs.append(job)
        self.save_jobs(jobs)

        return job

    def get_running_jobs(self) -> JobList:
        """Get all running jobs (verifies process still exists)

        Returns:
            List of running SyncJob objects
        """
        jobs = self.load_jobs()
        running = []
        updated = False

        for job in jobs:
            if job.status == "running":
                # Check if process is still running
                if job.pid:
                    try:
                        os.kill(job.pid, 0)  # Check if process exists
                        running.append(job)
                    except OSError:
                        # Process no longer running, mark as completed
                        job.complete(success=True)
                        updated = True
                else:
                    # No PID, assume still running
                    running.append(job)

        if updated:
            self.save_jobs(jobs)

        return running

    def get_job_status(self, job_id: str) -> Optional[SyncJob]:
        """Get specific job by ID

        Args:
            job_id: Job ID to look up

        Returns:
            SyncJob object or None if not found
        """
        jobs = self.load_jobs()
        for job in jobs:
            if job.id == job_id:
                # If running, check if process still exists
                if job.status == "running" and job.pid:
                    try:
                        os.kill(job.pid, 0)
                    except OSError:
                        job.complete(success=True)
                        self.save_jobs(jobs)
                return job
        return None

    def cancel_job(self, job_id: str) -> bool:
        """Cancel a running job

        Args:
            job_id: Job ID to cancel

        Returns:
            True if successfully cancelled, False otherwise
        """
        jobs = self.load_jobs()
        for job in jobs:
            if job.id == job_id and job.status == "running" and job.pid:
                try:
                    # Send SIGTERM to process group
                    os.killpg(os.getpgid(job.pid), signal.SIGTERM)
                    job.cancel()
                    self.save_jobs(jobs)
                    return True
                except (OSError, ProcessLookupError):
                    # Process already dead
                    job.cancel()
                    self.save_jobs(jobs)
                    return True
        return False

    def clear_completed_jobs(self) -> int:
        """Remove all completed/failed/cancelled jobs

        Returns:
            Number of jobs cleared
        """
        jobs = self.load_jobs()
        running_jobs = [j for j in jobs if j.status == "running"]
        cleared_count = len(jobs) - len(running_jobs)
        self.save_jobs(running_jobs)
        return cleared_count

    def get_all_jobs(self) -> JobList:
        """Get all jobs (running and completed)

        Returns:
            List of all SyncJob objects
        """
        return self.load_jobs()

    # --- Progress Tracking ---

    def update_job_progress(self, job_id: str, progress: float, message: Optional[str] = None):
        """Update job progress

        Args:
            job_id: Job ID to update
            progress: Progress percentage (0-100)
            message: Optional progress message
        """
        jobs = self.load_jobs()
        for job in jobs:
            if job.id == job_id:
                job.progress = progress
                if message:
                    job.add_log(message)
                self.save_jobs(jobs)
                break

    def mark_job_completed(self, job_id: str, success: bool = True, error: Optional[str] = None):
        """Mark a job as completed

        Args:
            job_id: Job ID to mark as completed
            success: Whether job completed successfully
            error: Optional error message if failed
        """
        jobs = self.load_jobs()
        for job in jobs:
            if job.id == job_id:
                job.complete(success=success, error=error)
                self.save_jobs(jobs)
                break

    def mark_job_failed(self, job_id: str, error: str):
        """Mark a job as failed

        Args:
            job_id: Job ID to mark as failed
            error: Error message
        """
        self.mark_job_completed(job_id, success=False, error=error)

    def get_job_logs(self, job_id: str) -> List[str]:
        """Get log messages for a job

        Args:
            job_id: Job ID to get logs for

        Returns:
            List of log messages
        """
        job = self.get_job_status(job_id)
        if job:
            return job.log
        return []
