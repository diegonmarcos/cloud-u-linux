# THE SAME APP, WITHOUT A COMPILER.
#
# A `home-manager switch` that realises the source derivation pulls a ~1.5 GB
# rustc closure onto a VM and compiles Rust on two cores. On oci-apps that disk
# is already at 74.9% and this fleet has been frozen by a monitor that became
# the load — so for every consumer that is not the builder, the store path has
# to arrive already built.
#
# This derivation therefore never mentions rustPlatform. Nix evaluates only the
# outputs you ask for, so a machine that installs `c3-watchdog-bin` has no
# compiler anywhere in its closure. That is the whole reason one flake can
# serve both the builder and the fleet.
#
# The assets are the STATIC MUSL pair, which is why there is no autoPatchelfHook
# here and da_my-ai's equivalent needs one: a static binary has no interpreter
# to rewrite and runs on any Linux of its architecture — NixOS, Ubuntu, a
# rescue initramfs.
#
# hashes.json is written by ship-c3-watchdog.yml and committed. It is the seam
# between the builder and everyone else: an update becomes a flake.lock bump
# you can review and roll back, instead of a rolling download that changes
# under a machine and leaves it running a three-week-old binary through four
# green deploys.
{ lib, stdenvNoCC, fetchurl }:

let
  pins = builtins.fromJSON (builtins.readFile ./hashes.json);
  system = stdenvNoCC.hostPlatform.system;
  arch = pins.${system} or (throw "c3-watchdog: no published asset for ${system}");
  url = a: "https://github.com/diegonmarcos/cloud-u-linux/releases/download/${pins.tag}/${a}";
  get = bin: fetchurl { url = url arch.${bin}.asset; inherit (arch.${bin}) hash; };
in
stdenvNoCC.mkDerivation {
  pname = "c3-watchdog-bin";
  version = pins.version;

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 ${get "c3-watchdog-d"}   $out/bin/c3-watchdog-d
    install -Dm755 ${get "c3-watchdog-tui"} $out/bin/c3-watchdog-tui
    runHook postInstall
  '';

  meta = with lib; {
    description = "Machine sampler and TUI panel — the published static build, not compiled here";
    homepage = "https://github.com/diegonmarcos/cloud-u-linux";
    license = licenses.mit;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "c3-watchdog-tui";
  };
}
