"""
Configuration Manager for sync-app
Handles loading, saving, and managing all configuration
Enhanced with full feature support from both gcl.py and rclone.py
"""

import json
from pathlib import Path
from typing import Dict, List, Optional, Any
from .models import SyncRepo, RepoType, MountConfig, RepoList, MountList


# Default Git repositories - your personal repos
DEFAULT_GIT_REPOS = {
    # Public repositories
    "front-Github_profile": "git@github.com:diegonmarcos/diegonmarcos.git",
    "front-Github_io": "git@github.com:diegonmarcos/diegonmarcos.github.io.git",
    "back-System": "git@github.com:diegonmarcos/back-System.git",
    "back-Algo": "git@github.com:diegonmarcos/back-Algo.git",
    "back-Graphic": "git@github.com:diegonmarcos/back-Graphic.git",
    "cyber-Cyberwarfare": "git@github.com:diegonmarcos/cyber-Cyberwarfare.git",
    "ops-Tooling": "git@github.com:diegonmarcos/ops-Tooling.git",
    "ops-Mylibs": "git@github.com:diegonmarcos/ops-Mylibs.git",
    "ml-MachineLearning": "git@github.com:diegonmarcos/ml-MachineLearning.git",
    "ml-DataScience": "git@github.com:diegonmarcos/ml-DataScience.git",
    "ml-Agentic": "git@github.com:diegonmarcos/ml-Agentic.git",
    # Private repositories
    "front-Notes_md": "git@github.com:diegonmarcos/front-Notes_md.git",
    "z-lecole42": "git@github.com:diegonmarcos/lecole42.git",
    "z-dev": "git@github.com:diegonmarcos/dev.git",
}


