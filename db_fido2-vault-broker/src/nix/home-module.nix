# home-manager module for fido2-vault-broker.
#
# Companion to nix/module.nix (system side). This module owns the
# user-session systemd unit so notify-send can pop in the user's seat
# session and $XDG_RUNTIME_DIR is available for the socket-style stuff.
#
# Operator-side, in your home.nix:
#
#     imports = [ inputs.fido2-vault-broker.homeManagerModules.default ];
#     programs.fido2-vault-broker = {
#       enable = true;
#       autostart = true;   # systemctl --user enable on activation
#     };

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.fido2-vault-broker;
in
{
  options.programs.fido2-vault-broker = {
    enable = lib.mkEnableOption "fido2-vault-broker user-session daemon";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The fido2-vault-broker package. Defaulted by the flake.";
    };

    autostart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "If true, the user unit is wantedBy default.target — systemctl --user enable on activation.";
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      description = "RUST_LOG passed to the daemon. Use `debug` while diagnosing.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Binary on the user's PATH (so `fido2-vault-broker seal` etc. work
    # from any shell without the system-package install path).
    home.packages = [ cfg.package ];

    systemd.user.services.fido2-vault-broker = {
      Unit = {
        Description = "FIDO2 vault broker — virtual authenticator backed by Vaultwarden";
        After = [ "graphical-session.target" ];
        # ConditionPathExists=/dev/uhid is intentionally NOT set: the unit
        # logs and exits cleanly if /dev/uhid isn't present yet (e.g.
        # waiting on udev). Restart=on-failure picks it up.
      };

      Service = {
        # Type=simple: daemon does NOT call sd_notify(READY=1).  Adding the
        # sd-notify wiring is tracked but out of scope for B.7+B.8.  Until
        # then, simple is the honest match for a long-running tokio future.
        Type = "simple";
        ExecStart = "${cfg.package}/bin/fido2-vault-broker run";
        Restart = "on-failure";
        RestartSec = 5;
        # No MemoryMax (2026-08-07): a hard per-service cap outside the global
        # PSI watchdog (aa_desk-usr.../cloud-data-system-protection.json) is a
        # spurious-kill risk with no upside — that watchdog is the sole kill
        # authority now.
        NoNewPrivileges = true;
        Environment = "RUST_LOG=${cfg.logLevel}";
      };

      Install = lib.mkIf cfg.autostart {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
