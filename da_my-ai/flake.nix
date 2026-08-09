{
  description = "my-ai — Claude Code via Headroom proxy (CLI + TTY dashboard + Tauri GUI/systray). Rebrand of claude-superset.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Tauri v2 on Linux: WebKitGTK 4.1 + libsoup3 provide the system webview;
        # libayatana-appindicator backs the systray. The rest is the Rust
        # toolchain + tauri build tooling. build.sh never assumes the host has
        # cargo/webkit — heavy steps run inside `nix develop`.
        buildInputs = with pkgs; [
          webkitgtk_4_1 gtk3 libsoup_3 glib openssl librsvg
          libayatana-appindicator
        ];

        nativeBuildInputs = with pkgs; [
          rustc cargo cargo-tauri rustfmt clippy
          pkg-config wrapGAppsHook3
          imagemagick jq gh
        ];
      in {
        # Pre-built binary fetched from GH Release — consumed by bb_flakes_termux
        # and ba_flakes_desktop as a flake input instead of the bash script stubs.
        # Hashes are maintained in nix/hashes.json; updated by ship-my-ai-app.yml.
        packages.default = pkgs.callPackage ./nix/my-ai.nix {};
        packages.my-ai   = pkgs.callPackage ./nix/my-ai.nix {};

        devShells.default = pkgs.mkShell {
          inherit buildInputs nativeBuildInputs;
          # Set as derivation env vars (not shellHook) so they are ALWAYS present
          # under `nix develop -c <cmd>`, which does not reliably run the shellHook.
          # makeSearchPathOutput "dev" covers every buildInput's *.pc — incl. glib
          # / gobject (glib-sys) which a webkit-only PKG_CONFIG_PATH would miss.
          # PKG_CONFIG_PATH only — do NOT set LD_LIBRARY_PATH here: webkit libs on
          # the build process's linker crash rustc/cargo. LD_LIBRARY_PATH is set
          # for RUNNING the gui (devShells.runtime + build.sh run), never building.
          PKG_CONFIG_PATH = pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" buildInputs;
          WEBKIT_DISABLE_COMPOSITING_MODE = "1";
        };

        # Lean Rust-only shell for the pure-Rust crates (my-ai, my-ai-dash) — no
        # webkit/gtk. Used on BOTH x86_64 and aarch64 (fast; aarch64 never pulls
        # the webkit closure since the GUI is x86-desktop-only).
        devShells.cli = pkgs.mkShell {
          packages = with pkgs; [ rustc cargo pkg-config ];
        };

        # Lean runtime shell for `build.sh run` — only the libs the prebuilt
        # my-ai-gui links, no build toolchain.
        devShells.runtime = pkgs.mkShell {
          inherit buildInputs;
          shellHook = ''
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath buildInputs}:$LD_LIBRARY_PATH"
          '';
        };

        # Plain strings for `nix eval --raw` — build.sh injects these directly into
        # the command env (`nix develop -c env PKG_CONFIG_PATH=… …`) because
        # `nix develop -c` does not reliably apply the shellHook / mkShell env vars.
        runtimeLibPath = pkgs.lib.makeLibraryPath buildInputs;
        pkgConfigPath = pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" buildInputs;
      }) // {
        # ── Claude Code assets — my-ai owns these, the flakes only deploy them ──
        #
        # Ownership is split by WHO CAN CHANGE A FILE AT RUNTIME:
        #
        #   statusline family (src/data/statusline)  →  embedded in the BINARY
        #     (core/src/statusline_assets.rs) and written by the daemon at startup.
        #     A flake must never declare those: home.file lays a second copy on top,
        #     which is how the deployed status line sat 141 lines stale for 8 days.
        #
        #   everything here                          →  exposed as a flake output
        #     because it is inert config the flakes must place in ~/.claude anyway.
        #     Shipping it through the binary would mean a GH release per asset edit.
        #
        # Plain files, identical on every machine, so this sits OUTSIDE
        # eachDefaultSystem — consumers use "${my-ai.claudeAssets}/agents", with no
        # system suffix.
        #
        # settings.base.json carries @HOME@ placeholders; the consuming flake
        # substitutes config.home.homeDirectory and merges the per-platform overlay
        # with lib.recursiveUpdate. Verified: base ⊕ overlay reproduces each
        # machine's previous settings.json (desktop byte-identical; termux differs
        # only in statusLine.command, where the literal $HOME is now pre-expanded).
        claudeAssets = ./src/data/claude;
      };
}
