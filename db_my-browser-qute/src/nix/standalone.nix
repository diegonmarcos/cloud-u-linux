# Standalone qutebrowser config bundle — NOT the desktop home-manager
# closure. Evaluates ONLY `programs.my-browser` via a minimal
# `home-manager.lib.homeManagerConfiguration` (reusing home-manager's real
# `programs.qutebrowser` renderer — the same code path the desktop flake
# uses — so the JSON→config.py logic lives in exactly one place: home-module.nix).
#
# Output: config.py + quickmarks + bookmarks/urls + qute-bookmarks.html + a
# `--basedir`-isolated launcher script, packaged as a tarball. This is what
# `build.sh release` builds and ships to GitHub Releases — a few hundred KB,
# independent of the ~6GB 37-module desktop HM closure. Installing it never
# touches ~/.config/qutebrowser (the HM-managed one); it runs isolated via
# `qutebrowser --basedir ~/.local/share/qutebrowser-standalone`.

{ nixpkgs, home-manager, system ? "x86_64-linux" }:
let
  pkgs = import nixpkgs { inherit system; };

  hm = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      ./home-module.nix
      {
        programs.my-browser.enable = true;
        home.username = "diego";
        home.homeDirectory = "/home/diego";
        home.stateVersion = "24.11";
      }
    ];
  };

  cfg = hm.config;
  # programs.qutebrowser's generated config.py/quickmarks (and our own
  # xdg.configFile entries — home-manager aliases xdg.configFile into
  # home.file internally) land in home.file, keyed by the FULL ABSOLUTE
  # path (verified via `nix eval`: home.file keys are
  # "${home.homeDirectory}/.config/...", not a relative
  # ".config/qutebrowser/..." — do not assume, confirm with nix eval).
  homeDir     = cfg.home.homeDirectory;
  configPy    = cfg.home.file."${homeDir}/.config/qutebrowser/config.py".source;
  quickmarks  = cfg.home.file."${homeDir}/.config/qutebrowser/quickmarks".source;
  bookmarks   = cfg.home.file."${homeDir}/.config/qutebrowser/bookmarks/urls".source;
  dashboard   = cfg.home.file."${homeDir}/.config/qutebrowser/qute-bookmarks.html".source;

  # The launcher must NOT bake in the CI runner's /nix/store paths for
  # config.py etc. — this bundle is extracted from a tarball on a machine
  # that never had those exact store paths, so any "${configPy}"-style
  # interpolation resolves to a path that doesn't exist there (this broke
  # the first release: cp: cannot stat '/nix/store/...-config.py'). The
  # launcher instead copies from files SIBLING to itself (resolved via its
  # own script location at runtime), which the tarball always ships intact.
  # qutebrowser itself is referenced by PATH — it's already installed via
  # the desktop's earlier (working) generations, not re-shipped here.
  launcher = pkgs.writeTextFile {
    name = "qutebrowser-standalone";
    executable = true;
    destination = "/bin/qutebrowser-standalone";
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      # readlink -f resolves the ~/.local/bin symlink to its real
      # location — a plain dirname/BASH_SOURCE[0] would resolve to the
      # SYMLINK's directory (~/.local/bin), not where config.py actually is.
      here="$(cd "$(dirname "$(readlink -f "''${BASH_SOURCE[0]}")")" && pwd)"
      basedir="''${QUTE_STANDALONE_BASEDIR:-$HOME/.local/share/qutebrowser-standalone}"
      mkdir -p "$basedir/config/bookmarks"
      cp -f "$here/config.py"          "$basedir/config/config.py"
      cp -f "$here/quickmarks"         "$basedir/config/quickmarks"
      cp -f "$here/bookmarks/urls"     "$basedir/config/bookmarks/urls"
      cp -f "$here/qute-bookmarks.html" "$basedir/config/qute-bookmarks.html"
      exec qutebrowser --basedir "$basedir" "$@"
    '';
  };
in
pkgs.runCommand "qutebrowser-standalone-bundle" {} ''
  mkdir -p $out
  cp ${configPy}   $out/config.py
  cp ${quickmarks} $out/quickmarks
  mkdir -p $out/bookmarks
  cp ${bookmarks}  $out/bookmarks/urls
  cp ${dashboard}  $out/qute-bookmarks.html
  cp ${launcher}/bin/qutebrowser-standalone $out/qutebrowser-standalone
  chmod +x $out/qutebrowser-standalone
''
