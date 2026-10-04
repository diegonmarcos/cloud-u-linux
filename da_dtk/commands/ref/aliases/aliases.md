# Diego's Aliases & Functions

> Auto-generated from `aliases.json` by `aliases.sh`
> Last updated: 2026-03-30 15:07:49


## Docker

| Alias | Description |
|-------|-------------|
| `dps` | docker ps |
| `dpsa` | docker ps -a |
| `dcu` | docker compose up |
| `dcd` | docker compose down |

## Functions

| Alias | Description |
|-------|-------------|
| `ai-cli` | AI CLI launcher |
| `hhelp` | flake inspector (config/tools/alias/envvar/profiles/grep) |
| `extract` | extract any archive (tar/zip/7z/rar/deb) |
| `backup` | backup file with timestamp |
| `qfind` | quick find by pattern |
| `serve` | start http-dev server |
| `myhelp` | quick reference card |
| `Ctrl+T` | find file |
| `Ctrl+R` | search history |
| `Ctrl+P` | search commands |
| `Alt+C` | cd to folder |

## Git

| Alias | Description |
|-------|-------------|
| `gs` | git status -sb |
| `ga` | git add |
| `gaa` | git add --all |
| `gc` | git commit |
| `gcm` | git commit -m |
| `gp` | git push |
| `gl` | git log --oneline --graph -20 |
| `gd` | git diff |
| `gco` | git checkout |
| `gpl` | git pull |
| `gcl` | git clone |
| `gcam` | git add --all + commit -m |
| `gpsh` | git push origin (current branch) |
| `gacp` | git add --all + commit + push |

## Misc

| Alias | Description |
|-------|-------------|
| `c` | clear |
| `cls` | clear |
| `h` | history |
| `hg` | history | grep |
| `path` | show PATH entries |
| `reload` | re-source fish config |
| `welcome` | show greeting screen |
| `chrome_no_CORS` | launch chromium without CORS |

## Modern Cli

| Alias | Description |
|-------|-------------|
| `ls` | eza --color=auto --icons |
| `ll` | eza -alF --icons |
| `la` | eza -A --icons |
| `l` | eza -CF --icons |
| `lh` | eza -lh --icons |
| `lt` | eza --tree --level=2 --icons |
| `cat` | bat --paging=never |
| `grep` | rg (ripgrep) |
| `find` | fd |
| `df` | duf |
| `du` | ncdu |

## Navigation

| Alias | Description |
|-------|-------------|
| `..` | cd .. |
| `...` | cd ../.. |
| `....` | cd ../../.. |
| `mkcd` | mkdir + cd |
| `mkd` | mkdir multiple + cd last |

## Python

| Alias | Description |
|-------|-------------|
| `py` | python3 |
| `python` | python3 |
| `pip` | pip3 |
| `ppy` | poetry run python3 |

## Safety

| Alias | Description |
|-------|-------------|
| `rm` | rm -i (confirm before delete) |
| `cp` | cp -i (confirm before overwrite) |
| `mv` | mv -i (confirm before overwrite) |

## Session

| Alias | Description |
|-------|-------------|
| `logout` | KDE logout |
| `reboot` | KDE reboot |
| `poweroff` | KDE shutdown |

## System

| Alias | Description |
|-------|-------------|
| `free` | free -h |
| `ports` | ss -tulanp |
| `myip` | curl -s ifconfig.me |
| `cpucap` | show CPU freq/capability |
| `duh` | du -h --max-depth=1 | sort |
| `localip` | show local IPs |

## Web Terminal

| Alias | Description |
|-------|-------------|
| `fish-e` | start web terminal (ttyd+tmux on WireGuard) |
| `fish-e-stop` | stop all fish-e sessions |


---
*Source: `1-aliases/aliases.json` | Generator: `1-aliases/aliases.sh`*
