{
  description = "my-browser-qute — vendored, rebranded qutebrowser with a native bookmark/plugin bar";

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

      # THE package — built from the qutebrowser source vendored in src/browser/.
      # No patch series: our changes (the native bookmark + plugin chrome bar)
      # live directly in that tree. Consumed by the desktop via the home-module
      # (programs.my-browser.package default) and shippable directly.
      packages.x86_64-linux.my-browser-qute =
        import ./nix/package.nix {
          pkgs = import nixpkgs { system = "x86_64-linux"; };
        };
      # Back-compat alias for the old output name.
      packages.x86_64-linux.my-browser =
        self.packages.x86_64-linux.my-browser-qute;
      packages.x86_64-linux.default =
        self.packages.x86_64-linux.my-browser-qute;

      # Standalone config bundle — see nix/standalone.nix. Ships to GitHub
      # Releases via build.sh release/gh-release, independent of the desktop
      # home-manager closure. Its launcher execs whatever `my-browser-qute` is
      # on PATH (a machine that installed packages.my-browser-qute).
      packages.x86_64-linux.standalone = import ./nix/standalone.nix {
        inherit nixpkgs home-manager;
        system = "x86_64-linux";
      };
    };
}
