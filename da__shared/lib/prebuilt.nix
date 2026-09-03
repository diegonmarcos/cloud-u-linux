# THE PUBLISHED BUILD, INSTALLED WITHOUT A COMPILER.
#
# Every app in this repo is built once, by one GitHub runner, and consumed by
# machines that must never build: a two-core OCI VM with a 75%-full disk, a
# laptop whose Rust link steps are what the freeze-guard exists for, a phone.
# A flake input alone does not give them that — `home-manager switch` realises
# the derivation, which means the toolchain closure and a compile. So the
# store path has to arrive already built, and this is how.
#
# It never mentions rustPlatform, nodejs or any toolchain. Nix evaluates only
# the outputs asked for, so a machine installing <app>-bin has no compiler
# anywhere in its closure.
#
# WHY IT IS HERE AND NOT COPIED PER APP
# It was copied per app, and then per consumer. my-webserver's fetch lives
# three times outside this repo — ba_flakes_desktop, bb_flakes_termux and
# vm-pilot — each with its own hashes.json to bump by hand, which is four
# places that must agree about one binary. That is the same shape as the unit
# that said `watchdog-d` while the asset said `my-watchdog`, and it ended the
# same way.
#
# hashes.json is the seam: written by the app's ship workflow, committed, so
# an update is a flake.lock bump you can review and roll back rather than a
# rolling download that changes under a machine.
{ lib, stdenv, stdenvNoCC, fetchurl, patchelf, gcc-unwrapped, libgcc }:

# pname   the derivation name
# hashes  path to hashes.json — { tag, version, <system>.<bin> = { asset, hash } }
# patchelf  true for a dynamically linked release binary that expects an FHS
#           interpreter (/lib64/ld-linux-*.so) which a nix store does not have.
#           A static musl build needs none — there is no interpreter to rewrite.
#
#           NOT autoPatchelfHook, and stripping OFF. Both were tried here and
#           the result dumped core on the first run. autoPatchelfHook reaches
#           for stdenv's pinned patchelf, which SIGABRTs ("Assertion
#           !section.empty() failed") replacing a different-length PT_INTERP on
#           a large binary; and stdenv's fixupPhase strips unless told not to,
#           which corrupts a Node SEA's injected blob sections into "no version
#           information available" and undefined symbols. ba_flakes_desktop
#           root-caused both in August 2026 and the knowledge lived only in
#           that module's comments — this is it moved somewhere every app
#           inherits it.
{ pname, hashes, patchelf ? false, meta ? { } }:

let
  pins = builtins.fromJSON (builtins.readFile hashes);
  # autoPatchelfHook needs a real stdenv to find a libc; a static binary is
  # just a file to copy, and stdenvNoCC keeps a compiler out of the closure.
  std = if patchelf then stdenv else stdenvNoCC;
  system = std.hostPlatform.system;
  arch = pins.${system} or (throw "${pname}: no published asset for ${system}");
  repo = "https://github.com/diegonmarcos/cloud-u-linux/releases/download";
  get = bin: fetchurl {
    url = "${repo}/${pins.tag}/${arch.${bin}.asset}";
    inherit (arch.${bin}) hash;
  };
  bins = builtins.attrNames arch;
in
std.mkDerivation {
  inherit pname;
  version = pins.version or "latest";

  dontUnpack = true;
  dontBuild = true;

  # A newer patchelf than the pinned one, invoked explicitly. See above.
  nativeBuildInputs = lib.optionals patchelf [ patchelf ];
  dontStrip = patchelf;
  dontPatchELF = patchelf;

  installPhase = let
    libs = lib.makeLibraryPath [ stdenv.cc.libc gcc-unwrapped.lib libgcc ];
    fix = b: lib.optionalString patchelf ''
      patchelf \
        --set-interpreter "$(cat "$NIX_BINTOOLS/nix-support/dynamic-linker")" \
        --set-rpath "${libs}" \
        $out/bin/${b}
    '';
  in ''
    runHook preInstall
    ${lib.concatMapStringsSep "\n" (b: ''
      install -Dm755 ${get b} $out/bin/${b}
      ${fix b}
    '') bins}
    runHook postInstall
  '';

  meta = { platforms = [ "x86_64-linux" "aarch64-linux" ]; } // meta;
}
