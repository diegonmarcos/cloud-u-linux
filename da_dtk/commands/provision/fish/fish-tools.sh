#!/bin/sh
# 23a — Install Fish + ALL CLI tools from desktop flake + fetch configs
# Requires: sudo access, package manager (apt/dnf/pacman/apk)
# Tracks installed packages in ~/.dtk-installed.json
set -eu

SUDO="sudo"
[ "$(id -u)" = "0" ] && SUDO=""
FISH_DIR="${HOME}/.config/fish"
STARSHIP_DIR="${HOME}/.config"
RAW="https://raw.githubusercontent.com/diegonmarcos/cloud-unix/main/ba_flakes_desktop/src/modules/programs/shells/fish"
MANIFEST="${HOME}/.dtk-installed.json"

echo "=== Fish Shell + Tools Setup (23a) ==="

# ═══════════════════════════════════════════════════════════════════
# PACKAGE MANAGER DETECTION
# ═══════════════════════════════════════════════════════════════════

_PM=""
_PM_INSTALL=""
_PM_UPDATE=""
if command -v apt-get >/dev/null 2>&1; then
    _PM="apt"; _PM_INSTALL="$SUDO apt-get install -y -qq"; _PM_UPDATE="$SUDO apt-get update -qq"
elif command -v dnf >/dev/null 2>&1; then
    _PM="dnf"; _PM_INSTALL="$SUDO dnf install -y"; _PM_UPDATE="true"
elif command -v pacman >/dev/null 2>&1; then
    _PM="pacman"; _PM_INSTALL="$SUDO pacman -S --noconfirm"; _PM_UPDATE="$SUDO pacman -Sy"
elif command -v apk >/dev/null 2>&1; then
    _PM="apk"; _PM_INSTALL="$SUDO apk add"; _PM_UPDATE="$SUDO apk update"
else
    echo "[!] No supported package manager found"; exit 1
fi
echo "[OK] Package manager: $_PM"

# ═══════════════════════════════════════════════════════════════════
# INSTALL MANIFEST — tracks what we installed in JSON
# ═══════════════════════════════════════════════════════════════════

_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_HOST=$(hostname -s 2>/dev/null || echo "unknown")
_INSTALLED_LIST=""
_SKIPPED_LIST=""
_EXISTED_LIST=""
_ok=0; _skip=0; _existed=0

