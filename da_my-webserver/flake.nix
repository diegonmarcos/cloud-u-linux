{
  description = "my-webserver — local file server with Markdown, JSON/YAML table and DevTools rendering";

  # WHY THIS FLAKE EXISTS
  #
  # It did not, and the cost was three copies of one binary's packaging living
  # in a different repository from the binary: ba_flakes_desktop and
  # bb_flakes_termux each carry a fetch derivation AND their own hashes.json,
  # and vm-pilot's my-stack.nix types the unit out a third time. Four places
  # have to agree about one artifact, and nothing makes them.
  #
  # This is the app owning its own install story. A consumer takes the flake
  # and enables the service; nobody else writes a fetchurl or a [Service]
  # block for it again.
  #
  # Nothing is built here. The Node Single Executable Application build is
  # heavy and fragile across environments (node --experimental-sea-config +
  # postject, both architectures) and is deliberately a CI-only job — see
  # build.json. So this flake publishes the PUBLISHED build, and the source
  # path that watchdog has is simply absent rather than pretended at.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    cloud-apps.url = "github:diegonmarcos/cloud-u-linux?dir=da__shared";
    cloud-apps.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, cloud-apps }:
    (flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        # patchelf = true, unlike my-watchdog: this is the official nodejs.org
        # runtime, dynamically linked against an FHS interpreter
        # (/lib64/ld-linux-x86-64.so.2) that a nix store does not have. A
        # static musl binary needs no such rewrite; this one fails with
        # "cannot execute: required file not found" without it.
        packages.my-webserver-bin = pkgs.callPackage cloud-apps.lib.mkPrebuilt {} {
          pname = "my-webserver";
          hashes = ./nix/hashes.json;
          patchelf = true;
          meta = {
            description = "Local file server with Markdown and table rendering";
            mainProgram = "my-webserver";
          };
        };
        packages.default = self.packages.${system}.my-webserver-bin;
      }))
    // {
      # ONE module, both trees — see da__shared/lib/mk-cloud-app.nix.
      #
      # No capabilities: this binds a port above 1024 on the mesh address and
      # needs nothing privileged. That is also why the unit here is the plain
      # one; a VM that must bind a specific mesh IP passes its own ExecStart
      # through the same mkService, rather than describing the service again.
      homeManagerModules.default = cloud-apps.lib.mkCloudApp {
        name = "my-webserver";
        description = "my-webserver — local file server";
        bins = [ "my-webserver" ];
        daemon = "my-webserver";
        hashes = ./nix/hashes.json;
        # A Node runtime's baseline is most of the 96M a std+libc sampler is
        # capped at, so this app carries its own number rather than inheriting
        # one that would OOM-kill it. Matches what vm-pilot already gives it.
        memoryMax = "192M";
      } { inherit self; };
      homeManagerModules.my-webserver = self.homeManagerModules.default;
      nixosModules.default = self.homeManagerModules.default;
      nixosModules.my-webserver = self.homeManagerModules.default;
    };
}
