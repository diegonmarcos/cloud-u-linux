#!/usr/bin/env python3
"""
Sync-App: Unified Git & Rclone Sync Manager
A masterpiece unification of gcl.sh and rclone.py

Usage:
    ./sync-app.py              # Launch TUI dashboard
    ./sync-app.py status       # Show all status
    ./sync-app.py git sync     # Sync all Git repos
    ./sync-app.py rclone mount # Mount default remote
    ./sync-app.py serve        # Start API server

Version: 1.0.0
Author: Diego N. Marcos
"""

import sys
from pathlib import Path

# Add sync_app package to path
sys.path.insert(0, str(Path(__file__).parent))

# Delegate to main module
from sync_app.main import main

if __name__ == '__main__':
    sys.exit(main())
