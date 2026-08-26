# 🐍 Python Virtual Environment for gcl.py

This folder contains all the Python venv setup files for `gcl.py`.

## 📁 Structure

```
Git/
├── gcl.py                    # Main script (in parent directory)
└── gcl_py-venv/             # This folder
    ├── gcl-venv.sh          # ✨ Unified venv manager
    ├── requirements.txt     # Python dependencies
    ├── README.md            # This file
    ├── VENV-README.md       # Detailed documentation
    └── venv/                # Virtual environment (created on setup)
```

## 🚀 Quick Start

```bash
cd gcl_py-venv

# Interactive menu (easiest!)
./gcl-venv.sh

# Or direct commands
./gcl-venv.sh setup    # One-time setup
./gcl-venv.sh run      # Launch TUI
./gcl-venv.sh status   # CLI command
./gcl-venv.sh help     # Show all options
```

**All functionality is in one script** - no separate setup/run scripts needed!

## 📝 Note

All scripts in this folder run `gcl.py` from the **parent directory** (`../gcl.py`).

See `VENV-README.md` for full documentation.
