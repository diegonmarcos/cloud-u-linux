# THE TARBALL A MACHINE WITH NO NIX INSTALLS FROM.
#
# It carries the published static binaries, the policy document, the shell
# installer — and a my-watchdog.service that NIX RENDERED from
# da__shared/lib/service.nix, the same expression the NixOS and home-manager modules
# render into their own namespaces.
#
# That last file is the point of this derivation existing at all. A tarball
# could have shipped a hand-written unit; every earlier version of this app
# did, in three separate places, and they disagreed about the binary's own
# name until a laptop ran a three-week-old daemon through four successful
# deploys. `serviceConfig` on NixOS and `[Service]` in a file are the same
# keys, so generating one from the other needs no translation layer and leaves
# nowhere for them to drift.
{ lib, runCommand, my-watchdog-bin, policy, mkService }:

let
  # THREE UNITS, ONE [Service]. The deployments genuinely differ — a Debian box
  # gets a system unit, a desktop gets a user unit that follows the session,
  # and a headless login gets a user unit that does not — but what the sampler
  # IS does not change with any of that, so only the [Unit] and [Install]
  # sections vary here.
  #
  # The two user units used to be checked-in files next to build.sh, and they
  # had already drifted from this expression: RestartSec 3 against 5, Nice 5
  # against 10, and no MemoryMax or MemorySwapMax at all — so the desktop ran
  # the one flavour with no memory ceiling, which is the shape of the leak that
  # starved gcp-proxy for a day. Two descriptions of one service is the exact
  # failure this whole layout exists to prevent, and it had grown back inside
  # the reference implementation.
  mkUnit = { desc, exec, after, wantedBy, partOf ? null }:
    lib.generators.toINI { } {
      Unit = { Description = desc; After = after; }
        // lib.optionalAttrs (partOf != null) { PartOf = partOf; };
      Service = mkService { inherit exec; };
      Install = { WantedBy = wantedBy; };
    };

  # The system unit install.sh places, for a machine with no nix.
  unit = mkUnit {
    desc = "my-watchdog — machine sampler";
    exec = "@BIN@/watchdog-d --no-tray";
    after = "network.target";
    wantedBy = "multi-user.target";
  };

  # A desktop session's own copy: the tray needs a session bus, so it follows
  # the session and stops with it rather than restarting forever against a bus
  # that is gone.
  unitUser = mkUnit {
    desc = "my-watchdog — machine sampler and guarded kill mailbox";
    exec = "%h/.local/bin/watchdog-d";
    after = "graphical-session.target";
    wantedBy = "graphical-session.target";
    partOf = "graphical-session.target";
  };

  # And for a login with no graphical session — a unit WantedBy a target that
  # never activates simply never starts, which reads as a broken build.
  unitUserHeadless = mkUnit {
    desc = "my-watchdog — machine sampler (headless)";
    exec = "%h/.local/bin/watchdog-d --no-tray";
    after = "network.target";
    wantedBy = "default.target";
  };
in
runCommand "my-watchdog-dist"
  { inherit unit unitUser unitUserHeadless; passAsFile = [ "unit" "unitUser" "unitUserHeadless" ]; } ''
  d="$out/my-watchdog"
  mkdir -p "$d"
  cp ${my-watchdog-bin}/bin/watchdog-d   "$d/watchdog-d"
  cp ${my-watchdog-bin}/bin/watchdog-tui "$d/watchdog-tui"
  cp ${policy}                            "$d/watchdog-policy.json"
  cp ${./watchdog-install.sh}             "$d/watchdog-install.sh"
  cp "$unitPath"                          "$d/my-watchdog.service"
  # Fetched by build.sh on a machine that HAS the repo, so build.sh install
  # stops carrying its own idea of what the unit says.
  cp "$unitUserPath"                      "$d/user-my-watchdog.service"
  cp "$unitUserHeadlessPath"              "$d/user-my-watchdog-headless.service"
  chmod +x "$d/watchdog-d" "$d/watchdog-tui" "$d/watchdog-install.sh"

  # The installer refuses to run without this and fails closed on a mismatch.
  # A truncated download is a failure this fleet has already had, and it does
  # not announce itself: the file is present, executable and short.
  ( cd "$d" && sha256sum watchdog-d watchdog-tui watchdog-policy.json my-watchdog.service > SHA256SUMS )

  tar -C "$out" -czf "$out/my-watchdog-dist.tar.gz" my-watchdog
''
