{
  description = "da_autofill-rbw-rofi — system-wide hotkey password autofill (browsers + any window) backed by rbw";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };

        rustToolchain = with pkgs; [ rustc cargo rustfmt clippy rust-analyzer ];

        # Runtime deps the binary will shell out to. Not linked, just
        # advertised so a `nix run` shell has them on PATH.
        runtimeDeps = with pkgs; [
          rbw
          rofi # rofi-wayland was merged into rofi in nixpkgs (2025)
          wofi
          wtype
          xdotool
          wl-clipboard
          xclip
          libnotify    # notify-send
        ];

        crate = pkgs.rustPlatform.buildRustPackage {
          pname = "da_autofill-rbw-rofi";
          version = "0.1.0";
          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;

          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ ];

          # No tests rely on network or device. Keep them on.
          doCheck = true;

          meta = with pkgs.lib; {
            description = "System-wide hotkey password autofill via rbw + rofi/wofi + wtype/xdotool";
            license = with licenses; [ mit asl20 ];
            platforms = platforms.linux;
            mainProgram = "da_autofill-rbw-rofi";
          };
        };
      in
      {
        packages.default = crate;
        packages.${"da_autofill-rbw-rofi"} = crate;

        devShells.default = pkgs.mkShell {
          name = "da_autofill-rbw-rofi-dev";
          packages = rustToolchain ++ runtimeDeps ++ (with pkgs; [
            pkg-config
            nodejs # build.sh helper uses node for JSON parsing
          ]);
          RUST_BACKTRACE = "1";
        };

        apps.default = {
          type = "app";
          program = "${crate}/bin/da_autofill-rbw-rofi";
        };
      });
}
