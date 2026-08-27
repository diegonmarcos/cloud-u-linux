{
  description = "my-browser — qutebrowser daily-driver with daemon integrations (FIDO2 + autofill)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }:
    {
      # System-independent home-manager module. Consumer wires this in their
      # home flake; the module reads JSON in src/2_configs/ at evaluation
      # time so editing the JSON is the only thing the operator does after
      # initial install.
      homeManagerModules.default = import ./nix/home-module.nix;

      # The FORK package — patched qutebrowser (native bookmark + plugin chrome
      # bar). This is what `my-browser` IS. Consumed by the desktop via the
      # home-module (programs.my-browser.package default) and shippable directly.
      packages.x86_64-linux.my-browser =
        import ./nix/fork.nix {
          pkgs = import nixpkgs { system = "x86_64-linux"; };
        };

      # Standalone config bundle — see nix/standalone.nix. Ships to GitHub
      # Releases via build.sh release/gh-release, independent of the desktop
      # home-manager closure. Its launcher execs whatever `qutebrowser` is on
      # PATH (the fork, on a machine that installed packages.my-browser).
      packages.x86_64-linux.standalone = import ./nix/standalone.nix {
        inherit nixpkgs home-manager;
        system = "x86_64-linux";
      };
    };
}