class ConfigManager:
    """Manages sync-app configuration with persistence"""

    VERSION = "1.0.0"

    def __init__(self, config_path: Optional[Path] = None):
        """Initialize ConfigManager

        Args:
            config_path: Custom config file path (defaults to ~/.config/sync-app/config.json)
        """
        self.config_dir = Path.home() / '.config' / 'sync-app'
        self.config_file = config_path or (self.config_dir / 'config.json')
        self.jobs_file = self.config_dir / 'jobs.json'
        self.log_dir = self.config_dir / 'logs'

        # Ensure directories exist
        self.config_dir.mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)

        # Load or create config
        self._config: Dict[str, Any] = {}
        self._load_or_create()

    def _load_or_create(self):
        """Load existing config or create default"""
        if self.config_file.exists():
            try:
                with open(self.config_file, 'r') as f:
                    self._config = json.load(f)
                self._migrate_config()
            except (json.JSONDecodeError, KeyError) as e:
                print(f"Warning: Failed to load config ({e}), creating new one")
                self._config = self._create_default_config()
                self.save()
        else:
            self._config = self._create_default_config()
            self.save()

    def _create_default_config(self) -> Dict[str, Any]:
        """Create default configuration"""
        home = str(Path.home())
        return {
            "version": self.VERSION,
            "git": {
                "workdir": f"{home}/Documents/Git",
                "merge_strategy": "theirs",
                "auto_commit_message": "fixes",
                "repos": {
                    name: {
                        "url": url,
                        "enabled": True,
                        "category": self._categorize_repo(name)
                    }
                    for name, url in DEFAULT_GIT_REPOS.items()
                }
            },
            "rclone": {
                "default_remote": "Gdrive",
                "default_mount": f"{home}/Documents/Gdrive",
                "bisync_base": f"{home}/Documents/Gdrive_Syncs",
                "log_dir": f"{home}/Documents/Gdrive/system/.rclone",
                "tpslimit": 10,
                "cache_mode": "full",
                "cache_max_age": "1h",
                "cache_max_size": "50G",
                "rules": [],
                "mounts": [
                    {
                        "name": "Gdrive",
                        "remote": "Gdrive:",
                        "local_path": f"{home}/Documents/Gdrive",
                        "cache_mode": "full",
                        "enabled": True,
                        "auto_mount": False
                    }
                ]
            },
            "api": {
                "host": "127.0.0.1",
                "port": 5050,
                "cors_origins": ["*"]
            },
            "tui": {
                "refresh_interval": 30,
                "show_ci_status": True,
                "compact_mode": False,
                "theme": "default"
            }
        }

    def _categorize_repo(self, name: str) -> str:
        """Categorize a repo based on its name prefix"""
        if name.startswith("front-"):
            return "frontend"
        elif name.startswith("back-"):
            return "backend"
        elif name.startswith("cyber-"):
            return "security"
        elif name.startswith("ops-"):
            return "devops"
        elif name.startswith("ml-"):
            return "ml"
        elif name.startswith("z-"):
            return "private"
        return "default"

    def _migrate_config(self):
        """Migrate config from older versions"""
        version = self._config.get("version", "0.0.0")
        home = str(Path.home())

        # Migrate from flat structure to nested structure
        if "git" not in self._config:
            # Old format: git_workdir, git_repos at top level
            self._config["git"] = {
                "workdir": self._config.pop("git_workdir", f"{home}/Documents/Git"),
                "merge_strategy": self._config.pop("merge_strategy", "theirs"),
                "auto_commit_message": self._config.pop("auto_commit_message", "fixes"),
                "repos": {}
            }
            # Migrate git_repos
            old_repos = self._config.pop("git_repos", {})
            for name, url in old_repos.items():
                if isinstance(url, str):
                    self._config["git"]["repos"][name] = {
                        "url": url,
                        "enabled": True,
                        "category": self._categorize_repo(name)
                    }
                else:
                    self._config["git"]["repos"][name] = url

        if "rclone" not in self._config:
            # Old format: rclone_rules, rclone_mounts at top level
            self._config["rclone"] = {
                "default_remote": self._config.pop("default_remote", "Gdrive"),
                "default_mount": self._config.pop("default_mount", f"{home}/Documents/Gdrive"),
                "bisync_base": self._config.pop("bisync_base", f"{home}/Documents/Gdrive_Syncs"),
                "log_dir": self._config.pop("log_dir", f"{home}/Documents/Gdrive/system/.rclone"),
                "tpslimit": self._config.pop("tpslimit", 10),
                "cache_mode": "full",
                "cache_max_age": "1h",
                "cache_max_size": "50G",
                "rules": [],
                "mounts": []
            }
            # Migrate rclone_rules
            old_rules = self._config.pop("rclone_rules", [])
            for rule in old_rules:
                self._config["rclone"]["rules"].append(rule)
            # Migrate rclone_mounts
            old_mounts = self._config.pop("rclone_mounts", [])
            for m in old_mounts:
                self._config["rclone"]["mounts"].append({
                    "name": m.get("name", "Gdrive"),
                    "remote": m.get("remote", "Gdrive:"),
                    "local_path": m.get("local", m.get("local_path", f"{home}/Documents/Gdrive")),
                    "cache_mode": m.get("mode", m.get("cache_mode", "full")),
                    "enabled": m.get("enabled", True),
                    "auto_mount": m.get("auto_mount", False)
                })

        # Clean up any remaining old top-level keys
        for old_key in ["api_port", "api_host"]:
            self._config.pop(old_key, None)

        # Add missing sections
        if "api" not in self._config:
            self._config["api"] = {
                "host": "127.0.0.1",
                "port": 5050,
                "cors_origins": ["*"]
            }

        if "tui" not in self._config:
            self._config["tui"] = {
                "refresh_interval": 30,
                "show_ci_status": True,
                "compact_mode": False,
                "theme": "default"
            }

        # Ensure rclone section has all required fields
        rclone = self._config.get("rclone", {})
        defaults = {
            "tpslimit": 10,
            "cache_mode": "full",
            "cache_max_age": "1h",
            "cache_max_size": "50G",
            "rules": [],
            "mounts": []
        }
        for key, value in defaults.items():
            if key not in rclone:
                rclone[key] = value

        # Update version
        if version != self.VERSION:
            self._config["version"] = self.VERSION
            self.save()

    def save(self):
        """Save configuration to file"""
        with open(self.config_file, 'w') as f:
            json.dump(self._config, f, indent=2)

    # ==================== Git Properties ====================

    @property
    def git_workdir(self) -> Path:
        """Get Git working directory"""
        return Path(self._config["git"]["workdir"])

    @property
    def git_merge_strategy(self) -> str:
        """Get default merge strategy"""
        return self._config["git"].get("merge_strategy", "theirs")

    @property
    def git_commit_message(self) -> str:
        """Get default commit message"""
        return self._config["git"].get("auto_commit_message", "fixes")

    @property
    def git_repos_config(self) -> Dict[str, Dict]:
        """Get raw Git repos config"""
        return self._config["git"].get("repos", {})

    # ==================== Rclone Properties ====================

    @property
    def rclone_default_remote(self) -> str:
        """Get default rclone remote"""
        return self._config["rclone"].get("default_remote", "Gdrive")

    @property
    def rclone_default_mount(self) -> Path:
        """Get default mount path"""
        return Path(self._config["rclone"].get("default_mount",
                    str(Path.home() / "Documents" / "Gdrive")))

    @property
    def rclone_bisync_base(self) -> Path:
        """Get bisync base directory"""
        return Path(self._config["rclone"].get("bisync_base",
                    str(Path.home() / "Documents" / "Gdrive_Syncs")))

    @property
    def rclone_log_dir(self) -> Path:
        """Get rclone log directory"""
        log_dir = self._config["rclone"].get("log_dir")
        if log_dir:
            path = Path(log_dir)
            path.mkdir(parents=True, exist_ok=True)
            return path
        return self.log_dir

    @property
    def rclone_tpslimit(self) -> int:
        """Get API calls per second limit"""
        return self._config["rclone"].get("tpslimit", 10)

    @property
    def rclone_cache_mode(self) -> str:
        """Get VFS cache mode"""
        return self._config["rclone"].get("cache_mode", "full")

    @property
    def rclone_rules_config(self) -> List[Dict]:
        """Get raw rclone rules config"""
        return self._config["rclone"].get("rules", [])

    @property
    def rclone_mounts_config(self) -> List[Dict]:
        """Get raw mount configs"""
        return self._config["rclone"].get("mounts", [])

    # ==================== API Properties ====================

    @property
    def api_host(self) -> str:
        return self._config.get("api", {}).get("host", "127.0.0.1")

    @property
    def api_port(self) -> int:
        return self._config.get("api", {}).get("port", 5050)

    # ==================== TUI Properties ====================

    @property
    def tui_refresh_interval(self) -> int:
        return self._config.get("tui", {}).get("refresh_interval", 30)

    @property
    def tui_show_ci_status(self) -> bool:
        return self._config.get("tui", {}).get("show_ci_status", True)

    # ==================== Repo Accessors ====================

    def get_all_repos(self) -> RepoList:
        """Get all repositories (Git + Rclone) as SyncRepo objects"""
        repos: RepoList = []

        # Git repositories
        for name, info in self.git_repos_config.items():
            if isinstance(info, str):
                # Old format: just URL string
                info = {"url": info, "enabled": True, "category": "default"}

            repos.append(SyncRepo(
                id=f"git:{name}",
                name=name,
                type=RepoType.GIT,
                source=str(self.git_workdir / name),
                destination=info.get("url", ""),
                enabled=info.get("enabled", True),
                category=info.get("category", "git")
            ))

        # Rclone rules
        for rule in self.rclone_rules_config:
            rule_type = rule.get("type", "rclone_bisync")
            try:
                repo_type = RepoType(rule_type)
            except ValueError:
                repo_type = RepoType.RCLONE_BISYNC

            repos.append(SyncRepo(
                id=f"rclone:{rule['name']}",
                name=rule["name"],
                type=repo_type,
                source=rule.get("source", ""),
                destination=rule.get("destination", ""),
                enabled=rule.get("enabled", True),
                category="rclone",
                conflict_resolve=rule.get("conflict_resolve", "newer"),
                delete_extra=rule.get("delete_extra", True)
            ))

        return repos

    def get_git_repos(self) -> RepoList:
        """Get only Git repositories"""
        return [r for r in self.get_all_repos() if r.type == RepoType.GIT]

    def get_rclone_repos(self) -> RepoList:
        """Get only Rclone sync rules"""
        return [r for r in self.get_all_repos() if r.type != RepoType.GIT]

    def get_mounts(self) -> MountList:
        """Get mount configurations"""
        return [MountConfig.from_dict(m) for m in self.rclone_mounts_config]

    def get_repo_by_id(self, repo_id: str) -> Optional[SyncRepo]:
        """Get a specific repository by ID"""
        for repo in self.get_all_repos():
            if repo.id == repo_id:
                return repo
        return None

    def get_repo_by_name(self, name: str) -> Optional[SyncRepo]:
        """Get a specific repository by name"""
        for repo in self.get_all_repos():
            if repo.name == name:
                return repo
        return None

    # ==================== Repo Management ====================

    def add_git_repo(self, name: str, url: str, category: str = "default", enabled: bool = True):
        """Add a new Git repository"""
        self._config["git"]["repos"][name] = {
            "url": url,
            "enabled": enabled,
            "category": category
        }
        self.save()

    def remove_git_repo(self, name: str) -> bool:
        """Remove a Git repository"""
        if name in self._config["git"]["repos"]:
            del self._config["git"]["repos"][name]
            self.save()
            return True
        return False

    def toggle_git_repo(self, name: str) -> bool:
        """Toggle Git repo enabled state"""
        if name in self._config["git"]["repos"]:
            repo = self._config["git"]["repos"][name]
            if isinstance(repo, dict):
                repo["enabled"] = not repo.get("enabled", True)
            else:
                self._config["git"]["repos"][name] = {
                    "url": repo,
                    "enabled": False,
                    "category": "default"
                }
            self.save()
            return True
        return False

    def add_rclone_rule(self, name: str, source: str, destination: str,
                        rule_type: str = "rclone_bisync",
                        conflict_resolve: str = "newer",
                        delete_extra: bool = True,
                        enabled: bool = True):
        """Add a new Rclone sync rule"""
        rule = {
            "name": name,
            "source": source,
            "destination": destination,
            "type": rule_type,
            "conflict_resolve": conflict_resolve,
            "delete_extra": delete_extra,
            "enabled": enabled
        }
        self._config["rclone"]["rules"].append(rule)
        self.save()

    def remove_rclone_rule(self, name: str) -> bool:
        """Remove an Rclone sync rule"""
        rules = self._config["rclone"]["rules"]
        for i, rule in enumerate(rules):
            if rule["name"] == name:
                rules.pop(i)
                self.save()
                return True
        return False

    def toggle_rclone_rule(self, name: str) -> bool:
        """Toggle Rclone rule enabled state"""
        for rule in self._config["rclone"]["rules"]:
            if rule["name"] == name:
                rule["enabled"] = not rule.get("enabled", True)
                self.save()
                return True
        return False

    def add_mount(self, name: str, remote: str, local_path: str,
                  cache_mode: str = "full", auto_mount: bool = False):
        """Add a mount configuration"""
        mount = {
            "name": name,
            "remote": remote,
            "local_path": local_path,
            "cache_mode": cache_mode,
            "enabled": True,
            "auto_mount": auto_mount
        }
        self._config["rclone"]["mounts"].append(mount)
        self.save()

    def remove_mount(self, name: str) -> bool:
        """Remove a mount configuration"""
        mounts = self._config["rclone"]["mounts"]
        for i, mount in enumerate(mounts):
            if mount["name"] == name:
                mounts.pop(i)
                self.save()
                return True
        return False

    # ==================== Settings ====================

    def update_git_settings(self, workdir: Optional[str] = None,
                           merge_strategy: Optional[str] = None,
                           commit_message: Optional[str] = None):
        """Update Git settings"""
        if workdir:
            self._config["git"]["workdir"] = workdir
        if merge_strategy:
            self._config["git"]["merge_strategy"] = merge_strategy
        if commit_message:
            self._config["git"]["auto_commit_message"] = commit_message
        self.save()

    def update_rclone_settings(self, default_remote: Optional[str] = None,
                               default_mount: Optional[str] = None,
                               tpslimit: Optional[int] = None):
        """Update Rclone settings"""
        if default_remote:
            self._config["rclone"]["default_remote"] = default_remote
        if default_mount:
            self._config["rclone"]["default_mount"] = default_mount
        if tpslimit:
            self._config["rclone"]["tpslimit"] = tpslimit
        self.save()

    def update_api_settings(self, host: Optional[str] = None,
                           port: Optional[int] = None):
        """Update API settings"""
        if host:
            self._config["api"]["host"] = host
        if port:
            self._config["api"]["port"] = port
        self.save()

    # ==================== Export/Import ====================

    def export_config(self) -> str:
        """Export config as JSON string"""
        return json.dumps(self._config, indent=2)

    def import_config(self, config_json: str):
        """Import config from JSON string"""
        self._config = json.loads(config_json)
        self._migrate_config()
        self.save()
