#!/bin/sh
# Install module — detect distro and install full dev toolchain
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Distro detection ──────────────────────────────────────────────

detect_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
      fedora|rhel|centos|rocky|alma) echo "fedora" ;;
      arch|manjaro)                  echo "arch" ;;
      debian|ubuntu|pop|mint)        echo "debian" ;;
      nixos)                         echo "nix" ;;
    esac
  elif [ -d /data/data/com.termux ]; then
    echo "termux"
  elif command -v sw_vers >/dev/null 2>&1; then
    echo "macos"
  fi
}

# ── Cloud CLIs ────────────────────────────────────────────────────

install_cloud_clis() {
  if ! command -v gcloud >/dev/null 2>&1; then
    echo "Installing Google Cloud SDK..."
    curl -sL https://sdk.cloud.google.com | bash -s -- --disable-prompts --install-dir=/opt 2>/dev/null || true
    ln -sf /opt/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud 2>/dev/null || true
  fi
  command -v oci >/dev/null 2>&1 || pip3 install oci-cli 2>/dev/null || pip install oci-cli 2>/dev/null || true
  command -v aws >/dev/null 2>&1 || pip3 install awscli 2>/dev/null || true
}

# ── Extras ────────────────────────────────────────────────────────

setup_starship() {
  command -v starship >/dev/null 2>&1 || return 0
  mkdir -p "${HOME}/.config"
  [ -f "${HOME}/.config/starship.toml" ] && return 0
  cat > "${HOME}/.config/starship.toml" << 'STAR'
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
}

setup_fish_config() {
  FISH_DIR="${HOME}/.config/fish"
  mkdir -p "$FISH_DIR"
  cat > "$FISH_DIR/config.fish" << 'FISHCONF'
if status is-interactive
    alias ls="eza --color=auto --icons 2>/dev/null || command ls --color=auto"
    alias ll="eza -alF --icons 2>/dev/null || command ls -alF"
    alias la="eza -A --icons 2>/dev/null || command ls -A"
    alias lt="eza --tree --level=2 --icons 2>/dev/null || tree -L 2"
    alias cat="bat --paging=never 2>/dev/null || command cat"
    alias grep="rg 2>/dev/null || command grep --color=auto"
    alias find="fd 2>/dev/null || command find"
    alias df="duf 2>/dev/null || command df -h"
    alias du="ncdu 2>/dev/null || command du -sh"
    alias ..="cd .."; alias ...="cd ../.."; alias ....="cd ../../.."
    alias rm="rm -i"; alias cp="cp -i"; alias mv="mv -i"
    abbr -a gs "git status -sb"
    abbr -a ga "git add"; abbr -a gaa "git add --all"
    abbr -a gc "git commit"; abbr -a gcm "git commit -m"
    abbr -a gp "git push"; abbr -a gpl "git pull"
    abbr -a gl "git log --oneline --graph --decorate -20"
    abbr -a gd "git diff"; abbr -a gco "git checkout"
    abbr -a dps "docker ps"; abbr -a dpsa "docker ps -a"
    abbr -a dcu "docker compose up"; abbr -a dcd "docker compose down"
    abbr -a dcl "docker compose logs -f"
    alias c="clear"; alias h="history"
    alias ports="ss -tulanp"; alias myip="curl -s ifconfig.me"
    alias py="python3"; alias cc="claude"
    alias reload="source ~/.config/fish/config.fish"
    fish_add_path -m ~/.cargo/bin ~/.npm-global/bin ~/go/bin ~/.local/bin ~/.nix-profile/bin
    if command -q starship; starship init fish | source; end
    if command -q zoxide; zoxide init fish | source; end
end
FISHCONF
  echo "Fish config written to $FISH_DIR/config.fish"
}

install_extras() {
  echo ""
  echo "=== Extras: Claude Code, Wrangler, Fish config ==="
  npm install -g @anthropic-ai/claude-code 2>/dev/null || true
  npm install -g wrangler 2>/dev/null || true
  if command -v fish >/dev/null 2>&1; then
    FISH_PATH="$(command -v fish)"
    grep -qxF "$FISH_PATH" /etc/shells 2>/dev/null || echo "$FISH_PATH" >> /etc/shells 2>/dev/null || true
    chsh -s "$FISH_PATH" "$(logname 2>/dev/null || whoami)" 2>/dev/null || true
    chsh -s "$FISH_PATH" root 2>/dev/null || true
  fi
  setup_fish_config
  setup_starship
  echo ""
  echo "=== Install complete ==="
}

# ── Distro installers ─────────────────────────────────────────────

