# Terminal Configuration Files

Shell configuration files with useful aliases and functions for Bash, Zsh, and Fish shells.

## Files

- **bash_aliases.sh** - Bash shell configuration
- **zsh_aliases.zsh** - Zsh shell configuration
- **fish_aliases.fish** - Fish shell configuration

## Installation

### Bash

Add to your `~/.bashrc`:
```bash
source /home/diego/Documents/Git/ops-Tooling/Terminal/bash_aliases.sh
```

Then reload:
```bash
source ~/.bashrc
```

### Zsh

Add to your `~/.zshrc`:
```zsh
source /home/diego/Documents/Git/ops-Tooling/Terminal/zsh_aliases.zsh
```

Then reload:
```zsh
source ~/.zshrc
```

### Fish

Add to your `~/.config/fish/config.fish`:
```fish
source /home/diego/Documents/Git/ops-Tooling/Terminal/fish_aliases.fish
```

Then reload:
```fish
source ~/.config/fish/config.fish
```

## Features

### Python Aliases
- `py` - Shortcut for `python3`
- `python` - Always use `python3`
- `pip` - Always use `pip3`

### Directory Navigation
- `..` - Go up one directory
- `...` - Go up two directories
- `....` - Go up three directories
- `.....` - Go up four directories

### List Commands
- `ll` - Long listing with details
- `la` - List all files including hidden
- `l` - Compact listing
- `lh` - Long listing with human-readable sizes
- `lt` - List sorted by modification time

### Git Shortcuts
- `gs` - git status
- `ga` - git add
- `gaa` - git add --all
- `gc` - git commit
- `gcm` - git commit -m
- `gp` - git push
- `gl` - git log (pretty graph)
- `gd` - git diff
- `gco` - git checkout
- `gb` - git branch
- `gpl` - git pull
- `gcl` - git clone
- `gst` - git stash
- `gstp` - git stash pop

### System Information
- `df` - Disk usage with human-readable sizes
- `du` - Directory usage with human-readable sizes
- `free` - Memory usage with human-readable sizes
- `ports` - Show all listening ports

### Networking (Zsh/Fish)
- `myip` - Show external IP address
- `localip` - Show local IP address
- `ping` - Ping with 5 packets default

### Development Shortcuts
- `serve` - Start Python HTTP server
- `jn` - Start Jupyter Notebook
- `dcu` - docker-compose up
- `dcd` - docker-compose down
- `dps` - docker ps
- `dpsa` - docker ps -a

### Safety Features
- `cp`, `mv`, `rm` - All prompt before overwriting/deleting

### Utility Functions

#### mkcd
Create directory and cd into it:
```bash
mkcd new-project
```

#### extract
Extract any archive automatically:
```bash
extract file.tar.gz
extract archive.zip
```

#### qfind
Quick find files by name:
```bash
qfind myfile
```

#### backup
Backup file with timestamp:
```bash
backup important.txt
# Creates: important.txt.backup.20251113_152530
```

#### gcam (Git commit all with message)
```bash
gcam "Fix bug in authentication"
# Equivalent to: git add --all && git commit -m "Fix bug in authentication"
```

#### gpsh (Git push to current branch)
```bash
gpsh
# Equivalent to: git push origin <current-branch>
```

## Customization

Feel free to modify these files to add your own aliases and functions. After editing, reload your shell configuration:

- Bash: `source ~/.bashrc`
- Zsh: `source ~/.zshrc`
- Fish: `source ~/.config/fish/config.fish`

## Compatibility

- **Bash**: Tested on Bash 4.0+
- **Zsh**: Tested on Zsh 5.0+
- **Fish**: Tested on Fish 3.0+

## Contributing

These are personal configuration files, but feel free to use and adapt them for your needs!

## License

Free to use and modify.
