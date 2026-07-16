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
          shellHook = ''
            export PKG_CONFIG_PATH="${pkgs.webkitgtk_4_1.dev}/lib/pkgconfig:${pkgs.libsoup_3.dev}/lib/pkgconfig:${pkgs.gtk3.dev}/lib/pkgconfig:$PKG_CONFIG_PATH"
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath buildInputs}:$LD_LIBRARY_PATH"
            export WEBKIT_DISABLE_COMPOSITING_MODE=1
          '';
        };

        # Lean runtime shell for `build.sh run` — only the libs the prebuilt
        # my-ai-gui links, no build toolchain.
        devShells.runtime = pkgs.mkShell {
          inherit buildInputs;
          shellHook = ''
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath buildInputs}:$LD_LIBRARY_PATH"
          '';
        };

        # Plain string for `nix eval --raw` — build.sh run caches it so every
        # GUI launch is a straight exec with the right webkit libs.
        runtimeLibPath = pkgs.lib.makeLibraryPath buildInputs;
      });
}