install_dev_fedora() {
  echo "=== Fedora/RHEL: Full Dev Toolchain ==="
  dnf install -y --skip-unavailable \
    fish git curl wget htop btop vim nano neovim \
    gcc gcc-c++ make cmake rust cargo golang \
    python3 python3-pip python3-virtualenv \
    nodejs npm \
    docker docker-compose \
    jq ripgrep fd-find bat tree fzf zoxide duf ncdu \
    rsync openssh-server wireguard-tools \
    tmux screen strace lsof bind-utils net-tools iproute nmap ncat \
    zip unzip p7zip tar gzip \
    man-db less which file \
    gnupg2 openssl \
    sqlite sqlite-devel postgresql-devel \
    gh rclone
  echo "Installing extras (eza, starship, terraform)..."
  command -v eza >/dev/null 2>&1 || cargo install eza 2>/dev/null || true
  command -v starship >/dev/null 2>&1 || curl -sS https://starship.rs/install.sh | sh -s -- -y 2>/dev/null || true
  if ! command -v terraform >/dev/null 2>&1; then
    dnf config-manager addrepo --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo 2>/dev/null || true
    dnf install -y terraform 2>/dev/null || true
  fi
  command -v sops >/dev/null 2>&1 || { curl -sLo /usr/local/bin/sops https://github.com/getsops/sops/releases/latest/download/sops-v3.9.4.linux.amd64 && chmod +x /usr/local/bin/sops; } 2>/dev/null || true
  command -v age >/dev/null 2>&1 || dnf install -y age 2>/dev/null || true
  install_cloud_clis
  install_extras
}

install_dev_arch() {
  echo "=== Arch Linux: Full Dev Toolchain ==="
  /usr/bin/pacman -Syu --noconfirm
  /usr/bin/pacman -S --noconfirm --needed \
    fish git curl wget htop btop vim nano neovim \
    base-devel gcc make cmake rust cargo go \
    python python-pip python-virtualenv \
    nodejs npm yarn typescript \
    docker docker-compose docker-buildx \
    jq yq ripgrep fd bat eza tree fzf zoxide duf ncdu \
    rsync openssh wireguard-tools \
    tmux screen strace lsof bind-tools net-tools iproute2 nmap ncat \
    zip unzip p7zip tar gzip \
    man-db less which file \
    sops age gnupg openssl \
    sqlite postgresql-libs \
    starship github-cli terraform \
    rclone unison
  install_cloud_clis
  install_extras
}

install_dev_debian() {
  echo "=== Debian/Ubuntu: Full Dev Toolchain ==="
  apt-get update -qq
  apt-get install -y -qq \
    fish git curl wget htop vim nano neovim \
    build-essential gcc make cmake rustc cargo golang \
    python3 python3-pip python3-venv \
    nodejs npm \
    docker.io docker-compose docker-buildx-plugin \
    jq ripgrep fd-find bat eza tree fzf duf ncdu \
    rsync openssh-server wireguard-tools \
    tmux screen strace lsof dnsutils net-tools iproute2 nmap ncat \
    zip unzip p7zip-full tar gzip \
    man-db less file \
    sops age gnupg openssl \
    sqlite3 libpq-dev \
    gh terraform \
    rclone
  install_cloud_clis
  install_extras
}

install_dev_nix() {
  echo "=== Nix: Full Dev Toolchain ==="
  if ! command -v nix >/dev/null 2>&1; then
    echo "Installing Nix..."
    curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
  fi
  nix-env -iA \
    nixpkgs.fish nixpkgs.git nixpkgs.curl nixpkgs.wget nixpkgs.htop nixpkgs.btop \
    nixpkgs.neovim nixpkgs.gcc nixpkgs.gnumake nixpkgs.cmake \
    nixpkgs.rustc nixpkgs.cargo nixpkgs.go \
    nixpkgs.python3 nixpkgs.nodejs_22 nixpkgs.yarn nixpkgs.typescript \
    nixpkgs.docker-compose \
    nixpkgs.jq nixpkgs.yq-go nixpkgs.ripgrep nixpkgs.fd nixpkgs.bat nixpkgs.eza \
    nixpkgs.tree nixpkgs.fzf nixpkgs.zoxide nixpkgs.duf nixpkgs.ncdu \
    nixpkgs.rsync nixpkgs.wireguard-tools nixpkgs.openssh \
    nixpkgs.tmux nixpkgs.strace nixpkgs.nmap \
    nixpkgs.unzip nixpkgs.p7zip \
    nixpkgs.sops nixpkgs.age nixpkgs.gnupg nixpkgs.openssl \
    nixpkgs.sqlite nixpkgs.starship nixpkgs.gh nixpkgs.terraform \
    nixpkgs.google-cloud-sdk nixpkgs.oci-cli nixpkgs.awscli2 \
    nixpkgs.flarectl nixpkgs.cloudflared nixpkgs.rclone
  install_extras
}

# ── Entry point ───────────────────────────────────────────────────

_distro="${1:-}"
if [ -z "$_distro" ]; then
  _detected=$(detect_distro)
  if [ -n "$_detected" ]; then
    echo "Detected: $_detected"
    printf "Use $_detected? [Y/n] "
    read -r _yn
    case "${_yn:-y}" in
      [Yy]*|"") _distro="$_detected" ;;
      *)
        echo "Distro:"
        echo "  1) fedora  2) arch  3) debian  4) nix"
        printf "> "
        read -r _di
        case "$_di" in 1) _distro="fedora" ;; 2) _distro="arch" ;; 3) _distro="debian" ;; 4) _distro="nix" ;; *) echo "Invalid"; exit 1 ;; esac
        ;;
    esac
  else
    echo "Distro:"
    echo "  1) fedora  2) arch  3) debian  4) nix"
    printf "> "
    read -r _di
    case "$_di" in 1) _distro="fedora" ;; 2) _distro="arch" ;; 3) _distro="debian" ;; 4) _distro="nix" ;; *) echo "Invalid"; exit 1 ;; esac
  fi
fi

case "$_distro" in
  fedora) install_dev_fedora ;;
  arch)   install_dev_arch ;;
  debian) install_dev_debian ;;
  nix)    install_dev_nix ;;
  *) echo "Unknown distro: $_distro"; exit 1 ;;
esac
