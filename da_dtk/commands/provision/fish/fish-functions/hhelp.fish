function hhelp
    set -l nixos_dir "$HOME/Mounts/Git/unix/aa_nixos-surface_host/src"
    set -l flake_dir "$HOME/Mounts/Git/unix/ba_flakes_desktop/src"
    set -l profiles_dir "$flake_dir/modules/profiles"
    set -l shells_dir "$flake_dir/modules/programs/shells"

    if test (count $argv) -eq 0
        set_color --bold cyan
        echo "hhelp — Home-Manager flake inspector"
        set_color normal
        echo ""

        # Flake info
        set_color --bold yellow
        echo "  Flakes:"
        set_color normal
        set_color magenta
        printf "    NixOS Host       "
        set_color normal
        if test -d "$nixos_dir"
            set -l nixos_rev (git -C "$nixos_dir/.." rev-parse --short HEAD 2>/dev/null; or echo "?")
            set -l nixos_dirty (git -C "$nixos_dir/.." diff --quiet 2>/dev/null; and echo ""; or echo " *dirty*")
            echo "~/Mounts/Git/unix/aa_nixos-surface_host/  ($nixos_rev$nixos_dirty)"
        else
            echo "(not found)"
        end
        set_color magenta
        printf "    Home-Manager     "
        set_color normal
        if test -d "$flake_dir"
            set -l hm_rev (git -C "$flake_dir/.." rev-parse --short HEAD 2>/dev/null; or echo "?")
            set -l hm_dirty (git -C "$flake_dir/.." diff --quiet 2>/dev/null; and echo ""; or echo " *dirty*")
            set -l hm_gen "?"
            if test -L "$HOME/.local/state/nix/profiles/home-manager"
                set hm_gen (readlink "$HOME/.local/state/nix/profiles/home-manager" 2>/dev/null | string replace -r '.*-(\d+)-link' '$1')
            end
            echo "~/Mounts/Git/unix/ba_flakes_desktop/  ($hm_rev$hm_dirty) gen $hm_gen"
        else
            echo "(not found)"
        end
        set_color magenta
        printf "    Profile          "
        set_color normal
        echo "$HM_PROFILE"
        echo ""

        set_color yellow
        echo "  Commands:"
        set_color normal
        echo "    hhelp config             Show flake.nix + common.nix (imports, session vars, paths)"
        echo "    hhelp tools              List all packages declared in profile modules"
        echo "    hhelp alias              List all shell functions and aliases (fish + bash + zsh)"
        echo "    hhelp envvar             List all env vars with current values"
        echo "    hhelp profiles           List profile modules with descriptions"
        echo "    hhelp grep <pattern>     Search across all flake source files"
        return 0
    end

    switch $argv[1]
        case config
            set_color --bold cyan
            echo "═══ Flake Configuration ═══"
            set_color normal
            echo ""

            # Main flake.nix
            set_color --bold yellow
            echo "── flake.nix ──"
            set_color normal
            if test -f "$flake_dir/flake.nix"
                command cat "$flake_dir/flake.nix"
            else
                echo "  (not found)"
            end
            echo ""

            # Common.nix (imports, session vars, paths)
            set_color --bold yellow
            echo "── common.nix (imports + session) ──"
            set_color normal
            if test -f "$flake_dir/modules/common.nix"
                command cat "$flake_dir/modules/common.nix"
            end

        case tools
            set_color --bold cyan
            echo "═══ Declared Packages (by profile) ═══"
            set_color normal
            echo ""

            for pfile in $profiles_dir/*.nix
                set -l pname (basename $pfile)
                set -l pdesc (command head -1 "$pfile" 2>/dev/null | command sed 's/^# //')
                set_color --bold green
                printf "── %s " "$pname"
                set_color --dim
                echo "($pdesc)"
                set_color normal
                # Extract "pkgname  # comment" lines, format as table
                command awk '
        /^\s*#/ { next }
        /^\s*\];/ { next }
        /^\s*home\.packages/ { next }
        /^\s*\(/ { next }
        /^\s*with pkgs/ { next }
        /^\s*customPkgs/ {
          pkg = $1; sub(/;.*/, "", pkg)
          comment = ""
          if (match($0, /#(.*)/, m)) comment = m[1]
          gsub(/^\s+/, "", comment)
          printf "  %-28s %s\n", pkg, comment
          next
        }
        /^\s+[a-zA-Z]/ {
          pkg = $1; sub(/;.*/, "", pkg)
          comment = ""
          if (match($0, /#(.*)/, m)) comment = m[1]
          gsub(/^\s+/, "", comment)
          if (pkg !~ /^(home|lib|config|pkgs|let|in|inherit)/)
            printf "  %-28s %s\n", pkg, comment
        }
      ' "$pfile" 2>/dev/null
                echo ""
            end

            # Custom packages
            set_color --bold green
            echo "── Custom packages (pkgs/) ──"
            set_color normal
            for pkg in $flake_dir/pkgs/*.nix
                test -f "$pkg"; or continue
                set -l desc (command grep -m1 'description' "$pkg" 2>/dev/null | command sed 's/.*"\(.*\)".*/\1/')
                printf "  %-28s %s\n" (basename $pkg .nix) "$desc"
            end

        case envvar
            set -l _vars EDITOR VISUAL PAGER LANG LC_ALL MANPAGER LESS ANTHROPIC_API_KEY OPENAI_BASE_URL OPENAI_API_KEY OLLAMA_HOST AUTHELIA_OIDC_CLIENT_ID AUTHELIA_TOKEN_URL AUTHELIA_OIDC_CREDENTIALS_DIR AUTHELIA_OIDC_TOKENS_DIR CARGO_HOME GOPATH PIP_CACHE_DIR npm_config_cache npm_config_prefix COREPACK_ENABLE_AUTO_PIN DEVICE HM_PROFILE BUILDSH_GUARDRAIL TF_PLUGIN_CACHE_DIR GNUPGHOME GIT_EDITOR RUSTUP_HOME PYTHONPATH JUPYTER_CONFIG_DIR STARSHIP_SHELL FZF_DEFAULT_COMMAND

            # Collect ALL env var declarations into a temp file (one pass, both tables use it)
            set -l _hm_root "$HOME/git/cloud-unix/ba_flakes_desktop/src"
            set -l _os_root "$HOME/git/cloud-unix/aa_nixos-surface_host/src"
            set -l _tmpfile (mktemp)
            # sessionVariables from all nix files
            command find "$_hm_root" "$_os_root" -name '*.nix' 2>/dev/null | sort | while read -l f
                command awk -v file="$f" '
        /[Ss]ession[Vv]ariables\s*=\s*\{/ { inside=1; src=file; gsub(/.*\/src\//, "", src); next }
        inside && /^\s*\};/ { inside=0; next }
        inside && /=/ && !/^[[:space:]]*#/ {
          line = $0; gsub(/^\s+/, "", line); gsub(/;\s*$/, "", line)
          if (line == "") next
          n = index(line, " = ")
          if (n > 0) {
            name = substr(line, 1, n-1); gsub(/"/, "", name)
            val = substr(line, n+3); gsub(/^"/, "", val); gsub(/";?\s*$/, "", val)
            printf "%s\t%s\t%s\n", name, val, src
          }
        }
      ' "$f" 2>/dev/null
            end >>"$_tmpfile"
            # set -gx from fish init
            command find "$_hm_root" -name '*.nix' 2>/dev/null | while read -l f
                command awk -v file="$f" '
        /set -gx [A-Za-z_]/ && !/^[[:space:]]*#/ && !/^\s*if / {
          line = $0; gsub(/^\s+/, "", line)
          gsub(/set -gx /, "", line)
          sp = index(line, " ")
          if (sp > 0) {
            name = substr(line, 1, sp-1)
            val = substr(line, sp+1); gsub(/\)?\s*$/, "", val)
            src = file; gsub(/.*\/src\//, "", src)
            if (name !~ /^#/) printf "%s\t%s\t%s\n", name, val, src
          }
        }
      ' "$f" 2>/dev/null
            end >>"$_tmpfile"

            # TABLE 1: Print every line from the collected data
            set_color --bold cyan
            echo "═══ Table 1: Declared (nix source) ═══"
            set_color normal
            echo ""
            while read -l line
                set -l parts (string split \t -- "$line")
                set -l name $parts[1]
                set -l val $parts[2]
                set -l src $parts[3]
                set_color green
                printf "  %-34s" "$name"
                set_color normal
                printf " = "
                set_color --dim
                printf "%-42s" "$val"
                set_color normal
                set_color --dim magenta
                echo "($src)"
                set_color normal
            end <"$_tmpfile"

            echo ""
            # TABLE 2: For EACH line from the SAME data, resolve the value
            set_color --bold cyan
            echo "═══ Table 2: Resolved ═══"
            set_color normal
            echo ""
            while read -l line
                set -l parts (string split \t -- "$line")
                set -l name $parts[1]
                set -l val $parts[2]
                set -l src $parts[3]
                # Resolve $HOME and ~ in value
                set -l resolved (echo "$val" | command sed "s|\\\$HOME|$HOME|g; s|~|$HOME|g; s|\\\$PYTHONPATH||g")
                # Strip quotes
                set resolved (echo "$resolved" | command sed 's/^"//; s/"$//')
                # Resolve: cat(file), dir→ls, file→cat, symlink→follow, else→echo
                if string match -q '*cat *' -- "$val"
                    # It's a cat command — extract filepath and cat it
                    set -l filepath (echo "$resolved" | command sed 's/^(cat //; s/)$//' | string trim)
                    if test -f "$filepath"
                        set -l content (command head -1 "$filepath" 2>/dev/null | string sub -l 20)"..."
                        set_color yellow
                        printf "  %-34s" "$name"
                        set_color --dim
                        echo "→ $content"
                    else
                        set_color red
                        printf "  %-34s" "$name"
                        echo "→ file not found"
                        set_color normal
                    end
                else if test -L "$resolved" 2>/dev/null
                    set -l target (readlink -f "$resolved" 2>/dev/null)
                    set_color cyan
                    printf "  %-34s" "$name"
                    set_color --dim
                    echo "→ symlink → $target"
                    set_color normal
                else if test -d "$resolved" 2>/dev/null
                    set -l items (command ls "$resolved" 2>/dev/null | head -8 | string join "  ")
                    set_color cyan
                    printf "  %-34s" "$name"
                    set_color --dim
                    echo "→ ls: $items"
                    set_color normal
                else if test -f "$resolved" 2>/dev/null
                    set -l line (command head -1 "$resolved" 2>/dev/null | string sub -l 70)
                    set_color cyan
                    printf "  %-34s" "$name"
                    set_color --dim
                    echo "→ cat: $line"
                    set_color normal
                else
                    set_color cyan
                    printf "  %-34s" "$name"
                    set_color --dim
                    echo "→ $val"
                    set_color normal
                end
            end <"$_tmpfile"
            command rm -f "$_tmpfile"

        case alias
            set_color --bold cyan
            echo "═══ Shell Functions & Aliases ═══"
            set_color normal
            echo ""

            # Fish shellAbbrs (abbreviations)
            set_color --bold yellow
            echo "── Fish abbreviations (fish.nix shellAbbrs) ──"
            set_color normal
            command awk '
      /shellAbbrs\s*=\s*\{/ { inside=1; next }
      inside && /^\s*\};/ { inside=0; next }
      inside && /^\s+\w+ = "/ {
        line = $0
        gsub(/^\s+/, "", line)
        split(line, parts, " = ")
        name = parts[1]
        val = parts[2]
        gsub(/";.*/, "", val)
        gsub(/"/, "", val)
        printf "  %-20s %s\n", name, val
      }
    ' "$shells_dir/fish.nix" 2>/dev/null
            echo ""

            # Fish shellAliases
            set_color --bold yellow
            echo "── Fish aliases (fish.nix shellAliases) ──"
            set_color normal
            command awk '
      /shellAliases\s*=\s*\{/ { inside=1; next }
      inside && /^\s*\};/ { inside=0; next }
      inside && /^\s+\w+ = "/ {
        line = $0
        gsub(/^\s+/, "", line)
        split(line, parts, " = ")
        name = parts[1]
        val = parts[2]
        gsub(/";.*/, "", val)
        gsub(/"/, "", val)
        printf "  %-20s %s\n", name, val
      }
    ' "$shells_dir/fish.nix" 2>/dev/null
            echo ""

            # Fish functions (multiline — just list names)
            set_color --bold yellow
            echo "── Fish functions (fish.nix) ──"
            set_color normal
            command awk '
      /^\s*functions\s*=\s*\{/ { inside=1; next }
      inside && /^\s*\};/ { inside=0; next }
      inside && /^\s+\w+ = / {
        name = $1
        if (name !~ /^(fish_greeting|enable)/)
          printf "  %s\n", name
      }
    ' "$shells_dir/fish.nix" 2>/dev/null
            echo ""

            # Bash aliases
            set_color --bold yellow
            echo "── Bash aliases (bash.nix) ──"
            set_color normal
            if test -f "$shells_dir/bash.nix"
                command awk '
        /shellAliases\s*=\s*\{/ { inside=1; next }
        inside && /^\s*\};/ { inside=0; next }
        inside && /^\s+\w+ = "/ {
          line = $0
          gsub(/^\s+/, "", line)
          split(line, parts, " = ")
          name = parts[1]
          val = parts[2]
          gsub(/";.*/, "", val)
          gsub(/"/, "", val)
          printf "  %-20s %s\n", name, val
        }
      ' "$shells_dir/bash.nix" 2>/dev/null
            end
            echo ""

            # Zsh aliases
            set_color --bold yellow
            echo "── Zsh aliases (zsh.nix) ──"
            set_color normal
            if test -f "$shells_dir/zsh.nix"
                command awk '
        /shellAliases\s*=\s*\{/ { inside=1; next }
        inside && /^\s*\};/ { inside=0; next }
        inside && /^\s+\w+ = "/ {
          line = $0
          gsub(/^\s+/, "", line)
          split(line, parts, " = ")
          name = parts[1]
          val = parts[2]
          gsub(/";.*/, "", val)
          gsub(/"/, "", val)
          printf "  %-20s %s\n", name, val
        }
      ' "$shells_dir/zsh.nix" 2>/dev/null
            end

        case profiles
            set_color --bold cyan
            echo "═══ Profile Modules ═══"
            set_color normal
            echo ""
            for pfile in $profiles_dir/*.nix
                set -l pname (basename $pfile .nix)
                set -l desc (command head -1 "$pfile" 2>/dev/null | command sed 's/^# //')
                set -l pkgcount (command grep -cE '^\s+pkgs\.|^\s+[a-z].*$' "$pfile" 2>/dev/null; or echo 0)
                printf "  %-30s %s\n" "$pname" "$desc"
            end

        case grep
            if test (count $argv) -lt 2
                echo "Usage: hhelp grep <pattern>"
                return 1
            end
            set_color --bold cyan
            echo "═══ Search: $argv[2] ═══"
            set_color normal
            echo ""
            command grep -rn --color=always "$argv[2]" "$flake_dir" 2>/dev/null \
                | command sed "s|$flake_dir/||"

        case '*'
            echo "Unknown command: $argv[1]"
            echo "Run 'hhelp' for usage"
            return 1
    end
end
