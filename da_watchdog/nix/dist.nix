# THE TARBALL A MACHINE WITH NO NIX INSTALLS FROM.
#
# It carries the published static binaries, the policy document, the shell
# installer — and a my-watchdog.service that NIX RENDERED from
# watchdog-service.nix, the same expression the NixOS and home-manager modules
# render into their own namespaces.
#
# That last file is the point of this derivation existing at all. A tarball
# could have shipped a hand-written unit; every earlier version of this app
# did, in three separate places, and they disagreed about the binary's own
# name until a laptop ran a three-week-old daemon through four successful
# deploys. `serviceConfig` on NixOS and `[Service]` in a file are the same
# keys, so generating one from the other needs no translation layer and leaves
# nowhere for them to drift.
{ lib, runCommand, my-watchdog-bin, policy }:

let
  service = import ./watchdog-service.nix { exec = "@BIN@/watchdog-d --no-tray"; };

  unit = lib.generators.toINI { } {
    Unit = {
      Description = "my-watchdog — machine sampler";
      After = "network.target";
    };
    Service = service;
    Install = { WantedBy = "multi-user.target"; };
  };
in
runCommand "my-watchdog-dist" { inherit unit; passAsFile = [ "unit" ]; } ''
  d="$out/my-watchdog"
  mkdir -p "$d"
  cp ${my-watchdog-bin}/bin/watchdog-d   "$d/watchdog-d"
  cp ${my-watchdog-bin}/bin/watchdog-tui "$d/watchdog-tui"
  cp ${policy}                            "$d/watchdog-policy.json"
  cp ${./watchdog-install.sh}             "$d/watchdog-install.sh"
  cp "$unitPath"                          "$d/my-watchdog.service"
  chmod +x "$d/watchdog-d" "$d/watchdog-tui" "$d/watchdog-install.sh"

  # The installer refuses to run without this and fails closed on a mismatch.
  # A truncated download is a failure this fleet has already had, and it does
  # not announce itself: the file is present, executable and short.
  ( cd "$d" && sha256sum watchdog-d watchdog-tui watchdog-policy.json my-watchdog.service > SHA256SUMS )

  tar -C "$out" -czf "$out/my-watchdog-dist.tar.gz" my-watchdog
''
