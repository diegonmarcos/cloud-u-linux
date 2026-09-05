{
  description = "c3-morpheus — the cloud's workflow orchestrator: workflow inventory, probe registry, and the entry points to the fleet and the PM board";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # What the CLI SHELLS OUT to. Advertised, not linked — same shape
        # da_watchdog uses for journalctl/lsblk/nft. The difference that
        # matters: a missing tool here is REPORTED as a missing tool
        # (`c3-morpheus doctor`), never swallowed into an empty list that
        # reads like "the cloud has no workflows".
        runtimeDeps = with pkgs; [
          curl  # every probe and the Dagu read
          jq    # the probe registry and the Dagu payload
          gh    # the GitHub Actions half
        ];

        crate = pkgs.rustPlatform.buildRustPackage {
          pname = "c3-morpheus";
          version = "0.1.0";
          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;

          # The tests are pure: they assert on the embedded probe registry and
          # on the one behaviour this version must guarantee, which is that
          # `run` never reports success while starting nothing.
          doCheck = true;

          meta = with pkgs.lib; {
            description = "Cloud workflow orchestrator and probe registry";
            homepage = "https://github.com/diegonmarcos/cloud-u-linux";
            license = licenses.mit;
            platforms = platforms.linux;
            mainProgram = "c3-morpheus";
          };
        };
      in
      {
        packages.default = crate;
        packages.c3-morpheus = crate;

        apps.default = {
          type = "app";
          program = "${crate}/bin/c3-morpheus";
        };

        devShells.default = pkgs.mkShell {
          name = "c3-morpheus-dev";
          packages = with pkgs; [ rustc cargo rustfmt clippy ] ++ runtimeDeps;
          RUST_BACKTRACE = "1";
        };
      });
}
