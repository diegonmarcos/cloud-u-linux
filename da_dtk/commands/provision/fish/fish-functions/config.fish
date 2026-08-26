# ~/.config/fish/config.fish: DO NOT EDIT -- this file has been generated
# automatically by home-manager.

# Only execute this file once per shell.
set -q __fish_home_manager_config_sourced; and exit
set -g __fish_home_manager_config_sourced 1

source /nix/store/mn7az047gg7m6f1cj00mcjr3523hdmpw-hm-session-vars.fish



status is-login; and begin

    # Login shell initialisation


end

status is-interactive; and begin

    # Abbreviations
    abbr --add -- dcd 'docker compose down'
    abbr --add -- dcu 'docker compose up'
    abbr --add -- dps 'docker ps'
    abbr --add -- dpsa 'docker ps -a'
    abbr --add -- ga 'git add'
    abbr --add -- gaa 'git add --all'
    abbr --add -- gc 'git commit'
    abbr --add -- gcl 'git clone'
    abbr --add -- gcm 'git commit -m'
    abbr --add -- gco 'git checkout'
    abbr --add -- gd 'git diff'
    abbr --add -- gl 'git log --oneline --graph --decorate -20'
    abbr --add -- gp 'git push'
    abbr --add -- gpl 'git pull'
    abbr --add -- gs 'git status -sb'

    # Aliases
    alias .. 'cd ..'
    alias ... 'cd ../..'
    alias .... 'cd ../../..'
    alias c clear
    alias cat 'bat --paging=never'
    alias chrome_no_CORS 'chromium --disable-web-security --user-data-dir=/tmp/chrome-nocors'
    alias cls clear
    alias cp 'cp -i'
    alias df duf
    alias dtk 'bash ~/git/cloud-mykonsole-dtk/dtk.sh'
    alias du ncdu
    alias find fd
    alias free 'free -h'
    alias gdrive 'bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh'
    alias grep rg
    alias h history
    alias l 'eza -CF --icons'
    alias la 'eza -A --icons'
    alias lh 'eza -lh --icons'
    alias ll 'eza -alF --icons'
    alias logout 'killall -9 -u $USER; qdbus org.kde.Shutdown /Shutdown logout'
    alias ls 'eza --color=auto --icons'
    alias lt 'eza --tree --level=2 --icons'
    alias mv 'mv -i'
    alias myip 'curl -s ifconfig.me'
    alias path 'echo $PATH | tr '\'':'\'' '\''\n'\'''
    alias pip pip3
    alias ports 'ss -tulanp'
    alias poweroff 'qdbus org.kde.Shutdown /Shutdown logoutAndShutdown'
    alias ppy 'poetry run python3'
    alias py python3
    alias python python3
    alias reboot 'qdbus org.kde.Shutdown /Shutdown logoutAndReboot'
    alias reload 'source ~/.config/fish/config.fish'
    alias rm 'rm -i'
    alias welcome _show_welcome

    # Interactive shell initialisation
    /nix/store/kclrlxmzq04ql912fbpy9i0a2pcgjbl1-fzf-0.56.2/bin/fzf --fish | source

    # NODE_PATH for shared ~/.node_modules (ESM doesn't read NODE_PATH, but CJS + tsx do)
    set -gx NODE_PATH "$HOME/.node_modules/node_modules"

    # Starship prompt
    if command -v starship &>/dev/null
        starship init fish | source
    end

    # Zoxide
    if command -v zoxide &>/dev/null
        zoxide init fish | source
    end

    # FZF
    if command -v fzf &>/dev/null
        fzf --fish | source
    end

    # Direnv
    if command -v direnv &>/dev/null
        direnv hook fish | source
    end

    # API keys from vault (read at shell init, not baked into Nix store)
    if test -f ~/git/cloud-vault/A0_keys/providers/anthropic/api-key_opaque
        set -gx ANTHROPIC_API_KEY (cat ~/git/cloud-vault/A0_keys/providers/anthropic/api-key_opaque)
    end

    # Vi mode
    fish_vi_key_bindings

    # Keybinding: Ctrl+P to search available commands with fzf
    bind \cp __fzf_search_commands
    bind -M insert \cp __fzf_search_commands

    # NVM via bass (if available)
    # set -gx NVM_DIR $HOME/.nvm

    # Ensure user PATH entries are set even when __HM_SESS_VARS_SOURCED is
    # inherited from a parent process (e.g. Plasma → Konsole).
    # fish_add_path is idempotent: no duplicates added.
    if test -d /mnt/shared/tools/scripts
        fish_add_path /mnt/shared/tools/scripts
    end
    for dir in /mnt/shared/tools/devops/bin /mnt/shared/tools/data/bin /mnt/shared/tools/dev/bin /mnt/shared/tools/base/bin
        if test -d $dir
            fish_add_path $dir
        end
    end
    if test -d $HOME/.npm-global/bin
        fish_add_path $HOME/.npm-global/bin
    end
    if test -d $HOME/.cargo/bin
        fish_add_path $HOME/.cargo/bin
    end
    if set -q CARGO_HOME; and test -d $CARGO_HOME/bin
        fish_add_path $CARGO_HOME/bin
    end
    if test -d $HOME/.local/bin
        fish_add_path $HOME/.local/bin
    end
    # nix-profile must come LAST so it has highest PATH priority
    # (patchelf'd binaries like claude-code override unpatched npm/cargo copies)
    if test -d $HOME/.nix-profile/bin
        fish_add_path $HOME/.nix-profile/bin
    end

    # Authelia OIDC credentials (vault paths)
    set -gx AUTHELIA_OIDC_CREDENTIALS_DIR "$HOME/git/cloud-vault/A0_keys/providers/authelia/signed-bearer_jwt/credentials"
    set -gx AUTHELIA_OIDC_TOKENS_DIR "$HOME/git/cloud-vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens"
    set -gx AUTHELIA_OIDC_CLIENT_ID claude-admin
    set -gx AUTHELIA_TOKEN_URL "https://auth.diegonmarcos.com/api/oidc/token"

    # http-dev runs as systemd user service (not per-shell)
    set -g __httpd_port 8000

    # Local overrides
    if test -f ~/.config/fish/config.local.fish
        source ~/.config/fish/config.local.fish
    end

    set -gx GPG_TTY (tty)

    if test "$TERM" != dumb
        eval (/home/diego/.nix-profile/bin/starship init fish)

    end

    # add completions generated by Home Manager to $fish_complete_path
    begin
        set -l joined (string join " " $fish_complete_path)
        set -l prev_joined (string replace --regex "[^\s]*generated_completions.*" "" $joined)
        set -l post_joined (string replace $prev_joined "" $joined)
        set -l prev (string split " " (string trim $prev_joined))
        set -l post (string split " " (string trim $post_joined))
        set fish_complete_path $prev "/home/diego/.local/share/fish/home-manager_generated_completions" $post
    end


end
