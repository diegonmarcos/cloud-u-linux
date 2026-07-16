{
  description = "my-ai — Claude Code via Headroom proxy (CLI + TTY dashboard + Tauri GUI). Rebrand of claude-superset.";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in {
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            rustc cargo rustfmt clippy
            pkg-config openssl
            jq gh
          ];
        };
      });
    };
}
