{
  description = "cloud-u-linux app library — one installer generator for every CLI/TUI/daemon in this repo";

  # WHY THIS EXISTS
  #
  # da_watchdog, da_my-ai, da_my-webserver and da_dtk are the same product
  # shape wearing different toolchains: something you run in a terminal,
  # usually a daemon behind it, a tray entry hosted by da__my-konsole, shipped
  # by one CI runner to machines that must never compile.
  #
  # Four copies of that install story is the bug this repo has already paid for
  # twice — once when a unit said `watchdog-d` while the release asset said
  # `my-watchdog` and a laptop ran a three-week-old daemon through four green
  # deploys, and once when a table declared thirteen columns into a frame that
  # fits eleven. Both were one thing described in two places.
  #
  # So: one generator, N renderings. Each app's flake.nix becomes DATA — a
  # name, its binaries, its service — and this produces the packages, the
  # NixOS module, the home-manager module and the tarball for machines with no
  # nix at all.
  #
  # Consumed as a flake INPUT, never as `import ../da__shared/…`. A relative
  # read reaches outside the consuming flake's directory, which works right up
  # until a project is carved into its own repository and then silently does
  # not — a class of breakage this repo has hit before.

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    lib.mkCloudApp = import ./lib/mk-cloud-app.nix;
    lib.mkService = import ./lib/service.nix;
    # The published build, fetched not compiled — what every machine that is
    # not the builder installs. `pkgs.callPackage cloud-apps.lib.mkPrebuilt {}`.
    lib.mkPrebuilt = import ./lib/prebuilt.nix;
  };
}
