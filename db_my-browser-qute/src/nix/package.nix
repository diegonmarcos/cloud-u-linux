# my-browser-qute — THE package.
#
# Built from the qutebrowser source VENDORED IN THIS REPO (src/browser/, a flat
# snapshot of upstream v3.7.0). There is no patch series any more: every change
# we make lives directly in that tree as ordinary source. What used to be
# patches/0001-my-browser-chrome-bar.patch is now
# src/browser/qutebrowser/mainwindow/mybar.py + two call sites in mainwindow.py;
# nixpkgs' own fix-restart.patch is folded into misc/quitter.py.
#
# We still borrow nixpkgs' qutebrowser DERIVATION (deps, Qt wrapping, pdf.js,
# asciidoc toolchain) via overrideAttrs — that is dependency reuse, not a patch.
# `src` and `patches` are replaced outright, so none of upstream's source or
# patch series survives; only the build recipe does.
#
# Identity is fully rebranded:
#   binary        my-browser-qute        (setup.py gui_scripts)
#   config dir    ~/.config/my-browser-qute      (standarddir.APPNAME)
#   data dir      ~/.local/share/my-browser-qute
#   share dir     $out/share/my-browser-qute     (misc/Makefile)
#   desktop id    org.mybrowser.qute
#   url scheme    mybrowser://  (registered ALONGSIDE qute://, which still works)
#   userscripts   MYBROWSER_* env vars, mirrored from the QUTE_* ones

{ pkgs }:

let
  # nixpkgs' qutebrowser binds pdf.js in a `let` (not an overridable attribute),
  # and we replace postPatch wholesale, so fetch it here. Version + hash lifted
  # from pkgs/applications/networking/browsers/qutebrowser/default.nix.
  pdfjs = pkgs.fetchzip {
    url = "https://github.com/mozilla/pdf.js/releases/download/v4.2.67/pdfjs-4.2.67-dist.zip";
    hash = "sha256-7kfT3+ZwoGqZ5OwkO9h3DIuBFd0v8fRlcufxoBdcy8c=";
    stripRoot = false;
  };
in
pkgs.qutebrowser.overrideAttrs (old: {
  pname = "my-browser-qute";
  version = "3.7.0";
  # buildPythonApplication already fixed `name` from upstream's pname/version at
  # eval time; overrideAttrs on pname/version alone does NOT re-derive it, so the
  # store path would still read qutebrowser-3.4.0. Set it explicitly.
  name = "my-browser-qute-3.7.0";

  # Our vendored tree, not upstream's release tarball.
  src = ../browser;

  # No patch series. Everything is consolidated into src/browser/.
  patches = [];

  # A git checkout (which is what src/browser/ is a snapshot of) does not carry
  # the generated help pages that the release tarball ships, so qute://help
  # would 404. Generate them from doc/*.asciidoc before the build — `asciidoc`
  # is already in the inherited nativeBuildInputs.
  preBuild = (old.preBuild or "") + ''
    ${pkgs.python3.interpreter} scripts/asciidoc2html.py
  '';

  # Upstream's postPatch substitutes the @qutebrowser@ restart placeholder and
  # the /usr data prefix. Ours is named @mybrowserqute@ and the binary moved.
  postPatch = ''
    substituteInPlace qutebrowser/misc/quitter.py \
      --subst-var-by mybrowserqute "$out/bin/my-browser-qute"
    sed -i "s,/usr,$out,g" qutebrowser/utils/standarddir.py
    sed -i "s,/usr/share/pdf.js,${pdfjs},g" qutebrowser/browser/pdfjs.py
  '';

  # Inherited postInstall greps $out/share/qutebrowser/{user,}scripts — which is
  # now $out/share/my-browser-qute/.
  postInstall = ''
    buildPythonPath "$out $propagatedBuildInputs"
    scripts=$(grep -rl python "$out"/share/my-browser-qute/{user,}scripts/ || true)
    for i in $scripts; do
      patchPythonScript "$i"
    done
  '';

  meta = (old.meta or {}) // {
    description = "my-browser-qute — keyboard-driven browser with a native bookmark/plugin bar";
    homepage = "https://github.com/diegonmarcos/cloud-unix";
    mainProgram = "my-browser-qute";
  };
})
