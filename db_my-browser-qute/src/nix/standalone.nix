# Standalone my-browser-qute config bundle — NOT the desktop home-manager
# closure. Evaluates ONLY `programs.my-browser` via a minimal
# `home-manager.lib.homeManagerConfiguration`, so the JSON→config.py logic
# lives in exactly one place: home-module.nix (which now renders config.py
# itself — see the formatters there — rather than going through
# home-manager's `programs.qutebrowser`).
#
# Output: config.py + quickmarks + bookmarks/urls + qute-bookmarks.html + a
# `--basedir`-isolated launcher script, packaged as a tarball. This is what
# `build.sh release` builds and ships to GitHub Releases — a few hundred KB,
# independent of the ~6GB 37-module desktop HM closure. Installing it never
# touches ~/.config/my-browser-qute (the HM-managed one); it runs isolated via
# `my-browser-qute --basedir ~/.local/share/my-browser-qute-standalone`.

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
  # Our generated config.py/quickmarks (and the other xdg.configFile
  # entries — home-manager aliases xdg.configFile into
  # home.file internally) land in home.file, keyed by the FULL ABSOLUTE
  # path (verified via `nix eval`: home.file keys are
  # "${home.homeDirectory}/.config/...", not a relative
  # ".config/my-browser-qute/..." — do not assume, confirm with nix eval).
  homeDir     = cfg.home.homeDirectory;
  configPy    = cfg.home.file."${homeDir}/.config/my-browser-qute/config.py".source;
  quickmarks  = cfg.home.file."${homeDir}/.config/my-browser-qute/quickmarks".source;
  bookmarks   = cfg.home.file."${homeDir}/.config/my-browser-qute/bookmarks/urls".source;
  dashboard   = cfg.home.file."${homeDir}/.config/my-browser-qute/qute-bookmarks.html".source;

  # The launcher must NOT bake in the CI runner's /nix/store paths for
  # config.py etc. — this bundle is extracted from a tarball on a machine
  # that never had those exact store paths, so any "${configPy}"-style
  # interpolation resolves to a path that doesn't exist there (this broke
  # the first release: cp: cannot stat '/nix/store/...-config.py'). The
  # launcher instead copies from files SIBLING to itself (resolved via its
  # own script location at runtime), which the tarball always ships intact.
  # my-browser-qute itself is referenced by PATH — it's already installed via
  # the desktop's earlier (working) generations, not re-shipped here.
  launcher = pkgs.writeTextFile {
    name = "my-browser-qute-standalone";
    executable = true;
    destination = "/bin/my-browser-qute-standalone";
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      # readlink -f resolves the ~/.local/bin symlink to its real
      # location — a plain dirname/BASH_SOURCE[0] would resolve to the
      # SYMLINK's directory (~/.local/bin), not where config.py actually is.
      here="$(cd "$(dirname "$(readlink -f "''${BASH_SOURCE[0]}")")" && pwd)"
      basedir="''${MYBROWSER_STANDALONE_BASEDIR:-''${QUTE_STANDALONE_BASEDIR:-$HOME/.local/share/my-browser-qute-standalone}}"
      mkdir -p "$basedir/config/bookmarks"
      cp -f "$here/config.py"          "$basedir/config/config.py"
      cp -f "$here/quickmarks"         "$basedir/config/quickmarks"
      cp -f "$here/bookmarks/urls"     "$basedir/config/bookmarks/urls"
      cp -f "$here/qute-bookmarks.html" "$basedir/config/qute-bookmarks.html"
      exec my-browser-qute --basedir "$basedir" "$@"
    '';
  };
in
pkgs.runCommand "my-browser-qute-standalone-bundle" {} ''
  mkdir -p $out
  cp ${configPy}   $out/config.py
  cp ${quickmarks} $out/quickmarks
  mkdir -p $out/bookmarks
  cp ${bookmarks}  $out/bookmarks/urls
  cp ${dashboard}  $out/qute-bookmarks.html
  cp ${launcher}/bin/my-browser-qute-standalone $out/my-browser-qute-standalone
  chmod +x $out/my-browser-qute-standalone
''
