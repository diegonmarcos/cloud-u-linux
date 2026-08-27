# my-browser (qute) — the FORK package.
#
# Upstream qutebrowser (from nixpkgs) with our patch series applied. The only
# patch today adds a native, data-driven bookmark + plugin chrome bar
# (qutebrowser/mainwindow/mybar.py + two hooks in mainwindow.py) — see
# patches/0001-my-browser-chrome-bar.patch. qutebrowser is pure Python + PyQt6,
# so this is a cheap `overrideAttrs` rebuild, not a Qt compile.
#
# Consumed by: home-module.nix (programs.my-browser.package default) and the
# flake's packages.<system>.my-browser output (what the release ships).
#
# Keep `pname`/binary as `qutebrowser` so the .desktop file, config dir
# (~/.config/qutebrowser), and every `spawn`/userscript path stay unchanged —
# this is a patched qutebrowser, not a rename of the binary. The BRAND is
# my-browser; the on-disk identity stays qutebrowser for drop-in compatibility.

{ pkgs }:

pkgs.qutebrowser.overrideAttrs (old: {
  patches = (old.patches or []) ++ [
    ./patches/0001-my-browser-chrome-bar.patch
  ];
})
