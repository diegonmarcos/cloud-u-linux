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
      });
}
