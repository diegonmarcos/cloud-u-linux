# ONE module. Import it from a NixOS configuration or from home-manager; it
# works out which it is in and emits the right shape.
#
# The two are not two products. A NixOS module and a home-manager module are
# both `{ config, options, lib, pkgs }: { options; config }` over different
# option trees — `systemd.services` there, `systemd.user.services` here — so
# the only real difference is the namespace the same service description is
# rendered into. Writing that description twice is exactly the failure this
# app has already had once at a lower level: the units said `watchdog-d`, the
# release assets said `my-watchdog`, and a laptop ran a three-week-old daemon
# through four green deploys because nothing joined them. Two modules would be
# the same mistake with better syntax highlighting.
#
# What genuinely differs is PRIVILEGE, and it is one `if`:
#
#   caps      cap_sys_ptrace/dac_read_search/net_admin are an xattr on an
#             inode; a store path is read-only. NixOS copies the binary into
#             /run/wrappers first (security.wrappers) — the mechanism does not
#             exist on the Ubuntu fleet, where build.sh's sudo setcap remains
#             the answer. Without them per-process io, PSS and the firewall
#             page are blank.
#   uid       /proc/<pid>/io is unreadable across uids, so a user-level sampler
#             shows dashes for every root daemon. The system unit runs as root;
#             the user unit cannot and does not pretend to.
#   /run      RuntimeDirectory= belongs to a system unit. runtime_dir() prefers
#             /run/my-watchdog when it exists.
{ self }:
{ config, options, lib, pkgs, ... }:

let
  cfg = config.services.my-watchdog;

  # home-manager declares home.homeDirectory; NixOS does not. Nothing subtler
  # is needed, and nothing subtler would be readable at 3am.
  isHM = options ? home.homeDirectory;

  pkgFor = system: if cfg.tray then self.packages.${system}.my-watchdog-tray else self.packages.${system}.my-watchdog;

  # THE SERVICE, described once. Both branches below render this; neither
  # invents a field of its own.
  common = {
    Restart = "always";
    RestartSec = 5;
    # A monitor that competes with what it monitors is the problem it exists to
    # report — this fleet has already had a freeze caused by a watchdog that
    # became the load.
    Nice = 10;
    IOSchedulingClass = "idle";
    MemoryMax = cfg.memoryMax;
    # MemoryMax WITHOUT this pushes a leak into swap instead of killing it:
    # an 11M-RSS process sat on 450M of swap and starved the box through io
    # pressure that read as a disk problem. Cap both or cap neither.
    MemorySwapMax = "0";
  };
in
{
  options.services.my-watchdog = {
    enable = lib.mkEnableOption "my-watchdog — the machine sampler and its panel";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgFor pkgs.stdenv.hostPlatform.system;
      defaultText = lib.literalExpression "my-watchdog, or my-watchdog-tray when tray = true";
      description = "The build to install. Both binaries — watchdog-d and watchdog-tui — come from it.";
    };

    tray = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install the tray build. A tray needs a session bus to sit on, which a
        VM has not and a root daemon cannot reach, so the system unit passes
        --no-tray regardless: on NixOS this only decides whether the panel you
        launch yourself carries an icon.
      '';
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "96M";
      description = "MemoryMax for the sampler, paired with MemorySwapMax=0.";
    };

    policy = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = ../configs/watchdog-policy.json;
      description = ''
        The protected-slices document. Installed to
        ~/.config/my-watchdog/watchdog-policy.json under home-manager and to
        /etc/my-watchdog/watchdog-policy.json on NixOS — both are search paths
        in watchdog.rs. One source of truth means every machine resolves the
        same document. null leaves it unmanaged.
      '';
    };

    startWith = lib.mkOption {
      type = lib.types.str;
      default =
        if !isHM then "multi-user.target"
        else if cfg.tray then "graphical-session.target"
        else "default.target";
      defaultText = lib.literalExpression "multi-user.target on NixOS; graphical-session.target with a tray, else default.target";
      description = ''
        What the unit is WantedBy. A headless box has no graphical-session.target,
        and a unit wanted by a target that never activates simply never starts —
        which reads as a broken build rather than a wiring mistake.
      '';
    };
  };

  # A plain `if`, not two mkIfs: the branch that does not apply is never
  # constructed, so home.packages is never mentioned inside a NixOS evaluation
  # and environment.etc is never mentioned inside a home-manager one.
  config = lib.mkIf cfg.enable (
    if isHM then {
      # watchdog-d and watchdog-tui, on PATH, from the generation — which is
      # what makes `watchdog-tui` the CURRENT build rather than whatever a
      # fetch last dropped in ~/.local/bin.
      home.packages = [ cfg.package ];

      xdg.configFile = lib.mkIf (cfg.policy != null) {
        "my-watchdog/watchdog-policy.json".source = cfg.policy;
      };

      systemd.user.services.my-watchdog = {
        Unit = {
          Description = "my-watchdog — machine sampler";
          After = [ cfg.startWith ];
        };
        Service = common // {
          Type = "simple";
          # The store path, not a name in ~/.local/bin. A generation that says
          # what it starts is a generation you can read the answer off.
          ExecStart = "${cfg.package}/bin/watchdog-d" + lib.optionalString (!cfg.tray) " --no-tray";
        };
        Install.WantedBy = [ cfg.startWith ];
      };
    } else {
      environment.systemPackages = [ cfg.package ];

      environment.etc = lib.mkIf (cfg.policy != null) {
        "my-watchdog/watchdog-policy.json".source = cfg.policy;
      };

      # THE ONE THING A HOME-MANAGER SWITCH CANNOT DO. setcap writes an xattr
      # on the inode and the store is read-only, so NixOS copies the binary to
      # /run/wrappers and sets them there. This is why the firewall page and
      # the per-process io columns are populated on a NixOS box and blank on
      # the Ubuntu fleet.
      security.wrappers.watchdog-d = {
        owner = "root";
        group = "root";
        capabilities = "cap_sys_ptrace,cap_dac_read_search,cap_net_admin+ep";
        source = "${cfg.package}/bin/watchdog-d";
      };

      systemd.services.my-watchdog = {
        description = "my-watchdog — machine sampler";
        wantedBy = [ cfg.startWith ];
        after = [ "network.target" ];
        serviceConfig = common // {
          Type = "simple";
          # The wrapper, not the store path: the store copy has no capabilities
          # and would sample exactly as blindly as a user-level daemon.
          ExecStart = "${config.security.wrapperDir}/watchdog-d --no-tray";
          User = "root";
          # /proc/<pid>/io is readable only for your own processes. Root is not
          # a convenience here — it is the difference between a process table
          # with io columns and one full of dashes.
          RuntimeDirectory = "my-watchdog";
          RuntimeDirectoryMode = "0770";
          RuntimeDirectoryPreserve = "yes";
        };
      };
    }
  );
}
