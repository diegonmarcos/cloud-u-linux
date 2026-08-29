# home-manager module for my-browser-rust-chromium.
#
# Unlike my-browser-qute (which renders JSON into a generated config.py),
# this browser's shell already bakes 2_configs/*.json into shell/data.js at
# CI build time (build.sh: _shell_data, jq -f shell-data.jq) — the tarball
# ships that baked file. This module's job is just the declarative install
# (package.nix's bundle) plus a live copy of the same *.json under
# ~/.config/, so an operator inspecting/diffing config on the desktop has one
# canonical place to look, matching every other db_my-browser-* app's layout.
#
# Operator integration (in your home.nix):
#
#     imports = [ inputs.my-browser-rust-chromium.homeManagerModules.default ];
#     programs.my-browser-rust-chromium = {
#       enable = true;
#       defaultBrowser = false;
#     };

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.my-browser-rust-chromium;
  name = "my-browser-rust-chromium";

  configsDir = ../2_configs;

  # Every *.json in 2_configs/ is the source of truth CI bakes into
  # shell/data.js (see shell-data.jq); mirror them verbatim into
  # ~/.config/${name}/ for inspection/diffing. Not re-parsed here — no
  # projection logic to duplicate, unlike qute's config.py rendering.
  jsonConfigs = [
    "default-window.json"
    "keybindings.json"
    "mybar.json"
    "plugins.json"
    "search-engines.json"
    "settings.json"
  ];
in
{
  options.programs.my-browser-rust-chromium = {
    enable = lib.mkEnableOption "my-browser-rust-chromium — Rust front-end + Chromium (CEF) backend browser";

    package = lib.mkOption {
      type = lib.types.package;
      default = import ./package.nix { inherit pkgs; };
      defaultText = lib.literalExpression "import ./package.nix { inherit pkgs; }";
      description = ''
        Browser package. Wraps CI's prebuilt release tarball (see
        package.nix — no CEF/Chromium build happens in Nix).
      '';
    };

    defaultBrowser = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Set xdg.mime so ${name} handles http(s) links by default.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    # Mirror 2_configs/*.json into ~/.config/${name}/ — SoT stays the repo,
    # this is a read-only reflection for the desktop.
    xdg.configFile = lib.listToAttrs (map (f: lib.nameValuePair
      "${name}/${f}"
      { source = "${configsDir}/${f}"; }
    ) jsonConfigs);

    # Desktop entry — same id/StartupWMClass the package's own
    # share/applications/${name}.desktop carries (2_configs/${name}.desktop),
    # declared again here so home-manager can own xdg.mimeApps wiring.
    # Note: db_my-browser-qute uses StartupWMClass = "my-browser-qute"; the
    # matching value here is "my-browser-rust-chromium" so window-manager
    # grouping/pinning works for this app too.
    xdg.desktopEntries."${name}" = {
      name = "My Browser (Rust/Chromium)";
      genericName = "Web Browser";
      comment = "Rust + real-Chromium (CEF) browser with a genuine Chrome TLS fingerprint";
      exec = "${cfg.package}/bin/${name} %U";
      icon = name;
      terminal = false;
      categories = [ "Network" "WebBrowser" ];
      mimeType = [
        "text/html" "text/xml" "application/xhtml+xml"
        "x-scheme-handler/http" "x-scheme-handler/https"
      ];
      startupNotify = true;
      settings = {
        StartupWMClass = name;
      };
    };

    xdg.mimeApps = lib.mkIf cfg.defaultBrowser {
      enable = true;
      defaultApplications = {
        "text/html"              = "${name}.desktop";
        "x-scheme-handler/http"  = "${name}.desktop";
        "x-scheme-handler/https" = "${name}.desktop";
      };
    };
  };
}
