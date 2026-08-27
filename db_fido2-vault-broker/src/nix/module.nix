# NixOS module for fido2-vault-broker.
#
# Importing this module declaratively wires up everything the daemon needs
# at the system level — kernel module load, /dev/uhid permissions + group,
# TPM2 userspace + group, and (optionally) a packaged binary in
# `environment.systemPackages`. The systemd unit itself runs as a USER
# unit (so it can pop notify-send and access $XDG_RUNTIME_DIR), wired up
# by the companion home-manager module at `./home-module.nix`.
#
# The package is supplied via `cfg.package`; a flake exposes
# `nixosModules.default` that defaults this to its own `packages.${system}.default`.
#
# Operator-side, in your host flake:
#
#     imports = [ inputs.fido2-vault-broker.nixosModules.default ];
#     programs.fido2-vault-broker = {
#       enable = true;
#       user   = "diego";
#       enableTpm = true;   # set false if your machine has no TPM2
#     };

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.fido2-vault-broker;
in
{
  options.programs.fido2-vault-broker = {
    enable = lib.mkEnableOption "fido2-vault-broker — virtual FIDO2 authenticator backed by Vaultwarden";

    user = lib.mkOption {
      type = lib.types.str;
      description = "Login user that will run the daemon and own /dev/uhid + /dev/tpmrm0 access via group membership.";
      example = "diego";
    };

    enableTpm = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable security.tpm2 (creates the `tss` group + udev rule for /dev/tpmrm0). Disable on machines with no TPM2.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      description = "The fido2-vault-broker package (binary + udev rule). Defaulted by the flake to `packages.${pkgs.system}.default`.";
    };

    installPackage = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the binary into environment.systemPackages so it's on PATH for all users.";
    };
  };

  config = lib.mkIf cfg.enable {
    # 1. Load the stock mainline `uhid` kernel driver at boot — no patches,
    #    no recompile, just `modprobe uhid` on activation. The driver is
    #    already in your kernel as a loadable module (CONFIG_UHID=m).
    boot.kernelModules = [ "uhid" ];

    # 2. /dev/uhid defaults to 0600 root:root. The package ships its udev
    #    rule at $out/lib/udev/rules.d/70-fido2-vault-broker.rules; pulling
    #    the package into services.udev.packages installs it declaratively
    #    (no inline rule strings to drift from the daemon's source).
    services.udev.packages = [ cfg.package ];

    # 3. Group definition — `tss` is created by security.tpm2 below when
    #    enableTpm is true; `uhid` is ours.
    users.groups.uhid = {};

    # 4. Add cfg.user to both groups (mkAfter so we don't clobber other modules
    #    that also extend extraGroups for the same user).
    users.users.${cfg.user}.extraGroups = lib.mkAfter (
      [ "uhid" ] ++ lib.optional cfg.enableTpm "tss"
    );

    # 5. TPM2 userspace + /dev/tpmrm0 permissions via the upstream NixOS
    #    module. `tctiEnvironment` exports TCTI=device:/dev/tpmrm0 so
    #    tss-esapi auto-finds the device without our daemon hardcoding it.
    security.tpm2 = lib.mkIf cfg.enableTpm {
      enable = true;
      pkcs11.enable = false;       # we don't use PKCS#11
      tctiEnvironment.enable = true;
    };

    # 6. Optionally place the binary on PATH system-wide.
    environment.systemPackages = lib.mkIf cfg.installPackage [ cfg.package ];

    # 7. Companion assertion — fail the build with a clear message if the
    #    operator forgot to set `user`.
    assertions = [{
      assertion = cfg.user != "";
      message = "programs.fido2-vault-broker.user must be set (the user that owns the daemon's group membership)";
    }];
  };
}
