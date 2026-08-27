{
  description = "my-browser-rust-chromium — Rust front-end + Chromium (CEF) backend";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # TODO (phase 2): prebuilt libcef as a fixed-output derivation.
        # cef-rs' download-cef normally fetches this at build time, which Nix's
        # sandbox forbids — so we must vendor it as a fixed-output derivation:
        #
        #   libcef = pkgs.stdenv.mkDerivation {
        #     pname = "cef-binary"; version = "<CEF_VERSION>";
        #     src = pkgs.fetchurl {
        #       url = "https://cef-builds.spotifycdn.com/cef_binary_<VER>_linux64.tar.bz2";
        #       sha256 = "<TODO>";                      # the fixed output hash
        #     };
        #     installPhase = "mkdir -p $out && cp -r . $out";
        #   };
        # then export CEF_PATH=${libcef} into the build + runtime env.
      in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [ cmake ninja pkg-config ]; # browser-window/cef build
          buildInputs = with pkgs; [
            rustc cargo rustfmt clippy
            # CEF runtime deps (X11/GL/NSS etc.) — trimmed list, expand as linker asks:
            libGL nss nspr
            xorg.libX11 xorg.libXcomposite xorg.libXdamage xorg.libXrandr
            atk at-spi2-atk cups gtk3 pango cairo alsa-lib
          ];
          shellHook = ''
            echo "my-browser-rust-chromium devshell (skeleton)."
            echo "TODO: pin libcef fixed-output derivation, then: cargo run"
          '';
        };

        # packages.default = ... ;  # TODO once libcef + cargo build wired
      });
}
