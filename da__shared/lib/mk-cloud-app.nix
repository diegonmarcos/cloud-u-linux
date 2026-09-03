# mkCloudApp — the install story every app in this repo shares, as a function.
#
# Give it what differs (a name, its binaries, whether it has a daemon and what
# that daemon runs) and it returns what does not: the prebuilt package, the
# module that installs into NixOS *and* home-manager, and the tarball for a
# machine with no nix.
#
#   mkCloudApp {
#     name    = "my-watchdog";                 # the systemd unit and the option path
#     bins    = { watchdog-d = "my-watchdog-@arch@"; watchdog-tui = "my-watchdog-tui-@arch@"; };
#     daemon  = "watchdog-d";                  # null for an app with no service
#     args    = "--no-tray";                   # what the SYSTEM unit passes
#     hashes  = ./nix/hashes.json;             # written by this app's ship workflow
#     policy  = ./configs/watchdog-policy.json;# optional, installed to the right place per tree
#     source  = { build = self.packages.…; tray = self.packages.…; };  # optional source builds
#   }
#
# WHY A GENERATOR RATHER THAN FOUR COPIES
# The apps differ in toolchain — Rust, Rust+Tauri, a Node SEA, plain shell —
# and not at all in how a machine acquires and runs them. Copying this file per
# app would put the same description in four places, which is precisely the
# failure mode both of this repo's recent outages had in common.
{ name, bins, daemon ? null, args ? "", hashes, policy ? null, source ? { }
, description ? name, capabilities ? null, memoryMax ? "96M" }:

{ self }:
{ config, options, lib, pkgs, ... }:

let
  cfg = config.services.${name};

  # home-manager declares home.homeDirectory; NixOS does not. Nothing subtler
  # is needed, and nothing subtler would be readable at 3am.
  isHM = options ? home.homeDirectory;
  system = pkgs.stdenv.hostPlatform.system;

  service = exec: import ./service.nix { inherit exec; inherit (cfg) memoryMax; };
in
{
  options.services.${name} = {
    enable = lib.mkEnableOption description;

    source = lib.mkOption {
      type = lib.types.enum ([ "prebuilt" ] ++ lib.attrNames source);
      default = "prebuilt";
      description = ''
        Where the binaries come from. "prebuilt" fetches the published static
        assets named in this app's hashes.json — no compiler enters the
        closure, which is what lets a two-core VM run this at all. Any other
        value builds from source and belongs to the builder and to a developer.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = if cfg.source == "prebuilt" then self.packages.${system}."${name}-bin" else source.${cfg.source}.${system};
      defaultText = lib.literalExpression "the prebuilt package, or the source build named by `source`";
      description = "The build to install. Every binary this app ships comes from it.";
    };

    args = lib.mkOption {
      type = lib.types.str;
      default = args;
      description = ''
        What the unit passes the daemon. A deployment choice, not a property of
        the app: the desktop wants a port and a root, a VM wants the mesh
        address it may bind, and a sampler wants --no-tray. systemd specifiers
        such as %h are valid here.
      '';
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = memoryMax;
      description = ''
        MemoryMax, paired with MemorySwapMax=0 — capping one without the other
        pushes a leak into swap instead of killing it, which starved gcp-proxy
        for a day through io pressure that read as a disk problem.

        The default comes from the APP, not from this library: 96M suits a
        sampler written in std+libc and would OOM-kill a Node runtime whose
        baseline is most of it. An app that does not say gets the careful
        number, and a consumer can still raise it.
      '';
    };

    startWith = lib.mkOption {
      type = lib.types.str;
      default = if isHM then "default.target" else "multi-user.target";
      description = ''
        What the unit is WantedBy. A headless box has no graphical-session.target,
        and a unit wanted by a target that never activates simply never starts —
        which reads as a broken build rather than a wiring mistake.
      '';
    };
  } // lib.optionalAttrs (policy != null) {
    policy = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = policy;
      description = "Configuration document, installed where this app looks for it. null leaves it unmanaged.";
    };
  };

  # A plain `if`, not two mkIfs: the branch that does not apply is never
  # constructed, so home.packages is never mentioned inside a NixOS evaluation
  # and environment.etc is never mentioned inside a home-manager one.
  config = lib.mkIf cfg.enable (
    if isHM then lib.mkMerge [
      { home.packages = [ cfg.package ]; }
      (lib.mkIf (policy != null && cfg.policy != null) {
        xdg.configFile."${name}/${baseNameOf policy}".source = cfg.policy;
      })
      (lib.mkIf (daemon != null) {
        systemd.user.services.${name} = {
          Unit = { Description = description; After = [ cfg.startWith ]; };
          # The store path, not a name in ~/.local/bin. A generation that says
          # what it starts is a generation you can read the answer off.
          Service = service "${cfg.package}/bin/${daemon}${lib.optionalString (cfg.args != "") " ${cfg.args}"}";
          Install.WantedBy = [ cfg.startWith ];
        };
      })
    ]
    else lib.mkMerge [
      { environment.systemPackages = [ cfg.package ]; }
      (lib.mkIf (policy != null && cfg.policy != null) {
        environment.etc."${name}/${baseNameOf policy}".source = cfg.policy;
      })
      # THE ONE THING A HOME-MANAGER SWITCH CANNOT DO. setcap writes an xattr
      # on the inode and the store is read-only, so NixOS copies the binary to
      # /run/wrappers and sets them there. On the Ubuntu fleet this has no
      # equivalent, and the shell installer's setcap stays the answer.
      (lib.mkIf (capabilities != null && daemon != null) {
        security.wrappers.${daemon} = {
          owner = "root"; group = "root";
          inherit capabilities;
          source = "${cfg.package}/bin/${daemon}";
        };
      })
      (lib.mkIf (daemon != null) {
        systemd.services.${name} = {
          inherit description;
          wantedBy = [ cfg.startWith ];
          after = [ "network.target" ];
          # The wrapper when there is one: the store copy has no capabilities
          # and would sample exactly as blindly as a user-level daemon.
          serviceConfig = service (
            (if capabilities != null then "${config.security.wrapperDir}/${daemon}" else "${cfg.package}/bin/${daemon}")
            + lib.optionalString (cfg.args != "") " ${cfg.args}"
          ) // {
            User = "root";
            RuntimeDirectory = name;
            RuntimeDirectoryMode = "0770";
            RuntimeDirectoryPreserve = "yes";
          };
        };
      })
    ]
  );
}
