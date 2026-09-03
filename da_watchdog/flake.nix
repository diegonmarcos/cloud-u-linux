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
    # The [Service] block every app in this repo shares. An input, not a
    # relative import: `import ../da__shared/…` reaches outside this flake's
    # directory and works right up until this project is carved into its own
    # repository, then silently does not.
    cloud-apps.url = "github:diegonmarcos/cloud-u-linux?dir=da__shared";
    cloud-apps.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, cloud-apps }:
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

        # One recipe, two builds. `tui` is what produces the panel binary at
        # all — watchdog-tui declares required-features = ["tui"], so a default
        # build silently ships the daemon alone. `tray` is the one that must
        # stay optional: a headless fleet member has no session bus for ksni to
        # sit on, and a tray it cannot draw is weight it carries to every VM.
        mkWatchdog = { tray }: pkgs.rustPlatform.buildRustPackage {
          pname = if tray then "my-watchdog-tray" else "my-watchdog";
          version = "0.1.0";
          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;

          buildNoDefaultFeatures = true;
          buildFeatures = [ "tui" ] ++ pkgs.lib.optional tray "tray";

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

        crate = mkWatchdog { tray = false; };
      in
      {
        packages.default = crate;
        packages.my-watchdog = crate;
        # The published static build, fetched not compiled — what every machine
        # that is not the builder installs. See nix/prebuilt.nix.
        packages.my-watchdog-bin = pkgs.callPackage ./nix/prebuilt.nix {};
        # Tier 3: what a Debian box downloads. Binaries, policy, installer and
        # a unit rendered from the same expression the modules render.
        packages.dist = pkgs.callPackage ./nix/dist.nix {
          inherit (self.packages.${system}) my-watchdog-bin;
          inherit (cloud-apps.lib) mkService;
          policy = ./data/watchdog-policy.json;
        };
        # The desktop build. Same source, same version, one feature more.
        packages.my-watchdog-tray = mkWatchdog { tray = true; };

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
      })
    // {
      # HOW IT RUNS, published beside WHAT IT IS.
      #
      # Until now this flake stopped at the binary, so every consumer wrote the
      # rest itself: vm-pilot retypes the unit as a heredoc, my-konsole's
      # build.sh writes a launcher, build.sh install copies a .service. Three
      # descriptions written apart drift apart — they disagreed on the binary's
      # own name, and a laptop ran a three-week-old daemon through four green
      # deploys because nothing joined them. Importing this module is the join:
      # the ExecStart and the file on PATH are one store path by construction.
      #
      #   inputs.my-watchdog.url = "github:diegonmarcos/cloud-u-linux?dir=da_watchdog";
      #   imports = [ inputs.my-watchdog.homeManagerModules.default ];
      #   services.my-watchdog = { enable = true; tray = true; };
      # ONE module, both trees. It works out whether it is being evaluated by
      # NixOS or by home-manager and renders the same service description into
      # systemd.services or systemd.user.services accordingly — see the header
      # of nix/module.nix for why that is one `if` and not two products.
      #
      #   inputs.my-watchdog.url = "github:diegonmarcos/cloud-u-linux?dir=da_watchdog";
      #   imports = [ inputs.my-watchdog.nixosModules.default ];        # or homeManagerModules
      #   services.my-watchdog.enable = true;
      #
      # Named for its job, beside the one that does the same job without nix:
      # nix/watchdog-install.nix installs by DESCRIBING, nix/watchdog-install.sh
      # installs by DOING, and both are downstream of the same service
      # description so a Debian box and this laptop cannot end up running
      # different units.
      homeManagerModules.default = import ./nix/watchdog-install.nix {
        inherit self;
        inherit (cloud-apps.lib) mkService;
      };
      homeManagerModules.my-watchdog = self.homeManagerModules.default;
      nixosModules.default = self.homeManagerModules.default;
      nixosModules.my-watchdog = self.homeManagerModules.default;
    };
}