_install() {
    _cmd="$1"; _pkg="${2:-$1}"; _cat="${3:-misc}"
    if command -v "$_cmd" >/dev/null 2>&1; then
        _existed=$((_existed + 1))
        _EXISTED_LIST="${_EXISTED_LIST}    {\"cmd\": \"$_cmd\", \"pkg\": \"$_pkg\", \"category\": \"$_cat\"},
"
        return 0
    fi
    if $_PM_INSTALL "$_pkg" >/dev/null 2>&1; then
        echo "[+] $_cmd"; _ok=$((_ok + 1))
        _INSTALLED_LIST="${_INSTALLED_LIST}    {\"cmd\": \"$_cmd\", \"pkg\": \"$_pkg\", \"category\": \"$_cat\"},
"
    else
        echo "[!] $_cmd ($_pkg not in $_PM repos)"; _skip=$((_skip + 1))
        _SKIPPED_LIST="${_SKIPPED_LIST}    {\"cmd\": \"$_cmd\", \"pkg\": \"$_pkg\", \"category\": \"$_cat\"},
"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# STEP 1: Install Fish
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "── Step 1: Fish Shell ──"
_install fish fish shell

# ═══════════════════════════════════════════════════════════════════
# STEP 2: Install ALL CLI tools from desktop flake profiles
# (excludes heavy packages: llvm, jdk, gcloud, awscli, azure-cli,
#  ansible, R, octave, postgresql-server, mysql, prometheus, grafana,
#  valgrind, wireshark, torch/scipy ML stack, pandoc, graphviz, istioctl)
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "── Step 2: CLI Tools ──"
$_PM_UPDATE >/dev/null 2>&1 || true

# ── Profile 1: Shell & Core ──────────────────────────────────────
echo "[*] Shell & Core utilities..."
_install eza eza shell
_install bat bat shell
_install fd fd-find shell
_install rg ripgrep shell
_install fzf fzf shell
_install zoxide zoxide shell
_install yazi yazi shell
_install btop btop shell
_install multitail multitail shell
_install ncdu ncdu shell
_install duf duf shell
_install tree tree shell
_install jq jq shell
_install yq yq shell
_install rsync rsync shell
_install rclone rclone shell
_install curl curl shell
_install wget wget shell
_install htop htop shell
_install less less shell
_install bc bc shell
_install unzip unzip shell
_install zip zip shell
_install 7z p7zip-full shell
_install neofetch neofetch shell
_install lshw lshw shell
_install lspci pciutils shell
_install lsusb usbutils shell
_install socat socat shell
_install ttyd ttyd shell
_install gh gh shell
_install tmux tmux shell
_install xclip xclip shell
_install wl-copy wl-clipboard shell
_install file file shell
_install patch patch shell
_install diff diffutils shell
_install ss iproute2 shell
_install dig dnsutils shell
_install ssh openssh-client shell

# ── Profile 2: Dev Languages ─────────────────────────────────────
echo "[*] Development languages..."
_install go golang dev
_install gopls gopls dev
_install node nodejs dev
_install npm npm dev
_install pnpm pnpm dev
_install yarn yarnpkg dev
_install tsc typescript dev
_install esbuild esbuild dev
_install python3 python3 dev
_install pip3 python3-pip dev
_install pipx pipx dev
_install uv uv dev
_install gcc gcc dev
_install g++ g++ dev
_install ruby ruby dev

# ── Profile 3: Build & Debug ─────────────────────────────────────
echo "[*] Build & debug tools..."
_install cmake cmake build
_install ninja ninja-build build
_install make make build
_install meson meson build
_install automake automake build
_install autoconf autoconf build
_install libtool libtool build
_install pkg-config pkg-config build
_install gdb gdb build
_install strace strace build
_install ltrace ltrace build
_install shellcheck shellcheck build
_install shfmt shfmt build
_install git-lfs git-lfs build
_install delta git-delta build
_install diff-so-fancy diff-so-fancy build
_install direnv direnv build
_install just just build
_install watchexec watchexec build
_install act act build
_install cppcheck cppcheck build
_install doxygen doxygen build

# ── Profile 4: Containers & Cloud ────────────────────────────────
echo "[*] Containers & cloud..."
_install docker docker.io cloud
_install podman podman cloud
_install buildah buildah cloud
_install skopeo skopeo cloud
_install dive dive cloud
_install docker-compose docker-compose cloud
_install kubectl kubectl cloud
_install helm helm cloud
_install k9s k9s cloud
_install kubectx kubectx cloud
_install stern stern cloud
_install terraform terraform cloud
_install cloudflared cloudflared cloud
_install sops sops cloud
_install age age cloud

# ── Profile 5: Security & Networking ─────────────────────────────
echo "[*] Security & networking..."
_install nmap nmap security
_install nc netcat-openbsd security
_install mtr mtr security
_install tcpdump tcpdump security
_install iftop iftop security
_install nethogs nethogs security
_install gpg gnupg security
_install openssl openssl security
_install pass pass security
_install gopass gopass security
_install ssh-audit ssh-audit security
_install httpie httpie security
_install wg wireguard-tools security
_install openvpn openvpn security
_install tor tor security
_install torsocks torsocks security
_install lynis lynis security
_install hexyl hexyl security
_install certbot certbot security
_install binwalk binwalk security

# ── Profile 6: Data ──────────────────────────────────────────────
echo "[*] Data tools..."
_install sqlite3 sqlite3 data
_install pgcli pgcli data
_install mycli mycli data
_install litecli litecli data
_install redis-cli redis-tools data

# ── Prompt & integrations ────────────────────────────────────────
echo "[*] Prompt & integrations..."
_install starship starship shell

echo ""
printf "[OK] %d installed  [=] %d existed  [!] %d skipped\n" "$_ok" "$_existed" "$_skip"

# ═══════════════════════════════════════════════════════════════════
# STEP 3: Write install manifest JSON
# ═══════════════════════════════════════════════════════════════════

# Strip trailing commas
_INSTALLED_LIST=$(printf '%s' "$_INSTALLED_LIST" | sed '$ s/,$//')
_SKIPPED_LIST=$(printf '%s' "$_SKIPPED_LIST" | sed '$ s/,$//')
_EXISTED_LIST=$(printf '%s' "$_EXISTED_LIST" | sed '$ s/,$//')

cat > "$MANIFEST" << MANIFEST_EOF
{
  "dtk_version": "23a",
  "date": "$_DATE",
  "host": "$_HOST",
  "package_manager": "$_PM",
  "counts": {
    "installed": $_ok,
    "existed": $_existed,
    "skipped": $_skip
  },
  "installed": [
$_INSTALLED_LIST
  ],
  "existed": [
$_EXISTED_LIST
  ],
  "skipped": [
$_SKIPPED_LIST
  ]
}
MANIFEST_EOF
echo "[OK] Manifest: $MANIFEST"

# ═══════════════════════════════════════════════════════════════════
# STEP 4: Set fish as default shell
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "── Step 4: Default shell ──"
if command -v fish >/dev/null 2>&1; then
    FISH_PATH=$(command -v fish)
    grep -q "$FISH_PATH" /etc/shells 2>/dev/null || echo "$FISH_PATH" | $SUDO tee -a /etc/shells >/dev/null 2>&1 || true
    CURRENT_SHELL=$(getent passwd "$(whoami)" 2>/dev/null | cut -d: -f7 || echo "")
    [ "$CURRENT_SHELL" != "$FISH_PATH" ] && $SUDO chsh -s "$FISH_PATH" "$(whoami)" 2>/dev/null && echo "[+] Default shell: fish" || true
else
    echo "[!] Fish not installed — cannot set as default"
fi

# ═══════════════════════════════════════════════════════════════════
# STEP 5: Skip if HM-managed
# ═══════════════════════════════════════════════════════════════════

if [ -L "$FISH_DIR/config.fish" ] || ! mkdir -p "$FISH_DIR" 2>/dev/null || ! touch "$FISH_DIR/.test" 2>/dev/null; then
    echo "[OK] Fish config managed by home-manager — skipping config deploy"
    exit 0
fi
rm -f "$FISH_DIR/.test"

# ═══════════════════════════════════════════════════════════════════
# STEP 6: Generate config.fish with fallback aliases
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "── Step 6: Fish config ──"
mkdir -p "$FISH_DIR/functions" "$FISH_DIR/conf.d" "$FISH_DIR/completions"

cat > "$FISH_DIR/config.fish" << 'FISHCONF'
# Generated by dtk.sh 23a — non-HM config with fallback aliases
if status is-interactive
    # Modern CLI with fallbacks
    if command -q eza
        alias ls="eza --color=auto --icons"
        alias ll="eza -alF --icons"
        alias la="eza -A --icons"
        alias l="eza -CF --icons"
        alias lh="eza -lh --icons"
        alias lt="eza --tree --level=2 --icons"
    else
        alias ls="command ls --color=auto"
        alias ll="command ls -alF --color=auto"
        alias la="command ls -A --color=auto"
        alias l="command ls -CF --color=auto"
        alias lh="command ls -lh --color=auto"
        alias lt="tree -L 2 2>/dev/null; or command ls -R"
    end
    if command -q bat;    alias cat="bat --paging=never"; end
    if command -q rg;     alias grep="rg"; end
    if command -q fd;     alias find="fd"; end
    if command -q duf;    alias df="duf";  else; alias df="command df -h"; end
    if command -q ncdu;   alias du="ncdu"; else; alias du="command du -sh"; end

    # Navigation
    alias ..="cd .."; alias ...="cd ../.."; alias ....="cd ../../.."

    # Safety
    alias rm="rm -i"; alias cp="cp -i"; alias mv="mv -i"

    # Python
    alias py="python3"; alias python="python3"; alias pip="pip3"

    # System
    alias free="free -h"
    alias ports="ss -tulanp"
    alias myip="curl -s ifconfig.me"

    # Misc
    alias c="clear"; alias cls="clear"; alias h="history"
    alias path="echo \$PATH | tr ':' '\\n'"
    alias reload="source ~/.config/fish/config.fish"

    # Custom tools
    alias dtk="bash ~/git/cloud-mykonsole-dtk/dtk.sh"

    # Git abbreviations
    abbr -a gs "git status -sb"; abbr -a ga "git add"; abbr -a gaa "git add --all"
    abbr -a gc "git commit"; abbr -a gcm "git commit -m"
    abbr -a gp "git push"; abbr -a gpl "git pull"; abbr -a gcl "git clone"
    abbr -a gl "git log --oneline --graph --decorate -20"
    abbr -a gd "git diff"; abbr -a gco "git checkout"

    # Docker abbreviations
    abbr -a dps "docker ps"; abbr -a dpsa "docker ps -a"
    abbr -a dcu "docker compose up"; abbr -a dcd "docker compose down"

    # PATH
    fish_add_path -m ~/.cargo/bin ~/.npm-global/bin ~/go/bin ~/.local/bin ~/.nix-profile/bin

    # Integrations (only if installed)
    if command -q starship; starship init fish | source; end
    if command -q zoxide;   zoxide init fish | source; end
    if command -q fzf;      fzf --fish | source; end
    if command -q direnv;   direnv hook fish | source; end
end
FISHCONF
echo "[OK] config.fish"

# ═══════════════════════════════════════════════════════════════════
# STEP 7: Fetch functions from unix repo
# ═══════════════════════════════════════════════════════════════════

echo "[+] Fetching fish functions..."
FUNCS_URL="$RAW/functions"
for fn in fish_greeting ai-cli cloud-ai-cli gacp gcam gpsh git_current_branch \
          extract mkcd mkd serve hhelp myhelp localip duh backup cpucap qfind \
          hg fish-e fish-e-stop __fzf_search_commands; do
    _body_tmp=$(mktemp)
    if curl -sfL "$FUNCS_URL/${fn}.fish" -o "$_body_tmp" 2>/dev/null && [ -s "$_body_tmp" ]; then
        { echo "function $fn"; sed 's/^/  /' "$_body_tmp"; echo "end"; } > "$FISH_DIR/functions/${fn}.fish"
        echo "[OK] functions/${fn}.fish"
    else
        echo "[!] functions/${fn}.fish not found"
    fi
    rm -f "$_body_tmp"
done

# ═══════════════════════════════════════════════════════════════════
# STEP 8: Starship config
# ═══════════════════════════════════════════════════════════════════

mkdir -p "$STARSHIP_DIR"
cat > "$STARSHIP_DIR/starship.toml" << 'STAR'
format = "$username$hostname$directory$git_branch$git_status$cmd_duration$line_break$character"
[character]
success_symbol = "[>](green)"
error_symbol = "[>](red)"
[directory]
truncation_length = 3
[git_branch]
format = "[$branch]($style) "
[cmd_duration]
min_time = 2000
STAR
echo "[OK] starship.toml"

echo ""
echo "=== Done ==="
echo "  ~/.config/fish/config.fish"
echo "  ~/.config/fish/functions/ ($(ls "$FISH_DIR/functions/" 2>/dev/null | wc -l) files)"
echo "  ~/.config/starship.toml"
echo "  ~/.dtk-installed.json (install manifest)"
echo "  Tools: $_ok installed, $_existed existed, $_skip skipped"
echo ""
echo "Run: source ~/.config/fish/config.fish"
