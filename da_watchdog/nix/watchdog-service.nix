# THE SERVICE, described once, in the only place that describes it.
#
# Three installers render this: nix/watchdog-install.nix splices it into
# systemd.services on NixOS and systemd.user.services under home-manager, and
# the dist tarball ships it through lib.generators.toINI as a plain
# my-watchdog.service that nix/watchdog-install.sh drops on a Debian box.
#
# It is a separate file for one reason: three renderings of one description is
# a guarantee, three descriptions that happen to agree is a coincidence, and
# this app has already paid for the difference. Its units said `watchdog-d`
# while its release assets said `my-watchdog`, so a laptop ran a binary from
# three weeks earlier through four successful deploys with nothing to notice.
# A file that no installer may fork is what makes that unrepeatable.
#
# systemd's own INI keys, verbatim: what goes in serviceConfig on NixOS is
# what goes in [Service] in a file, so a translation layer here would only be
# somewhere else for the two to drift.
{ exec, memoryMax ? "96M" }:

{
  Type = "simple";
  ExecStart = exec;
  Restart = "always";
  RestartSec = 5;

  # A monitor that competes with what it monitors is the problem it exists to
  # report — this fleet has already had a freeze caused by a watchdog that
  # became the load.
  Nice = 10;
  IOSchedulingClass = "idle";

  MemoryMax = memoryMax;
  # MemoryMax WITHOUT this pushes a leak into swap instead of killing it: an
  # 11M-RSS fluent-bit sat on 450M of swap and starved gcp-proxy through io
  # pressure that read as a disk problem for a day. Cap both or cap neither.
  MemorySwapMax = "0";
}
