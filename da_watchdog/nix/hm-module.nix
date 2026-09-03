# The home-manager half of this flake: what to RUN, beside what to build.
#
# The package alone was never the missing piece. Every consumer of this app has
# had to re-describe how it runs — vm-pilot's my-stack.nix retypes the unit as
# a heredoc, my-konsole's build.sh writes a launcher, build.sh install copies a
# .service by hand — and because those three descriptions were written apart
# they drifted apart: the units say `watchdog-d`, the release assets say
# `my-watchdog`, and a laptop ran a binary from three weeks earlier through
# four green deploys because no one owner joined the two.
#
# This module is that owner. Import it and `home-manager switch` installs the
# daemon, the panel and the unit from one store path, with the name in the
# ExecStart being the same file the profile puts on PATH — a pair that cannot
# drift because it is one expression.
{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.my-watchdog;
in
{
  options.services.my-watchdog = {
    enable = lib.mkEnableOption ''
      my-watchdog — the machine sampler and its panel.

      One caveat, and it is the only thing build.sh does that a generation
      cannot: file capabilities. cap_sys_ptrace, cap_dac_read_search and
      cap_net_admin are an xattr on the inode, and a store path is read-only,
      so per-process io, PSS and the firewall page stay blank under this module
      until something privileged grants them. On NixOS that something is
      security.wrappers, at the system level, not here
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default =
        if cfg.tray
        then self.packages.${pkgs.stdenv.hostPlatform.system}.my-watchdog-tray
        else self.packages.${pkgs.stdenv.hostPlatform.system}.my-watchdog;
      defaultText = lib.literalExpression "my-watchdog, or my-watchdog-tray when tray = true";
      description = "The build to install. Both binaries — watchdog-d and watchdog-tui — come from it.";
    };

    # A tray needs a session bus to sit on. A VM has neither, and linking ksni
    # into the fleet build would carry a UI no server ever draws, so the tray
    # is a different derivation rather than a runtime flag on one.
    tray = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install the tray build and let the daemon draw an icon. False gives the
        headless sampler and passes --no-tray, which is what a server wants: a
        unit that tries to reach a bus that is not there restarts forever.
      '';
    };

    startWith = lib.mkOption {
      type = lib.types.str;
      default = if cfg.tray then "graphical-session.target" else "default.target";
      defaultText = lib.literalExpression "graphical-session.target with a tray, default.target without";
      description = ''
        What the unit is WantedBy. A headless box has no graphical-session.target,
        and a unit wanted by a target that never activates simply never starts —
        which reads as a broken build rather than a wiring mistake.
      '';
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "96M";
      description = "MemoryMax for the sampler. A monitor that competes with what it monitors is the problem it exists to report.";
    };

    policy = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = ../configs/watchdog-policy.json;
      description = ''
        The protected-slices document, installed to
        ~/.config/my-watchdog/watchdog-policy.json. One source of truth means
        every machine resolves the same document. null leaves it unmanaged.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # watchdog-d and watchdog-tui, on PATH, from the generation. This is what
    # makes `watchdog-tui` the CURRENT build rather than whatever a fetch last
    # dropped in ~/.local/bin.
    home.packages = [ cfg.package ];

    xdg.configFile = lib.mkIf (cfg.policy != null) {
      "my-watchdog/watchdog-policy.json".source = cfg.policy;
    };

    systemd.user.services.my-watchdog = {
      Unit = {
        Description = "my-watchdog — machine sampler";
        After = [ cfg.startWith ];
      };
      Service = {
        Type = "simple";
        # The store path, not a name in ~/.local/bin. A generation that says
        # what it starts is a generation you can read the answer off.
        ExecStart = "${cfg.package}/bin/watchdog-d" + lib.optionalString (!cfg.tray) " --no-tray";
        Restart = "always";
        RestartSec = 5;
        Nice = 10;
        IOSchedulingClass = "idle";
        MemoryMax = cfg.memoryMax;
      };
      Install.WantedBy = [ cfg.startWith ];
    };

  };
}
