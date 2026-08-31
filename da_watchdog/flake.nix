{
  description = "my-watchdog — a machine sampler and its panel, installable on its own";

  # WHY THIS FLAKE EXISTS
  # my-watchdog used to reach a machine only through that machine's system
  # configuration: to update the panel you rebuilt NixOS. That is the wrong
  # shape for an app. It made every fix to a dashboard a system generation, and
  # on an 8GB laptop six local evaluations OOM-froze the desktop in July.
  #
  # This makes it an independent artifact. `nix run` it, `nix profile install`
  # it, or let a host flake take it as an input — none of which evaluates or
  # rebuilds the system it runs on. The update is: pull this flake, run this
  # flake.
  #
  # The same crate also ships as a static musl binary on the rolling release
  # and as a container image, because a fleet is not all NixOS and an app that
  # only installs one way is an app with a prerequisite.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };

        rustToolchain = with pkgs; [ rustc cargo rustfmt clippy rust-analyzer ];

        # What the panel SHELLS OUT to. Not linked — advertised, so a `nix run`
        # shell can answer the questions the panel asks. Absent, the panel does
        # not crash: every reader treats a missing tool as an unmeasured box,
        # which is the difference between a partial dashboard and no dashboard.
        runtimeDeps = with pkgs; [
          systemd    # journalctl, systemctl — the logs tab and the unit list
          util-linux # lsblk, findmnt
          procps     # ps, the process table's fallback reader
          btrfs-progs # subvolume quotas, the storage box's per-mount figures
          iproute2   # the network box
        ];

        crate = pkgs.rustPlatform.buildRustPackage {
          pname = "my-watchdog";
          version = "0.1.0";
          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;

          # `tui` is what builds the panel binary at all: watchdog-tui
          # declares required-features = ["tui"], so a default build silently
          # produces the daemon alone. The tray is left OUT — ksni links
          # libdbus, and this package must build on a headless fleet member
          # that has no session bus to talk to.
          buildNoDefaultFeatures = true;
          buildFeatures = [ "tui" ];

          nativeBuildInputs = [ pkgs.pkg-config ];

          # The tests are pure: they parse fixtures and assert on layout, and
          # the two that touch the machine read /proc, which the sandbox has.
          doCheck = true;

          meta = with pkgs.lib; {
            description = "Machine sampler and TUI panel — one JSON snapshot, three renderers";
            homepage = "https://github.com/diegonmarcos/cloud-u-linux";
            license = licenses.mit;
            platforms = platforms.linux;
            mainProgram = "watchdog-tui";
          };
        };
      in
      {
        packages.default = crate;
        packages.my-watchdog = crate;

        # `nix run github:diegonmarcos/cloud-u-linux?dir=da_watchdog` opens the
        # panel. The panel rather than the daemon, because a person running
        # this by hand wants to LOOK at the machine; the daemon is what a
        # service unit starts.
        apps.default = {
          type = "app";
          program = "${crate}/bin/watchdog-tui";
        };
        apps.my-watchdog = {
          type = "app";
          program = "${crate}/bin/watchdog-d";
        };

        devShells.default = pkgs.mkShell {
          name = "my-watchdog-dev";
          packages = rustToolchain ++ runtimeDeps ++ (with pkgs; [ pkg-config dbus sass esbuild ]);
          RUST_BACKTRACE = "1";
        };
      });
}
