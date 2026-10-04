# home-manager module for my-browser-qute.
#
# Reads four JSON files (settings / search-engines / keybindings / bookmarks)
# and renders them into my-browser-qute's config.py. The JSON files are the SoT
# — edit them, run home-manager switch, the config rewrites itself.
#
# It no longer goes through home-manager's `programs.qutebrowser`: that module
# hard-codes ~/.config/qutebrowser, and my-browser-qute's config dir is
# ~/.config/my-browser-qute (standarddir.APPNAME). The ~40 lines of config.py
# formatting it provided are inlined below instead, so this module owns the
# whole projection and has no upstream-qutebrowser dependency left.
#
# Operator integration (in your home.nix):
#
#     imports = [ inputs.my-browser-qute.homeManagerModules.default ];
#     programs.my-browser = {
#       enable = true;
#       defaultBrowser = true;   # set xdg.mime defaults to my-browser-qute
#     };

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.my-browser;

  # ── config.py formatters ────────────────────────────────────────────────
  # Lifted verbatim (behaviour-wise) from home-manager's
  # modules/programs/qutebrowser.nix. Inlined because that module writes to
  # ~/.config/qutebrowser and we need ~/.config/my-browser-qute.
  formatValue = v:
    if v == null then "None"
    else if builtins.isBool v then (if v then "True" else "False")
    else if builtins.isString v then ''"${v}"''
    else if builtins.isList v then "[${lib.concatStringsSep ", " (map formatValue v)}]"
    else builtins.toString v;

  formatLine = o: n: v:
    if builtins.isAttrs v
    then lib.concatStringsSep "\n" (lib.mapAttrsToList (formatLine "${o}${n}.") v)
    else "${o}${n} = ${formatValue v}";

  # Dict settings (aliases, searchengines) MUST serialize as c.x['k'] = "v" —
  # attribute-style (c.aliases.default-window = ...) is invalid Python for
  # hyphenated keys AND the wrong qutebrowser API.
  formatDictLine = o: n: v: ''${o}['${n}'] = "${v}"'';

  formatKeyBindings = m: b:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (k: c:
      if c == null
      then ''config.unbind("${k}", mode="${m}")''
      else ''config.bind("${k}", "${lib.escape [ ''"'' ] c}", mode="${m}")'') b);

  formatQuickmarks = n: url: "${n} ${url}";

  # Resolve JSON config paths relative to this module's directory.
  configsDir = ../2_configs;

  settings        = builtins.fromJSON (builtins.readFile "${configsDir}/qute-settings.json");
  searchEngines   = builtins.fromJSON (builtins.readFile "${configsDir}/qute-search-engines.json");
  keyBindings     = builtins.fromJSON (builtins.readFile "${configsDir}/qute-keybindings.json");

  # qute-bookmarks.json is the SECTION SoT for the dashboard (see src/dashboard).
  # For qutebrowser's flat quickmarks we flatten only the CURATED inline links —
  # a section's direct "links" → "Section/name", and each folder's "links" →
  # "Section/Folder/name" — all pure-eval-safe. Source-driven sections/folders
  # (history / front / cloud:*) carry no inline links here; they're resolved at
  # generate-time by gen-dashboard.sh, so they live only in the dashboard.
  bookmarks       = builtins.fromJSON (builtins.readFile "${configsDir}/qute-bookmarks.json");
  flatQuickmarks  = lib.foldl' (acc: s:
      let
        direct  = lib.mapAttrs' (n: url: lib.nameValuePair "${s.name}/${n}" url) (s.links or {});
        folders = lib.foldl' (a: f:
            a // lib.mapAttrs' (n: url: lib.nameValuePair "${s.name}/${f.name}/${n}" url) (f.links or {})
          ) {} (s.folders or []);
      in acc // direct // folders
    ) {} (bookmarks.sections or []);

  # "New Default Window" / "Open Saved Tabs" — data-driven from
  # qute-default-window.json's tabs[] ({url, pinned}).
  #
  # NO auto-pinning in these aliases. The `pinned:true` flag is NOT honored
  # here — it needs the session mechanism instead (see below). Two verified
  # reasons the alias-chain approach is impossible:
  #   1. `<N>tab-pin` count-glue is KEYPARSER-ONLY. Through an alias/command
  #      runner it is looked up as a literal command → "1tab-pin: no such
  #      command" (reproduced live). Aliases run through the command parser,
  #      not the key parser.
  #   2. `tab-focus N ;; tab-pin` avoids that, but `open -w` (default_window)
  #      splits the window context — the chained commands don't reliably run
  #      in the newly-opened window ("no tab with index 2", reproduced live).
  # Proper declarative pinned-default-tabs = a qutebrowser session YAML
  # (`:session-load`), which carries per-tab pinned state natively. Tracked in
  # PLAN_qute-master-roadmap.md (Track C). For now these aliases just OPEN the
  # tabs (correct, no errors); pin manually with <Ctrl-p> if wanted.
  dwTabsRaw = (builtins.fromJSON (builtins.readFile "${configsDir}/qute-default-window.json")).tabs or [];
  # Tolerate the old plain-string-url schema too (pinned defaults to false).
  dwTabs = map (t: if builtins.isString t then { url = t; pinned = false; } else t) dwTabsRaw;

  # default_window: first url → new window (open -w), rest → tabs (open -t).
  defaultWindowCmd = lib.concatStringsSep " ;; "
    (lib.imap0 (i: t: (if i == 0 then "open -w " else "open -t ") + t.url) dwTabs);

  # open_saved_tabs: same list, all as tabs in the CURRENT window.
  openSavedTabsCmd = lib.concatStringsSep " ;; " (map (t: "open -t " + t.url) dwTabs);

  # fresh_window (`:` command): a truly EMPTY new window — one about:blank tab,
  # no predefined/saved tabs. Session restore only fires on the very first
  # process start, so `open -w about:blank` in a running instance is inherently
  # fresh. Paired with the desktop-entry action below.
  freshWindowCmd = "open -w about:blank";

  # ── Desktop-entry launch commands (for the taskbar right-click Actions) ──
  # These are `qutebrowser <args>` process invocations (NOT `:` commands): a
  # right-click Action spawns the binary, and qutebrowser's single-instance IPC
  # routes them to the running window. `--target window` forces a NEW window.
  #   Fresh       → one empty about:blank window (no restore).
  #   Saved Tabs  → the qute-default-window.json tab set, opened in a new window.
  savedTabsArgs      = lib.concatStringsSep " " (map (t: t.url) dwTabs);
  freshDesktopExec   = "my-browser-qute --target window about:blank";
  savedTabsDesktopExec = "my-browser-qute --target window ${savedTabsArgs}";

  # "1 Open Last Session Tabs" — restore the auto-saved session (qutebrowser
  # saves `_autosave` on quit when content.auto_save.session is true, which
  # qute-settings.json enables). Distinct from open_saved_tabs (fixed default
  # set): this reopens whatever was actually open last time.
  # `_autosave` is qutebrowser's INTERNAL session name — session-load refuses
  # it without --force ("_autosave is an internal session, use --force to load
  # anyways", reproduced live). Hence the flag.
  lastSessionCmd = "session-load --force _autosave";

  # "Config-shortcuts" — deep-link the dashboard's Shortcuts reference tab. The
  # dashboard JS auto-opens that tab when the URL ends in #shortcuts.
  dashboardHtml = "file:///home/diego/.config/my-browser-qute/qute-bookmarks.html";
  configShortcutsCmd = "open ${dashboardHtml}#shortcuts";

  # ── PLUGIN REGISTRY (qute-plugins.json) — see PLAN_plugins-vaultwarden.md ──
  # A 'plugin' is config|userscript|daemon. Config plugins are runtime-
  # toggleable via :config-cycle (ZERO footprint when off) — this is what
  # keeps the browser minimal while still offering Brave-parity features.
  # From the registry we generate, data-driven:
  #   • default settings for each ENABLED config plugin (registry is the SoT
  #     for those leaves — they are intentionally removed from qute-settings.json),
  #   • `:plugin-toggle-<id>` aliases (live :config-cycle, no rebuild),
  #   • keybindings for config plugins that declare one,
  #   • the `:plugins` / `:plugins-vaultwarden` manager-page aliases.
  plugins    = (builtins.fromJSON (builtins.readFile "${configsDir}/qute-plugins.json")).plugins or [];
  cfgPlugins = lib.filter (p: (p.surface or "") == "config" && (p ? option)) plugins;
  # :config-cycle needs literal true/false/enum tokens, not Nix bools.
  vtok = v: if builtins.isBool v then (if v then "true" else "false") else toString v;
  cycleCmd = p: "config-cycle ${p.option} ${vtok p.on_value} ${vtok p.off_value}";
  pluginSettings = lib.foldl' lib.recursiveUpdate {}
    (map (p: lib.setAttrByPath (lib.splitString "." p.option)
              (if (p.enabled or false) then p.on_value else p.off_value)) cfgPlugins);
  pluginToggleAliases = lib.listToAttrs
    (map (p: lib.nameValuePair "plugin-toggle-${p.id}" (cycleCmd p)) cfgPlugins);
  pluginKeybinds = lib.listToAttrs
    (map (p: lib.nameValuePair p.keybinding (cycleCmd p))
      (lib.filter (p: p ? keybinding) cfgPlugins));
  pluginPageAliases = {
    "plugins"             = "open ${dashboardHtml}#plugins";
    "plugins-vaultwarden" = "open ${dashboardHtml}#plugins-vaultwarden";
  };

  # Vaultwarden integration config (build.json::integrations.vaultwarden_bitwarden_cli).
  # build.json lives at the project root, two levels up from src/nix/.
  buildJson = builtins.fromJSON (builtins.readFile ../../build.json);
  vwCfg = buildJson.integrations.vaultwarden_bitwarden_cli or { enabled = false; };

  # Strip ANY leading-underscore key recursively before passing to
  # qutebrowser — by convention every doc/annotation field in our JSON
  # configs starts with "_" (e.g. _description, _comment, _method_options,
  # _flake_modules_dir_note). qutebrowser would otherwise reject them as
  # unknown settings.
  stripDocs = v:
    if builtins.isAttrs v then
      lib.mapAttrs (_: stripDocs) (lib.filterAttrs
        (n: _: ! (lib.hasPrefix "_" n))
        v)
    else if builtins.isList v then map stripDocs v
    else v;

  cleanSettings      = stripDocs settings;
  cleanSearchEngines = stripDocs searchEngines;
  # qute-keybindings.json is now the enriched SoT (key → { cmd, desc, group }).
  # stripDocs drops the _description / _comment_* keys; project each remaining
  # binding object down to its bare `cmd` string for programs.qutebrowser.keyBindings.
  cleanKeyBindings   = lib.mapAttrs
    (_mode: binds: lib.mapAttrs (_k: v: v.cmd) binds)
    (stripDocs keyBindings);
