# THE SERVICE, described once, for every app in this repo that has one.
#
# Three installers render it: mkCloudApp splices it into systemd.services on
# NixOS and into systemd.user.services under home-manager, and the dist tarball
# ships it through lib.generators.toINI as a plain .service file that
# <name>-install.sh drops on a Debian box.
#
# Three renderings of one description is a guarantee; three descriptions that
# happen to agree is a coincidence, and this repo has already paid for the
# difference. my-watchdog's units said `watchdog-d` while its release assets
# said `my-watchdog`, so a laptop ran a binary from three weeks earlier through
# four successful deploys with nothing to notice. A file that no installer may
# fork is what makes that unrepeatable.
#
# The defaults are the fleet's hard-won ones and an app overrides only what it
# must: a monitor that competes with what it monitors, and a MemoryMax without
# a MemorySwapMax, have each taken this fleet down once.
#
# systemd's own INI keys, verbatim: what goes in serviceConfig on NixOS is
# what goes in [Service] in a file, so a translation layer here would only be
# somewhere else for the two to drift.
{ exec, memoryMax ? "96M", extra ? { } }:

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
} // extra