in
{
  options.programs.my-browser = {
    enable = lib.mkEnableOption "my-browser — qutebrowser daily-driver with daemon integrations";

    package = lib.mkOption {
      type = lib.types.package;
      default = import ./package.nix { inherit pkgs; };
      defaultText = lib.literalExpression "import ./package.nix { inherit pkgs; }";
      description = ''
        Browser package. Defaults to my-browser-qute, built from the vendored
        source in src/browser/ (native bookmark + plugin chrome bar included).
        Set to `pkgs.qutebrowser` to run stock upstream qutebrowser instead —
        note that reverts the config dir to ~/.config/qutebrowser.
      '';
    };

    defaultBrowser = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Set xdg.mime so my-browser-qute handles http(s) links by default.";
    };

    extraSettings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Extra settings merged on top of the JSON-driven config (escape hatch — prefer editing the JSON in src/2_configs/).";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ]
      ++ lib.optionals (vwCfg.enabled or false) [ pkgs.bitwarden-cli pkgs.keyutils ];

    # config.py — rendered here (see the formatters above), written to
    # ~/.config/my-browser-qute/. Assembly order matters: settings, then dict
    # settings (aliases / searchengines), then keybindings, so a later bind can
    # reference an alias defined earlier.
    xdg.configFile."my-browser-qute/config.py".text =
      let
        allSettings = lib.recursiveUpdate
          (lib.recursiveUpdate cleanSettings pluginSettings) cfg.extraSettings;

        # Numeric-prefixed aliases sort to the top of the `:` command completion.
        allAliases = {
          default_window   = defaultWindowCmd;
          open_saved_tabs  = openSavedTabsCmd;
          fresh_window     = freshWindowCmd;        # New Window (Fresh) — empty
          "0-default-tabs"   = defaultWindowCmd;    # "0 Open Default Tabs"
          "1-last-session"   = lastSessionCmd;      # "1 Open Last Session Tabs"
          "config-shortcuts" = configShortcutsCmd;  # Shortcuts reference (,s)
        } // pluginPageAliases     # :plugins, :plugins-vaultwarden (manager page)
          // pluginToggleAliases;  # :plugin-toggle-<id> (live :config-cycle)

        # Ctrl-Shift-N → New Default Window; Ctrl-Shift-T → Open Saved Tabs
        # (same list, as tabs in the current window); Ctrl-Shift-B → Vaultwarden
        # autofill (qute-bitwarden userscript, bundled with the package).
        # ONE merged `normal` set. NB: `//` between two attrsets that BOTH have a
        # `normal` key is SHALLOW — it replaces the whole set, not merges it. The
        # previous form (`{normal=…} // optionalAttrs {normal.<C-S-b>=…}`) silently
        # dropped every other normal bind whenever vaultwarden was enabled. Merge
        # all leaf keys into a single `normal` instead, then recursiveUpdate onto
        # the JSON binds (cleanKeyBindings) which is a proper deep merge.
        allKeyBindings = lib.recursiveUpdate cleanKeyBindings {
          normal = {
            "<Ctrl-Shift-n>" = "default_window";
            "<Ctrl-Shift-t>" = "open_saved_tabs";
            ",pp"            = "plugins";   # open the Plugins manager page
          }
          // pluginKeybinds   # ,pa ,pj ,pd ,pf ,pm — live config-plugin toggles
          // lib.optionalAttrs (vwCfg.enabled or false) {
               "<Ctrl-Shift-b>" = "spawn --userscript qute-bitwarden --totp";
             };
        };
      in lib.concatStringsSep "\n" (
        [ "config.load_autoconfig()" ]
        ++ lib.mapAttrsToList (formatLine "c.") allSettings
        ++ lib.mapAttrsToList (formatDictLine "c.aliases") allAliases
        ++ lib.mapAttrsToList (formatDictLine "c.url.searchengines") cleanSearchEngines
        ++ lib.mapAttrsToList formatKeyBindings allKeyBindings
      );

    xdg.configFile."my-browser-qute/quickmarks".text =
      lib.concatStringsSep "\n" (lib.mapAttrsToList formatQuickmarks flatQuickmarks);

    # `bw config server <url>` is idempotent and carries no secret — safe to
    # run declaratively on every activation. The actual `bw login` (needs the
    # master password) is a ONE-TIME MANUAL step; it cannot be automated
    # here without storing a credential outside sops, which we don't do.
    home.activation.bwVaultwardenServer = lib.mkIf (vwCfg.enabled or false)
      (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        ${pkgs.bitwarden-cli}/bin/bw config server ${lib.escapeShellArg vwCfg.server_url} >/dev/null 2>&1 || true
      '');

    # Bookmark dashboard start page — generated (gen-dashboard.sh) into dist/,
    # committed, installed here. qute-settings.json points url.start_pages +
    # url.default_page at this file.
    xdg.configFile."my-browser-qute/qute-bookmarks.html".source = ../../dist/qute-bookmarks.html;

    # Multi-engine search page — same generator, SoT is qute-search-engines.json
    # (the identical file behind c.url.searchengines). One query box, every
    # engine stacked below it, Enter opens the pick in a new tab.
    xdg.configFile."my-browser-qute/qute-websearch.html".source = ../../dist/qute-websearch.html;

    # Native qutebrowser Bookmarks (the built-in :bookmark-list) — the FULL list
    # (curated + cloud-resolved), generated by gen-dashboard.sh into dist/ so it
    # matches the dashboard exactly. quickmarks above only carry the curated
    # folders (cloud:* can't be resolved in pure eval); this file carries all.
    xdg.configFile."my-browser-qute/bookmarks/urls".source = ../../dist/qute-bookmarks-urls;

    # mybar.json — SoT for the FORK's native chrome bar (mybar.py reads it from
    # the config dir). Generated by gen-dashboard.sh from qute-bookmarks.json +
    # qute-plugins.json. Harmless with stock qutebrowser (it just ignores it).
    xdg.configFile."my-browser-qute/mybar.json".source = ../../dist/mybar.json;

    # Override the upstream qutebrowser desktop entry (same id →
    # ~/.local/share/applications wins over the nix-store copy via XDG_DATA_DIRS
    # precedence) to EXTEND its right-click taskbar Actions. Upstream ships
    # `new-window` + `preferences`; we keep both and add the two session-aware
    # launchers. Data-driven: the Saved-Tabs Exec is built from
    # qute-default-window.json (savedTabsDesktopExec), so editing that JSON
    # rewrites the menu on the next build. Keeps the original id so xdg.mimeApps
    # (below) and any pinned taskbar entry still resolve.
    xdg.desktopEntries."org.mybrowser.qute" = {
      name = "my-browser-qute";
      genericName = "Web Browser";
      exec = "my-browser-qute --untrusted-args %u";
      icon = "my-browser-qute";
      terminal = false;
      categories = [ "Network" "WebBrowser" ];
      mimeType = [
        "text/html" "text/xml" "application/xhtml+xml" "application/xml"
        "application/rdf+xml" "image/gif" "image/webp" "image/jpeg" "image/png"
        "x-scheme-handler/http" "x-scheme-handler/https" "x-scheme-handler/qute"
        "x-scheme-handler/mybrowser"
      ];
      startupNotify = true;
      settings = {
        StartupWMClass = "my-browser-qute";
        Keywords = "Browser";
      };
      actions = {
        "new-window"        = { name = "New Window";               exec = "my-browser-qute"; };
        "new-window-fresh"  = { name = "New Window (Fresh)";       exec = freshDesktopExec; };
        "new-window-saved"  = { name = "New Window (Saved Tabs)";  exec = savedTabsDesktopExec; };
        "preferences"       = { name = "Preferences";             exec = "my-browser-qute mybrowser://settings"; };
      };
    };

    # Default-browser is a DATA-DRIVEN toggle: build.json::browser.default_browser
    # OR the module's defaultBrowser option (either true wins). Flip the JSON to
    # own/disown http(s)/html without touching Nix.
    xdg.mimeApps = lib.mkIf (cfg.defaultBrowser || (buildJson.browser.default_browser or false)) {
      enable = true;
      defaultApplications = {
        "text/html"             = "org.mybrowser.qute.desktop";
        "x-scheme-handler/http"  = "org.mybrowser.qute.desktop";
        "x-scheme-handler/https" = "org.mybrowser.qute.desktop";
        "x-scheme-handler/about" = "org.mybrowser.qute.desktop";
        "x-scheme-handler/unknown" = "org.mybrowser.qute.desktop";
      };
    };
  };
}
